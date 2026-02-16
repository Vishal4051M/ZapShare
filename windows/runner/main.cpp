#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <string>

#include "flutter_window.h"
#include "utils.h"

// Custom message ID for deep link handling
#define WM_DEEPLINK_URL (WM_USER + 100)

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // DISABLED: Single-instance check for development mode
  // In production (MSIX), the protocol registration will handle this properly
  // For now, allow dual windows so OAuth callback can complete
  /*
  CreateMutex(NULL, TRUE, L"ZapShareInstanceMutex");
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
      HWND hwnd = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"ZapShare");
      if (hwnd) {
          // Check if we have command line arguments (deep link)
          if (!command_line_arguments.empty()) {
              // Send the deep link URL to the existing window using WM_COPYDATA
              std::string url = command_line_arguments[0];
              
              COPYDATASTRUCT cds;
              cds.dwData = WM_DEEPLINK_URL;
              cds.cbData = (DWORD)(url.length() + 1) * sizeof(char);
              cds.lpData = (PVOID)url.c_str();
              
              SendMessage(hwnd, WM_COPYDATA, 0, (LPARAM)&cds);
              
              // Give the existing window time to process
              Sleep(100);
          }
          
          // Bring existing window to front
          ShowWindow(hwnd, SW_RESTORE);
          SetForegroundWindow(hwnd);
          
          // Exit this instance
          return EXIT_SUCCESS;
      }
  }
  */

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(900, 650);
  if (!window.Create(L"ZapShare", origin, size)) { // Ensure title matches FindWindow
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
