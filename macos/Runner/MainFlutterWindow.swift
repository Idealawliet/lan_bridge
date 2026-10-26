import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "LAN Bridge"
    self.contentMinSize = NSSize(width: 600, height: 520)
    self.setContentSize(NSSize(width: 1180, height: 800))

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    self.delegate = self
    self.isReleasedWhenClosed = false
    (NSApp.delegate as? AppDelegate)?.configureBackground(window: self,
        messenger: flutterViewController.engine.binaryMessenger)
  }
}
