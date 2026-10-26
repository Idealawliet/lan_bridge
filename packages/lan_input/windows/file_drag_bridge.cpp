#include "file_drag_bridge.h"
#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>
#include <atomic>
#include <algorithm>
#include <thread>
#include <utility>
#include <cstring>
#include <chrono>
namespace lan_input {
namespace {
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
constexpr ULONG_PTR marker = static_cast<ULONG_PTR>(0x4C414E4252494447ULL);
std::string Utf8(const std::wstring& value) {
  const int n = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string out(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), out.data(), n, nullptr, nullptr);
  return out;
}
void Mouse(bool down) {
  INPUT input{}; input.type = INPUT_MOUSE;
  input.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
  input.mi.dwExtraInfo = marker; SendInput(1, &input, sizeof(INPUT));
}
void Escape() {
  INPUT input[2]{};
  for (auto& i : input) { i.type = INPUT_KEYBOARD; i.ki.wVk = VK_ESCAPE; i.ki.dwExtraInfo = marker; }
  input[1].ki.dwFlags = KEYEVENTF_KEYUP; SendInput(2, input, sizeof(INPUT));
}
class FilesData final : public IDataObject {
 public:
  explicit FilesData(std::vector<std::wstring> paths) : paths_(std::move(paths)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) { return E_POINTER; }
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_IDataObject) { *out = static_cast<IDataObject*>(this); AddRef(); return S_OK; } return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override { auto n = --refs_; if (!n) delete this; return n; }
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* fmt, STGMEDIUM* medium) override {
    if (!medium) return E_POINTER;
    if (QueryGetData(fmt) != S_OK) return DV_E_FORMATETC;
    size_t chars = 1;
    for (auto& path : paths_) chars += path.size() + 1;
    HGLOBAL memory = GlobalAlloc(GHND, sizeof(DROPFILES) + chars * sizeof(wchar_t));
    if (!memory) return E_OUTOFMEMORY;
    auto* drop = static_cast<DROPFILES*>(GlobalLock(memory));
    if (!drop) { GlobalFree(memory); return E_OUTOFMEMORY; }
    drop->pFiles = sizeof(DROPFILES); drop->fWide = TRUE;
    auto* next = reinterpret_cast<wchar_t*>(reinterpret_cast<BYTE*>(drop) + sizeof(DROPFILES));
    for (auto& path : paths_) { std::memcpy(next, path.c_str(), (path.size() + 1) * sizeof(wchar_t)); next += path.size() + 1; }
    *next = 0; GlobalUnlock(memory);
    medium->tymed = TYMED_HGLOBAL; medium->hGlobal = memory; medium->pUnkForRelease = nullptr; return S_OK;
  }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* fmt) override {
    return fmt && fmt->cfFormat == CF_HDROP && (fmt->tymed & TYMED_HGLOBAL) && fmt->dwAspect == DVASPECT_CONTENT ? S_OK : DV_E_FORMATETC;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC* out) override { if (out) out->ptd = nullptr; return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction, IEnumFORMATETC** out) override {
    if (direction != DATADIR_GET) return E_NOTIMPL;
    FORMATETC format{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL}; return SHCreateStdEnumFmtEtc(1, &format, out);
  }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override { return OLE_E_ADVISENOTSUPPORTED; }
 private:
  std::atomic<ULONG> refs_{1};
  std::vector<std::wstring> paths_;
};
class DragSource final : public IDropSource {
 public:
  DragSource(std::atomic<bool>& cancel, FileDragBridge::Callback callback) : cancel_(cancel), callback_(std::move(callback)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) { return E_POINTER; }
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_IDropSource) { *out = static_cast<IDropSource*>(this); AddRef(); return S_OK; } return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override { auto n = --refs_; if (!n) delete this; return n; }
  HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape, DWORD keys) override {
    if (escape || cancel_) return DRAGDROP_S_CANCEL;
    if (!(keys & MK_LBUTTON)) return DRAGDROP_S_DROP;
    if (!ready_) { ready_ = true; callback_({{V("type"), V("fileDragReady")}}); }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override { return DRAGDROP_S_USEDEFAULTCURSORS; }
 private:
  std::atomic<ULONG> refs_{1};
  std::atomic<bool>& cancel_; FileDragBridge::Callback callback_; bool ready_ = false;
};
class EdgeTarget final : public IDropTarget {
 public:
  explicit EdgeTarget(FileDragBridge::Callback callback) : callback_(std::move(callback)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) { return E_POINTER; }
    *out = nullptr;
    if (iid == IID_IUnknown || iid == IID_IDropTarget) { *out = static_cast<IDropTarget*>(this); AddRef(); return S_OK; } return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override { auto n = --refs_; if (!n) delete this; return n; }
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL point, DWORD* effect) override {
    *effect = DROPEFFECT_NONE;
    FORMATETC format{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL}; STGMEDIUM medium{};
    if (armed_ && SUCCEEDED(data->GetData(&format, &medium))) {
      auto drop = static_cast<HDROP>(medium.hGlobal);
      const UINT count = DragQueryFileW(drop, 0xffffffff, nullptr, 0);
      flutter::EncodableList paths;
      if (count <= 10000) {
        for (UINT i = 0; i < count; ++i) {
          const UINT length = DragQueryFileW(drop, i, nullptr, 0);
          std::wstring path(length + 1, L'\0'); DragQueryFileW(drop, i, path.data(), length + 1); path.resize(length);
          paths.emplace_back(Utf8(path));
        }
      }
      ReleaseStgMedium(&medium);
      if (!paths.empty()) {
        armed_ = false; *effect = DROPEFFECT_COPY;
        callback_({{V("type"), V("fileDrag")}, {V("paths"), V(paths)}, {V("x"), V(static_cast<double>(point.x))}, {V("y"), V(static_cast<double>(point.y))}});
      }
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override { *effect = DROPEFFECT_NONE; return S_OK; }
  HRESULT STDMETHODCALLTYPE DragLeave() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject*, DWORD, POINTL, DWORD* effect) override { *effect = DROPEFFECT_NONE; return S_OK; }
  void Arm() { armed_ = true; }
 private:
  std::atomic<ULONG> refs_{1}; FileDragBridge::Callback callback_; bool armed_ = true;
};
}
struct FileDragBridge::State {
  Callback callback; HWND edge = nullptr; EdgeTarget* target = nullptr;
  bool ole = false; std::atomic<bool> cancel{false}, running{false}; std::thread thread;
  std::atomic<bool> stopWatch{false};
  std::atomic<ULONGLONG> heartbeat{GetTickCount64()};
  std::thread watchdog;
};
FileDragBridge::FileDragBridge(Callback callback) : state_(std::make_unique<State>()) {
  state_->callback = std::move(callback); state_->ole = SUCCEEDED(OleInitialize(nullptr));
  auto* state = state_.get();
  state_->watchdog = std::thread([state] {
    while (!state->stopWatch) {
      if (state->running && GetTickCount64() - state->heartbeat.load() > 2500) {
        state->cancel = true; Escape(); Mouse(false);
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  });
}
FileDragBridge::~FileDragBridge() {
  state_->stopWatch = true; state_->watchdog.join();
  Cancel(); if (state_->thread.joinable()) state_->thread.join();
  if (state_->edge) { RevokeDragDrop(state_->edge); DestroyWindow(state_->edge); }
  if (state_->target) state_->target->Release();
  if (state_->ole) OleUninitialize();
}
std::string FileDragBridge::Configure(bool enabled, const std::string& edge, double start, double end) {
  if (!enabled) { if (state_->edge) ShowWindow(state_->edge, SW_HIDE); return {}; }
  if (!state_->ole) return "OLE initialization failed";
  if (!state_->edge) {
    state_->edge = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
        L"STATIC", L"LAN Bridge file edge", WS_POPUP, 0, 0, 8, 8, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!state_->edge) return "Cannot create file drop edge";
    SetLayeredWindowAttributes(state_->edge, 0, 32, LWA_ALPHA);
    state_->target = new EdgeTarget(state_->callback);
    if (FAILED(RegisterDragDrop(state_->edge, state_->target))) {
      DestroyWindow(state_->edge); state_->edge = nullptr;
      state_->target->Release(); state_->target = nullptr;
      return "Cannot register file drop edge";
    }
  }
  state_->target->Arm();
  const int width = GetSystemMetrics(SM_CXSCREEN), height = GetSystemMetrics(SM_CYSCREEN);
  const bool horizontal = edge == "left" || edge == "right";
  const int length = horizontal ? height : width;
  const int begin = static_cast<int>(start * length);
  const int extent = std::max(1, static_cast<int>(end * length) - begin);
  SetWindowPos(state_->edge, HWND_TOPMOST,
      horizontal ? (edge == "left" ? 0 : width - 8) : begin,
      horizontal ? begin : (edge == "top" ? 0 : height - 8),
      horizontal ? 8 : extent, horizontal ? extent : 8, SWP_NOACTIVATE | SWP_SHOWWINDOW);
  return {};
}
std::string FileDragBridge::Begin(const std::vector<std::wstring>& paths) {
  if (paths.empty() || state_->running) return "A file drag is already running or has no files";
  if (state_->thread.joinable()) state_->thread.join();
  state_->cancel = false; state_->running = true;
  auto* state = state_.get();
  state_->thread = std::thread([state, paths] {
    const HRESULT ole = OleInitialize(nullptr);
    if (FAILED(ole)) { state->running = false; state->callback({{V("type"),V("fileDragEnded")},{V("cancelled"),V(true)}}); return; }
    auto* data = new FilesData(paths); auto* source = new DragSource(state->cancel, state->callback);
    Mouse(true); DWORD effect = DROPEFFECT_NONE;
    const HRESULT result = DoDragDrop(data, source, DROPEFFECT_COPY, &effect);
    Mouse(false); data->Release(); source->Release(); OleUninitialize(); state->running = false;
    state->callback({{V("type"),V("fileDragEnded")},{V("cancelled"),V(result != DRAGDROP_S_DROP || effect == DROPEFFECT_NONE)}});
  });
  return {};
}
void FileDragBridge::Cancel() { state_->cancel = true; if (state_->running) { Escape(); Mouse(false); } }
void FileDragBridge::Heartbeat() { state_->heartbeat = GetTickCount64(); }
void FileDragBridge::CancelLocalDrag() { Escape(); Mouse(false); }
}
