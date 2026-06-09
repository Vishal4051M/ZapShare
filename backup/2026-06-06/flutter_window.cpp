#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar_windows.h>

#include "flutter/generated_plugin_registrant.h"
#include "video_plugin.h"
#include "mpv_window.h"
#include <dwmapi.h>

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

  // Create MPV window early (hidden) so it's ready when video playback starts
  mpv_window_ = std::make_unique<MpvWindow>();
  if (!mpv_window_->Create()) {
      OutputDebugStringW(L"Failed to create MPV Window\n");
  } else {
      OutputDebugStringW(L"MPV Window Created (hidden)\n");
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  
  // Register VideoPlugin manually
  video_plugin_ = std::make_unique<VideoPlugin>(
      flutter_controller_->engine()->messenger(),
      mpv_window_.get());
  
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  
  // Set Main Window for VideoPlugin event dispatch
  if (video_plugin_) {
      video_plugin_->SetMainWindow(GetHandle());
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    HWND hwnd = flutter_controller_->view()->GetNativeWindow();

    // Enable DWM Transparency so Flutter's transparent pixels
    // reveal the MPV window behind it
    MARGINS margins = {-1};
    HRESULT hr = DwmExtendFrameIntoClientArea(hwnd, &margins);
    if (FAILED(hr)) {
        OutputDebugStringW(L"DwmExtendFrameIntoClientArea failed\n");
    }
    
    this->Show();
    
    // Position MPV behind Flutter (but don't show it yet — it will
    // become visible when video playback starts via is_video_active_)
    if (mpv_window_) {
        mpv_window_->UpdatePosition(GetHandle());
    }
  });

  flutter_controller_->ForceRedraw();
  
  return true;
}

void FlutterWindow::OnDestroy() {
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
  // Give Flutter first crack at handling messages.
  // BUT: For WM_SIZE, WM_MOVE, WM_ACTIVATE, WM_WINDOWPOSCHANGED, WM_SYSCOMMAND
  // we MUST NOT early-return even if Flutter consumes them, because
  // Win32Window::MessageHandler needs to run too (it calls MoveWindow on the
  // Flutter child content). Without this, Flutter never resizes after fullscreen
  // toggle and stays stuck at the old layout size.
  
  bool flutter_handled = false;
  LRESULT flutter_result = 0;
  
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      flutter_handled = true;
      flutter_result = *result;
    }
  }

  // Handle MPV-specific custom messages that should return immediately
  switch (message) {
    case WM_MPV_EVENT:
      if (video_plugin_) {
          video_plugin_->ProcessEvents();
      }
      return 0;
    case WM_FONTCHANGE:
      if (flutter_controller_) {
          flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  // For messages that DON'T affect window size/position/focus,
  // respect Flutter's consumption and return early.
  if (flutter_handled) {
      switch (message) {
        // These MUST fall through to Win32Window::MessageHandler
        // even if Flutter consumed them:
        case WM_SIZE:
        case WM_MOVE:
        case WM_ACTIVATE:
        case WM_WINDOWPOSCHANGED:
        case WM_SYSCOMMAND:
        case WM_DISPLAYCHANGE:
            break; // Don't return early — fall through to base handler below
            
        default:
            // All other messages: if Flutter handled it, return its result
            return flutter_result;
      }
  }

  // ALWAYS let the base Win32Window::MessageHandler run for layout-critical
  // messages. This calls MoveWindow() on the Flutter child content to resize it,
  // handles WM_ACTIVATE focus, DPI changes, etc.
  LRESULT base_result = Win32Window::MessageHandler(hwnd, message, wparam, lparam);

  // After the base handler has run, force Flutter to update its metrics
  // on size-related messages. This is critical after fullscreen toggle:
  // window_manager changes window style asynchronously and Flutter may
  // not automatically pick up the new dimensions.
  if (flutter_controller_) {
      switch (message) {
        case WM_SIZE:
        case WM_WINDOWPOSCHANGED:
        case WM_EXITSIZEMOVE: {
            // Force Flutter's view to acknowledge the new size
            HWND flutter_hwnd = flutter_controller_->view()->GetNativeWindow();
            if (flutter_hwnd) {
                InvalidateRect(flutter_hwnd, nullptr, TRUE);
            }
            flutter_controller_->ForceRedraw();
            break;
        }
      }
  }

  // AFTER the base handler has resized the Flutter child window,
  // sync the MPV window to match. This ordering prevents glitches
  // where MPV would resize before Flutter, showing misaligned content.
  if (mpv_window_) {
      switch (message) {
        case WM_WINDOWPOSCHANGED:
        case WM_MOVE:
        case WM_SIZE:
        case WM_DISPLAYCHANGE:
             mpv_window_->UpdatePosition(hwnd);
             break;
             
        case WM_ACTIVATE:
            if (wparam == WA_INACTIVE) {
                // App lost focus — hide MPV window.
                // Fixes virtual desktop bleed: switching desktops sends
                // WA_INACTIVE, so MPV hides. Switching back sends WA_ACTIVE.
                mpv_window_->Hide();
            } else {
                // App gained focus — show and reposition MPV
                if (mpv_window_->IsVideoActive()) {
                    mpv_window_->Show();
                    mpv_window_->UpdatePosition(hwnd);
                }
            }
            break;
            
        case WM_SYSCOMMAND:
            if ((wparam & 0xFFF0) == SC_MINIMIZE) {
                mpv_window_->Hide();
            } else if ((wparam & 0xFFF0) == SC_RESTORE || 
                       (wparam & 0xFFF0) == SC_MAXIMIZE) {
                if (mpv_window_->IsVideoActive()) {
                    mpv_window_->Show();
                    mpv_window_->UpdatePosition(hwnd);
                }
            }
            break;
      }
  }

  return base_result;
}
