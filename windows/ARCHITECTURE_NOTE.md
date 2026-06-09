# Flutter + MPV Windows Architecture

This architecture achieves VLC-level smoothness and perfect UI overlay by using two synchronized top-level windows.

## Core Concept
Instead of trying to embed MPV *inside* Flutter (which causes Airspace issues) or copying textures (which causes performance issues), we use **Two Top-Level Windows**:

1.  **MPV Window (Bottom Layer)**
    *   Style: `WS_POPUP | WS_VISIBLE`
    *   Rendering: Direct D3D11 swapchain (`--vo=gpu-next --gpu-api=d3d11`)
    *   Position: Synchronized exactly to the content area of the Flutter window.
    *   Z-Order: Always `HWND_BOTTOM` (behind Flutter).

2.  **Flutter Window (Top Layer)**
    *   Style: Standard Win32 Window with `DwmExtendFrameIntoClientArea` (Glass Effect).
    *   Rendering: Flutter renders its UI using Angle/Direct3D.
    *   Transparency: Flutter renders `Colors.transparent` where the video should be. Windows DWM compositor blends this with the window behind it (MPV), effectively "punching a hole".

## Synchronization
*   **Movement/Resize**: The C++ `FlutterWindow` captures `WM_MOVE`, `WM_SIZE`, and `WM_WINDOWPOSCHANGED` messages. It immediately calls `MpvWindow::UpdatePosition()` to snap the MPV window to the new coordinates.
*   **Lifecycle**: `FlutterWindow` owns `MpvWindow`. When the app starts, MPV window is created (hidden). When `NativeMpvPlayer.initialize` is called, MPV process is launched. When app closes, `FlutterWindow` destroys `MpvWindow`.

## Communication
*   **IPC**: We use named pipes (`\\.\pipe\mpv_ipc_...`) for communication between the C++ runner and the MPV process (JSON-IPC).
*   **Platform Channel**: Flutter talks to C++ via `MethodChannel`. C++ forwards commands to the MPV process via IPC.

## Why this works
*   **No Copying**: MPV draws directly to the screen. 0% overhead.
*   **Hardware Acceleration**: Full D3D11 support.
*   **Perfect Overlay**: Flutter is a true window on top. All widgets, tooltips, and dialogs render normally over the video.
*   **Transparency**: Modern Windows DWM handles the composition efficiently.

## Implementation Details

### 1. `mpv_window.cpp`
Manages the native popup window and the MPV process.
```cpp
// Key: Create independent popup window, no parent/child relationship that enforces clipping
hwnd_ = CreateWindowExW(..., WS_POPUP | WS_VISIBLE, ...);

// Key: Sync position logic
void MpvWindow::UpdatePosition(HWND owner_hwnd) {
    // ... calculate coordinates ...
    SetWindowPos(hwnd_, HWND_BOTTOM, ...); // Keep behind
}
```

### 2. `flutter_window.cpp`
Integrates the MPV window.
```cpp
// Enable Glass Effect
DwmExtendFrameIntoClientArea(hwnd, &margins);

// Sync updates
case WM_MOVE:
    mpv_window_->UpdatePosition(hwnd);
```

### 3. `native_platform_mpv_player.dart`
Renders the hole.
```dart
return Container(color: Colors.transparent); // Shows video behind
```
