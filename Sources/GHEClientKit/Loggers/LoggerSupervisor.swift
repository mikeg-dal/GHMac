import Foundation
import GHEKit

/// The Band menu's logger choice (settings.ini keys `manual`/`n1mm`/`n3fjp`/`wintest`).
public enum LoggerSource: String, CaseIterable, Sendable, Hashable, Codable {
    case manual, n1mm, n3fjp, wintest
}

/// N1MM+ family settings.
public struct N1MMConfig: Sendable, Hashable {
    public var radioPort: UInt16
    public var rotorPort: UInt16
    /// 1 = VFO-A/Radio 1 only, 2 = VFO-B/Radio 2 only, 3 = both (`n1mmSelectedVFO`).
    public var selectedVFO: Int
    public init(radioPort: UInt16 = 12060, rotorPort: UInt16 = 12045, selectedVFO: Int = 1) {
        self.radioPort = radioPort; self.rotorPort = rotorPort; self.selectedVFO = selectedVFO
    }
}

/// Win-Test settings.
public struct WinTestConfig: Sendable, Hashable {
    public enum Bind: Sendable, Hashable { case network, loopback, custom(String) }
    public var port: UInt16
    public var bind: Bind
    public var filter: WinTestFilter
    public init(port: UInt16 = 9871, bind: Bind = .network, filter: WinTestFilter = WinTestFilter()) {
        self.port = port; self.bind = bind; self.filter = filter
    }
}

/// N3FJP settings.
public struct N3FJPConfig: Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public init(host: String = "127.0.0.1", port: UInt16 = 1100) { self.host = host; self.port = port }
}

/// Everything the supervisor needs to decide which monitors run.
public struct LoggerConfiguration: Sendable, Hashable {
    public var source: LoggerSource
    public var n1mm: N1MMConfig
    public var winTest: WinTestConfig
    public var n3fjp: N3FJPConfig
    /// SO2R: the radio this client context serves (1 or 2), or nil when SO2R gating is off.
    public var so2rRadio: Int?
    public init(source: LoggerSource = .manual, n1mm: N1MMConfig = .init(), winTest: WinTestConfig = .init(),
                n3fjp: N3FJPConfig = .init(), so2rRadio: Int? = nil) {
        self.source = source; self.n1mm = n1mm; self.winTest = winTest; self.n3fjp = n3fjp; self.so2rRadio = so2rRadio
    }
}

/// Where a UDP monitor listens. `host == nil` means the wildcard address.
public struct UDPBinding: Sendable, Hashable {
    public var port: UInt16
    public var host: String?
    public init(port: UInt16, host: String? = nil) { self.port = port; self.host = host }
}

/// Transport factories for the monitors (real sockets in the app, memory fakes in tests).
public struct LoggerTransports: Sendable {
    public var makeDatagramSource: @Sendable (UDPBinding) throws -> any DatagramSource
    public var connector: any StreamConnector
    public var clock: any GHEClock
    public init(makeDatagramSource: @escaping @Sendable (UDPBinding) throws -> any DatagramSource,
                connector: any StreamConnector, clock: any GHEClock = SystemClock()) {
        self.makeDatagramSource = makeDatagramSource; self.connector = connector; self.clock = clock
    }
}

/// Starts and stops the monitors for the selected logger and merges their events.
// Each source is started with its own settings (port/IP, VFO/radio choice).
public actor LoggerSupervisor {
    private let transports: LoggerTransports
    private let broadcaster = EventBroadcaster<LoggerEvent>()
    /// Focus radio from N1MM `<FocusRadioNr>`; share with the hotkey engine for SO2R.
    public nonisolated let activeRadio = ActiveRadioTracker()
    private var configuration: LoggerConfiguration?
    private var monitors: [any LoggerMonitor] = []
    private var pumps: [Task<Void, Never>] = []

    public init(transports: LoggerTransports) { self.transports = transports }

    /// Merged events of all running monitors.
    public nonisolated func events() -> AsyncStream<LoggerEvent> { broadcaster.subscribe() }

    public var current: LoggerConfiguration? { configuration }
    public var runningMonitorCount: Int { monitors.count }

    /// Applies a configuration; monitors restart only if it changed.
    public func apply(_ config: LoggerConfiguration) async {
        guard config != configuration else { return }
        await stopMonitors()
        configuration = config
        for m in makeMonitors(config) {
            do {
                let stream = try await m.start()
                monitors.append(m)
                let b = broadcaster
                pumps.append(Task { for await e in stream { b.yield(e) } })
            } catch {
                broadcaster.yield(.status("Cannot start logger monitor: \(error.localizedDescription)"))
            }
        }
    }

    public func stop() async {
        await stopMonitors()
        configuration = nil
    }

    private func stopMonitors() async {
        for m in monitors { await m.stop() }
        for p in pumps { p.cancel() }
        monitors = []; pumps = []
    }

    private func makeMonitors(_ c: LoggerConfiguration) -> [any LoggerMonitor] {
        var out: [any LoggerMonitor] = []
        func source(_ b: UDPBinding) -> (any DatagramSource)? {
            do { return try transports.makeDatagramSource(b) } catch {
                broadcaster.yield(.status("Cannot listen on UDP port \(b.port): \(error.localizedDescription)"))
                return nil
            }
        }
        switch c.source {
        case .manual:
            break
        case .n1mm:
            if let s = source(UDPBinding(port: c.n1mm.radioPort)) {
                out.append(DatagramLoggerMonitor.n1mmRadio(source: s, vfoSetting: c.n1mm.selectedVFO, tracker: activeRadio))
            }
            if let s = source(UDPBinding(port: c.n1mm.rotorPort)) {
                let gate = c.so2rRadio.map { SO2RGate(thisRadio: $0, tracker: activeRadio) }
                out.append(DatagramLoggerMonitor.n1mmRotor(source: s, gate: gate))
            }
        case .wintest:
            // Always bind the wildcard so broadcasts arrive; "Loopback" filters by sender.
            if let s = source(UDPBinding(port: c.winTest.port)) {
                out.append(DatagramLoggerMonitor.winTest(source: s, filter: c.winTest.filter,
                                                         loopbackOnly: c.winTest.bind == .loopback))
            }
        case .n3fjp:
            out.append(N3FJPMonitor(connector: transports.connector, host: c.n3fjp.host,
                                    port: c.n3fjp.port, clock: transports.clock))
        }
        return out
    }
}
