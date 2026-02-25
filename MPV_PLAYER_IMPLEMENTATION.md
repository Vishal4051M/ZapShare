# MPV Player Codebase Documentation

This document contains the core implementation of the native MPV player integration in ZapShare for Windows, which features a custom Direct3D child window rendering architecture to achieve zero-copy video playback with a Flutter overlay UI.

## 1. Native Window Management (C++)

Implements a native WIN32 child window that hosts the MPV rendering surface. Key features:
- Creates a `HWND_BOTTOM` child window to sit *behind* the Flutter window.
- Manages the MPV process and IPC communication.
- Handles resizing and Z-order management to prevent flickering.

### `windows/runner/mpv_child_window.cpp`

```cpp
#include "mpv_child_window.h"
#include <sstream>
#include <thread>
#include <atomic>
#include <mutex>
#include <iostream>

// ═══════════════════════════════════════════════════════════════════════════
// MpvChildWindow Implementation
// ═══════════════════════════════════════════════════════════════════════════

const wchar_t MpvChildWindow::kWindowClassName[] = L"MPV_CHILD_WINDOW";

MpvChildWindow::MpvChildWindow() = default;

MpvChildWindow::~MpvChildWindow() {
  Destroy();
}

int64_t MpvChildWindow::CreateNativeWindow(HWND parent, int x, int y, int width, int height) {
  std::cout << "[MpvChildWindow] Creating native window (STATIC)" << std::endl;
  parent_hwnd_ = parent;

  // Use system STATIC class for maximum stability
  // CRITICAL: WS_CLIPSIBLINGS | WS_CLIPCHILDREN prevents rendering conflicts
  hwnd_ = CreateWindowExW(
    0,
    L"STATIC",
    L"",
    WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
    x, y, width, height,
    parent,
    nullptr,
    GetModuleHandle(nullptr),
    nullptr
  );

  if (!hwnd_) {
    std::cerr << "[MpvChildWindow] Failed to create window: " << GetLastError() << std::endl;
    return 0;
  }

  // Show and update window
  ShowWindow(hwnd_, SW_SHOW);
  UpdateWindow(hwnd_);

  // CRITICAL: Push window to bottom immediately
  SetWindowPos(hwnd_, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  
  // CRITICAL: Delay before subsequent operations to allow window system to stabilize
  Sleep(50); 

  return reinterpret_cast<int64_t>(hwnd_);
}

bool MpvChildWindow::Resize(int x, int y, int width, int height) {
  if (!hwnd_) return false;

  // Scale coordinates to physical pixels for high-DPI displays
  double scale = 1.0;
  UINT dpi = GetDpiForWindow(hwnd_);
  if (dpi > 0) {
      scale = static_cast<double>(dpi) / 96.0;
  }

  int px = static_cast<int>(x * scale);
  int py = static_cast<int>(y * scale);
  int pw = static_cast<int>(width * scale);
  int ph = static_cast<int>(height * scale);

  // CRITICAL: Force MPV window to BOTTOM of Z-order.
  // This allows Flutter to draw controls *over* the MPV window (if parent clipping allows).
  // We use HWND_BOTTOM to prevent the child window from occluding the Flutter UI.
  if (!SetWindowPos(hwnd_, HWND_BOTTOM, px, py, pw, ph, SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
    return false;
  }
  return true;
}

// ... helper methods for process management ...
```

## 2. Flutter Native Integration (Dart)

The Flutter side manages the "hole" in the generic widget tree where the native window shows through.

### `lib/Screens/shared/native_mpv_video_widget.dart`

```dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'native_mpv_player.dart';

/// Professional video player with native MPV child window
/// Provides Flutter UI overlay on top of native rendering
class NativeMpvVideoPlayer extends StatefulWidget {
  final String? mpvPath;
  final VoidCallback? onReady;

  const NativeMpvVideoPlayer({super.key, this.mpvPath, this.onReady});

  @override
  State<NativeMpvVideoPlayer> createState() => NativeMpvVideoPlayerState();
}

class NativeMpvVideoPlayerState extends State<NativeMpvVideoPlayer> {
  late NativeMpvPlayer _player;
  bool _isReady = false;
  bool _isPlaying = false;
  // ... other state variables ...

  // Window dimensions (updated on layout)
  Rect _windowRect = Rect.zero;

  @override
  void initState() {
    super.initState();
    _player = NativeMpvPlayer();
    _setupListeners();
  }

  Future<void> initialize() async {
    if (_isReady) return;
    final mpvPath = widget.mpvPath ?? await _findMpvExecutable();

    // Wait for first layout to get window dimensions
    await Future.delayed(const Duration(milliseconds: 100));

    if (_windowRect == Rect.zero) {
      throw Exception('Window dimensions not available. Call after build.');
    }

    await _player.initialize(
      mpvPath: mpvPath,
      x: _windowRect.left.toInt(),
      y: _windowRect.top.toInt(),
      width: _windowRect.width.toInt(),
      height: _windowRect.height.toInt(),
    );

    setState(() => _isReady = true);
    widget.onReady?.call();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Update window rect and resize native window
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final newRect = Rect.fromLTWH(0, 0, constraints.maxWidth, constraints.maxHeight);
          if (_windowRect != newRect) {
            _windowRect = newRect;
            if (_isReady) {
              _player.resize(
                x: 0, 
                y: 0, 
                width: newRect.width.toInt(), 
                height: newRect.height.toInt()
              );
            }
          }
        });

        return MouseRegion(
          onHover: (_) => _handleMouseMove(),
          child: GestureDetector(
            onTap: _handleMouseMove,
            child: Stack(
              children: [
                // TRANS PARENT BACKGROUND
                // Only paint black if NOT ready, otherwise paint transparent
                // to prevent Flutter from over-painting the native window
                if (!_isReady)
                  Container(color: Colors.black)
                else
                  Container(color: Colors.transparent),

                // Overlay UI - Always in tree for animation
                _buildOverlayUI(),

                if (_isBuffering || !_isReady)
                  const Center(child: CircularProgressIndicator(color: Colors.white)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildOverlayUI() {
    return IgnorePointer(
      ignoring: !_showControls && _isPlaying,
      child: RepaintBoundary( // Optimization: Isolate overlay composition
        child: AnimatedOpacity(
          opacity: _showControls || !_isPlaying ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: Container(
            // ... UI controls implementation ...
          ),
        ), 
      ), 
    ); 
  }
}
```

## 3. Main Application Setup

The main entry point configures the window manager to support transparency.

### `lib/main.dart`

```dart
void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // ... initialization ...

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = const WindowOptions(
      size: Size(900, 650),
      minimumSize: Size(800, 600),
      center: true,
      backgroundColor: Colors.transparent, // KEY CONFIGURATION
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(DataRushApp(launchArgs: args));
}
```

## 4. Video Screen Usage

The screen hosting the player must also be transparent to allow the video to show through.

### `lib/Screens/shared/VideoPlayerScreen.dart`

```dart
  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.transparent, // KEY CONFIGURATION
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Video Layer
            Center(
              child: RepaintBoundary(
                child: _player.buildVideoWidget(backgroundColor: Colors.transparent),
              ),
            ),
            
            // ... Overlays ...
          ],
        ),
      ),
    );
  }
```
