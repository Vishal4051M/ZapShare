#ifndef RUNNER_MPV_PLUGIN_H_
#define RUNNER_MPV_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar.h> // Definitions for Plugin class

#include <memory>
#include <string>
#include <mutex>
#include <vector>

// Forward declaration
class MpvWindow;

using flutter::MethodCall;
using flutter::MethodResult;
using flutter::MethodChannel;

class MpvPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar, 
                                    MpvWindow* mpv_window);
  
  MpvPlugin(FlutterDesktopPluginRegistrarRef registrar, MpvWindow* mpv_window);
  virtual ~MpvPlugin();

 private:
  void HandleMethodCall(
      const MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<MethodResult<flutter::EncodableValue>> result);

  void HandleResizeWindow(const flutter::EncodableMap* args,
                          std::unique_ptr<MethodResult<flutter::EncodableValue>> result);
  void HandleDestroyWindow(const flutter::EncodableMap* args,
                           std::unique_ptr<MethodResult<flutter::EncodableValue>> result);

  void LaunchMpv(const flutter::EncodableMap* args,
                 std::unique_ptr<MethodResult<flutter::EncodableValue>> result);
  void SendCommand(const flutter::EncodableMap* args,
                   std::unique_ptr<MethodResult<flutter::EncodableValue>> result);
  void SetProperty(const flutter::EncodableMap* args,
                   std::unique_ptr<MethodResult<flutter::EncodableValue>> result);
  void GetProperty(const flutter::EncodableMap* args,
                   std::unique_ptr<MethodResult<flutter::EncodableValue>> result);
  void PollEvents(const flutter::EncodableMap* args,
                  std::unique_ptr<MethodResult<flutter::EncodableValue>> result);

  // Helper
  void OnMpvEvent(const std::string& event_json);

  // Access to internal registrar for registration
  flutter::PluginRegistrarWindows* GetRegistrar() { return registrar_.get(); }

  std::unique_ptr<flutter::PluginRegistrarWindows> registrar_;
  std::unique_ptr<MethodChannel<flutter::EncodableValue>> channel_;
  
  MpvWindow* mpv_window_; // Weak reference, owned by FlutterWindow

  std::mutex event_queue_mutex_;
  std::vector<std::string> pending_events_;
};

#endif  // RUNNER_MPV_PLUGIN_H_
