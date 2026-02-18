#include "mpv_window.h"

#include <iostream>
#include <vector>
#include <string>
#include <windows.h>

// Window class name
const wchar_t kMpvWindowClassName[] = L"MpvVideoWindow";

// Job object to auto-kill MPV when ZapShare exits (even on crash/force-kill)
static HANDLE g_job_object = nullptr;

static void EnsureJobObject() {
    if (g_job_object) return;
    g_job_object = CreateJobObject(nullptr, nullptr);
    if (g_job_object) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {};
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(g_job_object, JobObjectExtendedLimitInformation,
                                &info, sizeof(info));
    }
}

MpvWindow::MpvWindow() {
    EnsureJobObject();
}

MpvWindow::~MpvWindow() {
  Destroy();
}

void MpvWindow::RegisterWindowClass() {
  WNDCLASS wc = {};
  wc.lpfnWndProc = DefWindowProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kMpvWindowClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
  RegisterClass(&wc);
}

bool MpvWindow::Create() {
  RegisterWindowClass();

  // Create a top-level POPUP window — NOT owned, NOT visible initially.
  // We place it BEHIND Flutter in Z-order via UpdatePosition().
  // WS_EX_TOOLWINDOW: Hides from taskbar and alt-tab
  // WS_EX_NOACTIVATE: Prevents stealing focus from Flutter
  // No WS_VISIBLE: Hidden until video playback starts
  hwnd_ = CreateWindowEx(
      WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kMpvWindowClassName,
      L"ZapShare Video",
      WS_POPUP | WS_CLIPCHILDREN,  // Hidden initially
      0, 0, 100, 100,
      nullptr,        // No owner — owned windows are forced ABOVE owner by Windows
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
  
  // WID — render into our window
  command += L" --wid=" + std::to_wstring((long long)hwnd_);
  
  // IPC pipe
  std::wstring w_ipc(ipc_pipe_name.begin(), ipc_pipe_name.end());
  command += L" --input-ipc-server=" + w_ipc;
  
  // Rendering
  command += L" --vo=gpu"; 
  command += L" --gpu-api=d3d11";
  command += L" --hwdec=auto-safe";  // Use HW decode when safe (saves CPU & RAM vs software decode)
  
  // UI/Behavior
  command += L" --no-input-default-bindings";
  command += L" --no-osc";
  command += L" --no-osd-bar";
  command += L" --keep-open=yes";
  command += L" --idle=yes";
  command += L" --force-window=yes";
  command += L" --player-operation-mode=pseudo-gui";
  
  // Logging (warn level to reduce disk I/O)
  command += L" --log-file=mpv_ipc_debug.log";
  command += L" --msg-level=all=warn";
  
  // Smooth playback (lightweight only — no --interpolation/--tscale which eat ~200MB GPU RAM)
  command += L" --video-sync=display-resample";

  // Network streaming cache — reduced from 500M/20s to 50M/5s to cut RAM from ~990MB to ~150MB
  command += L" --cache=yes";
  command += L" --demuxer-max-bytes=50M";
  command += L" --demuxer-readahead-secs=5";
  command += L" --force-seekable=yes";

  STARTUPINFO si = { sizeof(si) };
  PROCESS_INFORMATION pi = {};
  
  OutputDebugStringW(L"Launching MPV with command: ");
  OutputDebugStringW(command.c_str());
  OutputDebugStringW(L"\n");
  
  std::wcerr << L"[MpvWindow] Launching MPV: " << command << std::endl;

  std::vector<wchar_t> cmd_vec(command.begin(), command.end());
  cmd_vec.push_back(0);

  // CREATE_SUSPENDED so we can assign to Job Object before the process runs
  if (CreateProcess(
          nullptr,
          cmd_vec.data(),
          nullptr,
          nullptr,
          FALSE,
          CREATE_NO_WINDOW | CREATE_SUSPENDED,
          nullptr,
          nullptr,
          &si,
          &pi)) {
    // Assign to Job Object — guarantees MPV is killed if ZapShare crashes or is force-closed
    if (g_job_object) {
        AssignProcessToJobObject(g_job_object, pi.hProcess);
    }
    ResumeThread(pi.hThread);
    
    mpv_process_ = pi.hProcess;
    mpv_thread_ = pi.hThread;
    is_video_active_ = true;
    return 0;
  } else {
    DWORD err = GetLastError();
    std::cerr << "Failed to launch MPV: " << err << std::endl;
    return err;
  }
}

void MpvWindow::UpdatePosition(HWND flutter_hwnd) {
  if (!hwnd_ || !flutter_hwnd) return;

  // If Flutter is minimized, hide MPV
  if (IsIconic(flutter_hwnd)) {
      if (IsWindowVisible(hwnd_)) {
          ShowWindow(hwnd_, SW_HIDE);
      }
      return;
  }

  // Get Flutter window client area in screen coordinates
  RECT rect;
  GetClientRect(flutter_hwnd, &rect);

  POINT topLeft = {rect.left, rect.top};
  ClientToScreen(flutter_hwnd, &topLeft);
  
  int width = rect.right - rect.left;
  int height = rect.bottom - rect.top;

  // Only show if video is active
  if (is_video_active_ && !IsWindowVisible(hwnd_)) {
      ShowWindow(hwnd_, SW_SHOWNA);
  }

  // Place MPV *behind* Flutter in Z-order so Flutter's transparent overlay is on top.
  // IMPORTANT: NO SWP_ASYNCWINDOWPOS — synchronous positioning prevents visual
  // glitches (black gaps, misalignment) during resize and fullscreen transitions.
  SetWindowPos(hwnd_, flutter_hwnd, 
               topLeft.x, topLeft.y, 
               width, height, 
               SWP_NOACTIVATE | SWP_NOCOPYBITS);
}

void MpvWindow::Stop() {
  is_video_active_ = false;
  
  if (mpv_process_) {
    TerminateProcess(mpv_process_, 0);
    WaitForSingleObject(mpv_process_, 1000);  // Wait up to 1s for clean exit
    CloseHandle(mpv_process_);
    mpv_process_ = nullptr;
    if (mpv_thread_) {
        CloseHandle(mpv_thread_);
        mpv_thread_ = nullptr;
    }
  }

  // Hide the window but don't destroy it (can be reused)
  if (hwnd_) {
    ShowWindow(hwnd_, SW_HIDE);
  }
}

void MpvWindow::Destroy() {
  Stop();

  if (hwnd_) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
}

void MpvWindow::Show() {
  if (hwnd_ && is_video_active_) ShowWindow(hwnd_, SW_SHOWNA);
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
