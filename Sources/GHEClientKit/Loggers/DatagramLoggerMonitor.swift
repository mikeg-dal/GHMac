import Foundation
import GHEKit

/// A logger monitor fed by a UDP datagram source (N1MM radio, N1MM rotor, Win-Test).
/// The source is injected; tests use `MemoryDatagramSource`.
public actor DatagramLoggerMonitor: LoggerMonitor {
    /// Turns one datagram into events. Never throws: a bad packet only produces fewer events.
    public typealias Handler = @Sendable (Datagram) -> [LoggerEvent]

    public nonisolated let name: String
    private let source: any DatagramSource
    private let handler: Handler
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<LoggerEvent>.Continuation?

    public init(name: String, source: any DatagramSource, handler: @escaping Handler) {
        self.name = name; self.source = source; self.handler = handler
    }

    public func start() async throws -> AsyncStream<LoggerEvent> {
        await stop()
        let datagrams = try await source.datagrams()
        let (stream, c) = AsyncStream<LoggerEvent>.makeStream()
        continuation = c
        let handler = handler
        // Each datagram is handled on its own; nothing a packet contains can stop the loop.
        // Whole datagrams are parsed (no 256/512-byte truncation here).
        task = Task.detached {
            for await d in datagrams {
                for e in handler(d) { c.yield(e) }
            }
            c.finish()
        }
        return stream
    }

    public func stop() async {
        task?.cancel(); task = nil
        await source.close()
        continuation?.finish(); continuation = nil
    }
}

public extension DatagramLoggerMonitor {
    /// N1MM+ RadioInfo monitor. Updates `tracker` from `<FocusRadioNr>`.
    static func n1mmRadio(source: any DatagramSource, vfoSetting: Int,
                          tracker: ActiveRadioTracker? = nil) -> DatagramLoggerMonitor {
        DatagramLoggerMonitor(name: "N1MM radio", source: source) { d in
            let events = N1MMRadioParser.events(for: LoggerText.decode(d.bytes), vfoSetting: vfoSetting)
            for case .focusRadio(let r) in events { tracker?.set(r) }
            return events
        }
    }

    /// N1MM+ rotor (Alt-J) monitor. With a gate, commands are dropped while the
    /// other radio has focus.
    static func n1mmRotor(source: any DatagramSource, gate: SO2RGate? = nil) -> DatagramLoggerMonitor {
        DatagramLoggerMonitor(name: "N1MM rotor", source: source) { d in
            let text = LoggerText.decode(d.bytes)
            if let gate, !gate.accepts { return [.raw(text), .status("Rotor command ignored (SO2R)")] }
            return N1MMRotorParser.events(for: text)
        }
    }

    /// Win-Test monitor: SETAZIMUTH and STATUS. `loopbackOnly` drops packets from
    /// other hosts (the "Loopback" bind option; the socket itself binds the wildcard).
    static func winTest(source: any DatagramSource, filter: WinTestFilter,
                        loopbackOnly: Bool = false) -> DatagramLoggerMonitor {
        DatagramLoggerMonitor(name: "Win-Test", source: source) { d in
            if loopbackOnly && !(d.source.hasPrefix("127.") || d.source.hasPrefix("[::1]") || d.source.hasPrefix("::1")) {
                return []
            }
            return WinTestParser.events(for: d.bytes, filter: filter)
        }
    }
}
