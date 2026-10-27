import Foundation

/// A fake DCU-1: answers `AI1;` with `ddd;`, turns on `AP1nnn;AM1;`, stops on `;`.
/// No `BI`, no jog. A thin wrapper over `FakeRT21Device` with the `.dcu1` personality.
public final class FakeDCU1Device: Sendable {
    public let core: FakeRT21Device

    public init(heading: Double = 0, clock: any GHEClock = SystemClock(), degreesPerSecond: Double = 6) {
        var o = FakeRT21Device.Options()
        o.personality = .dcu1
        o.degreesPerSecond = degreesPerSecond
        core = FakeRT21Device(heading: heading, clock: clock, options: o)
    }

    public func makeTransport() -> FakeDeviceTransport { core.makeTransport() }
    public var heading: Double { core.heading }
    public var isMoving: Bool { core.isMoving }
    public var commands: [String] { core.commands }
    public func setHeading(_ h: Double) { core.setHeading(h) }
}

/// Helpers for other packages' tests and the simulator.
public enum FakeDevices {
    /// A fake RT-21 network module (single connection) as found at `host:6555`.
    public static func rt21NetworkModule(heading: Double = 0, clock: any GHEClock = SystemClock(),
                                         lockOnSecondConnection: Bool = false) -> FakeRT21Device {
        var o = FakeRT21Device.Options()
        o.singleConnection = true
        o.lockOnSecondConnection = lockOnSecondConnection
        return FakeRT21Device(heading: heading, clock: clock, options: o)
    }

    /// A resolver for `DefaultTransportFactory(simulated:)`: maps simulated ids to devices,
    /// handing out a fresh link per `make`.
    public static func resolver(_ devices: [String: any FakeSerialDevice]) -> @Sendable (String) -> (any ByteTransport)? {
        { id in devices[id].map { FakeDeviceTransport(device: $0) } }
    }

    /// A transport factory whose `.simulated(id)` endpoints are served by these fake devices
    /// (unknown ids fail to open). Serial/TCP endpoints still get real transports.
    public static func factory(_ devices: [String: any FakeSerialDevice], leases: EndpointLeases? = nil) -> DefaultTransportFactory {
        DefaultTransportFactory(leases: leases, simulated: resolver(devices))
    }
}
