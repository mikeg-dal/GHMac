import Foundation
import Synchronization
import Testing
import GHEKit
@testable import GHEServerKit

/// A rotor double: records commands, emits readings on demand.
actor ScriptedRotor: RotorDriver {
    nonisolated let name: String
    private var continuation: AsyncStream<RotorReading>.Continuation?
    private(set) var commands: [String] = []

    init(name: String) { self.name = name }

    func start() async throws -> AsyncStream<RotorReading> {
        let (s, c) = AsyncStream<RotorReading>.makeStream()
        continuation = c
        return s
    }
    func goTo(_ target: TurnTarget) async {
        switch target {
        case .heading(let h): commands.append("goto \(h)")
        case .cw: commands.append("cw")
        case .ccw: commands.append("ccw")
        case .raw(let s): commands.append("raw \(s)")
        }
    }
    func stop() async { commands.append("stop") }
    func query() async { commands.append("query") }
    func close() async { commands.append("close"); continuation?.finish() }
    func emit(_ h: Double, _ status: RotorStatus = .ok) {
        continuation?.yield(RotorReading(name: name, heading: h, status: status))
    }
    func end() { continuation?.finish() }
}

/// A port resolver over a mutable table (port name → endpoint).
final class TablePortResolver: PortResolver, @unchecked Sendable {
    private let table = Mutex<[String: Endpoint]>([:])
    init(_ t: [String: Endpoint] = [:]) { table.withLock { $0 = t } }
    func set(_ name: String, _ ep: Endpoint?) { table.withLock { $0[name] = ep } }
    func portNames() -> [String] { ["N/A"] + table.withLock { Array($0.keys) }.sorted() }
    func endpoint(for portName: String, settings: SerialSettings) -> Endpoint? { table.withLock { $0[portName] } }
}

/// A factory that hands out transports from a closure and records every make.
final class RecordingTransportFactory: TransportFactory, @unchecked Sendable {
    private let maker: @Sendable (Endpoint) -> any ByteTransport
    private let made = Mutex<[any ByteTransport]>([])
    init(_ maker: @escaping @Sendable (Endpoint) -> any ByteTransport) { self.maker = maker }
    func make(_ endpoint: Endpoint) -> any ByteTransport {
        let t = maker(endpoint)
        made.withLock { $0.append(t) }
        return t
    }
    var count: Int { made.withLock { $0.count } }
}

/// A transport that records overlap: `open()` while another instance from the same tracker is open.
final class TrackingTransport: ByteTransport, @unchecked Sendable {
    final class Tracker: @unchecked Sendable {
        let state = Mutex<(open: Int, maxOpen: Int, opens: Int, failOpens: Bool)>((0, 0, 0, false))
        var maxConcurrent: Int { state.withLock { $0.maxOpen } }
        var opens: Int { state.withLock { $0.opens } }
        func setFailOpens(_ on: Bool) { state.withLock { $0.failOpens = on } }
    }
    let tracker: Tracker
    let inner = MemoryTransport()
    private let isOpenNow = Mutex(false)
    init(_ t: Tracker) { tracker = t }

    func open() async throws -> AsyncThrowingStream<[UInt8], any Error> {
        let fail = tracker.state.withLock { s -> Bool in
            s.opens += 1
            return s.failOpens
        }
        if fail { throw TransportError.openFailed("refused") }
        tracker.state.withLock { s in s.open += 1; s.maxOpen = max(s.maxOpen, s.open) }
        isOpenNow.withLock { $0 = true }
        return try await inner.open()
    }
    func write(_ bytes: [UInt8]) async throws { try await inner.write(bytes) }
    func close() async {
        let was = isOpenNow.withLock { o -> Bool in defer { o = false }; return o }
        if was { tracker.state.withLock { $0.open -= 1 } }
        await inner.close()
    }
    func fail() {
        let was = isOpenNow.withLock { o -> Bool in defer { o = false }; return o }
        if was { tracker.state.withLock { $0.open -= 1 } }
        inner.fail()
    }
}

func asciiWrites(_ b: [[UInt8]]) -> [String] { b.map { String(decoding: $0, as: UTF8.self) } }
