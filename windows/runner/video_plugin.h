#ifndef RUNNER_VIDEO_PLUGIN_H_
#define RUNNER_VIDEO_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/binary_messenger.h>
#include <memory>
#include <thread>
#include <atomic>
#include <string>
#include <windows.h>
#include <vector>
#include <mutex>

#include "mpv_window.h"

class VideoPlugin {
 public:
  VideoPlugin(flutter::BinaryMessenger* messenger, MpvWindow* mpv_window);
  virtual ~VideoPlugin();

  // Disallow copy and assign.
  VideoPlugin(const VideoPlugin&) = delete;
  VideoPlugin& operator=(const VideoPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  MpvWindow* mpv_window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  
  // IPC
  HANDLE pipe_handle_ = INVALID_HANDLE_VALUE;
  std::thread read_thread_;
  std::atomic<bool> keep_reading_ = false;
  
  void ConnectToPipe(const std::string& pipe_name);
  void SendCommand(const std::string& command_json);
  void StartReadThread();
  void StopReadThread();
  
  // Helpers
  // int64_t request_id_ = 1; 

  // Thread safety
  friend class FlutterWindow;
  void SetMainWindow(HWND hwnd) { main_hwnd_ = hwnd; }
  void ProcessEvents();
  
  struct MpvEvent {
      std::string method;
      std::unique_ptr<flutter::EncodableValue> value;
  };
  
  HWND main_hwnd_ = nullptr;
  std::mutex queue_mutex_;
  std::vector<MpvEvent> event_queue_;
  std::atomic<bool> observers_initialized_ = false; 

  void EnqueueEvent(const std::string& method, std::unique_ptr<flutter::EncodableValue> value);
};

#endif  // RUNNER_VIDEO_PLUGIN_H_
