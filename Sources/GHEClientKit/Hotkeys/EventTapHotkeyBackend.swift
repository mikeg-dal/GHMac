import ApplicationServices
import CoreGraphics
import Foundation

/// Optional "advanced" backend: a session `CGEventTap` that swallows registered keys,
/// including Option-only combinations RegisterEventHotKey refuses. Needs Accessibility
/// permission. The tap is re-enabled when macOS disables it on timeout. Main thread only.
public final class EventTapHotkeyBackend: HotkeyBackend {
    public var onPress: ((KeyName) -> Void)?
    public private(set) var registered: Set<KeyName> = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// How many times the tap was re-enabled after a timeout.
    public private(set) var reenableCount = 0

    public init() {}

    deinit { stop() }

    /// Whether the app has Accessibility permission.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show the Accessibility prompt (only call when the user enables this backend).
    public static func requestTrust() -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Creates the tap on the main run loop.
    public func start() throws {
        guard tap == nil else { return }
        guard Self.isTrusted else { throw HotkeyError.accessibilityNotTrusted }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: eventTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { throw HotkeyError.eventTapUnavailable }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t; source = src
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    public var isRunning: Bool { tap != nil }

    public func register(_ key: KeyName) throws {
        guard key.macKeyCode != nil else { throw HotkeyError.unknownKey(key.legacyString) }
        registered.insert(key.normalized)
    }
    public func unregister(_ key: KeyName) { registered.remove(key.normalized) }
    public func unregisterAll() { registered.removeAll() }

    /// The registered key for a key-down, or nil to let the event through.
    public static func match(keyCode: UInt16, flags: CGEventFlags, registered: Set<KeyName>) -> KeyName? {
        guard let k = KeyName(keyCode: keyCode, cgFlags: flags), registered.contains(k) else { return nil }
        return k
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true); reenableCount += 1 }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if let k = Self.match(keyCode: code, flags: event.flags, registered: registered) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onPress?(k) }
                return nil   // swallow
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private func eventTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTapHotkeyBackend>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
