#ifndef RUNNER_MPV_WINDOW_H_
#define RUNNER_MPV_WINDOW_H_

#include <windows.h>
#include <string>
#include <memory>

class MpvWindow {
 public:
  MpvWindow();
  ~MpvWindow();

  // Creates the MPV video window.
  // invalidates existing window if any.
  bool Create();

  // Launch MPV process with the given arguments attached to this window
  // Returns 0 on success, or a Windows Error Code (DWORD) on failure.
  DWORD LaunchMpv(const std::wstring& mpv_executable_path, const std::string& ipc_pipe_name);

  // Synchronize position with the Flutter window
  // Used to keep MPV window strictly behind Flutter window
  void UpdatePosition(HWND flutter_hwnd);

  // Destroy window and process
  void Destroy();

  // Visibility control
  void Show();
  void Hide();

  // Get the window handle
  HWND GetHandle() const { return hwnd_; }
  
  // Check if MPV acts well
  bool IsMpvRunning();

 private:
  HWND hwnd_ = nullptr;
  HANDLE mpv_process_ = nullptr;
  HANDLE mpv_thread_ = nullptr;
  
  // Register window class
  void RegisterWindowClass();
};

#endif  // RUNNER_MPV_WINDOW_H_
