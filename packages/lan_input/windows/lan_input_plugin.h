#ifndef FLUTTER_PLUGIN_LAN_INPUT_PLUGIN_H_
#define FLUTTER_PLUGIN_LAN_INPUT_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace lan_input {

class NativeBridge;
class FileDragBridge;

class LanInputPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  explicit LanInputPlugin(flutter::PluginRegistrarWindows* registrar);
  ~LanInputPlugin() override;
  LanInputPlugin(const LanInputPlugin&) = delete;
  LanInputPlugin& operator=(const LanInputPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  flutter::PluginRegistrarWindows* registrar_;
  int window_proc_id_ = -1;
  std::unique_ptr<NativeBridge> bridge_;
  std::unique_ptr<FileDragBridge> file_drag_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methods_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
};

}  // namespace lan_input
#endif
