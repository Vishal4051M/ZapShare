#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Enable drag and drop
  EnableDragDrop();

  return true;
}

void FlutterWindow::OnDestroy() {
  DisableDragDrop();
  
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DROPFILES: {
      HDROP hdrop = (HDROP)wparam;
      if (!is_drag_over_) {
        is_drag_over_ = true;
        SendDragEnterToFlutter();
      }
      auto files = GetDroppedFiles(hdrop);
      SendFilesToFlutter(files);
      is_drag_over_ = false;
      SendDragLeaveToFlutter();
      DragFinish(hdrop);
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::EnableDragDrop() {
  DragAcceptFiles(GetHandle(), TRUE);
}

void FlutterWindow::DisableDragDrop() {
  DragAcceptFiles(GetHandle(), FALSE);
}

std::vector<std::string> FlutterWindow::GetDroppedFiles(HDROP hdrop) {
  std::vector<std::string> files;
  
  UINT fileCount = DragQueryFile(hdrop, 0xFFFFFFFF, nullptr, 0);
  
  for (UINT i = 0; i < fileCount; i++) {
    UINT pathLength = DragQueryFile(hdrop, i, nullptr, 0);
    if (pathLength > 0) {
      std::wstring widePath(pathLength + 1, L'\0');
      DragQueryFile(hdrop, i, widePath.data(), pathLength + 1);
      
      // Convert wide string to UTF-8
      int utf8Length = WideCharToMultiByte(CP_UTF8, 0, widePath.c_str(), -1, nullptr, 0, nullptr, nullptr);
      if (utf8Length > 0) {
        std::string utf8Path(utf8Length - 1, '\0');
        WideCharToMultiByte(CP_UTF8, 0, widePath.c_str(), -1, utf8Path.data(), utf8Length, nullptr, nullptr);
        files.push_back(utf8Path);
      }
    }
  }
  
  return files;
}

void FlutterWindow::SendFilesToFlutter(const std::vector<std::string>& files) {
  if (!flutter_controller_ || !flutter_controller_->engine()) {
    return;
  }
  
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "zapshare/drag_drop",
      &flutter::StandardMethodCodec::GetInstance());
  
  flutter::EncodableList fileList;
  for (const auto& file : files) {
    fileList.push_back(flutter::EncodableValue(file));
  }
  
  channel->InvokeMethod("onFilesDropped", std::make_unique<flutter::EncodableValue>(fileList));
}

void FlutterWindow::SendDragEnterToFlutter() {
  if (!flutter_controller_ || !flutter_controller_->engine()) {
    return;
  }
  
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "zapshare/drag_drop",
      &flutter::StandardMethodCodec::GetInstance());
  
  channel->InvokeMethod("onDragEnter", nullptr);
}

void FlutterWindow::SendDragLeaveToFlutter() {
  if (!flutter_controller_ || !flutter_controller_->engine()) {
    return;
  }
  
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "zapshare/drag_drop",
      &flutter::StandardMethodCodec::GetInstance());
  
  channel->InvokeMethod("onDragLeave", nullptr);
}
