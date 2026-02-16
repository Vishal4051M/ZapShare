# Complete MPV IPC Integration Code

This document contains the **exact, complete, and corrected code** for all files involved in the MPV integration.

**Instructions:**
1.  **Replace** the contents of each file with the code blocks below.
2.  **Rebuild** your Windows application (`flutter run -d windows`).

---

## 1. C++ Plugin Implementation (`windows/runner/video_plugin.cpp`)

**Key Fixes:**
*   **Event-Driven Initialization**: Waits for `file-loaded` event from MPV before sending `observe_property` commands. This fixes the duration/seek race condition.
*   **Robust JSON Parsing**: Handles nested objects and arrays correctly.
*   **Correct ID Mapping**: Duration (1), Time (2), Pause (3), Idle (4), Tracks (5), Subs (6).
*   **Subtitle Auto-Start**: Sends `sid=auto` immediately after file load.

```cpp
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

// Robust JSON parser helper
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

                                try {
                                    // CRITICAL: Check for file-loaded event to initialize observers
                                    std::string event = ExtractJsonValue(line, "event");
                                    if (event == "file-loaded") {
                                        DebugLog("MPV: file-loaded detected. Sending observers...");
                                        // Send observers strictly after file is loaded
                                        // ID 1: Duration
                                        SendCommand("{ \"command\": [\"observe_property\", 1, \"duration\"] }\n");
                                        // ID 2: Time Position
                                        SendCommand("{ \"command\": [\"observe_property\", 2, \"time-pos\"] }\n");
                                        // ID 3: Pause State
                                        SendCommand("{ \"command\": [\"observe_property\", 3, \"pause\"] }\n");
                                        // ID 4: Buffering/Idle
                                        SendCommand("{ \"command\": [\"observe_property\", 4, \"core-idle\"] }\n");
                                        // ID 5: Tracks
                                        SendCommand("{ \"command\": [\"observe_property\", 5, \"track-list\"] }\n");
                                        // ID 6: Subtitle Text
                                        SendCommand("{ \"command\": [\"observe_property\", 6, \"sub-text\"] }\n");
                                        
                                        // Enable subtitles by default
                                        SendCommand("{ \"command\": [\"set_property\", \"sid\", \"auto\"] }\n");
                                    }

                                    std::string idStr = ExtractJsonValue(line, "id");
                                    std::string name = ExtractJsonValue(line, "name");
                                    std::string dataStr = ExtractJsonValue(line, "data");

                                    // If data is missing (null/empty), we generally skip unless it's a specific signal
                                    if (dataStr == "null" || dataStr.empty()) {
                                        // Some events might just be signals, but property changes usually have data
                                    } else {
                                        if (idStr == "1" || name == "duration") {
                                            // Duration (ID 1)
                                            double val = ParseDouble(dataStr);
                                            DebugLog("MPV Duration update (ID 1): " + std::to_string(val));
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
      
      // Pass valid pipe path to MPV
      if (!mpv_window_->LaunchMpv(mpv_path, pipe_full_path)) {
          DebugLog("Failed to launch MPV process.");
          result->Error("LAUNCH_FAILED", "Failed to launch MPV process");
          return;
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
      
      // NOTE: We do NOT send observe_property here anymore.
      // We process commands when "file-loaded" event is received in the read thread.
      
      // Force MPV to talk to us - verify RX
      SendCommand("{ \"command\": [\"request_log_messages\", \"info\"] }\n");
      
      result->Success();
      
  } else if (method_name == "dispose") {
      StopReadThread();
      mpv_window_->Destroy();
      result->Success();
      
  } else if (method_name == "command") {
     const auto* arguments = std::get_if<flutter::EncodableList>(method_call.arguments());
     if (arguments) {
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
```

---

## 2. Flutter Platform Implementation (`lib/Screens/shared/native_platform_mpv_player.dart`)

**Key Fixes:**
*   **Simplified Initialization**: Removed `Future.delayed` and manual `observe_property` calls.
*   **Correct Seek Type**: Sends seconds as `double` (float) to MPV.
*   **Track Parsing**: Handles JSON track list parsing.

```dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'video_player_interface.dart';

// -----------------------------------------------------------------------------
// Native Platform MPV Player Implementation
// -----------------------------------------------------------------------------

class NativePlatformMpvPlayer implements PlatformVideoPlayer {
  static const MethodChannel _channel = MethodChannel('zapshare/video_player');

  bool _isInitialized = false;

  // ---------------------------------------------------------------------------
  // Streams
  // ---------------------------------------------------------------------------

  final _playingController = StreamController<bool>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferController = StreamController<Duration>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<bool>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  final _subtitleTracksController =
      StreamController<List<SubtitleTrackInfo>>.broadcast();
  final _audioTracksController =
      StreamController<List<AudioTrackInfo>>.broadcast();
  final _activeSubtitleController =
      StreamController<SubtitleTrackInfo?>.broadcast();
  final _activeAudioController = StreamController<AudioTrackInfo?>.broadcast();
  Duration _currentPosition = Duration.zero;

  Completer<void>? _initCompleter;

  NativePlatformMpvPlayer() {
    _initializeInternal();
  }

  Future<void> _initializeInternal() async {
    if (_initCompleter != null) return _initCompleter!.future;
    _initCompleter = Completer<void>();

    try {
      debugPrint("NativePlatformMpvPlayer: Connecting to native plugin...");
      _channel.setMethodCallHandler(_handleMethodCall);
      await _channel.invokeMethod('initialize');

      // Note: We do NOT set observers here. C++ handles "file-loaded" event.
      
      _isInitialized = true;
      debugPrint("NativePlatformMpvPlayer: Initialized successfully.");
      _initCompleter!.complete();
    } catch (e) {
      debugPrint("MPV Init Error: $e");
      _errorController.add(e.toString());
      _initCompleter!.completeError(e);
      _initCompleter = null; // Allow retry
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    // Uncomment for detailed IPC logs
    debugPrint("[MPV IPC] Received: ${call.method} with args: ${call.arguments}");

    switch (call.method) {
      case 'onPosition':
        if (call.arguments is num) {
          final positionSeconds = (call.arguments as num).toDouble();
          final position = Duration(
            milliseconds: (positionSeconds * 1000).round(),
          );
          _positionController.add(position);
          _currentPosition = position;
        }
        break;
      case 'onDuration':
        if (call.arguments is num) {
          final durationSeconds = (call.arguments as num).toDouble();
          final duration = Duration(
            milliseconds: (durationSeconds * 1000).round(),
          );
          // Always process duration updates from native side
          _durationController.add(duration);
          _handleDurationUpdate(duration);
        }
        break;
      case 'onState':
        if (call.arguments is bool) {
          final isPlaying = call.arguments as bool;
          _playingController.add(isPlaying);
        }
        break;
      case 'onBuffering':
        if (call.arguments is bool) {
          final isBuffering = call.arguments as bool;
          _bufferingController.add(isBuffering);
        }
        break;
      case 'onError':
        debugPrint("MPV Player Error from Native: ${call.arguments}");
        _errorController.add(call.arguments.toString());
        break;
      case 'onTracks':
        if (call.arguments is String) {
          try {
            final List<dynamic> tracks = jsonDecode(call.arguments as String);
            _handleTrackUpdate(tracks);
          } catch (e) {
            debugPrint("Error parsing tracks: $e");
          }
        }
        break;
      case 'onSubtitle':
        // Optional: Expose subtitle text to UI if needed
        break;
    }
  }

  void _handleTrackUpdate(List<dynamic> tracks) {
    final subs = <SubtitleTrackInfo>[];
    final audios = <AudioTrackInfo>[];
    SubtitleTrackInfo? activeSub;
    AudioTrackInfo? activeAudio;

    for (var t in tracks) {
      if (t is! Map) continue;
      final type = t['type'];
      final id = t['id'];
      final lang = t['lang'] ?? 'unknown';
      final title = t['title'] ?? t['label'] ?? 'Track $id';
      final selected = t['selected'] == true;

      if (type == 'sub') {
        final info = SubtitleTrackInfo(
          id: id.toString(),
          title: "$title ($lang)",
          language: lang,
        );
        subs.add(info);
        if (selected) activeSub = info;
      } else if (type == 'audio') {
        final info = AudioTrackInfo(
          id: id.toString(),
          title: "$title ($lang)",
          language: lang,
        );
        audios.add(info);
        if (selected) activeAudio = info;
      }
    }

    _subtitleTracksController.add(subs);
    _audioTracksController.add(audios);
    _activeSubtitleController.add(activeSub);
    _activeAudioController.add(activeAudio);
  }

  // ---------------------------------------------------------------------------
  // PlatformVideoPlayer Implementation
  // ---------------------------------------------------------------------------

  @override
  Future<void> open(String source, {String? subtitlePath}) async {
    if (!_isInitialized) await _initializeInternal();

    // Reset state
    _currentPosition = Duration.zero;
    _positionController.add(Duration.zero);

    // Load file
    await _sendCommand(['loadfile', source]);

    // Note: C++ now handles 'file-loaded' event automatically to start observers
    
    // Start polling fallback just in case IPC event is missed (safety net)
    _startDurationPolling();

    // Auto-play
    await play();

    if (subtitlePath != null) {
      await _sendCommand(['sub-add', subtitlePath]);
    }
  }

  // Duration polling timer (Safety Net)
  Timer? _durationTimer;
  Duration _lastKnownDuration = Duration.zero;

  void _startDurationPolling() {
    _durationTimer?.cancel();
    _lastKnownDuration = Duration.zero;

    // Poll every 1 second until we get a valid duration
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_lastKnownDuration.inMilliseconds > 0) {
        timer.cancel(); // We have duration, stop polling
        return;
      }
      // Retry observing if stuck
      _sendCommand(['observe_property', 1, 'duration']);
    });
  }

  // Handle duration updates to stop polling
  void _handleDurationUpdate(Duration dur) {
    debugPrint("NativePlatformMpvPlayer: Duration update received: $dur");
    if (dur.inMilliseconds > 0) {
      _lastKnownDuration = dur;
      _durationTimer?.cancel();
      _durationTimer = null;
    }
  }

  bool _localPlayingState = false;

  @override
  Future<void> play() async {
    _localPlayingState = true;
    _playingController.add(true);
    await _sendCommand(['set', 'pause', 'no']);
  }

  @override
  Future<void> pause() async {
    _localPlayingState = false;
    _playingController.add(false);
    await _sendCommand(['set', 'pause', 'yes']);
  }

  @override
  Future<void> playOrPause() async {
    if (_localPlayingState) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    _currentPosition = position;
    _positionController.add(position);

    // Use floating point seconds for precision
    final seconds = position.inMilliseconds / 1000.0;
    // Send as double for correct JSON serialization
    await _sendCommand(['seek', seconds, 'absolute']);
  }

  @override
  Future<void> setRate(double speed) async {
    await _sendCommand(['set', 'speed', speed]);
  }

  @override
  Future<void> setVolume(double volume) async {
    await _sendCommand(['set', 'volume', volume]);
  }

  @override
  Future<void> dispose() async {
    _stopPolling();
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}

    _playingController.close();
    _positionController.close();
    _durationController.close();
    _bufferController.close();
    _bufferingController.close();
    _completedController.close();
    _errorController.close();

    _subtitleTracksController.close();
    _audioTracksController.close();
    _activeSubtitleController.close();
    _activeAudioController.close();
  }

  @override
  Future<void> setSubtitleTrack(dynamic track) async {
    if (track == null) {
      await _sendCommand(['set', 'sid', 'no']);
    } else if (track is SubtitleTrackInfo) {
      await _sendCommand(['set', 'sid', track.id]);
    }
  }

  @override
  Future<void> setAudioTrack(dynamic track) async {
    if (track is AudioTrackInfo) {
      await _sendCommand(['set', 'aid', track.id]);
    }
  }
  
  // Getters
  Duration get currentPosition => _currentPosition;
  @override
  Stream<bool> get playingStream => _playingController.stream;
  @override
  Stream<Duration> get positionStream => _positionController.stream;
  @override
  Stream<Duration> get durationStream => _durationController.stream;
  @override
  Stream<Duration> get bufferStream => _bufferController.stream;
  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;
  @override
  Stream<bool> get completedStream => _completedController.stream;
  @override
  Stream<String> get errorStream => _errorController.stream;
  @override
  Stream<List<SubtitleTrackInfo>> get subtitleTracksStream => _subtitleTracksController.stream;
  @override
  Stream<List<AudioTrackInfo>> get audioTracksStream => _audioTracksController.stream;
  @override
  Stream<SubtitleTrackInfo?> get activeSubtitleTrackStream => _activeSubtitleController.stream;
  @override
  Stream<AudioTrackInfo?> get activeAudioTrackStream => _activeAudioController.stream;

  @override
  Widget buildVideoWidget({BoxFit? fit, Color? backgroundColor, Widget Function(BuildContext)? subtitleBuilder}) {
    return _NativeMpvWidget(player: this);
  }

  @override
  Future<void> setProperty(String key, String value) async {
    await _sendCommand(['set', key, value]);
  }

  Future<void> _sendCommand(List<dynamic> args) async {
    try {
      await _channel.invokeMethod('command', args);
    } on PlatformException catch (e) {
      debugPrint("Command failed: ${e.message}");
    }
  }

  void _stopPolling() {}
}

class _NativeMpvWidget extends StatefulWidget {
  final NativePlatformMpvPlayer player;
  const _NativeMpvWidget({Key? key, required this.player}) : super(key: key);
  @override
  State<_NativeMpvWidget> createState() => _NativeMpvWidgetState();
}

class _NativeMpvWidgetState extends State<_NativeMpvWidget> {
  String? _error;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    widget.player.errorStream.listen((err) {
      if (mounted) setState(() => _error = err);
    });
    Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (widget.player._isInitialized && !_initialized) {
        setState(() => _initialized = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Container(
        color: Colors.black,
        child: Center(child: Text("Player Error:\n$_error", style: const TextStyle(color: Colors.red))),
      );
    }
    return Container(
      color: Colors.transparent,
      child: Stack(
        children: [
          GestureDetector(
            onTap: () => widget.player.playOrPause(),
            behavior: HitTestBehavior.translucent,
            child: Container(color: Colors.transparent),
          ),
          if (!_initialized)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }
}
```
