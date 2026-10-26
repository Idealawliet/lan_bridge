#ifndef LAN_INPUT_FILE_DRAG_BRIDGE_H_
#define LAN_INPUT_FILE_DRAG_BRIDGE_H_
#include <windows.h>
#include <flutter/encodable_value.h>
#include <functional>
#include <memory>
#include <string>
#include <vector>
namespace lan_input {
class FileDragBridge {
 public:
  using Callback = std::function<void(flutter::EncodableMap)>;
  explicit FileDragBridge(Callback callback);
  ~FileDragBridge();
  std::string Configure(bool enabled, const std::string& edge, double start = 0, double end = 1);
  std::string Begin(const std::vector<std::wstring>& paths);
  void Cancel();
  void Heartbeat();
  static void CancelLocalDrag();
 private:
  struct State;
  std::unique_ptr<State> state_;
};
}
#endif
