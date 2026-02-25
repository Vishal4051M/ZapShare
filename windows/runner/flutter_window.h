#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <vector>
#include <string>

#include "win32_window.h"

// Forward declaration
class MpvWindow;


// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Drag and drop support
  bool is_drag_over_ = false;
  void EnableDragDrop();
  void DisableDragDrop();
  std::vector<std::string> GetDroppedFiles(HDROP hdrop);
  void SendFilesToFlutter(const std::vector<std::string>& files);
  void SendDragEnterToFlutter();
  void SendDragLeaveToFlutter();

  // MPV Overlay Window (The "Window 1")
  std::unique_ptr<class MpvWindow> mpv_window_;
  std::unique_ptr<class VideoPlugin> video_plugin_;

 public: 
  class MpvWindow* GetMpvWindow() { return mpv_window_.get(); }
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
