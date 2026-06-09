# ZapShare MPV Video Player Architecture

This document describes the implementation details of the Native MPV Video Player integration for the Windows platform in the ZapShare application.

## 1. High-Level Architecture

The video player uses a **hybrid composition** approach where a native Win32 window (hosted by a separate MPV process) is rendered *behind* the Flutter window. The Flutter UI is transparent in the video area, allowing the video to "shine through".

### Components:
1.  **Flutter UI (`NativePlatformMpvPlayer`)**: Handles user interaction (play/pause, seek), state management, and renders the transparent hole for the video.
2.  **Platform Channel (`zapshare/video_player`)**: A bidirectional communication channel between Dart and C++.
3.  **C++ Host (`VideoPlugin`)**: Manages the MPV process, handles IPC communication, and proxies events to Flutter.
4.  **MPV Process (`mpv.exe`)**: The actual video player engine running as a child process, rendering to a dedicated HWND via `--wid`.

## 2. Communication Flow (IPC)

The system uses **Named Pipes** for Inter-Process Communication (IPC) between the C++ plugin and the MPV process.

### **Initialization Sequence:**
1.  **Flutter** calls `initialize`.
2.  **C++** creates a unique named pipe: `\\.\pipe\zapshare_mpv_<PID>`.
3.  **C++** launches `mpv.exe` with arguments:
    *   `--wid=<HWND>` (Window ID of the native child window)
    *   `--input-ipc-server=\\.\pipe\zapshare_mpv_<PID>` (Connect to our pipe)
    *   `--vo=gpu-next`, `--gpu-api=d3d11`, `--hwdec=auto` (Hardware acceleration)
4.  **Flutter** (via C++) sends initial `observe_property` commands to subscribe to state changes.

### **Property Observation Protocol:**
To avoid polling and ensure efficient updates, we use MPV's `observe_property` command with specific IDs:

| ID | Property | Description |
| :--- | :--- | :--- |
| **1** | `duration` | Total video duration in seconds. |
| **2** | `time-pos` | Current playback position in seconds. |
| **3** | `pause` | Play/Pause state (true/false). |
| **4** | `core-idle` | Buffering state (true/false). |
| **5** | `track-list` | List of audio/subtitle tracks (JSON). |
| **6** | `sub-text` | Current subtitle text. |

### **JSON Protocol Examples:**

**Sending a Command (Flutter -> MPV):**
```json
// Seek to 120.5 seconds
{ "command": ["seek", 120.5, "absolute"] }

// Enable subtitles
{ "command": ["set", "sid", "auto"] }
```

**Receiving an Event (MPV -> Flutter):**
```json
// Duration Update
{ "event": "property-change", "id": 1, "name": "duration", "data": 3600.5 }

// Position Update
{ "event": "property-change", "id": 2, "name": "time-pos", "data": 120.5 }
```

## 3. Key Source Files

### 3.1. Flutter Platform Implementation
**File:** `lib/Screens/shared/native_platform_mpv_player.dart`

Handles the Dart side of the implementation, including stream controllers for state and method channel invocation.

```dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'video_player_interface.dart';

class NativePlatformMpvPlayer implements PlatformVideoPlayer {
  static const MethodChannel _channel = MethodChannel('zapshare/video_player');
  bool _isInitialized = false;

  // Streams for state management
  final _playingController = StreamController<bool>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferController = StreamController<Duration>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  // ... other controllers

  Future<void> _initializeInternal() async {
    // ...
    await _channel.invokeMethod('initialize');
    
    // Subscribe to properties
    Future.delayed(const Duration(milliseconds: 500), () async {
      await _sendCommand(['observe_property', 1, 'duration']);
      await _sendCommand(['observe_property', 2, 'time-pos']);
      await _sendCommand(['observe_property', 3, 'pause']);
      // ...
      await _sendCommand(['set', 'sid', 'auto']); // Enable subs
    });
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPosition':
        // Update position stream
        break;
      case 'onDuration':
        // Update duration stream
        break;
      case 'onTracks':
        // Parse track list JSON
        break;
    }
  }

  @override
  Future<void> seek(Duration position) async {
    // CRITICAL: Send seconds as a double (number), not string!
    final seconds = position.inMilliseconds / 1000.0;
    await _sendCommand(['seek', seconds, 'absolute']);
  }
  
  // ... rest of implementation
}
```

### 3.2. C++ Plugin Implementation
**File:** `windows/runner/video_plugin.cpp`

Manages the MPV process, the Named Pipe reading thread, and JSON parsing.

```cpp
#include "video_plugin.h"
// ... includes

// Custom JSON extraction to handle nested objects/arrays (important for track-list)
std::string ExtractJsonValue(const std::string& json, const std::string& key) {
    // ... robust parsing logic ...
}

void VideoPlugin::StartReadThread() {
    read_thread_ = std::thread([this]() {
        // ...
        while (keep_reading_) {
            // Read from pipe...
            // Parse line...
            
            std::string idStr = ExtractJsonValue(line, "id");
            std::string dataStr = ExtractJsonValue(line, "data");

            if (idStr == "1" || name == "duration") {
                double val = ParseDouble(dataStr);
                EnqueueEvent("onDuration", val);
            } else if (idStr == "2" || name == "time-pos") {
                double val = ParseDouble(dataStr);
                EnqueueEvent("onPosition", val);
            }
            // ... handle other IDs
        }
    });
}

void VideoPlugin::HandleMethodCall(/*...*/) {
    if (method_name == "initialize") {
        // Launch MPV with --input-ipc-server=\\.\pipe\...
        // Connect to pipe
        // Send initial commands
    } else if (method_name == "command") {
        // Forward command string to pipe
    }
}
```

### 3.3. C++ Window Management
**File:** `windows/runner/mpv_window.cpp`

Handles the creation of the native Win32 window that hosts MPV.

```cpp
bool MpvWindow::LaunchMpv(const std::wstring& mpv_executable_path, const std::string& ipc_pipe_name) {
  // Build command line
  std::wstring command = L"\"" + mpv_executable_path + L"\"";
  command += L" --wid=" + std::to_wstring((long long)hwnd_);
  command += L" --input-ipc-server=" + w_ipc;
  command += L" --vo=gpu-next";
  command += L" --hwdec=auto";
  
  // CreateProcess...
}

void MpvWindow::UpdatePosition(HWND flutter_hwnd) {
  // Keep the MPV window exactly behind the Flutter window
  // Calculations map Flutter client area to screen coordinates
  SetWindowPos(hwnd_, flutter_hwnd, ..., SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}
```

## 4. Troubleshooting Guide

### Issue: Duration is 0 / Seek bar stuck
*   **Cause**: `observe_property` for duration (ID 1) not sent or MPV validation failed.
*   **Fix**: Ensure `["observe_property", 1, "duration"]` is sent. The C++ code must accept `0` or partial values and force an update to Dart.

### Issue: Seek doesn't work (resets to start)
*   **Cause**: Sending seek target as a string `["seek", "120", "absolute"]`.
*   **Fix**: Send as a number `["seek", 120.0, "absolute"]`.

### Issue: Subtitles not showing
*   **Cause**: Subtitles defaults to off or `sub-text` not observed.
*   **Fix**: Send `["set", "sid", "auto"]` at startup and observe ID 6 (`sub-text`).
