import Foundation
import GHEKit
import Synchronization

/// Phidget encoder knobs (1052/1057/1047…) through Phidget22: a manager reports attach and
/// detach; for every attached device an encoder channel (turns) and its digital inputs
/// (push button) are opened. Callbacks arrive on Phidget threads and are forwarded to
/// `events()` subscribers.
public final class PhidgetKnobService: KnobService, @unchecked Sendable {
    private let api: Phidget22API?
    private let broadcaster = EventBroadcaster<KnobEvent>()
    /// A Phidget handle; only passed to the thread-safe Phidget22 C API.
    private struct Handle: @unchecked Sendable { let raw: OpaquePointer }
    private struct State {
        var manager: Handle?
        var channels: [Int: [Handle]] = [:]   // serial → opened channels
        var started = false
        /// Retained self passed to C callbacks as their context.
        var context: Unmanaged<PhidgetKnobService>?
    }
    private let state = Mutex(State())

    /// Uses the shared loader result; `api == nil` means Phidget22 is unavailable.
    public init(api: Phidget22API? = try? Phidget22Loader.shared.get()) { self.api = api }

    public var isAvailable: Bool { api != nil }

    /// Starts the manager on first subscription. With no library the stream simply never yields.
    public func events() -> AsyncStream<KnobEvent> {
        let s = broadcaster.subscribe()
        start()
        return s
    }

    public func start() {
        guard let api else { return }
        let ctx: Unmanaged<PhidgetKnobService>? = state.withLock { s in
            guard !s.started else { return nil }
            s.started = true
            s.context = Unmanaged.passRetained(self)
            return s.context
        }
        guard let ctx else { return }
        var m: OpaquePointer?
        guard api.managerCreate(&m) == Phidget22API.ok, let m else { return }
        _ = api.managerSetOnAttachHandler(m, phidgetManagerAttach, ctx.toOpaque())
        _ = api.managerSetOnDetachHandler(m, phidgetManagerDetach, ctx.toOpaque())
        state.withLock { $0.manager = Handle(raw: m) }
        _ = api.managerOpen(m)
    }

    public func stop() {
        guard let api else { return }
        let (m, chans, ctx) = state.withLock { s in
            defer { s.manager = nil; s.channels = [:]; s.started = false; s.context = nil }
            return (s.manager, s.channels.values.flatMap { $0 }, s.context)
        }
        for c in chans {
            _ = api.close(c.raw)
            var h: OpaquePointer? = c.raw
            _ = api.delete(&h)
        }
        if let m {
            _ = api.managerClose(m.raw)
            var h: OpaquePointer? = m.raw
            _ = api.managerDelete(&h)
        }
        ctx?.release()
    }

    // MARK: Callback entry points

    fileprivate func attached(_ channel: OpaquePointer?) {
        guard let api, let channel else { return }
        var cls: Int32 = 0, serial: Int32 = 0, index: Int32 = 0
        guard api.getChannelClass(channel, &cls) == Phidget22API.ok,
              api.getDeviceSerialNumber(channel, &serial) == Phidget22API.ok else { return }
        _ = api.getChannel(channel, &index)
        var h: OpaquePointer?
        switch cls {
        case Phidget22API.channelClassEncoder:
            guard api.encoderCreate(&h) == Phidget22API.ok, let h else { return }
            _ = api.setDeviceSerialNumber(h, serial)
            _ = api.setChannel(h, index)
            _ = api.encoderSetOnPositionChangeHandler(h, phidgetPositionChange, contextPointer)
            _ = api.open(h)
            _ = api.encoderSetDataInterval?(h, 16)
            remember(h, serial: Int(serial))
            broadcaster.yield(.attached(serial: Int(serial)))
        case Phidget22API.channelClassDigitalInput:
            guard api.digitalInputCreate(&h) == Phidget22API.ok, let h else { return }
            _ = api.setDeviceSerialNumber(h, serial)
            _ = api.setChannel(h, index)
            _ = api.digitalInputSetOnStateChangeHandler(h, phidgetStateChange, contextPointer)
            _ = api.open(h)
            remember(h, serial: Int(serial))
        default:
            break
        }
    }

    fileprivate func detached(_ channel: OpaquePointer?) {
        guard let api, let channel else { return }
        var cls: Int32 = 0, serial: Int32 = 0
        guard api.getChannelClass(channel, &cls) == Phidget22API.ok, cls == Phidget22API.channelClassEncoder,
              api.getDeviceSerialNumber(channel, &serial) == Phidget22API.ok else { return }
        broadcaster.yield(.detached(serial: Int(serial)))
    }

    fileprivate func positionChanged(_ channel: OpaquePointer?, _ delta: Int32) {
        guard let serial = serial(of: channel) else { return }
        broadcaster.yield(.delta(serial: serial, Int(delta)))
    }

    fileprivate func stateChanged(_ channel: OpaquePointer?, _ value: Int32) {
        guard let serial = serial(of: channel) else { return }
        broadcaster.yield(.button(serial: serial, pressed: value != 0))
    }

    private var contextPointer: UnsafeMutableRawPointer? { state.withLock { $0.context?.toOpaque() } }

    private func remember(_ h: OpaquePointer, serial: Int) {
        state.withLock { $0.channels[serial, default: []].append(Handle(raw: h)) }
    }

    private func serial(of channel: OpaquePointer?) -> Int? {
        guard let api, let channel else { return nil }
        var s: Int32 = 0
        return api.getDeviceSerialNumber(channel, &s) == Phidget22API.ok ? Int(s) : nil
    }
}

private func service(_ ctx: UnsafeMutableRawPointer?) -> PhidgetKnobService? {
    ctx.map { Unmanaged<PhidgetKnobService>.fromOpaque($0).takeUnretainedValue() }
}

private func phidgetManagerAttach(_ m: OpaquePointer?, _ ctx: UnsafeMutableRawPointer?, _ ch: OpaquePointer?) {
    service(ctx)?.attached(ch)
}

private func phidgetManagerDetach(_ m: OpaquePointer?, _ ctx: UnsafeMutableRawPointer?, _ ch: OpaquePointer?) {
    service(ctx)?.detached(ch)
}

private func phidgetPositionChange(_ ch: OpaquePointer?, _ ctx: UnsafeMutableRawPointer?, _ delta: Int32,
                                   _ time: Double, _ index: Int32) {
    service(ctx)?.positionChanged(ch, delta)
}

private func phidgetStateChange(_ ch: OpaquePointer?, _ ctx: UnsafeMutableRawPointer?, _ state: Int32) {
    service(ctx)?.stateChanged(ch, state)
}
