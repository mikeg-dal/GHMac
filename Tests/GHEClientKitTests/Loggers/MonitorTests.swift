import Testing
import Foundation
import Synchronization
import GHEKit
@testable import GHEClientKit

@Suite struct DatagramMonitorTests {
    @Test func n1mmRadioMonitorAndFocusTracker() async throws {
        let src = MemoryDatagramSource()
        let tracker = ActiveRadioTracker()
        let m = DatagramLoggerMonitor.n1mmRadio(source: src, vfoSetting: 3, tracker: tracker)
        let sink = AutomationEventSink(try await m.start())
        src.inject(Array(radioInfo("<FocusEntry>132456</FocusEntry><FocusRadioNr>2</FocusRadioNr><RadioNr>1</RadioNr><Freq>1402500</Freq>").utf8))
        #expect(await eventually { sink.events.contains(.band(slot: .a, band: "20M")) })
        #expect(tracker.value == 2)
        #expect(sink.events.contains(.focusRadio(2)))
        await m.stop()
    }

    /// A 600-byte packet with FocusRadioNr at offset 550 is parsed.
    @Test func tvN17LongPacket() async throws {
        let src = MemoryDatagramSource()
        let m = DatagramLoggerMonitor.n1mmRadio(source: src, vfoSetting: 3)
        let sink = AutomationEventSink(try await m.start())
        var text = #"<?xml version="1.0" encoding="utf-8"?><RadioInfo><StationName>"#
        text += String(repeating: "X", count: 550 - text.utf8.count - "</StationName>".utf8.count) + "</StationName>"
        #expect(text.utf8.count == 550)
        text += "<FocusRadioNr>2</FocusRadioNr>"
        text += String(repeating: " ", count: 600 - text.utf8.count - "</RadioInfo>".utf8.count) + "</RadioInfo>"
        #expect(text.utf8.count == 600)
        src.inject(Array(text.utf8) + [0, 0, 0])
        #expect(await eventually { sink.events.contains(.focusRadio(2)) })
        await m.stop()
    }

    /// Garbage doesn't stop the listener.
    @Test func survivesGarbage() async throws {
        let src = MemoryDatagramSource()
        let m = DatagramLoggerMonitor.n1mmRadio(source: src, vfoSetting: 3)
        let sink = AutomationEventSink(try await m.start())
        src.inject([0xFF, 0xFE, 0x00, 0x80])
        src.inject(Array(radioInfo("<RadioNr>1</RadioNr><Freq>08</Freq><FocusEntry>08</FocusEntry>").utf8))
        src.inject(Array(radioInfo("<RadioNr>1</RadioNr><Freq>702500</Freq>").utf8))
        #expect(await eventually { sink.events.contains(.band(slot: .a, band: "40M")) })
        await m.stop()
    }

    @Test func rotorMonitorWithSO2RGate() async throws {
        let src = MemoryDatagramSource()
        let tracker = ActiveRadioTracker()
        let m = DatagramLoggerMonitor.n1mmRotor(source: src, gate: SO2RGate(thisRadio: 2, tracker: tracker))
        let sink = AutomationEventSink(try await m.start())
        let p = Array("<N1MMRotor><rotor>T</rotor><goazi>123.0</goazi></N1MMRotor>".utf8)
        // No focus yet → accepted.
        src.inject(p)
        #expect(await eventually { sink.events.filter { $0 == .turnActive(raw: "123.0") }.count == 1 })
        // Focus on radio 1 → the radio-2 context ignores it.
        tracker.set(1)
        src.inject(p)
        #expect(await eventually { sink.events.contains(.status("Rotor command ignored (SO2R)")) })
        #expect(sink.events.filter { $0 == .turnActive(raw: "123.0") }.count == 1)
        await m.stop()
    }

    @Test func winTestLoopbackFilter() async throws {
        let src = MemoryDatagramSource()
        let m = DatagramLoggerMonitor.winTest(source: src, filter: WinTestFilter(), loopbackOnly: true)
        let sink = AutomationEventSink(try await m.start())
        let w1 = automationBytes(hex: WinTestVectorTests.w1Hex)
        src.inject(w1, from: "192.168.1.5:9871")
        src.inject(w1, from: "127.0.0.1:9871")
        #expect(await eventually { sink.events.contains(.turnActive(raw: "270")) })
        #expect(sink.events.filter { $0 == .turnActive(raw: "270") }.count == 1)
        await m.stop()
    }

    @Test func stopFinishesStream() async throws {
        let src = MemoryDatagramSource()
        let m = DatagramLoggerMonitor.n1mmRadio(source: src, vfoSetting: 3)
        let stream = try await m.start()
        await m.stop()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }
}

/// Connector whose attempts fail until `accept` is set; records attempts.
final class N3FJPScriptedConnector: StreamConnector, Sendable {
    struct State { var attempts: [String] = []; var servers: [MemoryStreamConnection] = []; var clients: [MemoryStreamConnection] = []; var accept = false }
    let state = Mutex(State())
    func connect(host: String, port: UInt16) async throws -> any StreamConnection {
        try state.withLock { s in
            s.attempts.append("\(host):\(port)")
            guard s.accept else { throw TransportError.openFailed("refused") }
            let (c, srv) = MemoryStreamConnection.pair()
            s.servers.append(srv); s.clients.append(c)
            return c
        }
    }
    var attempts: [String] { state.withLock { $0.attempts } }
    var lastServer: MemoryStreamConnection? { state.withLock { $0.servers.last } }
    var lastClient: MemoryStreamConnection? { state.withLock { $0.clients.last } }
    func setAccept(_ a: Bool) { state.withLock { $0.accept = a } }
}

@Suite struct N3FJPMonitorTests {
    @Test func reconnectsEverySecondOnManualClock() async throws {
        let clock = ManualClock()
        let conn = N3FJPScriptedConnector()
        let m = N3FJPMonitor(connector: conn, host: "127.0.0.1", port: 1100, clock: clock)
        let sink = AutomationEventSink(try await m.start())
        #expect(await eventually { clock.sleeperCount == 1 })
        #expect(conn.attempts == ["127.0.0.1:1100"])
        #expect(sink.events.contains(.status(N3FJPMonitor.waitingMessage)))
        await clock.advance(by: .milliseconds(999))
        #expect(conn.attempts.count == 1)
        await clock.advance(by: .milliseconds(1))
        #expect(await eventually { conn.attempts.count == 2 })
        #expect(await eventually { clock.sleeperCount == 1 })
        conn.setAccept(true)
        await clock.advance(by: .seconds(1))
        #expect(await eventually { conn.attempts.count == 3 && conn.lastServer != nil })

        // Two lines in one segment are both processed.
        let server = try #require(conn.lastServer)
        try await server.send(Array("<CMD><READBMFRESPONSE><BAND>20</BAND><MODE>CW</MODE><FREQ>14.025</FREQ></CMD>\r\n<CMD><FREQ>7.025</FREQ></CMD>\r\n".utf8))
        #expect(await eventually { sink.events.contains(.band(slot: .a, band: "40M")) })
        #expect(sink.events.contains(.band(slot: .a, band: "20M")))
        #expect(sink.events.contains(.frequency(vfo: .a, mhz: 14.025)))
        #expect(conn.lastClient?.sentChunks.isEmpty == true)   // the monitor sends nothing

        // EOF → waiting → reconnect after 1 s.
        let waitingBefore = sink.events.filter { $0 == .status(N3FJPMonitor.waitingMessage) }.count
        await server.close()
        #expect(await eventually { sink.events.filter { $0 == .status(N3FJPMonitor.waitingMessage) }.count == waitingBefore + 1 })
        #expect(await eventually { clock.sleeperCount == 1 })
        await clock.advance(by: .seconds(1))
        #expect(await eventually { conn.attempts.count == 4 })
        await m.stop()
    }

    @Test func stopEndsLoop() async throws {
        let clock = ManualClock()
        let conn = N3FJPScriptedConnector()
        let m = N3FJPMonitor(connector: conn, clock: clock)
        let stream = try await m.start()
        #expect(await eventually { clock.sleeperCount == 1 })
        await m.stop()
        for await _ in stream {}
        await clock.advance(by: .seconds(5))
        #expect(conn.attempts.count == 1)
    }
}

@Suite struct LoggerSupervisorTests {
    final class Sources: Sendable {
        let map = Mutex<[UInt16: MemoryDatagramSource]>([:])
        let bindings = Mutex<[UDPBinding]>([])
        func make(_ b: UDPBinding) -> any DatagramSource {
            let s = MemoryDatagramSource()
            map.withLock { $0[b.port] = s }
            bindings.withLock { $0.append(b) }
            return s
        }
        subscript(port: UInt16) -> MemoryDatagramSource? { map.withLock { $0[port] } }
    }

    func make() -> (LoggerSupervisor, Sources, N3FJPScriptedConnector, ManualClock) {
        let s = Sources(), c = N3FJPScriptedConnector(), clock = ManualClock()
        let t = LoggerTransports(makeDatagramSource: { s.make($0) }, connector: c, clock: clock)
        return (LoggerSupervisor(transports: t), s, c, clock)
    }

    @Test func eachSourceUsesItsOwnSettings() async throws {
        let (sup, sources, conn, clock) = make()
        let sink = AutomationEventSink(sup.events())
        var cfg = LoggerConfiguration(source: .n1mm, n1mm: N1MMConfig(radioPort: 12061, rotorPort: 12046, selectedVFO: 3))
        cfg.winTest = WinTestConfig(port: 9999, filter: WinTestFilter(selectedRadio: 3))
        cfg.n3fjp = N3FJPConfig(host: "127.0.0.1", port: 1234)
        await sup.apply(cfg)
        #expect(await sup.runningMonitorCount == 2)
        #expect(sources.bindings.withLock { $0.map(\.port) } == [12061, 12046])
        sources[12061]?.inject(Array(radioInfo("<RadioNr>2</RadioNr><Freq>702500</Freq>").utf8))
        #expect(await eventually { sink.events.contains(.band(slot: .b, band: "40M")) })

        // Win-Test gets its own port and radio setting.
        cfg.source = .wintest
        await sup.apply(cfg)
        #expect(await sup.runningMonitorCount == 1)
        #expect(sources.bindings.withLock { $0.last } == UDPBinding(port: 9999, host: nil))
        sources[9999]?.inject(Array(#"STATUS: "STN1" "" 0 1 1 1 140250 0 "CW" 0 "CW" 70250"#.utf8) + [0xD5, 0])
        #expect(await eventually { sink.events.contains(.band(slot: .b, band: "40M")) && sink.events.contains(.frequency(vfo: .b, mhz: 7.025)) })

        // N3FJP gets its own host and port.
        cfg.source = .n3fjp
        await sup.apply(cfg)
        #expect(await eventually { conn.attempts == ["127.0.0.1:1234"] })
        #expect(await eventually { clock.sleeperCount == 1 })

        cfg.source = .manual
        await sup.apply(cfg)
        #expect(await sup.runningMonitorCount == 0)
        await clock.advance(by: .seconds(3))
        #expect(conn.attempts.count == 1)
        await sup.stop()
    }

    @Test func unchangedConfigDoesNotRestart() async {
        let (sup, sources, _, _) = make()
        let cfg = LoggerConfiguration(source: .n1mm)
        await sup.apply(cfg)
        await sup.apply(cfg)
        #expect(sources.bindings.withLock { $0.count } == 2)
        await sup.stop()
    }

    /// Through the supervisor: radio-2 context, FocusRadioNr=1 → Alt-J ignored.
    @Test func so2rGateSharedBetweenMonitors() async {
        let (sup, sources, _, _) = make()
        let sink = AutomationEventSink(sup.events())
        await sup.apply(LoggerConfiguration(source: .n1mm, so2rRadio: 2))
        sources[12060]?.inject(Array(radioInfo("<FocusRadioNr>1</FocusRadioNr>").utf8))
        #expect(await eventually { sink.events.contains(.focusRadio(1)) })
        #expect(sup.activeRadio.value == 1)
        sources[12045]?.inject(Array("<N1MMRotor><goazi>90</goazi></N1MMRotor>".utf8))
        #expect(await eventually { sink.events.contains(.status("Rotor command ignored (SO2R)")) })
        #expect(!sink.events.contains(.turnActive(raw: "90")))
        await sup.stop()
    }
}
