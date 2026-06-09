#include "mpv_plugin.h"
#include "mpv_window.h"

#include <iostream>
#include <flutter/encodable_value.h>

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::EncodableList;

// static
void MpvPlugin::RegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar_ref, 
                                      MpvWindow* mpv_window) {
  auto plugin = std::make_unique<MpvPlugin>(registrar_ref, mpv_window);
  plugin->GetRegistrar()->AddPlugin(std::move(plugin));
}

MpvPlugin::MpvPlugin(FlutterDesktopPluginRegistrarRef registrar_ref, MpvWindow* mpv_window)
    : registrar_(std::make_unique<flutter::PluginRegistrarWindows>(registrar_ref)),
      mpv_window_(mpv_window) {
      
  channel_ = std::make_unique<MethodChannel<EncodableValue>>(
      registrar_->messenger(), "com.zapshare/mpv_player",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

MpvPlugin::~MpvPlugin() {}

void MpvPlugin::HandleMethodCall(
    const MethodCall<EncodableValue>& method_call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
    
  const auto* arguments = std::get_if<EncodableMap>(method_call.arguments());
  
  if (method_call.method_name() == "launchMpv") {
    LaunchMpv(arguments, std::move(result));
  } else if (method_call.method_name() == "resizeWindow") {
    HandleResizeWindow(arguments, std::move(result));
  } else if (method_call.method_name() == "destroyWindow") {
    HandleDestroyWindow(arguments, std::move(result));
  } else if (method_call.method_name() == "sendCommand") {
    SendCommand(arguments, std::move(result));
  } else if (method_call.method_name() == "setProperty") {
    SetProperty(arguments, std::move(result));
  } else if (method_call.method_name() == "getProperty") {
    GetProperty(arguments, std::move(result));
  } else if (method_call.method_name() == "pollEvents") {
    PollEvents(arguments, std::move(result));
  } else {
    result->NotImplemented();
  }
}

void MpvPlugin::LaunchMpv(const EncodableMap* args,
                          std::unique_ptr<MethodResult<EncodableValue>> result) {
  if (!mpv_window_) {
       result->Error("NO_WINDOW", "MPV Window not initialized");
       return;
  }
  
  auto path_it = args->find(EncodableValue("mpvPath"));
  if (path_it == args->end()) {
      result->Error("INVALID_ARGS", "mpvPath required");
      return;
  }
  
  std::string mpv_path;
  if (std::holds_alternative<std::string>(path_it->second)) {
      mpv_path = std::get<std::string>(path_it->second);
  }
  
  if (mpv_window_->LaunchMpv(mpv_path)) {
       // Start IPC Loop
       if (auto client = mpv_window_->GetIpcClient()) {
           client->StartEventLoop([this](const std::string& event) {
               OnMpvEvent(event);
           });
       }
       result->Success(EncodableValue(mpv_window_->GetPipeName()));
  } else {
       result->Error("LAUNCH_FAILED", "Failed to launch MPV process");
  }
}

void MpvPlugin::HandleResizeWindow(const EncodableMap* args,
                                   std::unique_ptr<MethodResult<EncodableValue>> result) {
    if (!mpv_window_) {
        result->Error("NO_WINDOW", "MPV Window not initialized");
        return;
    }

    int x = 0, y = 0, width = 0, height = 0;
    
    auto x_it = args->find(EncodableValue("x"));
    if (x_it != args->end()) x = std::get<int>(x_it->second);
      
    auto y_it = args->find(EncodableValue("y"));
    if (y_it != args->end()) y = std::get<int>(y_it->second);
      
    auto w_it = args->find(EncodableValue("width"));
    if (w_it != args->end()) width = std::get<int>(w_it->second);
      
    auto h_it = args->find(EncodableValue("height"));
    if (h_it != args->end()) height = std::get<int>(h_it->second);
    
    mpv_window_->SetLayout(x, y, width, height);
    result->Success();
}

void MpvPlugin::HandleDestroyWindow(const EncodableMap* args,
                                    std::unique_ptr<MethodResult<EncodableValue>> result) {
    if (mpv_window_) {
        mpv_window_->Stop();
        result->Success();
    } else {
        result->Error("NO_WINDOW", "MPV Window not initialized");
    }
}

void MpvPlugin::SendCommand(const EncodableMap* args,
                            std::unique_ptr<MethodResult<EncodableValue>> result) {
    auto cmd_it = args->find(EncodableValue("command"));
    if (cmd_it == args->end()) {
        result->Error("INVALID_ARGS", "command required");
        return;
    }
    
    std::string command = std::get<std::string>(cmd_it->second);
    if (mpv_window_->GetIpcClient() && mpv_window_->GetIpcClient()->SendCommand(command)) {
        result->Success();
    } else {
        result->Error("IPC_ERROR", "Failed to send command");
    }
}

void MpvPlugin::SetProperty(const EncodableMap* args,
                            std::unique_ptr<MethodResult<EncodableValue>> result) {
    auto prop_it = args->find(EncodableValue("property"));
    auto val_it = args->find(EncodableValue("value"));
    
    if (prop_it != args->end() && val_it != args->end()) {
        std::string prop = std::get<std::string>(prop_it->second);
        std::string val = std::get<std::string>(val_it->second);
        if (mpv_window_->GetIpcClient() && mpv_window_->GetIpcClient()->SetProperty(prop, val)) {
             result->Success();
        } else {
             result->Error("IPC_ERROR", "Failed to set property");
        }
    } else {
        result->Error("INVALID_ARGS", "property and value required");
    }
}

void MpvPlugin::GetProperty(const EncodableMap* args,
                            std::unique_ptr<MethodResult<EncodableValue>> result) {
    // Basic implementation - for robust sync getters, we might need to block or use callbacks
    // For now, return empty or implement simple read
    result->Success(EncodableValue("")); 
}

void MpvPlugin::OnMpvEvent(const std::string& event_json) {
    std::lock_guard<std::mutex> lock(event_queue_mutex_);
    if (pending_events_.size() < 1000) {
        pending_events_.push_back(event_json);
    }
}

void MpvPlugin::PollEvents(const EncodableMap* args,
                           std::unique_ptr<MethodResult<EncodableValue>> result) {
    std::vector<std::string> events;
    {
        std::lock_guard<std::mutex> lock(event_queue_mutex_);
        events.swap(pending_events_);
    }
    
    EncodableList list;
    for (const auto& evt : events) {
        list.push_back(EncodableValue(evt));
    }
    result->Success(EncodableValue(list));
}
