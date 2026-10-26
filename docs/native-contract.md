# Native bridge contract

Package: `lan_input`. Channels: `lan_input/methods`, `lan_input/events`.
Windows plugin class: `LanInputPluginCApi`; macOS class: `LanInputPlugin`.
Only Windows and macOS are supported. All coordinates use the primary display's native coordinate system (Windows physical pixels, macOS CG display points). Screen sizes may differ; crossing uses normalized vertical position.

Methods:
- `getStatus` -> `{supported: bool, accessibility: bool, inputMonitoring: bool, screen: {x: double, y: double, width: double, height: double}}`
- `requestPermissions` -> request macOS Accessibility/Input Monitoring, no-op Windows.
- `startCapture` -> enable global mouse monitoring. Capture keys/buttons/scroll only while remote. Must fail explicitly without permissions.
- `stopCapture` -> disable hooks/tap; restore local input; release injected keys/buttons.
- `setRemoteCapture` `{enabled: bool}` -> when true, suppress physical local keyboard/mouse, emit input events; immediately restore on false.
  Enabling must fail with `input_busy` if any physical key or mouse button is held; the app retries on a later edge movement. Held-key/button dragging across displays is not supported.
- `heartbeat` -> refresh a native deadman timer. If no heartbeat for 2500 ms, disable remote suppression and release injected inputs, emit `captureLost`.
- `inject` `{event: {...}}` -> replay an input event, ignoring tagged injected events in capture.
- `warp` `{x: double, y: double}` -> position local pointer on primary display.
- `releaseAll` -> release all injected keys/buttons.

Events (maps):
- `{type: 'move', x: double, y: double, dx: double, dy: double}`. In local mode x/y are absolute. In remote mode dx/dy are relative physical movement with no anchor warps or injected events reflected back.
- `{type: 'button', button: int, down: bool}` buttons 1=left, 2=right, 3=middle, 4=back, 5=forward.
- `{type: 'key', usage: int, down: bool}` USB HID keyboard usage page 0x07, including modifiers E0-E7; unmapped keys ignored.
- `{type: 'scroll', dx: double, dy: double}` wheel detents, positive dy scrolls up, positive dx scrolls right.
- `{type: 'emergency'}` Ctrl+Alt+Escape (macOS Ctrl+Option+Escape). Restore local input synchronously before emitting; available on source and target.
- `{type: 'captureLost', message: String}` native tap/hook disabled or heartbeat expired.

Injection supports move `{type:'move',x,y}`, button/key/scroll as above. Clamp positions. Validate all method arguments. Track and release injected inputs on shutdown, emergency, disconnect. Restore any cursor association/clipping. Do not record keystrokes or request elevated privileges automatically. The source owns physical input; target does not forward physical events.


## v0.2 文件拖放与剪贴板

新增方法：`clipboardRevision`、`clipboardHasFiles`、`configureFileEdge(enabled,left)`、`prepareFileDrag`、`cancelLocalDrag`、`beginFileDrag(paths)`、`cancelFileDrag`。

边缘捕获 `fileDrag` 事件包含绝对路径数组 `paths` 与原生屏幕纵坐标 `y`（控制器再归一化）。接收文件完整校验后调用 `beginFileDrag`；原生层报告 `fileDragReady`，源端才恢复转发移动。`fileDragEnded` 表示系统会话结束。准备阶段提前松开会取消传输，两端释放模拟输入。Windows 使用 CF_HDROP / OLE，macOS 使用文件 URL / NSDraggingSession，复制语义，缓存需留存供系统读取。边缘仅在已配对连接中启用。


## v0.3 四向文件边缘

`configureFileEdge` 增加 `edge: left|right|top|bottom`、归一化 `start`/`end` 参数。边缘窗口仅覆盖相接段；原来的 `left` 布尔参数仅保留给关闭边缘的兼容调用。`fileDrag` 同时包含原生 `x`/`y` 坐标。Windows 坐标向下递增，macOS 文件事件使用 CGEvent 坐标，NSPanel 放置时转换 AppKit 的向上坐标。上下布局按 x 映射，左右布局按 y 映射。


## v0.7 捕获模式边界

原生 `move` 增加布尔字段 `captured`：false 为本地指针坐标采样，true 为已接管的相对移动。事件合并时不能跨越该字段的变化。Dart 忽略与当前远程状态不符的移动，避免接管前积压的本地移动在进入目标后造成跳变。坐标继续使用各平台原生单位，跨屏比例与相对增量缩放由 Dart 统一处理。


## v0.8.1 光标与文件剪贴板

`setCursorVisible({visible: bool})` 控制本机显示状态，与来源端 `setRemoteCapture` 的捕获状态分开。客户端已连接但未接管时隐藏，`enter` 后显示，`leave` 后隐藏；停止捕获、断线、紧急恢复、原生心跳超时均恢复。来源端远程捕获仍优先隐藏本地光标。

文件剪贴板优先于图片预览与文本。使用已有系统 `Pasteboard.files/writeFiles`（macOS 文件 URL / Windows CF_HDROP），通过 `share` 文件流同步原字节。`offer.clipboard=true` 与 `drag=true` 互斥；剪贴板同步开启时自动接受，校验完成后写入接收方本地路径。传输中本机剪贴板发生变化或同步暂停时，不覆盖新内容。系统文件写入只在活动配对会话中执行，不传递来源端绝对路径。

控制会话协议为 7；两端需一起升级。鼠标发送队列可每 4 ms 合并，接收队列仅合并相邻有效绝对鼠标位置；所有按键、按钮、滚轮、enter/leave/layout 都是不可跨越的顺序边界。
