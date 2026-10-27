import Foundation
import GHEKit

public enum WIOBaseError: Error, Equatable, LocalizedError {
    /// Base PTT is ticked but CTS is not asserted at open.
    case pttNotSupported(port: String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .pttNotSupported(let p): "The GH Base unit on \(p) does not support Base PTT Mode"
        case .closed: "The GHE Base is closed."
        }
    }
}

public enum WIOBaseEvent: Sendable, Equatable {
    /// The link to the Base failed (cable pull, TCP reset, write error).
    case linkLost(String)
    /// The Base closed because its last remote was released, or on request.
    case closed
}

/// One Base (XBee coordinator) on one port, shared by every device on that port.
///
/// Every frame goes through ONE writer queue, so frames never interleave.
/// The validate frame is still sent, but the 3 s wait is an async sleep.
public actor WIOBase {
    public nonisolated let portName: String
    public nonisolated let basePTT: Bool
    /// Link and lifecycle events.
    public nonisolated let events = EventBroadcaster<WIOBaseEvent>()

    private let transport: any ByteTransport
    private let clock: any GHEClock
    private var remotes: [Int: PhysicalRemote] = [:]
    private var decoder = XBeeDecoder()
    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private let outbox: AsyncStream<[UInt8]>
    private let outboxContinuation: AsyncStream<[UInt8]>.Continuation
    private var closing = false
    public private(set) var isAlive = false
    /// Frames dropped because CTS was low in Base PTT mode.
    public private(set) var framesDroppedForPTT = 0

    public init(portName: String, transport: any ByteTransport, clock: any GHEClock, basePTT: Bool = false) {
        self.portName = portName
        self.transport = transport
        self.clock = clock
        self.basePTT = basePTT
        (outbox, outboxContinuation) = AsyncStream<[UInt8]>.makeStream()
    }

    /// Opens the port, sends the validate frame and waits `validateWait` (asynchronously).
    public func open(validateWait: Duration = Timing.wioBaseValidateWait) async throws {
        let stream = try await transport.open()
        if basePTT {
            // Base PTT needs CTS asserted at open; otherwise refuse.
            let cts = (try? await (transport as? any ModemControl)?.modemLines().cts) ?? false
            if !cts {
                await transport.close()
                throw WIOBaseError.pttNotSupported(port: portName)
            }
        }
        isAlive = true
        startWriter()
        readerTask = Task { [weak self] in
            do {
                for try await chunk in stream { await self?.ingest(chunk) }
                await self?.linkEnded(nil)
            } catch {
                await self?.linkEnded(error)
            }
        }
        send(XBeeFrame.validate)
        try? await clock.sleep(for: validateWait)
        guard isAlive else { throw WIOBaseError.closed }
    }

    /// Queues one frame for the single writer. Never blocks.
    public nonisolated func send(_ frame: [UInt8]) {
        outboxContinuation.yield(frame)
    }

    /// The shared remote at a WIO address (0 = the Base's own I/O), created on first use.
    public func physicalRemote(address: Int) -> PhysicalRemote {
        if let r = remotes[address] { return r }
        let r = PhysicalRemote(address: address, base: self, clock: clock)
        remotes[address] = r
        return r
    }

    /// The remote at an address if one exists.
    public func existingRemote(address: Int) -> PhysicalRemote? { remotes[address] }

    /// Called by a remote whose last user detached. Closes the Base when no remotes remain.
    func remoteClosed(_ remote: PhysicalRemote) async {
        if let r = remotes[remote.address], r === remote { remotes[remote.address] = nil }
        if remotes.isEmpty { await close() }
    }

    public func close() async {
        guard !closing else { return }
        closing = true
        isAlive = false
        let rs = Array(remotes.values)
        remotes.removeAll()
        for r in rs { await r.baseGone() }
        outboxContinuation.finish()
        readerTask?.cancel()
        await transport.close()
        events.yield(.closed)
        events.finish()
    }

    public var badFrameCount: Int { decoder.badFrames }

    // MARK: - Internals

    private func startWriter() {
        let transport = self.transport
        let ptt = basePTT
        let outbox = self.outbox
        writerTask = Task { [weak self] in
            for await frame in outbox {
                if ptt {
                    // While CTS is low the frame is dropped; the 800 ms refresh resends the image.
                    let cts = (try? await (transport as? any ModemControl)?.modemLines().cts) ?? false
                    if !cts { await self?.countPTTDrop(); continue }
                }
                do { try await transport.write(frame) } catch {
                    await self?.linkEnded(error)
                    return
                }
            }
        }
    }

    private func countPTTDrop() { framesDroppedForPTT += 1 }

    private func ingest(_ chunk: [UInt8]) async {
        for f in decoder.push(chunk) {
            guard let addr = f.wioAddress, let r = remotes[addr] else { continue }
            await r.handle(f)
        }
    }

    private func linkEnded(_ error: (any Error)?) async {
        guard !closing else { return }
        closing = true
        isAlive = false
        let why = error.map { ($0 as? LocalizedError)?.errorDescription ?? "\($0)" } ?? "The connection was closed."
        events.yield(.linkLost(why))
        let rs = Array(remotes.values)
        remotes.removeAll()
        for r in rs { await r.baseGone() }
        outboxContinuation.finish()
        await transport.close()
        events.finish()
    }
}
