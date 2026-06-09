# ZapShare Windows Video Player Architecture (Rewrite)

## Overview

This document describes the completely rewritten video player architecture for ZapShare on Windows. The new architecture prioritizes performance, stability, and correctness by using two synchronized top-level windows instead of child window embedding or texture rendering.

## Architecture Guidelines

### Core Principles
1.  **Dual Top-Level Windows**:
    *   **Flutter Window**: The main application window containing the UI controls. It is transparent (`DwmExtendFrameIntoClientArea`) to reveal the video window behind it.
    *   **MPV Window**: A separate, popup window (`WS_POPUP`) running the MPV player via hardware GPU rendering (`--wid`). It is strictly synchronized to stay behind the Flutter window.
    
2.  **Hardware Acceleration**:
    *   We bypass Flutter's software rasterizer for video.
    *   MPV renders directly to its window using `d3d11` and `gpu-next`.
    *   Output: `vo=gpu-next`, `hwdec=auto`, `gpu-api=d3d11`.

3.  **Synchronization**:
    *   The `MpvWindow` class hooks into the `FlutterWindow` message loop (`WM_MOVE`, `WM_SIZE`, `WM_WINDOWPOSCHANGED`).
    *   It updates the MPV window position using `SetWindowPos` relative to the Flutter window (using `hWndInsertAfter = flutterHwnd` to keep it below).

4.  **IPC Communication**:
    *   Control logic is decoupled. Flutter sends commands via `MethodChannel` to `VideoPlugin`.
    *   `VideoPlugin` writes JSON commands to a named pipe (`\\.\pipe\zapshare_mpv_socket`), which MPV listens to.

## Component Diagram

```mermaid
graph TD
    subgraph Flutter["Flutter Engine (UI)"]
        UI[Video Widget (Transparent)]
        Ctrl[MpvController]
        Channel[MethodChannel 'zapshare/video_player']
        
        UI --> Ctrl
        Ctrl --> Channel
    end

    subgraph Cpp["C++ Native Plugin"]
        Handler[VideoPlugin::HandleMethodCall]
        WindowMgr[MpvWindow]
        PipeClient[IPC Pipe Client]
        
        Channel --"Initialize/Command"--> Handler
        Handler --> WindowMgr
        Handler --> PipeClient
    end

    subgraph OS["Windows OS"]
        WinFlutter[Flutter Window (WS_EX_LAYERED)]
        WinMPV[MPV Window (WS_POPUP)]
        Pipe[Named Pipe]
        
        WinFlutter --"WM_WINDOWPOSCHANGED"--> WindowMgr
        WindowMgr --"SetWindowPos"--> WinMPV
        
        PipeClient --"JSON IPC"--> Pipe
    end

    subgraph MPV["MPV Process"]
        Core[mpv.exe]
        Render[D3D11 Renderer]
        
        Pipe --> Core
        Core --> Render
        Render --> WinMPV
    end
```

## File Structure

- **C++ Layer**:
  - `windows/runner/mpv_window.h/cpp`: Manages the raw Win32 window and mpv.exe process.
  - `windows/runner/video_plugin.h/cpp`: Handles Flutter<->Native communication and IPC.
  - `windows/runner/flutter_window.cpp`: Main window host, modified to synchronize with MPV window.

- **Dart Layer**:
  - `lib/Screens/shared/native_platform_mpv_player.dart`: Flutter controller and widget.

## Integration Details

### Initialization Flow
1. `FlutterWindow` is created.
2. `MpvWindow` is created immediately (invisible).
3. Flutter UI starts.
4. User navigates to player.
5. Flutter calls `initialize`.
6. `VideoPlugin` launches `mpv.exe` targeting the `MpvWindow` HWND.
7. `VideoPlugin` connects to IPC pipe.
8. Player is ready.

### Layout & Transparency
- The Flutter window uses `DwmExtendFrameIntoClientArea` to make its client area transparent to the desktop composition engine.
- This effectively makes "pixels with 0 alpha" transparent, revealing the window underneath.
- Since we position the MPV window exactly underneath, the video shows through the transparent parts of the Flutter UI.

## Troubleshooting

- **White Screen**: Ensure `MpvWindow` is created with valid HWND and `SetWindowPos` is placing it correctly behind. Ensure Flutter UI background is `Colors.transparent`.
- **Hangs**: IPC reading is done on a separate thread (or simplified to write-only if stability is paramount) to prevent blocking the UI thread.
- **Controls Not Working**: Verify named pipe connection in `video_plugin.cpp`.
