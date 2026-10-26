#include "lan_input_plugin.h"
#include "file_drag_bridge.h"

#include <flutter/standard_method_codec.h>
#include <flutter/event_stream_handler_functions.h>
#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <future>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace lan_input {
namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kDeliverEvents = WM_APP + 0x31D;
constexpr UINT kRunTask = WM_APP + 0x31E;
constexpr ULONG_PTR kInjectedTag = static_cast<ULONG_PTR>(0x4C414E4252494447ULL);
constexpr ULONGLONG kDeadmanMs = 2500;

struct Key {
  int usage;
  WORD scan;
  bool extended;
};

// USB keyboard usage page 0x07 -> Windows set-1 scan codes. Physical
// positions, including left/right modifiers, survive differing OS layouts.
constexpr Key kKeys[] = {
    {0x04, 0x1e, false}, {0x05, 0x30, false}, {0x06, 0x2e, false},
    {0x07, 0x20, false}, {0x08, 0x12, false}, {0x09, 0x21, false},
    {0x0a, 0x22, false}, {0x0b, 0x23, false}, {0x0c, 0x17, false},
    {0x0d, 0x24, false}, {0x0e, 0x25, false}, {0x0f, 0x26, false},
    {0x10, 0x32, false}, {0x11, 0x31, false}, {0x12, 0x18, false},
    {0x13, 0x19, false}, {0x14, 0x10, false}, {0x15, 0x13, false},
    {0x16, 0x1f, false}, {0x17, 0x14, false}, {0x18, 0x16, false},
    {0x19, 0x2f, false}, {0x1a, 0x11, false}, {0x1b, 0x2d, false},
    {0x1c, 0x15, false}, {0x1d, 0x2c, false}, {0x1e, 0x02, false},
    {0x1f, 0x03, false}, {0x20, 0x04, false}, {0x21, 0x05, false},
    {0x22, 0x06, false}, {0x23, 0x07, false}, {0x24, 0x08, false},
    {0x25, 0x09, false}, {0x26, 0x0a, false}, {0x27, 0x0b, false},
    {0x28, 0x1c, false}, {0x29, 0x01, false}, {0x2a, 0x0e, false},
    {0x2b, 0x0f, false}, {0x2c, 0x39, false}, {0x2d, 0x0c, false},
    {0x2e, 0x0d, false}, {0x2f, 0x1a, false}, {0x30, 0x1b, false},
    {0x31, 0x2b, false}, {0x33, 0x27, false}, {0x34, 0x28, false},
    {0x35, 0x29, false}, {0x36, 0x33, false}, {0x37, 0x34, false},
    {0x38, 0x35, false}, {0x39, 0x3a, false}, {0x3a, 0x3b, false},
    {0x3b, 0x3c, false}, {0x3c, 0x3d, false}, {0x3d, 0x3e, false},
    {0x3e, 0x3f, false}, {0x3f, 0x40, false}, {0x40, 0x41, false},
    {0x41, 0x42, false}, {0x42, 0x43, false}, {0x43, 0x44, false},
    {0x44, 0x57, false}, {0x45, 0x58, false}, {0x46, 0x37, true},
    {0x47, 0x46, false}, {0x48, 0x45, false}, {0x49, 0x52, true},
    {0x4a, 0x47, true}, {0x4b, 0x49, true}, {0x4c, 0x53, true},
    {0x4d, 0x4f, true}, {0x4e, 0x51, true}, {0x4f, 0x4d, true},
    {0x50, 0x4b, true}, {0x51, 0x50, true}, {0x52, 0x48, true},
    {0x53, 0x45, true}, {0x54, 0x35, true}, {0x55, 0x37, false},
    {0x56, 0x4a, false}, {0x57, 0x4e, false}, {0x58, 0x1c, true},
    {0x59, 0x4f, false}, {0x5a, 0x50, false}, {0x5b, 0x51, false},
    {0x5c, 0x4b, false}, {0x5d, 0x4c, false}, {0x5e, 0x4d, false},
    {0x5f, 0x47, false}, {0x60, 0x48, false}, {0x61, 0x49, false},
    {0x62, 0x52, false}, {0x63, 0x53, false}, {0x64, 0x56, false},
    {0x65, 0x5d, true}, {0x68, 0x64, false}, {0x69, 0x65, false},
    {0x6a, 0x66, false}, {0x6b, 0x67, false}, {0x6c, 0x68, false},
    {0x6d, 0x69, false}, {0x6e, 0x6a, false}, {0x6f, 0x6b, false},
    {0x70, 0x6c, false}, {0x71, 0x6d, false}, {0x72, 0x6e, false},
    {0x73, 0x76, false}, {0x87, 0x73, false}, {0x89, 0x7d, false},
    {0x8a, 0x79, false}, {0x8b, 0x7b, false}, {0xe0, 0x1d, false},
    {0xe1, 0x2a, false}, {0xe2, 0x38, false}, {0xe3, 0x5b, true},
    {0xe4, 0x1d, true}, {0xe5, 0x36, false}, {0xe6, 0x38, true},
    {0xe7, 0x5c, true},
};

const Key* FindKey(int usage) {
  for (const auto& key : kKeys) {
    if (key.usage == usage) return &key;
  }
  return nullptr;
}

int UsageFor(const KBDLLHOOKSTRUCT& event) {
  if (event.vkCode == VK_PAUSE) return 0x48;
  if (event.vkCode == VK_NUMLOCK) return 0x53;
  const bool extended = (event.flags & LLKHF_EXTENDED) != 0;
  for (const auto& key : kKeys) {
    if (key.scan == event.scanCode && key.extended == extended) {
      return key.usage;
    }
  }
  return 0;
}

const Value* Field(const Map& map, const char* name) {
  const auto it = map.find(Value(name));
  return it == map.end() ? nullptr : &it->second;
}

bool Number(const Map& map, const char* name, double& output) {
  const Value* value = Field(map, name);
  if (!value) return false;
  if (const auto* number = std::get_if<double>(value)) output = *number;
  else if (const auto* number = std::get_if<int32_t>(value)) output = *number;
  else if (const auto* number = std::get_if<int64_t>(value)) {
    output = static_cast<double>(*number);
  } else return false;
  return std::isfinite(output);
}

bool Boolean(const Map& map, const char* name, bool& output) {
  const Value* value = Field(map, name);
  if (!value) return false;
  const auto* boolean = std::get_if<bool>(value);
  if (!boolean) return false;
  output = *boolean;
  return true;
}

std::string String(const Map& map, const char* name) {
  const Value* value = Field(map, name);
  if (value) {
    if (const auto* string = std::get_if<std::string>(value)) return *string;
  }
  return {};
}

RECT PrimaryScreen() {
  POINT point{0, 0};
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (GetMonitorInfoW(MonitorFromPoint(point, MONITOR_DEFAULTTOPRIMARY), &info)) {
    return info.rcMonitor;
  }
  return RECT{0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)};
}

Map MouseMove(POINT point, double dx, double dy, bool captured) {
  return {{Value("type"), Value("move")},
          {Value("x"), Value(static_cast<double>(point.x))},
          {Value("y"), Value(static_cast<double>(point.y))},
          {Value("dx"), Value(dx)}, {Value("dy"), Value(dy)},
          {Value("captured"), Value(captured)}};
}

Map KeyEvent(int usage, bool down) {
  return {{Value("type"), Value("key")}, {Value("usage"), Value(usage)},
          {Value("down"), Value(down)}};
}

Map ButtonEvent(int button, bool down) {
  return {{Value("type"), Value("button")}, {Value("button"), Value(button)},
          {Value("down"), Value(down)}};
}

}  // namespace

// All hooks, SendInput state, and the deadman live on a dedicated message-loop
// thread. A stalled Flutter/UI thread cannot keep physical input suppressed.
class NativeBridge {
 public:
  explicit NativeBridge(HWND window) : window_(window) {
    worker_ = std::thread([this] { Run(); });
    std::unique_lock<std::mutex> lock(start_mutex_);
    started_.wait(lock, [this] { return ready_; });
  }

  ~NativeBridge() {
    Invoke([this] {
      StopCapture();
      PostQuitMessage(0);
    });
    worker_.join();
  }

  template <typename Function>
  auto Invoke(Function function) -> decltype(function()) {
    using Result = decltype(function());
    auto task = std::make_shared<std::packaged_task<Result()>>(std::move(function));
    auto future = task->get_future();
    auto callback = new std::function<void()>([task] { (*task)(); });
    if (!PostThreadMessageW(thread_id_, kRunTask, 0,
                            reinterpret_cast<LPARAM>(callback))) {
      delete callback;
      throw std::runtime_error("Native input thread is unavailable");
    }
    return future.get();
  }

  std::deque<Map> DrainEvents() {
    std::lock_guard<std::mutex> lock(event_mutex_);
    std::deque<Map> result;
    result.swap(event_queue_);
    return result;
  }

  std::string StartCapture() {
    if (keyboard_hook_ && mouse_hook_) return {};
    StopCapture();
    HMODULE module = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&KeyboardProc), &module);
    keyboard_hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardProc, module, 0);
    mouse_hook_ = SetWindowsHookExW(WH_MOUSE_LL, MouseProc, module, 0);
    if (!keyboard_hook_ || !mouse_hook_) {
      const DWORD error = GetLastError();
      StopCapture();
      return "Cannot install Windows input hooks (error " +
             std::to_string(error) + ")";
    }
    last_heartbeat_ = GetTickCount64();
    GetCursorPos(&last_mouse_);
    // Seed modifiers held before monitoring began, without logging local keys.
    const std::pair<int, int> modifiers[] = {
        {VK_LCONTROL, 0xe0}, {VK_LSHIFT, 0xe1}, {VK_LMENU, 0xe2},
        {VK_LWIN, 0xe3}, {VK_RCONTROL, 0xe4}, {VK_RSHIFT, 0xe5},
        {VK_RMENU, 0xe6}, {VK_RWIN, 0xe7}};
    for (const auto& modifier : modifiers) {
      if (GetAsyncKeyState(modifier.first) & 0x8000) {
        physical_keys_.insert(modifier.second);
      }
    }
    return {};
  }

  void StopCapture() {
    remote_ = false;
    if (keyboard_hook_) UnhookWindowsHookEx(keyboard_hook_);
    if (mouse_hook_) UnhookWindowsHookEx(mouse_hook_);
    keyboard_hook_ = nullptr;
    mouse_hook_ = nullptr;
    ReleaseAll();
    physical_keys_.clear();
    physical_buttons_.clear();
    std::lock_guard<std::mutex> lock(event_mutex_);
    event_queue_.clear();
  }

  std::string SetRemote(bool enabled, bool file_drag = false) {
    if (enabled && file_drag && !(GetAsyncKeyState(VK_LBUTTON) & 0x8000)) return "input_busy";
    if (enabled && (!keyboard_hook_ || !mouse_hook_)) {
      return "Start input capture before sharing input";
    }
    if (enabled == remote_) return {};
    if (enabled) {
      for (int key = 1; key < 256; ++key) {
        if (file_drag && key == VK_LBUTTON) continue;
        if (GetAsyncKeyState(key) & 0x8000) return "input_busy";
      }
      if (!physical_keys_.empty() || (!physical_buttons_.empty() &&
          !(file_drag && physical_buttons_.size() == 1 && physical_buttons_.count(1)))) {
        return "input_busy";
      }
    }
    remote_ = enabled;
    if (enabled) {
      const RECT screen = PrimaryScreen();
      anchor_ = POINT{screen.left + (screen.right - screen.left) / 2,
                      screen.top + (screen.bottom - screen.top) / 2};
      if (!MovePointer(anchor_.x, anchor_.y)) {
        remote_ = false;
        return "Windows rejected cursor positioning";
      }
    } else {
      GetCursorPos(&last_mouse_);
    }
    return {};
  }

  void Heartbeat() { last_heartbeat_ = GetTickCount64(); }
  void ExternalEvent(Map event) { Emit(std::move(event)); }

  bool MovePointer(double x, double y) {
    const RECT screen = PrimaryScreen();
    x = std::clamp(x, static_cast<double>(screen.left),
                   static_cast<double>(screen.right - 1));
    y = std::clamp(y, static_cast<double>(screen.top),
                   static_cast<double>(screen.bottom - 1));
    const int virtual_x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int virtual_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int virtual_width = std::max(1, GetSystemMetrics(SM_CXVIRTUALSCREEN));
    const int virtual_height = std::max(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));
    INPUT input{};
    input.type = INPUT_MOUSE;
    // Target the centre of a native pixel in the 0..65535 absolute interval.
    input.mi.dx = static_cast<LONG>((x - virtual_x + 0.5) * 65536.0 /
                                   virtual_width);
    input.mi.dy = static_cast<LONG>((y - virtual_y + 0.5) * 65536.0 /
                                   virtual_height);
    input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                       MOUSEEVENTF_VIRTUALDESK;
    input.mi.dwExtraInfo = kInjectedTag;
    return SendInput(1, &input, sizeof(INPUT)) == 1;
  }

  std::string Inject(const Map& event) {
    const std::string type = String(event, "type");
    if (type == "move") {
      double x = 0, y = 0;
      if (!Number(event, "x", x) || !Number(event, "y", y)) {
        return "A move requires finite x and y coordinates";
      }
      if (!MovePointer(x, y)) return InjectionFailure();
    } else if (type == "key") {
      double usage_value = 0;
      bool down = false;
      if (!Number(event, "usage", usage_value) ||
          usage_value != std::floor(usage_value) || usage_value < 0 ||
          usage_value > 255 || !Boolean(event, "down", down)) {
        return "A key requires an integer USB usage and boolean down";
      }
      const int usage = static_cast<int>(usage_value);
      // Some platform-specific usages have no Windows equivalent.
      if (!FindKey(usage)) return {};
      if (!SendKey(usage, down)) return InjectionFailure();
      if (down) injected_keys_.insert(usage);
      else injected_keys_.erase(usage);
    } else if (type == "button") {
      double button_value = 0;
      bool down = false;
      if (!Number(event, "button", button_value) ||
          button_value != std::floor(button_value) || button_value < 1 ||
          button_value > 5 || !Boolean(event, "down", down)) {
        return "A button requires an integer 1..5 and boolean down";
      }
      const int button = static_cast<int>(button_value);
      if (!SendButton(button, down)) return InjectionFailure();
      if (down) injected_buttons_.insert(button);
      else injected_buttons_.erase(button);
    } else if (type == "scroll") {
      double dx = 0, dy = 0;
      if (!Number(event, "dx", dx) || !Number(event, "dy", dy) ||
          std::abs(dx) > 1000 || std::abs(dy) > 1000) {
        return "Scroll deltas must be finite and within +/-1000 detents";
      }
      scroll_x_ += dx * WHEEL_DELTA;
      scroll_y_ += dy * WHEEL_DELTA;
      const LONG horizontal = static_cast<LONG>(std::trunc(scroll_x_));
      const LONG vertical = static_cast<LONG>(std::trunc(scroll_y_));
      scroll_x_ -= horizontal;
      scroll_y_ -= vertical;
      if (!SendWheel(horizontal, true) || !SendWheel(vertical, false)) {
        return InjectionFailure();
      }
    } else {
      return "Unsupported input event type";
    }
    return {};
  }

  void ReleaseAll() {
    for (int usage : injected_keys_) SendKey(usage, false);
    for (int button : injected_buttons_) SendButton(button, false);
    injected_keys_.clear();
    injected_buttons_.clear();
    scroll_x_ = scroll_y_ = 0;
  }

 private:
  static std::string InjectionFailure() {
    return "Windows rejected SendInput. Elevated windows and the secure "
           "desktop cannot be controlled by a normal-privilege process.";
  }

  static bool SendKey(int usage, bool down) {
    const Key* key = FindKey(usage);
    if (!key) return true;
    INPUT input{};
    input.type = INPUT_KEYBOARD;
    input.ki.dwExtraInfo = kInjectedTag;
    if (usage == 0x48) {
      input.ki.wVk = VK_PAUSE;
      input.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
    } else {
      input.ki.wScan = key->scan;
      input.ki.dwFlags = KEYEVENTF_SCANCODE |
                         (key->extended ? KEYEVENTF_EXTENDEDKEY : 0) |
                         (down ? 0 : KEYEVENTF_KEYUP);
    }
    return SendInput(1, &input, sizeof(INPUT)) == 1;
  }

  static bool SendButton(int button, bool down) {
    INPUT input{};
    input.type = INPUT_MOUSE;
    input.mi.dwExtraInfo = kInjectedTag;
    switch (button) {
      case 1:
        input.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
        break;
      case 2:
        input.mi.dwFlags = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
        break;
      case 3:
        input.mi.dwFlags = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
        break;
      case 4:
      case 5:
        input.mi.dwFlags = down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
        input.mi.mouseData = button == 4 ? XBUTTON1 : XBUTTON2;
        break;
      default:
        return false;
    }
    return SendInput(1, &input, sizeof(INPUT)) == 1;
  }

  static bool SendWheel(LONG amount, bool horizontal) {
    if (amount == 0) return true;
    INPUT input{};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
    input.mi.mouseData = static_cast<DWORD>(amount);
    input.mi.dwExtraInfo = kInjectedTag;
    return SendInput(1, &input, sizeof(INPUT)) == 1;
  }

  void Emit(Map event) {
    bool post = false;
    {
      std::lock_guard<std::mutex> lock(event_mutex_);
      post = event_queue_.empty();
      bool old_capture = false, capture = false;
      Boolean(event, "captured", capture);
      if (!event_queue_.empty()) Boolean(event_queue_.back(), "captured", old_capture);
      // Mouse motion is losslessly coalesced, without moving across a key,
      // button, or scroll event in the queue.
      if (!event_queue_.empty() && old_capture == capture && String(event, "type") == "move" &&
          String(event_queue_.back(), "type") == "move") {
        double old_dx = 0, old_dy = 0, dx = 0, dy = 0;
        Number(event_queue_.back(), "dx", old_dx);
        Number(event_queue_.back(), "dy", old_dy);
        Number(event, "dx", dx);
        Number(event, "dy", dy);
        event[Value("dx")] = Value(old_dx + dx);
        event[Value("dy")] = Value(old_dy + dy);
        event_queue_.back() = std::move(event);
      } else if (event_queue_.size() < 2048) {
        event_queue_.push_back(std::move(event));
      } else {
        remote_ = false;
        ReleaseAll();
        event_queue_.clear();
        event_queue_.push_back(
            {{Value("type"), Value("captureLost")},
             {Value("message"), Value("Input queue overflow; local control restored")}});
      }
    }
    if (post) PostMessageW(window_, kDeliverEvents, 0, 0);
  }

  void Run() {
    current_ = this;
    MSG message{};
    PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
    const UINT_PTR timer = SetTimer(nullptr, 0, 100, nullptr);
    {
      std::lock_guard<std::mutex> lock(start_mutex_);
      thread_id_ = GetCurrentThreadId();
      ready_ = true;
    }
    started_.notify_one();
    last_heartbeat_ = GetTickCount64();
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
      if (message.message == kRunTask) {
        std::unique_ptr<std::function<void()>> callback(
            reinterpret_cast<std::function<void()>*>(message.lParam));
        (*callback)();
      } else if (message.message == WM_TIMER) {
        if ((keyboard_hook_ || mouse_hook_ || !injected_keys_.empty() ||
             !injected_buttons_.empty()) &&
            GetTickCount64() - last_heartbeat_ > kDeadmanMs) {
          StopCapture();
          Emit({{Value("type"), Value("captureLost")},
                {Value("message"), Value("Heartbeat expired; local control restored")}});
        }
      } else {
        TranslateMessage(&message);
        DispatchMessageW(&message);
      }
    }
    if (timer) KillTimer(nullptr, timer);
    StopCapture();
    current_ = nullptr;
  }

  static LRESULT CALLBACK KeyboardProc(int code, WPARAM message, LPARAM data) {
    NativeBridge* self = current_;
    if (code < 0 || !self) return CallNextHookEx(nullptr, code, message, data);
    const auto& event = *reinterpret_cast<const KBDLLHOOKSTRUCT*>(data);
    // Ignore all synthetic events, including other accessibility software.
    // Only physical input is forwarded; our tagged releases cannot loop.
    if (event.dwExtraInfo == kInjectedTag || (event.flags & LLKHF_INJECTED)) {
      return CallNextHookEx(nullptr, code, message, data);
    }
    const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
    const int usage = UsageFor(event);
    if (usage != 0) {
      if (down) self->physical_keys_.insert(usage);
      else self->physical_keys_.erase(usage);
    }
    const auto& keys = self->physical_keys_;
    const bool control = keys.count(0xe0) || keys.count(0xe4);
    const bool alt = keys.count(0xe2) || keys.count(0xe6);
    if (down && event.vkCode == VK_ESCAPE && control && alt) {
      self->remote_ = false;
      self->ReleaseAll();
      self->Emit({{Value("type"), Value("emergency")}});
      GetCursorPos(&self->last_mouse_);
      return 1;
    }
    if (self->remote_) {
      if (usage != 0) self->Emit(KeyEvent(usage, down));
      return 1;
    }
    return CallNextHookEx(nullptr, code, message, data);
  }

  static LRESULT CALLBACK MouseProc(int code, WPARAM message, LPARAM data) {
    NativeBridge* self = current_;
    if (code < 0 || !self) return CallNextHookEx(nullptr, code, message, data);
    const auto& event = *reinterpret_cast<const MSLLHOOKSTRUCT*>(data);
    if (event.dwExtraInfo == kInjectedTag || (event.flags & LLMHF_INJECTED)) {
      return CallNextHookEx(nullptr, code, message, data);
    }
    if (message == WM_MOUSEMOVE) {
      const POINT origin = self->remote_ ? self->anchor_ : self->last_mouse_;
      const double dx = static_cast<double>(event.pt.x - origin.x);
      const double dy = static_cast<double>(event.pt.y - origin.y);
      self->last_mouse_ = event.pt;
      if (!self->remote_ || dx != 0 || dy != 0) {
        self->Emit(MouseMove(event.pt, dx, dy, self->remote_));
      }
      if (self->remote_) {
        // Re-anchoring is tagged and ignored by the hooks, so a source screen
        // edge never clips continued relative movement on the target.
        self->MovePointer(self->anchor_.x, self->anchor_.y);
        return 1;
      }
    } else if (message == WM_MOUSEWHEEL || message == WM_MOUSEHWHEEL) {
      if (self->remote_) {
        const double delta = static_cast<double>(static_cast<SHORT>(
                                 HIWORD(event.mouseData))) / WHEEL_DELTA;
        self->Emit({{Value("type"), Value("scroll")},
                    {Value("dx"), Value(message == WM_MOUSEHWHEEL ? delta : 0.0)},
                    {Value("dy"), Value(message == WM_MOUSEWHEEL ? delta : 0.0)}});
        return 1;
      }
    } else {
      int button = 0;
      bool down = false;
      switch (message) {
        case WM_LBUTTONDOWN: button = 1; down = true; break;
        case WM_LBUTTONUP: button = 1; break;
        case WM_RBUTTONDOWN: button = 2; down = true; break;
        case WM_RBUTTONUP: button = 2; break;
        case WM_MBUTTONDOWN: button = 3; down = true; break;
        case WM_MBUTTONUP: button = 3; break;
        case WM_XBUTTONDOWN:
          button = HIWORD(event.mouseData) == XBUTTON1 ? 4 : 5;
          down = true;
          break;
        case WM_XBUTTONUP:
          button = HIWORD(event.mouseData) == XBUTTON1 ? 4 : 5;
          break;
      }
      if (button) {
        if (down) self->physical_buttons_.insert(button);
        else self->physical_buttons_.erase(button);
        if (self->remote_) {
          self->Emit(ButtonEvent(button, down));
          return 1;
        }
      }
    }
    return CallNextHookEx(nullptr, code, message, data);
  }

  HWND window_;
  std::thread worker_;
  DWORD thread_id_ = 0;
  std::mutex start_mutex_;
  std::condition_variable started_;
  bool ready_ = false;
  std::mutex event_mutex_;
  std::deque<Map> event_queue_;
  HHOOK keyboard_hook_ = nullptr;
  HHOOK mouse_hook_ = nullptr;
  bool remote_ = false;
  ULONGLONG last_heartbeat_ = 0;
  POINT anchor_{};
  POINT last_mouse_{};
  std::set<int> physical_keys_;
  std::set<int> physical_buttons_;
  std::set<int> injected_keys_;
  std::set<int> injected_buttons_;
  double scroll_x_ = 0, scroll_y_ = 0;
  static thread_local NativeBridge* current_;
};

thread_local NativeBridge* NativeBridge::current_ = nullptr;

void LanInputPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<LanInputPlugin>(registrar));
}

LanInputPlugin::LanInputPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
        if (message != kDeliverEvents || !bridge_) return std::nullopt;
        for (auto& event : bridge_->DrainEvents()) {
          if (sink_) sink_->Success(Value(std::move(event)));
        }
        return 0;
      });
  const HWND window = GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
  bridge_ = std::make_unique<NativeBridge>(window);
  file_drag_ = std::make_unique<FileDragBridge>([this](Map event) {
    bridge_->Invoke([this, event = std::move(event)]() mutable { bridge_->ExternalEvent(std::move(event)); });
  });
  methods_ = std::make_unique<flutter::MethodChannel<Value>>(
      registrar_->messenger(), "lan_input/methods",
      &flutter::StandardMethodCodec::GetInstance());
  methods_->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call,
             std::unique_ptr<flutter::MethodResult<Value>> result) {
        HandleMethodCall(call, std::move(result));
      });
  events_ = std::make_unique<flutter::EventChannel<Value>>(
      registrar_->messenger(), "lan_input/events",
      &flutter::StandardMethodCodec::GetInstance());
  events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
      [this](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink)
          -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
        sink_ = std::move(sink);
        return nullptr;
      },
      [this](const Value*)
          -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
        bridge_->Invoke([this] { bridge_->StopCapture(); });
        sink_.reset();
        return nullptr;
      }));
}

LanInputPlugin::~LanInputPlugin() {
  file_drag_.reset();
  methods_->SetMethodCallHandler(nullptr);
  events_->SetStreamHandler(nullptr);
  bridge_.reset();
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
}

void LanInputPlugin::HandleMethodCall(
    const flutter::MethodCall<Value>& call,
    std::unique_ptr<flutter::MethodResult<Value>> result) {
  const auto* arguments = call.arguments()
                              ? std::get_if<Map>(call.arguments())
                              : nullptr;
  const std::string& method = call.method_name();
  try {
    if (method == "getStatus") {
      const RECT screen = PrimaryScreen();
      result->Success(Value(Map{
          {Value("supported"), Value(true)},
          {Value("accessibility"), Value(true)},
          {Value("inputMonitoring"), Value(true)},
          {Value("screen"), Value(Map{
               {Value("x"), Value(static_cast<double>(screen.left))},
               {Value("y"), Value(static_cast<double>(screen.top))},
               {Value("width"), Value(static_cast<double>(screen.right - screen.left))},
               {Value("height"), Value(static_cast<double>(screen.bottom - screen.top))}})}}));
      return;
    }
    if (method == "requestPermissions") {
      result->Success();
      return;
    }
    std::string error;
    if (method == "clipboardRevision") {
      result->Success(Value(static_cast<int64_t>(GetClipboardSequenceNumber()))); return;
    } else if (method == "clipboardHasFiles") {
      result->Success(Value(IsClipboardFormatAvailable(CF_HDROP) != FALSE)); return;
    } else if (method == "configureFileEdge") {
      bool enabled = false, left = false;
      if (!arguments || !Boolean(*arguments, "enabled", enabled)) { result->Error("invalid_arguments", "enabled required"); return; }
      Boolean(*arguments, "left", left);
      std::string edge = String(*arguments, "edge");
      if (edge.empty()) edge = left ? "left" : "right";
      double start = 0, end = 1;
      if ((Field(*arguments, "start") && !Number(*arguments, "start", start)) ||
          (Field(*arguments, "end") && !Number(*arguments, "end", end)) ||
          start < 0 || end > 1 || start >= end ||
          (edge != "left" && edge != "right" && edge != "top" && edge != "bottom")) {
        result->Error("invalid_arguments", "Invalid edge geometry"); return;
      }
      error = file_drag_->Configure(enabled, edge, start, end);
    } else if (method == "prepareFileDrag") {
      error = bridge_->Invoke([this] { return bridge_->SetRemote(true, true); });
      if (error.empty()) FileDragBridge::CancelLocalDrag();
    } else if (method == "cancelLocalDrag") {
      FileDragBridge::CancelLocalDrag();
    } else if (method == "cancelFileDrag") {
      file_drag_->Cancel();
    } else if (method == "beginFileDrag") {
      const Value* value = arguments ? Field(*arguments, "paths") : nullptr;
      const auto* list = value ? std::get_if<flutter::EncodableList>(value) : nullptr;
      if (!list || list->empty() || list->size() > 10000) { result->Error("invalid_arguments", "paths required"); return; }
      std::vector<std::wstring> paths;
      for (const auto& item : *list) {
        const auto* path = std::get_if<std::string>(&item);
        if (!path || path->empty() || path->find('\0') != std::string::npos) { result->Error("invalid_arguments", "invalid path"); return; }
        const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(), static_cast<int>(path->size()), nullptr, 0);
        if (!n) { result->Error("invalid_arguments", "invalid UTF8 path"); return; }
        std::wstring wide(n, L'\0'); MultiByteToWideChar(CP_UTF8, 0, path->data(), static_cast<int>(path->size()), wide.data(), n); paths.push_back(std::move(wide));
      }
      error = file_drag_->Begin(paths);
    } else if (method == "startCapture") {
      error = bridge_->Invoke([this] { return bridge_->StartCapture(); });
    } else if (method == "stopCapture") {
      file_drag_->Configure(false, "left"); file_drag_->Cancel();
      bridge_->Invoke([this] { bridge_->StopCapture(); });
    } else if (method == "heartbeat") {
      file_drag_->Heartbeat();
      bridge_->Invoke([this] { bridge_->Heartbeat(); });
    } else if (method == "releaseAll") {
      bridge_->Invoke([this] { bridge_->ReleaseAll(); });
    } else if (method == "setRemoteCapture") {
      bool enabled = false;
      if (!arguments || !Boolean(*arguments, "enabled", enabled)) {
        result->Error("invalid_arguments", "enabled must be a boolean");
        return;
      }
      error = bridge_->Invoke([this, enabled] { return bridge_->SetRemote(enabled); });
    } else if (method == "warp") {
      double x = 0, y = 0;
      if (!arguments || !Number(*arguments, "x", x) || !Number(*arguments, "y", y)) {
        result->Error("invalid_arguments", "warp requires finite x and y");
        return;
      }
      const bool moved = bridge_->Invoke([this, x, y] { return bridge_->MovePointer(x, y); });
      if (!moved) error = "Windows rejected cursor positioning";
    } else if (method == "inject") {
      const Value* value = arguments ? Field(*arguments, "event") : nullptr;
      const auto* event = value ? std::get_if<Map>(value) : nullptr;
      if (!event) {
        result->Error("invalid_arguments", "inject requires an event map");
        return;
      }
      error = bridge_->Invoke([this, event] { return bridge_->Inject(*event); });
    } else {
      result->NotImplemented();
      return;
    }
    if (error == "input_busy") {
      result->Error("input_busy", "Release keys and mouse buttons before crossing screens");
    } else if (error.empty()) result->Success();
    else result->Error("native_input_error", error);
  } catch (const std::exception& exception) {
    result->Error("native_input_error", exception.what());
  }
}

}  // namespace lan_input
