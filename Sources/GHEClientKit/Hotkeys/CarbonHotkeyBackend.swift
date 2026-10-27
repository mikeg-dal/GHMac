import Carbon.HIToolbox
import Foundation

/// Global hotkeys through Carbon `RegisterEventHotKey` (no TCC permission needed; the key is
/// consumed system-wide). Main thread only.
public final class CarbonHotkeyBackend: HotkeyBackend {
    public var onPress: ((KeyName) -> Void)?

    private var refs: [UInt32: (key: KeyName, ref: EventHotKeyRef)] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4748_454B   // 'GHEK'

    public init() {}

    deinit {
        for (_, v) in refs { UnregisterEventHotKey(v.ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Checks a key without registering it.
    public static func validate(_ key: KeyName) throws -> UInt16 {
        if KeyCodeTable.unsupportedByRegisterEventHotKey.contains(key.base) {
            throw HotkeyError.unsupportedKey(key.legacyString)
        }
        guard let code = key.macKeyCode else { throw HotkeyError.unknownKey(key.legacyString) }
        if key.isOptionOnlyCombination { throw HotkeyError.optionOnlyCombination(key.legacyString) }
        return code
    }

    public func register(_ key: KeyName) throws {
        let k = key.normalized
        guard !refs.values.contains(where: { $0.key == k }) else { return }
        let code = try Self.validate(k)
        try installHandlerIfNeeded()
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), KeyCodeTable.carbonModifiers(k.modifiers),
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotkeyError.registrationFailed(k.legacyString, status) }
        refs[id] = (k, ref)
    }

    public func unregister(_ key: KeyName) {
        let k = key.normalized
        for (id, v) in refs where v.key == k {
            UnregisterEventHotKey(v.ref)
            refs[id] = nil
        }
    }

    public func unregisterAll() {
        for (_, v) in refs { UnregisterEventHotKey(v.ref) }
        refs.removeAll()
    }

    public var registeredKeys: [KeyName] { refs.values.map(\.key) }

    fileprivate func fire(id: UInt32) {
        guard let k = refs[id]?.key else { return }
        onPress?(k)
    }

    private func installHandlerIfNeeded() throws {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyCallback, 1, &spec, me, &handler)
        if status != noErr { throw HotkeyError.registrationFailed("event handler", status) }
    }
}

private func carbonHotkeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                  _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hk = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    guard status == noErr else { return status }
    Unmanaged<CarbonHotkeyBackend>.fromOpaque(userData).takeUnretainedValue().fire(id: hk.id)
    return noErr
}
