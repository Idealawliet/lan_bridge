import Cocoa

/// File URLs are copied through a real AppKit dragging session. The small edge
/// window accepts system file drags at the paired screen boundary.
final class FileDragBridge: NSObject, NSDraggingSource {
    var emit: ([String: Any]) -> Void = { _ in }
    private var edgeWindow: NSWindow?
    private var edgeView: FileEdgeView?
    private var dragWindow: NSWindow?
    private var session: NSDraggingSession?
    private static let marker: Int64 = 0x4C414E494E505554

    func configure(enabled: Bool, left: Bool) {
        configure(enabled: enabled, edge: left ? "left" : "right", start: 0, end: 1)
    }
    func configure(enabled: Bool, edge: String, start: Double, end: Double) {
        if !enabled { edgeWindow?.orderOut(nil); return }
        if edgeWindow == nil {
            let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .statusBar
            window.isOpaque = false
            window.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.12)
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = FileEdgeView()
            view.onFiles = { [weak self] urls, point in
                self?.emit(["type": "fileDrag", "paths": urls.map { $0.path }, "x": point.x, "y": point.y])
            }
            window.contentView = view
            edgeWindow = window; edgeView = view
        }
        // NSScreen uses bottom-left; CGEvent uses the main display's top-left.
        guard let screen = NSScreen.screens.first else { return }
        let frame = screen.frame
        edgeView?.armed = true
        let horizontal = edge == "left" || edge == "right"
        let start = CGFloat(start), end = CGFloat(end)
        let rect = horizontal
            ? NSRect(x: edge == "left" ? frame.minX : frame.maxX - 8,
                     y: frame.maxY - end * frame.height, width: 8, height: (end - start) * frame.height)
            : NSRect(x: frame.minX + start * frame.width,
                     y: edge == "top" ? frame.maxY - 8 : frame.minY,
                     width: (end - start) * frame.width, height: 8)
        edgeWindow?.setFrame(rect, display: true)
        edgeWindow?.orderFrontRegardless()
    }

    func begin(paths: [String]) -> String? {
        guard session == nil, !paths.isEmpty else { return "A native drag is already active" }
        let point = NSEvent.mouseLocation
        let window = NSWindow(contentRect: NSRect(x: point.x - 2, y: point.y - 2, width: 8, height: 8), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        window.contentView = view; window.orderFrontRegardless()
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 2, y: 2), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { window.close(); return "Cannot create drag event" }
        let items = paths.map { path -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: NSURL(fileURLWithPath: path))
            let image = NSWorkspace.shared.icon(forFile: path)
            item.setDraggingFrame(NSRect(x: 2, y: 2, width: 32, height: 32), contents: image)
            return item
        }
        dragWindow = window
        session = view.beginDraggingSession(with: items, event: event, source: self)
        session?.animatesToStartingPositionsOnCancelOrFail = false
        return nil
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        emit(["type": "fileDragReady"])
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        self.session = nil
        dragWindow?.close(); dragWindow = nil
        emit(["type": "fileDragEnded", "cancelled": operation.isEmpty])
    }
    func cancel() {
        if session != nil { Self.cancelLocal() }
    }
    static func cancelLocal() {
        for down in [true, false] {
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down) {
                event.setIntegerValueField(.eventSourceUserData, value: marker); event.post(tap: .cghidEventTap)
            }
        }
        if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero, mouseButton: .left) {
            event.setIntegerValueField(.eventSourceUserData, value: marker); event.post(tap: .cghidEventTap)
        }
    }
}

private final class FileEdgeView: NSView {
    var armed = true
    var onFiles: ([URL], CGPoint) -> Void = { _, _ in }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard armed, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty, urls.count <= 10000 else { return [] }
        armed = false
        let point = CGEvent(source: nil)?.location ?? .zero
        // Leave AppKit's callback before cancelling the original drag.
        DispatchQueue.main.async { [weak self] in self?.onFiles(urls, point) }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}
