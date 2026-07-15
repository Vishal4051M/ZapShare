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

#include <algorithm>
namespace Gdiplus {
    using std::min;
    using std::max;
}
#include <gdiplus.h>

#ifndef WM_MPV_EVENT
#define WM_MPV_EVENT (WM_USER + 101)
#endif

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "user32.lib")

// Helpers for Desktop Capture and Input Injection
static int GetEncoderClsid(const WCHAR* format, CLSID* pClsid) {
  UINT num = 0;
  UINT size = 0;
  Gdiplus::GetImageEncodersSize(&num, &size);
  if (size == 0) return -1;
  Gdiplus::ImageCodecInfo* pImageCodecInfo = (Gdiplus::ImageCodecInfo*)(malloc(size));
  if (pImageCodecInfo == NULL) return -1;
  Gdiplus::GetImageEncoders(num, size, pImageCodecInfo);
  for (UINT j = 0; j < num; ++j) {
    if (wcscmp(pImageCodecInfo[j].MimeType, format) == 0) {
      *pClsid = pImageCodecInfo[j].Clsid;
      free(pImageCodecInfo);
      return j;
    }
  }
  free(pImageCodecInfo);
  return -1;
}

static std::vector<uint8_t> CaptureDesktopJpeg() {
    std::vector<uint8_t> buffer;
    HDC hdcScreen = GetDC(NULL);
    if (!hdcScreen) return buffer;
    HDC hdcMem = CreateCompatibleDC(hdcScreen);
    if (!hdcMem) {
        ReleaseDC(NULL, hdcScreen);
        return buffer;
    }
    int width = GetSystemMetrics(SM_CXSCREEN);
    int height = GetSystemMetrics(SM_CYSCREEN);
    HBITMAP hBitmap = CreateCompatibleBitmap(hdcScreen, width, height);
    if (!hBitmap) {
        DeleteDC(hdcMem);
        ReleaseDC(NULL, hdcScreen);
        return buffer;
    }
    HGDIOBJ hOld = SelectObject(hdcMem, hBitmap);
    BitBlt(hdcMem, 0, 0, width, height, hdcScreen, 0, 0, SRCCOPY);

    Gdiplus::Bitmap bitmap(hBitmap, NULL);
    CLSID encoderClsid;
    if (GetEncoderClsid(L"image/jpeg", &encoderClsid) != -1) {
        Gdiplus::EncoderParameters encoderParameters;
        encoderParameters.Count = 1;
        encoderParameters.Parameter[0].Guid = Gdiplus::EncoderQuality;
        encoderParameters.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
        encoderParameters.Parameter[0].NumberOfValues = 1;
        ULONG quality = 50; 
        encoderParameters.Parameter[0].Value = &quality;

        IStream* pStream = NULL;
        if (CreateStreamOnHGlobal(NULL, TRUE, &pStream) == S_OK) {
            if (bitmap.Save(pStream, &encoderClsid, &encoderParameters) == Gdiplus::Status::Ok) {
                LARGE_INTEGER lnOffset;
                lnOffset.QuadPart = 0;
                if (pStream->Seek(lnOffset, STREAM_SEEK_SET, NULL) == S_OK) {
                    STATSTG statstg;
                    if (pStream->Stat(&statstg, STATFLAG_NONAME) == S_OK) {
                        buffer.resize(static_cast<size_t>(statstg.cbSize.QuadPart));
                        ULONG bytesRead = 0;
                        pStream->Read(buffer.data(), static_cast<ULONG>(buffer.size()), &bytesRead);
                    }
                }
            }
            pStream->Release();
        }
    }
    SelectObject(hdcMem, hOld);
    DeleteObject(hBitmap);
    DeleteDC(hdcMem);
    ReleaseDC(NULL, hdcScreen);
    return buffer;
}

static void SendMouseMove(double dx, double dy) {
    INPUT input = {};
    input.type = INPUT_MOUSE;
    // dx/dy are relative pixels — use MOUSEEVENTF_MOVE without ABSOLUTE flag
    input.mi.dx = static_cast<LONG>(dx);
    input.mi.dy = static_cast<LONG>(dy);
    input.mi.dwFlags = MOUSEEVENTF_MOVE;
    SendInput(1, &input, sizeof(INPUT));
}

static void SendRightClick() {
    INPUT inputs[2] = {};
    inputs[0].type = INPUT_MOUSE;
    inputs[0].mi.dwFlags = MOUSEEVENTF_RIGHTDOWN;
    inputs[1].type = INPUT_MOUSE;
    inputs[1].mi.dwFlags = MOUSEEVENTF_RIGHTUP;
    SendInput(2, inputs, sizeof(INPUT));
}

static void SendMouseClick(double tapX, double tapY) {
    INPUT inputs[3] = {};
    
    inputs[0].type = INPUT_MOUSE;
    inputs[0].mi.dx = static_cast<LONG>(tapX * 65535.0);
    inputs[0].mi.dy = static_cast<LONG>(tapY * 65535.0);
    inputs[0].mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE;

    inputs[1].type = INPUT_MOUSE;
    inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;

    inputs[2].type = INPUT_MOUSE;
    inputs[2].mi.dwFlags = MOUSEEVENTF_LEFTUP;

    SendInput(3, inputs, sizeof(INPUT));
}

static void SendMouseLongPress(double tapX, double tapY) {
    INPUT inputs[2] = {};
    
    inputs[0].type = INPUT_MOUSE;
    inputs[0].mi.dx = static_cast<LONG>(tapX * 65535.0);
    inputs[0].mi.dy = static_cast<LONG>(tapY * 65535.0);
    inputs[0].mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE;
    SendInput(1, &inputs[0], sizeof(INPUT));

    inputs[1].type = INPUT_MOUSE;
    inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    SendInput(1, &inputs[1], sizeof(INPUT));

    Sleep(600);

    inputs[0].type = INPUT_MOUSE;
    inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    SendInput(1, &inputs[0], sizeof(INPUT));
}

static void SendMouseDrag(double startX, double startY, double endX, double endY, int durationMs) {
    INPUT input = {};
    
    input.type = INPUT_MOUSE;
    input.mi.dx = static_cast<LONG>(startX * 65535.0);
    input.mi.dy = static_cast<LONG>(startY * 65535.0);
    input.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE;
    SendInput(1, &input, sizeof(INPUT));

    input.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    SendInput(1, &input, sizeof(INPUT));

    int steps = 10;
    int sleepPerStep = durationMs / steps;
    if (sleepPerStep < 10) sleepPerStep = 10;
    for (int i = 1; i <= steps; ++i) {
        double t = static_cast<double>(i) / steps;
        double currX = startX + (endX - startX) * t;
        double currY = startY + (endY - startY) * t;

        input.mi.dx = static_cast<LONG>(currX * 65535.0);
        input.mi.dy = static_cast<LONG>(currY * 65535.0);
        input.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE;
        SendInput(1, &input, sizeof(INPUT));
        Sleep(sleepPerStep);
    }

    input.mi.dwFlags = MOUSEEVENTF_LEFTUP;
    SendInput(1, &input, sizeof(INPUT));
}

static void SendMouseScroll(double tapX, double tapY, double scrollDelta) {
    INPUT inputs[2] = {};
    
    inputs[0].type = INPUT_MOUSE;
    inputs[0].mi.dx = static_cast<LONG>(tapX * 65535.0);
    inputs[0].mi.dy = static_cast<LONG>(tapY * 65535.0);
    inputs[0].mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE;
    SendInput(1, &inputs[0], sizeof(INPUT));

    inputs[1].type = INPUT_MOUSE;
    inputs[1].mi.dwFlags = MOUSEEVENTF_WHEEL;
    inputs[1].mi.mouseData = static_cast<DWORD>(-scrollDelta * 120.0); 
    SendInput(1, &inputs[1], sizeof(INPUT));
}

static void SendKeyboardType(const std::wstring& text) {
    std::vector<INPUT> inputs;
    for (wchar_t ch : text) {
        INPUT inputDown = {};
        inputDown.type = INPUT_KEYBOARD;
        inputDown.ki.dwFlags = KEYEVENTF_UNICODE;
        inputDown.ki.wScan = ch;
        inputs.push_back(inputDown);

        INPUT inputUp = {};
        inputUp.type = INPUT_KEYBOARD;
        inputUp.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        inputUp.ki.wScan = ch;
        inputs.push_back(inputUp);
    }
    if (!inputs.empty()) {
        SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
    }
}

static void SendVirtualKey(WORD vk) {
    INPUT inputs[2] = {};

    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wVk = vk;

    inputs[1].type = INPUT_KEYBOARD;
    inputs[1].ki.wVk = vk;
    inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;

    SendInput(2, inputs, sizeof(INPUT));
}

static void HandleInjectControl(const flutter::EncodableMap& map) {
    auto action_it = map.find(flutter::EncodableValue("action"));
    if (action_it == map.end() || !std::holds_alternative<std::string>(action_it->second)) {
        return;
    }
    std::string action = std::get<std::string>(action_it->second);

    auto get_double = [&](const std::string& key) -> double {
        auto it = map.find(flutter::EncodableValue(key));
        if (it != map.end()) {
            if (std::holds_alternative<double>(it->second)) return std::get<double>(it->second);
            if (std::holds_alternative<int32_t>(it->second)) return static_cast<double>(std::get<int32_t>(it->second));
            if (std::holds_alternative<int64_t>(it->second)) return static_cast<double>(std::get<int64_t>(it->second));
        }
        return 0.0;
    };

    auto get_int = [&](const std::string& key) -> int {
        auto it = map.find(flutter::EncodableValue(key));
        if (it != map.end()) {
            if (std::holds_alternative<int32_t>(it->second)) return std::get<int32_t>(it->second);
            if (std::holds_alternative<int64_t>(it->second)) return static_cast<int>(std::get<int64_t>(it->second));
        }
        return 0;
    };

    auto get_string = [&](const std::string& key) -> std::string {
        auto it = map.find(flutter::EncodableValue(key));
        if (it != map.end() && std::holds_alternative<std::string>(it->second)) {
            return std::get<std::string>(it->second);
        }
        return "";
    };

    if (action == "click" || action == "long_press") {
        double tapX = get_double("tapX");
        double tapY = get_double("tapY");
        if (action == "click") {
            SendMouseClick(tapX, tapY);
        } else {
            SendMouseLongPress(tapX, tapY);
        }
    } else if (action == "swipe" || action == "drag") {
        double tapX = get_double("tapX");
        double tapY = get_double("tapY");
        double endX = get_double("endX");
        double endY = get_double("endY");
        int duration = get_int("duration");
        if (duration <= 0) duration = 300;
        SendMouseDrag(tapX, tapY, endX, endY, duration);
    } else if (action == "scroll") {
        double tapX = get_double("tapX");
        double tapY = get_double("tapY");
        double scrollDelta = get_double("scrollDelta");
        SendMouseScroll(tapX, tapY, scrollDelta);
    } else if (action == "type") {
        std::string text = get_string("text");
        if (!text.empty()) {
            std::wstring wtext;
            int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, NULL, 0);
            if (size > 0) {
                wtext.resize(size - 1);
                MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, &wtext[0], size);
            }
            SendKeyboardType(wtext);
        }
    } else if (action == "key") {
        std::string key = get_string("text");
        WORD vk = 0;
        if (key == "backspace") vk = VK_BACK;
        else if (key == "enter") vk = VK_RETURN;
        else if (key == "tab") vk = VK_TAB;
        else if (key == "delete") vk = VK_DELETE;
        else if (key == "escape") vk = VK_ESCAPE;
        else if (key == "up") vk = VK_UP;
        else if (key == "down") vk = VK_DOWN;
        else if (key == "left") vk = VK_LEFT;
        else if (key == "right") vk = VK_RIGHT;

        if (vk != 0) {
            SendVirtualKey(vk);
        }
    } else if (action == "mousemove") {
        // Relative delta mouse movement for Android touchpad
        double dx = get_double("tapX");
        double dy = get_double("tapY");
        SendMouseMove(dx, dy);
    } else if (action == "right_click") {
        SendRightClick();
    }
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Initialize GDI+
  Gdiplus::GdiplusStartupInput gdiplusStartupInput;
  Gdiplus::GdiplusStartup((ULONG_PTR*)&gdiplusToken_, &gdiplusStartupInput, nullptr);

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

  // Register zapshare/desktop_capture method channel
  capture_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "zapshare/desktop_capture",
      &flutter::StandardMethodCodec::GetInstance()
  );

  capture_channel_->SetMethodCallHandler(
      [](const auto &call, auto result) {
          const std::string& method_name = call.method_name();
          if (method_name == "captureFrame") {
              std::vector<uint8_t> jpeg_bytes = CaptureDesktopJpeg();
              if (jpeg_bytes.empty()) {
                  result->Error("CAPTURE_FAILED", "Failed to capture desktop frame");
              } else {
                  result->Success(flutter::EncodableValue(jpeg_bytes));
              }
          } else if (method_name == "injectControl") {
              const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
              if (map) {
                  HandleInjectControl(*map);
                  result->Success();
              } else {
                  result->Error("INVALID_ARGS", "Expected Map for injectControl");
              }
          } else {
              result->NotImplemented();
          }
      }
  );

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
  
  EnableDragDrop();

  return true;
}

void FlutterWindow::OnDestroy() {
  DisableDragDrop();

  if (capture_channel_) {
      capture_channel_.reset();
  }

  if (gdiplusToken_ != 0) {
      Gdiplus::GdiplusShutdown(gdiplusToken_);
      gdiplusToken_ = 0;
  }

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
    case WM_DROPFILES: {
      HDROP hDrop = (HDROP)wparam;
      std::vector<std::string> paths = GetDroppedFiles(hDrop);
      SendFilesToFlutter(paths);
      DragFinish(hDrop);
      return 0;
    }
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

void FlutterWindow::EnableDragDrop() {
  DragAcceptFiles(GetHandle(), TRUE);
  HWND flutter_hwnd = flutter_controller_ ? flutter_controller_->view()->GetNativeWindow() : nullptr;
  if (flutter_hwnd) {
    DragAcceptFiles(flutter_hwnd, TRUE);
  }
}

void FlutterWindow::DisableDragDrop() {
  DragAcceptFiles(GetHandle(), FALSE);
  HWND flutter_hwnd = flutter_controller_ ? flutter_controller_->view()->GetNativeWindow() : nullptr;
  if (flutter_hwnd) {
    DragAcceptFiles(flutter_hwnd, FALSE);
  }
}

std::vector<std::string> FlutterWindow::GetDroppedFiles(HDROP hdrop) {
  std::vector<std::string> paths;
  UINT fileCount = DragQueryFileW(hdrop, 0xFFFFFFFF, NULL, 0);
  for (UINT i = 0; i < fileCount; i++) {
    UINT size = DragQueryFileW(hdrop, i, NULL, 0);
    std::wstring wpath(size, L'\0');
    DragQueryFileW(hdrop, i, &wpath[0], size + 1);
    
    // Convert to UTF-8
    int utf8_size = WideCharToMultiByte(CP_UTF8, 0, wpath.c_str(), -1, NULL, 0, NULL, NULL);
    if (utf8_size > 0) {
      std::string path(utf8_size - 1, '\0');
      WideCharToMultiByte(CP_UTF8, 0, wpath.c_str(), -1, &path[0], utf8_size, NULL, NULL);
      paths.push_back(path);
    }
  }
  return paths;
}

void FlutterWindow::SendFilesToFlutter(const std::vector<std::string>& files) {
  if (!flutter_controller_) return;
  flutter::EncodableList list;
  for (const auto& file : files) {
    list.push_back(flutter::EncodableValue(file));
  }
  
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "zapshare/drag_drop",
      &flutter::StandardMethodCodec::GetInstance()
  );
  
  channel->InvokeMethod("onFilesDropped", std::make_unique<flutter::EncodableValue>(list));
}

void FlutterWindow::SendDragEnterToFlutter() {
  if (!flutter_controller_) return;
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "zapshare/drag_drop",
      &flutter::StandardMethodCodec::GetInstance()
  );
  channel->InvokeMethod("onDragEnter", nullptr);
}

void FlutterWindow::SendDragLeaveToFlutter() {
  if (!flutter_controller_) return;
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "zapshare/drag_drop",
      &flutter::StandardMethodCodec::GetInstance()
  );
  channel->InvokeMethod("onDragLeave", nullptr);
}
