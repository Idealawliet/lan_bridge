import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private weak var mainWindow: NSWindow?
  private var lifecycle: FlutterMethodChannel?
  private var quitting = false
  private var controlItem: NSMenuItem?
  private var signalItem: NSMenuItem?
  private var activity: NSObjectProtocol?

  func configureBackground(window: NSWindow, messenger: FlutterBinaryMessenger) {
    mainWindow = window
    lifecycle = FlutterMethodChannel(name: "lan_bridge/lifecycle", binaryMessenger: messenger)
    if statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.button?.image = NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "LAN Bridge")
      if item.button?.image == nil { item.button?.title = "LB" }
      let menu = NSMenu()
      let control = NSMenuItem(title: "正在控制本机", action: nil, keyEquivalent: "")
      let signal = NSMenuItem(title: "未连接", action: nil, keyEquivalent: "")
      menu.addItem(control); menu.addItem(signal); menu.addItem(.separator())
      controlItem = control; signalItem = signal
      let open = NSMenuItem(title: "打开 LAN Bridge", action: #selector(openWindow), keyEquivalent: "")
      open.target = self; menu.addItem(open)
      menu.addItem(.separator())
      let quit = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "q")
      quit.target = self; menu.addItem(quit)
      item.menu = menu; statusItem = item
    }
    lifecycle?.setMethodCallHandler { [weak self] call, result in
      if call.method == "quit" {
        result(nil)
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return
      }
      guard call.method == "updateStatus",
            let args = call.arguments as? [String: Any],
            let control = args["control"] as? String,
            let signal = args["signal"] as? String,
            let bars = args["bars"] as? Int else {
        result(FlutterMethodNotImplemented); return
      }
      let level = max(0, min(4, bars))
      let meter = String(repeating: "▰", count: level) + String(repeating: "▱", count: 4 - level)
      self?.controlItem?.title = control
      self?.signalItem?.title = signal
      self?.statusItem?.button?.title = " \(control == "正在控制本机" || control == "本机正被远端控制" ? "本" : "远") \(meter)"
      self?.statusItem?.button?.toolTip = "\(control)\n\(signal)"
      self?.statusItem?.button?.setAccessibilityLabel("LAN Bridge · \(control) · \(signal)")
      result(nil)
    }
    // Heartbeats and input forwarding must continue while the UI is hidden.
    activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
        reason: "LAN Bridge keyboard and mouse sharing")
  }
  @objc private func openWindow() {
    mainWindow?.deminiaturize(nil)
    mainWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc private func quitApplication() { NSApp.terminate(nil) }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitting { return .terminateCancel }
    guard let lifecycle = lifecycle else { return .terminateNow }
    quitting = true
    lifecycle.invokeMethod("prepareQuit", arguments: nil) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }
        let notImplemented = (result as? NSObject) === FlutterMethodNotImplemented
        if result is FlutterError || notImplemented {
          self.quitting = false
          self.openWindow()
          sender.reply(toApplicationShouldTerminate: false)
          return
        }
        if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        sender.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
  }
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    openWindow(); return false
  }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
