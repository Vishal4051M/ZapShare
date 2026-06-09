#include "mpv_window.h"

#include <iostream>
#include <vector>
#include <string>
#include <windows.h>

const wchar_t kMpvWindowClassName[] = L"MpvVideoWindow";
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

  hwnd_ = CreateWindowEx(
      WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kMpvWindowClassName,
      L"ZapShare Video",
      WS_POPUP | WS_CLIPCHILDREN,
      0, 0, 100, 100,
      nullptr,
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

  std::wstring command = L"\"" + mpv_executable_path + L"\"";
  command += L" --wid=" + std::to_wstring((long long)hwnd_);
  
  std::wstring w_ipc(ipc_pipe_name.begin(), ipc_pipe_name.end());
  command += L" --input-ipc-server=" + w_ipc;
  
  command += L" --vo=gpu"; 
  command += L" --gpu-api=d3d11";
  command += L" --hwdec=auto-safe";
  
  command += L" --no-input-default-bindings";
  command += L" --no-osc";
  command += L" --no-osd-bar";
  command += L" --keep-open=yes";
  command += L" --idle=yes";
  command += L" --force-window=yes";
  command += L" --player-operation-mode=pseudo-gui";
  
  command += L" --log-file=mpv_ipc_debug.log";
  command += L" --msg-level=all=warn";
  
  command += L" --video-sync=display-resample";
  command += L" --profile=low-latency";
  command += L" --audio-buffer=0";
  command += L" --cache=no";
  command += L" --cache-pause=no";
  command += L" --demuxer-max-bytes=4096";
  command += L" --demuxer-readahead-secs=0";
  command += L" --force-seekable=no";

  STARTUPINFO si = { sizeof(si) };
  PROCESS_INFORMATION pi = {};
  
  std::wcerr << L"[MpvWindow] Launching MPV: " << command << std::endl;

  std::vector<wchar_t> cmd_vec(command.begin(), command.end());
  cmd_vec.push_back(0);

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

  if (IsIconic(flutter_hwnd)) {
      if (IsWindowVisible(hwnd_)) {
          ShowWindow(hwnd_, SW_HIDE);
      }
      return;
  }

  RECT rect;
  GetClientRect(flutter_hwnd, &rect);

  POINT topLeft = {rect.left, rect.top};
  ClientToScreen(flutter_hwnd, &topLeft);
  
  int width = rect.right - rect.left;
  int height = rect.bottom - rect.top;

  if (is_video_active_ && !IsWindowVisible(hwnd_)) {
      ShowWindow(hwnd_, SW_SHOWNA);
  }

  SetWindowPos(hwnd_, flutter_hwnd, 
               topLeft.x, topLeft.y, 
               width, height, 
               SWP_NOACTIVATE | SWP_NOCOPYBITS);
}

void MpvWindow::Stop() {
  is_video_active_ = false;
  
  if (mpv_process_) {
    TerminateProcess(mpv_process_, 0);
    WaitForSingleObject(mpv_process_, 1000);
    CloseHandle(mpv_process_);
    mpv_process_ = nullptr;
    if (mpv_thread_) {
        CloseHandle(mpv_thread_);
        mpv_thread_ = nullptr;
    }
  }

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
