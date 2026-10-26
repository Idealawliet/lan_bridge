import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private weak var mainWindow: NSWindow?
  private var lifecycle: FlutterMethodChannel?
  private var quitting = false
  private var activity: NSObjectProtocol?

  func configureBackground(window: NSWindow, messenger: FlutterBinaryMessenger) {
    mainWindow = window
    lifecycle = FlutterMethodChannel(name: "lan_bridge/lifecycle", binaryMessenger: messenger)
    if statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      item.button?.image = NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "LAN Bridge")
      if item.button?.image == nil { item.button?.title = "LB" }
      let menu = NSMenu()
      let open = NSMenuItem(title: "打开 LAN Bridge", action: #selector(openWindow), keyEquivalent: "")
      open.target = self; menu.addItem(open)
      menu.addItem(.separator())
      let quit = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "q")
      quit.target = self; menu.addItem(quit)
      item.menu = menu; statusItem = item
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
