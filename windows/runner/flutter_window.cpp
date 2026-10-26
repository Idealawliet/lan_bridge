#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include "resource.h"
namespace {
constexpr UINT kTray = WM_APP + 41;
constexpr UINT kQuitReady = WM_APP + 42;
constexpr UINT kShow = 1, kQuit = 2;
std::wstring Wide(const std::string& text) {
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
      static_cast<int>(text.size()), nullptr, 0);
  std::wstring value(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
      value.data(), size);
  return value;
}
const UINT kTaskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
}

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  lifecycle_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "lan_bridge/lifecycle",
      &flutter::StandardMethodCodec::GetInstance());
  lifecycle_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "updateStatus") { result->NotImplemented(); return; }
    const auto* args = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (!args) { result->Error("arguments", "Expected status map"); return; }
    const auto control = args->find(flutter::EncodableValue("control"));
    const auto signal = args->find(flutter::EncodableValue("signal"));
    const auto bars = args->find(flutter::EncodableValue("bars"));
    if (control == args->end() || signal == args->end() || bars == args->end() ||
        !std::holds_alternative<std::string>(control->second) ||
        !std::holds_alternative<std::string>(signal->second) ||
        !std::holds_alternative<int32_t>(bars->second)) {
      result->Error("arguments", "Invalid status fields"); return;
    }
    control_status_ = Wide(std::get<std::string>(control->second));
    signal_status_ = Wide(std::get<std::string>(signal->second));
    signal_bars_ = std::get<int32_t>(bars->second);
    UpdateTray();
    result->Success();
  });
  AddTray();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::AddTray() {
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = GetHandle();
  icon.uID = 1; icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon.uCallbackMessage = kTray;
  icon.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  lstrcpynW(icon.szTip, L"LAN Bridge", ARRAYSIZE(icon.szTip));
  tray_ready_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  if (tray_ready_) UpdateTray();
  if (!tray_ready_ && !IsWindowVisible(GetHandle())) OpenWindow();
}
void FlutterWindow::UpdateTray() {
  if (!tray_ready_) return;
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = GetHandle();
  icon.uID = 1; icon.uFlags = NIF_TIP;
  const auto tip = control_status_ + L"\n" + signal_status_;
  lstrcpynW(icon.szTip, tip.c_str(), ARRAYSIZE(icon.szTip));
  // Render the measured connection quality into the tray icon itself.
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  HBITMAP color = CreateCompatibleBitmap(screen, 32, 32);
  HBITMAP mask = CreateBitmap(32, 32, 1, 1, nullptr);
  if (dc && color && mask) {
    const auto old = SelectObject(dc, color);
    RECT bounds{0, 0, 32, 32};
    FillRect(dc, &bounds, GetSysColorBrush(COLOR_WINDOW));
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(99, 91, 219));
    RECT badge{0, 0, 32, 14};
    DrawTextW(dc, control_status_ == L"正在控制本机" ||
        control_status_ == L"本机正被远端控制" ? L"L" : L"R",
        -1, &badge, DT_CENTER | DT_SINGLELINE);
    for (int i = 0; i < 4; ++i) {
      RECT bar{2 + i * 8, 28 - i * 4, 7 + i * 8, 30};
      HBRUSH brush = CreateSolidBrush(i < signal_bars_
          ? RGB(99, 91, 219) : RGB(170, 170, 170));
      FillRect(dc, &bar, brush); DeleteObject(brush);
    }
    SelectObject(dc, mask);
    PatBlt(dc, 0, 0, 32, 32, BLACKNESS);
    SelectObject(dc, old);
    ICONINFO info{}; info.fIcon = TRUE; info.hbmMask = mask; info.hbmColor = color;
    HICON meter = CreateIconIndirect(&info);
    if (meter) {
      icon.uFlags |= NIF_ICON; icon.hIcon = meter;
      Shell_NotifyIconW(NIM_MODIFY, &icon);
      DestroyIcon(meter);
    } else { Shell_NotifyIconW(NIM_MODIFY, &icon); }
  } else { Shell_NotifyIconW(NIM_MODIFY, &icon); }
  if (color) DeleteObject(color);
  if (mask) DeleteObject(mask);
  if (dc) DeleteDC(dc);
  if (screen) ReleaseDC(nullptr, screen);
}
void FlutterWindow::OpenWindow() {
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
}
void FlutterWindow::RequestQuit() {
  if (quit_pending_ || !lifecycle_) return;
  quit_pending_ = true;
  const HWND window = GetHandle();
  lifecycle_->InvokeMethod("prepareQuit", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [window](const flutter::EncodableValue*) { PostMessageW(window, kQuitReady, 0, 0); },
          [this](const std::string&, const std::string&, const flutter::EncodableValue*) {
            quit_pending_ = false; OpenWindow();
          },
          [this]() { quit_pending_ = false; OpenWindow(); }));
}
void FlutterWindow::OnDestroy() {
  if (tray_ready_) {
    NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = GetHandle(); icon.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &icon); tray_ready_ = false;
  }
  lifecycle_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Handle close before Flutter can interpret it as engine termination.
  if (message == WM_CLOSE && !exiting_) {
    ShowWindow(hwnd, tray_ready_ ? SW_HIDE : SW_MINIMIZE);
    return 0;
  }
  if (message == kTaskbarCreated) { AddTray(); return 0; }
  if (message == kQuitReady) {
    exiting_ = true;
    return Win32Window::MessageHandler(hwnd, WM_CLOSE, 0, 0);
  }
  // The base class clears its HWND during WM_DESTROY, so delete the tray
  // entry while the owner handle is still valid.
  if (message == WM_DESTROY && tray_ready_) {
    NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = hwnd; icon.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &icon); tray_ready_ = false;
  }
  if (message == kTray) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) OpenWindow();
    if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, control_status_.c_str());
      AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, signal_status_.c_str());
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, kShow, L"打开 LAN Bridge");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING | (quit_pending_ ? MF_GRAYED : 0), kQuit, L"退出");
      POINT point{}; GetCursorPos(&point); SetForegroundWindow(hwnd);
      const UINT action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
          point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu); PostMessageW(hwnd, WM_NULL, 0, 0);
      if (action == kShow) OpenWindow();
      if (action == kQuit) RequestQuit();
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_GETMINMAXINFO: {
      const UINT dpi = GetDpiForWindow(hwnd);
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      limits->ptMinTrackSize.x = MulDiv(640, static_cast<int>(dpi), 96);
      limits->ptMinTrackSize.y = MulDiv(560, static_cast<int>(dpi), 96);
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
