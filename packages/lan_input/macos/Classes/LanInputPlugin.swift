import Cocoa
import FlutterMacOS
import ApplicationServices

/// All global monitoring is opt-in. Keyboard events are forwarded only while
/// remote capture is enabled; local keystrokes are never sent to Dart.
public final class LanInputPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let lock = NSRecursiveLock()
    private var sink: FlutterEventSink?
    private lazy var fileDrag: FileDragBridge = {
        let bridge = FileDragBridge()
        bridge.emit = { [weak self] event in self?.emit(event) }
        return bridge
    }()
    private var pendingEvents = [[String: Any]]()
    private var deliveryScheduled = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExited: DispatchSemaphore?
    private var watchdog: DispatchSourceTimer?
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var watchdogTripped = false
    private var remote = false
    private var switchShortcutEnabled = false
    private var switchShortcutPending = false
    private var switchShortcutKeyDown = false
    private var cursorHidden = false
    private var cursorVisible = true
    private var injectedKeys = Set<Int>()
    private var injectedButtons = Set<Int>()
    private var capsLock = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var lastClickButton = 0
    private var clickCount: Int64 = 1
    private var scrollCarryX = 0.0
    private var scrollCarryY = 0.0
    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()
    private static let marker: Int64 = 0x4C414E494E505554

    // USB HID keyboard page 0x07 -> macOS hardware virtual keycodes. Physical
    // positions are preserved; text uses the receiver's active keyboard layout.
    private static let keyCodes: [Int: CGKeyCode] = [
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3,
        0x0A: 5, 0x0B: 4, 0x0C: 34, 0x0D: 38, 0x0E: 40, 0x0F: 37,
        0x10: 46, 0x11: 45, 0x12: 31, 0x13: 35, 0x14: 12, 0x15: 15,
        0x16: 1, 0x17: 17, 0x18: 32, 0x19: 9, 0x1A: 13, 0x1B: 7,
        0x1C: 16, 0x1D: 6,
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23,
        0x23: 22, 0x24: 26, 0x25: 28, 0x26: 25, 0x27: 29,
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49,
        0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42,
        0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47,
        0x38: 44, 0x39: 57,
        0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96,
        0x3F: 97, 0x40: 98, 0x41: 100, 0x42: 101, 0x43: 109,
        0x44: 103, 0x45: 111,
        0x49: 114, 0x4A: 115, 0x4B: 116, 0x4C: 117,
        0x4D: 119, 0x4E: 121, 0x4F: 124, 0x50: 123,
        0x51: 125, 0x52: 126, 0x53: 71, 0x54: 75,
        0x55: 67, 0x56: 78, 0x57: 69, 0x58: 76,
        0x59: 83, 0x5A: 84, 0x5B: 85, 0x5C: 86, 0x5D: 87,
        0x5E: 88, 0x5F: 89, 0x60: 91, 0x61: 92, 0x62: 82,
        0x63: 65, 0x64: 10, 0x67: 81,
        0x68: 105, 0x69: 107, 0x6A: 113, 0x6B: 106,
        0x6C: 64, 0x6D: 79, 0x6E: 80, 0x6F: 90,
        0x85: 95, 0x87: 94, 0x89: 93, 0x90: 104, 0x91: 102,
        0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55,
        0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54
    ]
    private static let usages = Dictionary(uniqueKeysWithValues: keyCodes.map { ($0.value, $0.key) })
    private static let deviceModifierMasks: [CGKeyCode: UInt64] = [
        59: 0x0001, 56: 0x0002, 60: 0x0004, 55: 0x0008,
        54: 0x0010, 58: 0x0020, 61: 0x0040, 62: 0x2000
    ]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = LanInputPlugin()
        let methods = FlutterMethodChannel(name: "lan_input/methods", binaryMessenger: registrar.messenger)
        let events = FlutterEventChannel(name: "lan_input/events", binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(plugin, channel: methods)
        events.setStreamHandler(plugin)
    }

    override init() {
        super.init()
        source?.localEventsSuppressionInterval = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "lan_input.deadman"))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.checkHeartbeat() }
        timer.resume()
        watchdog = timer
    }

    deinit {
        watchdog?.cancel()
        stopCapture()
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        lock.lock(); pendingEvents.removeAll(); sink = events; lock.unlock()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stopCapture()
        lock.lock(); pendingEvents.removeAll(); sink = nil; lock.unlock()
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "setCursorVisible":
            guard let visible = args["visible"] as? Bool else { result(invalid("visible required")); return }
            lock.lock(); cursorVisible = visible; updateCursorLocked(); lock.unlock(); result(nil)
        case "clipboardRevision": result(NSPasteboard.general.changeCount)
        case "clipboardHasFiles": result(NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]))
        case "configureFileEdge":
            guard let enabled = args["enabled"] as? Bool else { result(invalid("enabled required")); return }
            let edge = args["edge"] as? String ?? ((args["left"] as? Bool ?? false) ? "left" : "right")
            let start = args["start"] as? Double ?? 0, end = args["end"] as? Double ?? 1
            guard ["left", "right", "top", "bottom"].contains(edge), start.isFinite, end.isFinite, start >= 0, end <= 1, start < end else { result(invalid("Invalid edge geometry")); return }
            fileDrag.configure(enabled: enabled, edge: edge, start: start, end: end); result(nil)
        case "cancelLocalDrag": FileDragBridge.cancelLocal(); result(nil)
        case "cancelFileDrag": fileDrag.cancel(); result(nil)
        case "prepareFileDrag":
            lock.lock()
            guard tap != nil, CGEventSource.buttonState(.hidSystemState, button: .left), !hasPhysicalInputHeld(allowLeft: true) else { lock.unlock(); result(FlutterError(code: "input_busy", message: "Keep holding the left mouse button and release other inputs", details: nil)); return }
            setRemoteLocked(true); lock.unlock()
            FileDragBridge.cancelLocal(); result(nil)
        case "beginFileDrag":
            guard let paths = args["paths"] as? [String], !paths.isEmpty, paths.count <= 10000, paths.allSatisfy({ !$0.contains("\0") && $0.hasPrefix("/") }) else { result(invalid("invalid paths")); return }
            lock.lock(); injectButtonLocked(1, down: true); lock.unlock()
            if let error = fileDrag.begin(paths: paths) { lock.lock(); releaseAllLocked(); lock.unlock(); result(invalid(error)) } else { result(nil) }
        case "getStatus":
            let bounds = CGDisplayBounds(CGMainDisplayID())
            result([
                "supported": true,
                "accessibility": AXIsProcessTrusted(),
                "inputMonitoring": CGPreflightListenEventAccess(),
                "screen": ["x": bounds.origin.x, "y": bounds.origin.y,
                           "width": bounds.width, "height": bounds.height]
            ])
        case "requestPermissions":
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            _ = CGRequestListenEventAccess()
            result(nil)
        case "configureSwitchShortcut":
            guard let enabled = args["enabled"] as? Bool else { result(invalid("enabled must be a boolean")); return }
            lock.lock(); switchShortcutEnabled = enabled; switchShortcutPending = false; switchShortcutKeyDown = false; lock.unlock()
            result(nil)
        case "startCapture":
            if let error = startCapture() { result(error) } else { result(nil) }
        case "stopCapture":
            fileDrag.configure(enabled: false, left: false); fileDrag.cancel()
            stopCapture(); result(nil)
        case "setRemoteCapture":
            guard let enabled = args["enabled"] as? Bool else {
                result(invalid("enabled must be a boolean")); return
            }
            lock.lock()
            guard !enabled || tap != nil else {
                lock.unlock(); result(invalid("startCapture must succeed first")); return
            }
            if enabled && !remote && hasPhysicalInputHeld() {
                lock.unlock()
                result(FlutterError(code: "input_busy", message: "Release keyboard keys and mouse buttons before crossing screens.", details: nil))
                return
            }
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            watchdogTripped = false
            setRemoteLocked(enabled)
            lock.unlock()
            result(nil)
        case "heartbeat":
            lock.lock()
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            watchdogTripped = false
            lock.unlock()
            result(nil)
        case "warp":
            guard let x = number(args["x"]), let y = number(args["y"]) else {
                result(invalid("x and y must be finite numbers")); return
            }
            let point = clamped(CGPoint(x: x, y: y))
            // A tagged event avoids capture feedback; warping does not generate
            // an untagged synthetic movement at the opposite display edge.
            if let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                   mouseCursorPosition: point, mouseButton: .left) {
                post(event)
            }
            result(nil)
        case "inject":
            guard AXIsProcessTrusted() else {
                result(FlutterError(code: "permission_denied", message: "Enable Accessibility for LAN Bridge in System Settings.", details: nil)); return
            }
            guard let event = args["event"] as? [String: Any] else {
                result(invalid("event must be a map")); return
            }
            lock.lock()
            let error = injectLocked(event)
            lock.unlock()
            result(error)
        case "releaseAll":
            lock.lock(); releaseAllLocked(); lock.unlock(); result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startCapture() -> FlutterError? {
        lock.lock()
        if tap != nil { lock.unlock(); return nil }
        lock.unlock()
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            return FlutterError(code: "permission_denied",
                                message: "Enable Accessibility and Input Monitoring for LAN Bridge, then reopen the app.", details: nil)
        }
        let eventTypes: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<LanInputPlugin>.fromOpaque(context).takeUnretainedValue().capture(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return FlutterError(code: "capture_failed", message: "macOS could not create an input event tap. Check input permissions and restart LAN Bridge.", details: nil)
        }
        let ready = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let loop = CFRunLoopGetCurrent() else {
                exited.signal()
                return
            }
            CFRunLoopAddSource(loop, runLoopSource, .commonModes)
            self?.recordRunLoop(loop)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, runLoopSource, .commonModes)
            CFMachPortInvalidate(port)
            exited.signal()
        }
        thread.name = "LAN Bridge input tap"
        thread.qualityOfService = QualityOfService.userInteractive
        lock.lock()
        tap = port; tapSource = runLoopSource; tapThread = thread; tapExited = exited
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        watchdogTripped = false
        lock.unlock()
        thread.start()
        if ready.wait(timeout: .now() + 2) == .timedOut {
            stopCapture()
            return FlutterError(code: "capture_failed", message: "Input tap did not start in time.", details: nil)
        }
        return nil
    }

    private func recordRunLoop(_ loop: CFRunLoop) {
        lock.lock(); tapRunLoop = loop; lock.unlock()
    }

    private func stopCapture() {
        lock.lock()
        switchShortcutPending = false
        switchShortcutKeyDown = false
        cursorVisible = true
        setRemoteLocked(false)
        updateCursorLocked()
        releaseAllLocked()
        let port = tap
        let loop = tapRunLoop
        let exited = tapExited
        tap = nil; tapSource = nil; tapRunLoop = nil; tapThread = nil; tapExited = nil
        lock.unlock()
        if let port = port { CFMachPortInvalidate(port) }
        if let loop = loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
            _ = exited?.wait(timeout: .now() + 1)
        }
    }

    private func setRemoteLocked(_ enabled: Bool) {
        guard enabled != remote else { return }
        remote = enabled
        // Disassociation preserves unbounded physical deltas while the source
        // cursor is held in place. Always balance this on every exit path.
        CGAssociateMouseAndMouseCursorPosition(enabled ? 0 : 1)
        updateCursorLocked()
    }

    private func updateCursorLocked() {
        let hide = remote || !cursorVisible
        if hide && !cursorHidden {
            CGDisplayHideCursor(CGMainDisplayID()); cursorHidden = true
        } else if !hide && cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID()); cursorHidden = false
        }
    }

    private func checkHeartbeat() {
        lock.lock()
        defer { lock.unlock() }
        guard !watchdogTripped,
              remote || !cursorVisible || !injectedKeys.isEmpty || !injectedButtons.isEmpty,
              ProcessInfo.processInfo.systemUptime - lastHeartbeat > 2.5 else { return }
        watchdogTripped = true
        cursorVisible = true
        setRemoteLocked(false)
        updateCursorLocked()
        if injectedButtons.contains(1) { FileDragBridge.cancelLocal() }
        releaseAllLocked()
        emit(["type": "captureLost", "message": "Input heartbeat expired; local control restored."])
    }

    private func capture(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cursorVisible = true
            setRemoteLocked(false)
            updateCursorLocked()
            releaseAllLocked()
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            emit(["type": "captureLost", "message": "macOS disabled the input tap; local control restored."])
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown && keyCode == 53 && event.flags.contains(.maskControl) && event.flags.contains(.maskAlternate) {
            cursorVisible = true
            setRemoteLocked(false)
            updateCursorLocked()
            releaseAllLocked()
            emit(["type": "emergency"])
            return nil
        }
        if switchShortcutEnabled && type == .keyDown && keyCode == 111 && event.flags.contains(.maskControl) && event.flags.contains(.maskAlternate) {
            switchShortcutPending = true
            switchShortcutKeyDown = true
            return nil
        }
        let swallowShortcut = switchShortcutPending && keyCode == 111 && (type == .keyDown || type == .keyUp)
        if swallowShortcut && type == .keyUp { switchShortcutKeyDown = false }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            emit(["type": "move", "captured": remote, "x": event.location.x, "y": event.location.y,
                  "dx": event.getDoubleValueField(.mouseEventDeltaX),
                  "dy": event.getDoubleValueField(.mouseEventDeltaY)])
        case .keyDown, .keyUp:
            if remote, !swallowShortcut, let usage = Self.usages[keyCode] {
                emit(["type": "key", "usage": usage, "down": type == .keyDown])
            }
        case .flagsChanged:
            if remote, let usage = Self.usages[keyCode] {
                if keyCode == 57 {
                    emit(["type": "key", "usage": usage, "down": true])
                    emit(["type": "key", "usage": usage, "down": false])
                } else if let mask = Self.deviceModifierMasks[keyCode] {
                    emit(["type": "key", "usage": usage, "down": event.flags.rawValue & mask != 0])
                }
            }
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            if remote {
                let native = Int(event.getIntegerValueField(.mouseEventButtonNumber))
                let button = native == 0 ? 1 : native == 1 ? 2 : native + 1
                if (1...5).contains(button) {
                    let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
                    emit(["type": "button", "button": button, "down": down])
                }
            }
        case .scrollWheel:
            if remote {
                let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
                let dy = continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) / 40.0
                    : event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
                let dx = continuous ? -event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) / 40.0
                    : -event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
                emit(["type": "scroll", "dx": dx, "dy": dy])
            }
        default: break
        }
        if switchShortcutPending && !switchShortcutKeyDown &&
            !event.flags.contains(.maskControl) && !event.flags.contains(.maskAlternate) {
            switchShortcutPending = false
            emit(["type": "switchShortcut"])
        }
        if swallowShortcut { return nil }
        return remote ? nil : Unmanaged.passUnretained(event)
    }

    private func injectLocked(_ input: [String: Any]) -> FlutterError? {
        guard let type = input["type"] as? String else { return invalid("event.type is required") }
        switch type {
        case "move":
            guard let x = number(input["x"]), let y = number(input["y"]) else { return invalid("move requires finite x/y") }
            let button = injectedButtons.sorted().first ?? 1
            let nativeButton = CGMouseButton(rawValue: UInt32(button - 1)) ?? .left
            let moveType: CGEventType = injectedButtons.isEmpty ? .mouseMoved
                : button == 1 ? .leftMouseDragged : button == 2 ? .rightMouseDragged : .otherMouseDragged
            guard let event = CGEvent(mouseEventSource: source, mouseType: moveType,
                                     mouseCursorPosition: clamped(CGPoint(x: x, y: y)), mouseButton: nativeButton) else { return injectionFailure() }
            event.flags = injectedFlags()
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button - 1))
            post(event)
        case "button":
            guard let button = integer(input["button"]), (1...5).contains(button), let down = input["down"] as? Bool else {
                return invalid("button requires button 1...5 and boolean down")
            }
            injectButtonLocked(button, down: down)
        case "key":
            guard let usage = integer(input["usage"]), (0...255).contains(usage), let down = input["down"] as? Bool else {
                return invalid("key requires a HID keyboard usage and boolean down")
            }
            // Keys absent from the receiver's hardware key table are ignored.
            injectKeyLocked(usage, down: down)
        case "scroll":
            guard let dx = number(input["dx"]), let dy = number(input["dy"]), abs(dx) <= 1000, abs(dy) <= 1000 else {
                return invalid("scroll requires finite dx/dy within 1000 detents")
            }
            scrollCarryX += -dx * 40.0
            scrollCarryY += dy * 40.0
            let x = Int32(scrollCarryX.rounded(.towardZero))
            let y = Int32(scrollCarryY.rounded(.towardZero))
            scrollCarryX -= Double(x); scrollCarryY -= Double(y)
            if x != 0 || y != 0 {
                guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                    wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return injectionFailure() }
                event.flags = injectedFlags()
                post(event)
            }
        default: return invalid("Unsupported input event type")
        }
        return nil
    }

    private func injectKeyLocked(_ usage: Int, down: Bool) {
        guard let code = Self.keyCodes[usage] else { return }
        let repeated = down && injectedKeys.contains(usage)
        if down {
            injectedKeys.insert(usage)
            if usage == 0x39 && !repeated { capsLock.toggle() }
        } else { injectedKeys.remove(usage) }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = injectedFlags()
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        post(event)
    }

    private func injectButtonLocked(_ button: Int, down: Bool) {
        if down { injectedButtons.insert(button) } else { injectedButtons.remove(button) }
        let point = clamped(CGEvent(source: nil)?.location ?? CGDisplayBounds(CGMainDisplayID()).origin)
        let native = CGMouseButton(rawValue: UInt32(button - 1)) ?? .left
        let type: CGEventType = button == 1 ? (down ? .leftMouseDown : .leftMouseUp)
            : button == 2 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
        if down {
            let now = ProcessInfo.processInfo.systemUptime
            if button == lastClickButton && now - lastClickTime <= NSEvent.doubleClickInterval
                && abs(point.x - lastClickPoint.x) <= 4 && abs(point.y - lastClickPoint.y) <= 4 {
                clickCount = min(clickCount + 1, 3)
            } else { clickCount = 1 }
            lastClickButton = button; lastClickPoint = point; lastClickTime = now
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: native) else { return }
        event.flags = injectedFlags()
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button - 1))
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        post(event)
    }

    private func injectedFlags() -> CGEventFlags {
        var flags: CGEventFlags = []
        if injectedKeys.contains(0xE0) || injectedKeys.contains(0xE4) { flags.insert(.maskControl) }
        if injectedKeys.contains(0xE1) || injectedKeys.contains(0xE5) { flags.insert(.maskShift) }
        if injectedKeys.contains(0xE2) || injectedKeys.contains(0xE6) { flags.insert(.maskAlternate) }
        if injectedKeys.contains(0xE3) || injectedKeys.contains(0xE7) { flags.insert(.maskCommand) }
        if capsLock { flags.insert(.maskAlphaShift) }
        return flags
    }

    private func releaseAllLocked() {
        // Ordinary keys first so their releases still include held modifiers.
        for key in injectedKeys.sorted() { injectKeyLocked(key, down: false) }
        for button in injectedButtons.sorted() { injectButtonLocked(button, down: false) }
        scrollCarryX = 0; scrollCarryY = 0
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cghidEventTap)
    }

    private func emit(_ event: [String: Any]) {
        lock.lock()
        var event = event
        if event["type"] as? String == "move",
           let previous = pendingEvents.last,
           previous["type"] as? String == "move",
           (previous["captured"] as? Bool) == (event["captured"] as? Bool) {
            event["dx"] = (previous["dx"] as? Double ?? 0) + (event["dx"] as? Double ?? 0)
            event["dy"] = (previous["dy"] as? Double ?? 0) + (event["dy"] as? Double ?? 0)
            pendingEvents[pendingEvents.count - 1] = event
        } else if pendingEvents.count < 2048 {
            pendingEvents.append(event)
        } else {
            cursorVisible = true
            setRemoteLocked(false)
            updateCursorLocked()
            releaseAllLocked()
            pendingEvents = [["type": "captureLost", "message": "Input queue overflow; local control restored."]]
        }
        guard !deliveryScheduled else { lock.unlock(); return }
        deliveryScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let callback = self.sink
            let batch = self.pendingEvents
            self.pendingEvents.removeAll(keepingCapacity: true)
            self.deliveryScheduled = false
            self.lock.unlock()
            for event in batch { callback?(event) }
        }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    private func hasPhysicalInputHeld(allowLeft: Bool = false) -> Bool {
        // Query HID state without exporting, retaining, or recording local keys.
        // Accepting an edge crossing while a local key is held would swallow its
        // later key-up and leave a modifier/button stuck in the source OS.
        for code in 0...127 {
            if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) { return true }
        }
        for value in 0...31 {
            if allowLeft && value == 0 { continue }
            if let button = CGMouseButton(rawValue: UInt32(value)),
               CGEventSource.buttonState(.hidSystemState, button: button) { return true }
        }
        return false
    }

    private func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        return double.isFinite ? double : nil
    }

    private func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value.rounded(.towardZero) == value,
              value >= 0, value <= 65535 else { return nil }
        return Int(value)
    }

    private func invalid(_ message: String) -> FlutterError {
        FlutterError(code: "invalid_argument", message: message, details: nil)
    }

    private func injectionFailure() -> FlutterError {
        FlutterError(code: "injection_failed", message: "macOS could not construct an input event.", details: nil)
    }
}
