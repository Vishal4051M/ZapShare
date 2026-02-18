#include "video_plugin.h"

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <memory>
#include <sstream>
#include <iostream>
#include <locale>
#include <variant>
#include <vector>
#include <thread>
#include <mutex>
#include <iomanip>
#include <chrono>

// Helper to parse double with dot separator regardless of locale
double ParseDouble(const std::string& s) {
    try {
        double val = 0.0;
        std::stringstream ss(s);
        ss.imbue(std::locale::classic());
        ss >> val;
        return val;
    } catch (...) {
        return 0.0;
    }
}

void DebugLog(const std::string& msg) {
    OutputDebugStringA((msg + "\n").c_str());
}

// Basic JSON parser helper
std::string ExtractJsonValue(const std::string& json, const std::string& key) {
    std::string keyPattern = "\"" + key + "\"";
    size_t keyPos = json.find(keyPattern);
    if (keyPos == std::string::npos) return ""; 
    
    // find colon
    size_t colonPos = json.find(':', keyPos + keyPattern.length());
    if (colonPos == std::string::npos) return "";
    
    // skip whitespace
    size_t start = json.find_first_not_of(" \t\r\n", colonPos + 1);
    if (start == std::string::npos) return "";
    
    if (json[start] == '"') {
        // String value: return content inside quotes, handling escaped quotes
        size_t end = start + 1;
        while (end < json.length()) {
            if (json[end] == '"' && json[end-1] != '\\') break;
            end++;
        }
        if (end >= json.length()) return "";
        return json.substr(start + 1, end - start - 1);
    } else if (json[start] == '[') {
        // Array value: return content inside brackets matching depth
        int depth = 1;
        size_t end = start + 1;
        bool inQuote = false;
        while (end < json.length() && depth > 0) {
             if (json[end] == '"' && json[end-1] != '\\') inQuote = !inQuote;
             if (!inQuote) {
                 if (json[end] == '[') depth++;
                 else if (json[end] == ']') depth--;
             }
             end++;
        }
        return json.substr(start, end - start);
    } else if (json[start] == '{') {
        // Object value
        int depth = 1;
        size_t end = start + 1;
        bool inQuote = false;
        while (end < json.length() && depth > 0) {
             if (json[end] == '"' && json[end-1] != '\\') inQuote = !inQuote;
             if (!inQuote) {
                 if (json[end] == '{') depth++;
                 else if (json[end] == '}') depth--;
             }
             end++;
        }
        return json.substr(start, end - start);
    } else {
        // Primitive value (number, bool, null)
        size_t end = json.find_first_of(",}", start);
        if (end == std::string::npos) end = json.length();
        std::string raw = json.substr(start, end - start);
        // Trim trailing whitespace
        size_t last = raw.find_last_not_of(" \t\r\n");
        if (last != std::string::npos) raw = raw.substr(0, last + 1);
        return raw;
    }
}

// ... in VideoPlugin

void VideoPlugin::StartReadThread() {
    // 1. If already marked as reading, don't start another.
    if (keep_reading_) return;
    
    // 2. Critically: If the previous thread object is still joinable (it finished on its own),
    // we MUST join it before assigning a new thread to it, otherwise std::terminate/abort is called.
    if (read_thread_.joinable()) {
        read_thread_.join();
    }
    
    keep_reading_ = true;
    read_thread_ = std::thread([this]() {
        char buffer[4096];
        DWORD bytesRead;
        std::string accumulated;
        
        DebugLog("VideoPlugin: Read thread started. Handle: " + std::to_string((long long)pipe_handle_));
        
        while (keep_reading_ && pipe_handle_ != INVALID_HANDLE_VALUE) {
            DWORD bytesAvail = 0;
            if (PeekNamedPipe(pipe_handle_, nullptr, 0, nullptr, &bytesAvail, nullptr)) {
                if (bytesAvail > 0) {
                    if (ReadFile(pipe_handle_, buffer, sizeof(buffer) - 1, &bytesRead, nullptr)) {
                        if (bytesRead > 0) {
                            buffer[bytesRead] = '\0';
                            accumulated += buffer;
                            
                            size_t pos = 0;
                            while ((pos = accumulated.find('\n')) != std::string::npos) {
                                std::string line = accumulated.substr(0, pos);
                                accumulated.erase(0, pos + 1);
                                
                                if (!line.empty() && line.back() == '\r') {
                                    line.pop_back();
                                }
                                
                                if (line.empty()) continue;
                        
                                // Enable verbose logging to debug duration/seek issues
                                DebugLog("MPV IN: " + line);
                                EnqueueEvent("onLog", std::make_unique<flutter::EncodableValue>("MPV IN: " + line));

                                try {
                                    std::string event = ExtractJsonValue(line, "event");
                                    
                                    if (event == "start-file") {
                                         // No-op
                                    } else if (event == "file-loaded") {
                                        DebugLog("MPV: file-loaded detected. Force fetching...");
                                        
                                        // CRITICAL: Force fetch immediately
                                        SendCommand("{ \"command\": [\"get_property\", \"duration\"], \"request_id\": 1 }\n");
                                        SendCommand("{ \"command\": [\"get_property\", \"track-list\"], \"request_id\": 2 }\n");

                                        // CRITICAL: also fetch again after playback starts
                                        std::thread([this]() {
                                            std::this_thread::sleep_for(std::chrono::milliseconds(500));
                                            if (pipe_handle_ != INVALID_HANDLE_VALUE)
                                                SendCommand("{ \"command\": [\"get_property\", \"duration\"], \"request_id\": 3 }\n");

                                            std::this_thread::sleep_for(std::chrono::milliseconds(1000));
                                            if (pipe_handle_ != INVALID_HANDLE_VALUE)
                                                SendCommand("{ \"command\": [\"get_property\", \"duration\"], \"request_id\": 4 }\n");

                                        }).detach();
                                    }

                                    std::string idStr = ExtractJsonValue(line, "id");
                                    if (idStr.empty()) {
                                        // Fallback: Check for request_id (used for manual get_property calls)
                                        idStr = ExtractJsonValue(line, "request_id");
                                    }
                                    std::string name = ExtractJsonValue(line, "name");
                                    std::string dataStr = ExtractJsonValue(line, "data");

                                    // If data is missing (null/empty), we generally skip unless it's a specific signal
                                    if (dataStr == "null" || dataStr.empty()) {
                                        // Some events might just be signals, but property changes usually have data
                                    } else {
                                        if (name == "duration" || idStr == "1" || idStr == "3" || idStr == "4" || idStr == "100") {
                                            // Duration
                                            double val = ParseDouble(dataStr);
                                            DebugLog("DURATION RECEIVED: " + dataStr);
                                            EnqueueEvent("onDuration", std::make_unique<flutter::EncodableValue>(val));
                                        } else if (idStr == "2" || name == "time-pos") {
                                            // Time Position (ID 2)
                                            double val = ParseDouble(dataStr);
                                            EnqueueEvent("onPosition", std::make_unique<flutter::EncodableValue>(val));
                                        } else if (idStr == "3" || name == "pause") {
                                            // Pause State
                                            bool isPaused = (dataStr.find("true") != std::string::npos);
                                            EnqueueEvent("onState", std::make_unique<flutter::EncodableValue>(!isPaused)); // playing = !paused
                                        } else if (idStr == "4" || name == "core-idle") {
                                            // Buffering State
                                            bool isIdle = (dataStr.find("true") != std::string::npos);
                                            EnqueueEvent("onBuffering", std::make_unique<flutter::EncodableValue>(isIdle));
                                        } else if (idStr == "5" || name == "track-list") {
                                            // Track List
                                            // Pass raw JSON string to Flutter, let it parse
                                            EnqueueEvent("onTracks", std::make_unique<flutter::EncodableValue>(dataStr));
                                        } else if (idStr == "6" || name == "sub-text") {
                                            // Subtitle Text
                                            EnqueueEvent("onSubtitle", std::make_unique<flutter::EncodableValue>(dataStr));
                                        }
                                    }
                                } catch (...) {
                                    DebugLog("Error parsing line: " + line);
                                }
                            }
                        }
                    } else {
                        // ReadFile failed despite Peek saying data was there?
                        DWORD error = GetLastError();
                         if (error == ERROR_BROKEN_PIPE) {
                            DebugLog("VideoPlugin: Pipe broken (disconnected)");
                            break;
                         }
                    }
                } else {
                    // No data available, sleep briefly to let WriteFile get a chance and avoid CPU spin
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                }
            } else {
                DWORD error = GetLastError();
                if (error == ERROR_BROKEN_PIPE) {
                    DebugLog("VideoPlugin: Pipe broken (disconnected during peek)");
                    break;
                } else if (error != ERROR_IO_PENDING) {
                     if (keep_reading_) {
                         DebugLog("VideoPlugin: Pipe peek failed. Error: " + std::to_string(error));
                         // If peek fails repeatedly, we might want to exit or sleep longer
                         std::this_thread::sleep_for(std::chrono::milliseconds(100));
                     }
                }
            }
        }
        DebugLog("VideoPlugin: Read thread stopped");
        keep_reading_ = false;
    });
}

VideoPlugin::VideoPlugin(flutter::BinaryMessenger* messenger, MpvWindow* mpv_window)
    : mpv_window_(mpv_window) {
    
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "zapshare/video_player",
          &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto &call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

VideoPlugin::~VideoPlugin() {
    StopReadThread();
    if (pipe_handle_ != INVALID_HANDLE_VALUE) {
        CloseHandle(pipe_handle_);
    }
}

// Helper to escape strings for JSON
std::string EscapeJsonString(const std::string& s) {
    std::stringstream ss;
    for (char c : s) {
        switch (c) {
            case '\"': ss << "\\\""; break;
            case '\\': ss << "\\\\"; break;
            case '\b': ss << "\\b"; break;
            case '\f': ss << "\\f"; break;
            case '\n': ss << "\\n"; break;
            case '\r': ss << "\\r"; break;
            case '\t': ss << "\\t"; break;
            default:
                if ('\x00' <= c && c <= '\x1f') {
                    ss << "\\u" << std::hex << std::setw(4) << std::setfill('0') << (int)c;
                } else {
                    ss << c;
                }
        }
    }
    return ss.str();
}

void VideoPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    
  const std::string& method_name = method_call.method_name();

  if (method_name == "initialize") {
      // 1. Launch MPV
      wchar_t buffer[MAX_PATH];
      GetModuleFileName(nullptr, buffer, MAX_PATH);
      std::wstring exe_path(buffer);
      std::wstring exe_dir = exe_path.substr(0, exe_path.find_last_of(L"\\/"));
      std::wstring mpv_path = exe_dir + L"\\mpv\\mpv.exe";
      
      // Use a unique pipe name for this instance to avoid conflicts with zombie processes
      char pipe_name[64];
      snprintf(pipe_name, sizeof(pipe_name), "zapshare_mpv_%lu", GetCurrentProcessId());
      std::string pipe_short_name = pipe_name;
      std::string pipe_full_path = "\\\\.\\pipe\\" + pipe_short_name;
      
      DebugLog("Initializing MPV with unique pipe: " + pipe_full_path);
      
      // Check existence first
      if (GetFileAttributesW(mpv_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
          DebugLog("MPV executable NOT FOUND at path.");
           // Convert wstring to string manually
          std::string path_utf8;
          for (wchar_t wc : mpv_path) {
              path_utf8 += (char)wc; 
          }
          result->Error("FILE_NOT_FOUND", "MPV executable not found. Expected at: " + path_utf8);
          return;
      }

      // Pass valid pipe path to MPV
      DWORD launchErr = mpv_window_->LaunchMpv(mpv_path, pipe_full_path);
      if (launchErr != 0) {
          DebugLog("Failed to launch MPV process. Error: " + std::to_string(launchErr));
          result->Error("LAUNCH_FAILED", "Failed to launch MPV process. System Error: " + std::to_string(launchErr));
          return;
      }
      
      // CRITICAL: Immediately show and position the MPV window after launch.
      // At restricted window sizes, no WM_SIZE/WM_MOVE fires, so UpdatePosition
      // from the message handler never triggers — the window stays invisible.
      if (main_hwnd_) {
          mpv_window_->Show();
          mpv_window_->UpdatePosition(main_hwnd_);
          DebugLog("MPV window shown and positioned behind Flutter.");
      }
      
      // 2. Connect to IPC
      // Wait for pipe to be available
      // Try for up to 5 seconds
      bool connected = false;
      for (int i = 0; i < 50; ++i) {
          if (WaitNamedPipeA(pipe_full_path.c_str(), 100)) {
               ConnectToPipe(pipe_full_path);
               if (pipe_handle_ != INVALID_HANDLE_VALUE) {
                   connected = true;
                   DebugLog("Successfully connected to MPV IPC pipe.");
                   break;
               }
          }
          // If WaitNamedPipe failed, it might not exist yet or be busy.
          if (i % 10 == 0) DebugLog("Waiting for MPV pipe... attempt " + std::to_string(i));
          Sleep(100);
      }
      
      if (!connected) {
          // One last try direct open
          ConnectToPipe(pipe_full_path);
          if (pipe_handle_ == INVALID_HANDLE_VALUE) {
               DWORD err = GetLastError();
               DebugLog("Final attempt to connect to pipe failed. Error: " + std::to_string(err));
               // Check if process is still running
               if (!mpv_window_->IsMpvRunning()) {
                   DebugLog("MPV process is NOT running.");
                   result->Error("MPV_EXITED", "MPV process exited unexpectedly during startup");
               } else {
                   DebugLog("MPV process IS running but pipe is unreachable.");
                   result->Error("IPC_FAILED", "Failed to connect to MPV IPC pipe (Timeout). Error: " + std::to_string(err));
               }
               return;
          }
          DebugLog("Connected on final attempt.");
      }
      
      StartReadThread();
      
      // Removed: Initial observe_property calls.
      // We now wait for "file-loaded" event in the read thread before observing properties.
      // This solves the timing issue where properties were observed too early.
      
      // Force MPV to talk to us - verify RX
      SendCommand("{ \"command\": [\"request_log_messages\", \"info\"] }\n");

      // GLOBAL OBSERVERS (Setup once)
      SendCommand("{ \"command\": [\"observe_property\", 1, \"duration\"] }\n");
      SendCommand("{ \"command\": [\"observe_property\", 2, \"time-pos\"] }\n");
      SendCommand("{ \"command\": [\"observe_property\", 3, \"pause\"] }\n");
      SendCommand("{ \"command\": [\"observe_property\", 4, \"core-idle\"] }\n");
      SendCommand("{ \"command\": [\"observe_property\", 5, \"track-list\"] }\n");
      SendCommand("{ \"command\": [\"observe_property\", 6, \"sub-text\"] }\n");
      SendCommand("{ \"command\": [\"set_property\", \"sid\", \"auto\"] }\n");
      
      result->Success();
      
  } else if (method_name == "dispose") {
      StopReadThread();
      // Use Stop() instead of Destroy() — kills MPV process and hides window,
      // but keeps the HWND alive for reuse on next video play.
      mpv_window_->Stop();
      result->Success();

  } else if (method_name == "resize") {
      // Called from Dart after fullscreen toggle to re-sync MPV window position
      if (main_hwnd_ && mpv_window_->IsVideoActive()) {
          mpv_window_->UpdatePosition(main_hwnd_);
      }
      result->Success();
      
  } else if (method_name == "command") {
     const auto* arguments = std::get_if<flutter::EncodableList>(method_call.arguments());
      if (arguments) {
          // Check for loadfile command to reset observer state
          if (arguments->size() > 0) {
              const auto& first_arg = (*arguments)[0];
              if (std::holds_alternative<std::string>(first_arg)) {
                  std::string cmd = std::get<std::string>(first_arg);
                  if (cmd == "loadfile") {
                      observers_initialized_ = false;
                  }
              }
          }

          std::stringstream ss;
         ss << "{ \"command\": [";
         for (size_t i = 0; i < arguments->size(); ++i) {
             if (i > 0) ss << ", ";
             const auto& val = (*arguments)[i];
             if (std::holds_alternative<std::string>(val)) {
                 ss << "\"" << EscapeJsonString(std::get<std::string>(val)) << "\"";
             } else if (std::holds_alternative<double>(val)) {
                  ss << std::get<double>(val);
             } else if (std::holds_alternative<int32_t>(val)) {
                  ss << std::get<int32_t>(val);
             } else if (std::holds_alternative<int64_t>(val)) {
                  ss << std::get<int64_t>(val);
             } else if (std::holds_alternative<bool>(val)) {
                  ss << (std::get<bool>(val) ? "true" : "false");
             }
         }
         ss << "] }\n";
         SendCommand(ss.str());
         result->Success();
     } else {
          result->Error("INVALID_ARGS", "Expected list for command");
      }
   } else if (method_name == "get_property") {
      const auto* args = std::get_if<flutter::EncodableList>(method_call.arguments());
      if (args && args->size() >= 2) {
          std::string name;
          if (std::holds_alternative<std::string>((*args)[0])) {
              name = std::get<std::string>((*args)[0]);
          }
          
          int64_t id = 0;
          const auto& idVal = (*args)[1];
          if (std::holds_alternative<int32_t>(idVal)) id = std::get<int32_t>(idVal);
          else if (std::holds_alternative<int64_t>(idVal)) id = std::get<int64_t>(idVal);

          if (!name.empty() && id != 0) {
              std::stringstream ss;
              ss << "{ \"command\": [\"get_property\", \"" << EscapeJsonString(name) << "\"], \"request_id\": " << id << " }\n";
              SendCommand(ss.str());
              result->Success();
          } else {
              result->Error("INVALID_ARGS", "Invalid arguments for get_property");
          }
      } else {
          result->Error("INVALID_ARGS", "Expected [name, id] for get_property");
      }

  } else {
    result->NotImplemented();
  }
}

void VideoPlugin::ConnectToPipe(const std::string& pipe_name) {
    if (pipe_handle_ != INVALID_HANDLE_VALUE) {
        CloseHandle(pipe_handle_);
    }
    
    pipe_handle_ = CreateFileA(
        pipe_name.c_str(),
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        0,
        nullptr);
}

void VideoPlugin::SendCommand(const std::string& command_json) {
    // Log to Dart
    std::string logCmd = command_json;
    if (!logCmd.empty() && logCmd.back() == '\n') logCmd.pop_back();
    EnqueueEvent("onLog", std::make_unique<flutter::EncodableValue>("MPV OUT: " + logCmd));

    if (pipe_handle_ == INVALID_HANDLE_VALUE) {
        DebugLog("Cannot send command: pipe handle is invalid.");
        return;
    }
    
    DWORD written;
    if (!WriteFile(pipe_handle_, command_json.c_str(), (DWORD)command_json.length(), &written, nullptr)) {
        DebugLog("WriteFile to MPV pipe failed. Error: " + std::to_string(GetLastError()));
    }
    
    if (command_json.empty() || command_json.back() != '\n') {
        char newline = '\n';
        WriteFile(pipe_handle_, &newline, 1, &written, nullptr);
    }
}

// Define custom message for MPV events
#define WM_MPV_EVENT (WM_USER + 101)

void VideoPlugin::EnqueueEvent(const std::string& method, std::unique_ptr<flutter::EncodableValue> value) {
    if (!main_hwnd_) return;
    
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        event_queue_.push_back({ method, std::move(value) });
    }
    
    PostMessage(main_hwnd_, WM_MPV_EVENT, 0, 0);
}

void VideoPlugin::ProcessEvents() {
    std::vector<MpvEvent> events;
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        if (event_queue_.empty()) return;
        // Swap to process outside lock
        events.swap(event_queue_);
    }
    
    for (auto& evt : events) {
         channel_->InvokeMethod(evt.method, std::move(evt.value));
    }
}

// Stop the read thread safely
// We must close the handle to unblock the ReadFile call in the thread.
void VideoPlugin::StopReadThread() {
    keep_reading_ = false;

    // Close handle to interrupt ReadFile
    if (pipe_handle_ != INVALID_HANDLE_VALUE) {
        CloseHandle(pipe_handle_);
        pipe_handle_ = INVALID_HANDLE_VALUE;
    }

    if (read_thread_.joinable()) {
        read_thread_.join();
    }
}
