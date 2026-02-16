#include "mpv_window.h"

#include <iostream>
#include <vector>
#include <string>
#include <windows.h>

// Window class name
const wchar_t kMpvWindowClassName[] = L"MpvVideoWindow";

MpvWindow::MpvWindow() {}

MpvWindow::~MpvWindow() {
  Destroy();
}

void MpvWindow::RegisterWindowClass() {
  WNDCLASS wc = {};
  wc.lpfnWndProc = DefWindowProc; // We don't need special handling, MPV takes over drawing
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kMpvWindowClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH); // Black background ensuring no weird artifacts
  RegisterClass(&wc);
}

bool MpvWindow::Create() {
  RegisterWindowClass();

  // Create a top-level POPUP window.
  // WS_POPUP: No borders, no caption.
  // WS_VISIBLE: visible initially (can act as black background)
  // WS_EX_TOOLWINDOW: Hides from taskbar/alt-tab
  // WS_EX_NOACTIVATE: Prevents taking focus
  hwnd_ = CreateWindowEx(
      WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kMpvWindowClassName,
      L"ZapShare Video",
      WS_POPUP | WS_VISIBLE | WS_CLIPCHILDREN,
      0, 0, 100, 100, // Initial size, will be updated immediately
      nullptr,        // No parent!
      nullptr,
      GetModuleHandle(nullptr),
      nullptr);

  if (!hwnd_) {
    DWORD error = GetLastError();
    std::cerr << "Failed to create MPV window: " << error << std::endl;
    return false;
  }

  return true;
}

DWORD MpvWindow::LaunchMpv(const std::wstring& mpv_executable_path, const std::string& ipc_pipe_name) {
  if (!hwnd_) {
      // If window was destroyed (e.g. via dispose), recreate it
      if (!Create()) {
          return ERROR_INVALID_WINDOW_HANDLE;
      }
  }
  
  if (mpv_process_) {
      TerminateProcess(mpv_process_, 0);
      CloseHandle(mpv_process_);
      mpv_process_ = nullptr;
      if (mpv_thread_) {
          CloseHandle(mpv_thread_);
          mpv_thread_ = nullptr;
      }
  }

  // Build command line
  std::wstring command = L"\"" + mpv_executable_path + L"\"";
  
  // WID
  command += L" --wid=" + std::to_wstring((long long)hwnd_);
  
  // IPC
  std::wstring w_ipc(ipc_pipe_name.begin(), ipc_pipe_name.end());
  command += L" --input-ipc-server=" + w_ipc;
  
  // Rendering & HWDEC (Strict Constraints)
  // Use 'gpu' instead of 'gpu-next' for better compatibility with older Intel drivers
  command += L" --vo=gpu"; 
  command += L" --gpu-api=d3d11";
  command += L" --hwdec=no";
  
  // Essential UI/Behavior settings
  command += L" --no-input-default-bindings";
  command += L" --no-osc";             // No on-screen controller
  command += L" --no-osd-bar";         // No OSD bar
  command += L" --keep-open=yes";      // Don't close on end
  command += L" --idle=yes";           // Wait for commands
  command += L" --force-window=yes";   // Ensure window exists
  command += L" --player-operation-mode=pseudo-gui";
  
  // Debug logging - Use absolute path for safety if possible, or just filename
  command += L" --log-file=mpv_ipc_debug.log";
  command += L" --msg-level=all=v";
  
  // Optimize for smooth playback
  command += L" --video-sync=display-resample"; // Smooth motion
  command += L" --interpolation";
  command += L" --tscale=oversample";

  // Critical for ZapShare network streaming
  command += L" --cache=yes";
  command += L" --demuxer-max-bytes=500M";
  command += L" --demuxer-readahead-secs=20";
  command += L" --force-seekable=yes";

  STARTUPINFO si = { sizeof(si) };
  PROCESS_INFORMATION pi = {};
  
  OutputDebugStringW(L"Launching MPV with command: ");
  OutputDebugStringW(command.c_str());
  OutputDebugStringW(L"\n");
  
  std::wcerr << L"[MpvWindow] Launching MPV with command: " << command << std::endl;

  // Create process
  // Note: command string must be mutable for CreateProcessW
  std::vector<wchar_t> cmd_vec(command.begin(), command.end());
  cmd_vec.push_back(0); // Null terminator

  if (CreateProcess(
          nullptr,
          cmd_vec.data(),
          nullptr,
          nullptr,
          FALSE, // Don't inherit handles
          CREATE_NO_WINDOW, // No console window
          nullptr,
          nullptr,
          &si,
          &pi)) {
    mpv_process_ = pi.hProcess;
    mpv_thread_ = pi.hThread;
    return 0; // Success
  } else {
    DWORD err = GetLastError();
    std::cerr << "Failed to launch MPV: " << err << std::endl;
    return err; // Return error code
  }
}

void MpvWindow::UpdatePosition(HWND flutter_hwnd) {
  if (!hwnd_ || !flutter_hwnd) return;

  // Get Flutter window client area bounds (inner content size)
  RECT rect;
  GetClientRect(flutter_hwnd, &rect); // (0, 0, width, height)

  // Convert to screen coordinates
  POINT topLeft = {rect.left, rect.top};
  ClientToScreen(flutter_hwnd, &topLeft);
  
  // Calculate width/height
  int width = rect.right - rect.left;
  int height = rect.bottom - rect.top;

  // Check if Flutter window is minimized
  if (IsIconic(flutter_hwnd)) {
      ShowWindow(hwnd_, SW_HIDE);
      return;
  } else {
      // Ensure visible if not minimized
      ShowWindow(hwnd_, SW_SHOWNA); 
  }

  // Positioning
  // We place MPV window *behind* Flutter window in Z-order.
  // hWndInsertAfter = flutter_hwnd -> places MPV *below* Flutter in Z-order.
  SetWindowPos(hwnd_, flutter_hwnd, 
               topLeft.x, topLeft.y, 
               width, height, 
               SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOCOPYBITS | SWP_ASYNCWINDOWPOS);
               
  // Note: SWP_ASYNCWINDOWPOS helps prevent blocking the calling thread (Flutter UI thread) 
  // if the MPV window (different thread/process) is busy.
}

void MpvWindow::Destroy() {
  if (mpv_process_) {
    // Graceful exit via IPC preferably, but force kill on destroy is safer to avoid zombies
    TerminateProcess(mpv_process_, 0);
    CloseHandle(mpv_process_);
    mpv_process_ = nullptr;
    if (mpv_thread_) {
        CloseHandle(mpv_thread_);
        mpv_thread_ = nullptr;
    }
  }

  if (hwnd_) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
}

void MpvWindow::Show() {
  if (hwnd_) ShowWindow(hwnd_, SW_SHOWNA);
}

void MpvWindow::Hide() {
  if (hwnd_) ShowWindow(hwnd_, SW_HIDE);
}

bool MpvWindow::IsMpvRunning() {
    if (!mpv_process_) return false;
    DWORD code = 0;
    if (GetExitCodeProcess(mpv_process_, &code)) {
        return code == STILL_ACTIVE;
    }
    return false;
}
