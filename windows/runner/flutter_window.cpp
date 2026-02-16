#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar_windows.h>

#include "flutter/generated_plugin_registrant.h"
#include "video_plugin.h" // New VideoPlugin
#include "mpv_window.h"   // New MpvWindow
#include <dwmapi.h>       // For DwmExtendFrameIntoClientArea

#ifndef WM_MPV_EVENT
#define WM_MPV_EVENT (WM_USER + 101)
#endif

#pragma comment(lib, "dwmapi.lib")

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // initialize MPV window immediately so it's ready
  mpv_window_ = std::make_unique<MpvWindow>();
  if (!mpv_window_->Create()) {
      // Log error but continue
      OutputDebugStringW(L"Failed to create MPV Window\n");
  } else {
      OutputDebugStringW(L"MPV Window Created Successfully\n");
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
  
  // Register VideoPlugin manually
  // We manage the plugin instance directly to avoid lifecycle issues with transient registrars.
  video_plugin_ = std::make_unique<VideoPlugin>(
      flutter_controller_->engine()->messenger(),
      mpv_window_.get());
  
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  
  // Set Main Window for VideoPlugin event dispatch early so we don't miss initialization events
  if (video_plugin_) {
      video_plugin_->SetMainWindow(GetHandle());
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    HWND hwnd = flutter_controller_->view()->GetNativeWindow();

    // CRITICAL: Enable DWM Transparency (Glass Effect)
    // This allows Flutter's transparent pixels to show the window BEHIND it (our MPV window).
    MARGINS margins = {-1};
    HRESULT hr = DwmExtendFrameIntoClientArea(hwnd, &margins);
    if (FAILED(hr)) {
        OutputDebugStringW(L"DwmExtendFrameIntoClientArea failed\n");
    }
    
    // Set Main Window for VideoPlugin event dispatch
    // FIX: Removed to prevent overwriting correct parent HWND with child HWND
    // if (video_plugin_) {
    //     video_plugin_->SetMainWindow(hwnd);
    // }
    
    this->Show();
    
    // Initial sync
    if (mpv_window_) {
        mpv_window_->Show();
        mpv_window_->UpdatePosition(GetHandle());
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();
  
  // Set transparent background for Flutter view to allow DWM to work
  // Note: Flutter needs to render transparently for this to work.
  // The user requirement says "Flutter Window... Style: WS_EX_LAYERED... Transparent background"
  // Win32Window::OnCreate sets typical styles. 
  // DwmExtendFrameIntoClientArea handles the composition transparency.
  
  return true;
}

void FlutterWindow::OnDestroy() {
  // Plugin must be destroyed before window to stop threads/IPC
  if (video_plugin_) {
      video_plugin_.reset();
  }

  if (mpv_window_) {
      mpv_window_->Destroy();
      mpv_window_.reset();
  }

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

  // Synchronize MPV Window Position
  if (mpv_window_) {
      switch (message) {
        case WM_WINDOWPOSCHANGED:
        case WM_MOVE:
        case WM_SIZE:
             mpv_window_->UpdatePosition(hwnd);
             break;
             
        case WM_ACTIVATE:
            if (wparam != WA_INACTIVE) {
                mpv_window_->UpdatePosition(hwnd);
                // Also bring MPV to just behind us again to be safe
            }
            break;
            
        case WM_SYSCOMMAND:
            if (wparam == SC_MINIMIZE) {
                mpv_window_->Hide();
            } else if (wparam == SC_RESTORE) {
                mpv_window_->Show();
                mpv_window_->UpdatePosition(hwnd);
            }
            break;
      }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_MPV_EVENT:
      if (video_plugin_) {
          video_plugin_->ProcessEvents();
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

