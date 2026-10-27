import Foundation
import Synchronization
import GHEKit
@testable import GHEClientKit

/// Collects events from a stream in the background.
final class AutomationEventSink<E: Sendable>: Sendable {
    private final class Store: Sendable { let items = Mutex<[E]>([]) }
    private let store = Store()
    private let task: Task<Void, Never>
    init(_ stream: AsyncStream<E>) {
        let store = store
        task = Task { for await e in stream { store.items.withLock { $0.append(e) } } }
    }
    var events: [E] { store.items.withLock { $0 } }
    func cancel() { task.cancel() }
}

func radioInfo(_ body: String) -> String {
    #"<?xml version="1.0" encoding="utf-8"?><RadioInfo>"# + body + "</RadioInfo>"
}

func automationBytes(hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}

extension Array where Element == LoggerEvent {
    var withoutRaw: [LoggerEvent] { filter { if case .raw = $0 { false } else { true } } }
    var bandAndFrequency: [LoggerEvent] {
        filter { switch $0 { case .band, .frequency: true; default: false } }
    }
}
