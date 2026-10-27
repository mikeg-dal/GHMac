import Foundation
import Synchronization

/// The N1MM focus radio (`<FocusRadioNr>`), shared by the rotor monitor and hotkeys.
public final class ActiveRadioTracker: Sendable {
    private let state = Mutex<Int?>(nil)
    public init(_ initial: Int? = nil) { state.withLock { $0 = initial } }
    /// nil = not reported yet.
    public var value: Int? { state.withLock { $0 } }
    public func set(_ radio: Int?) { state.withLock { $0 = radio } }
}

/// SO2R gating: the radio-1 context ignores input while radio 2 has focus and
/// vice versa.
public enum SO2RFilter {
    /// - Parameters:
    ///   - activeRadio: last `<FocusRadioNr>`, nil if none yet.
    ///   - thisRadio: 1 for the main context, 2 for the second-radio context.
    ///   - so2rActive: whether SO2R gating is on at all.
    // Unknown focus radio → accept.
    public static func accept(activeRadio: Int?, thisRadio: Int, so2rActive: Bool = true) -> Bool {
        guard so2rActive, let active = activeRadio else { return true }
        switch thisRadio {
        case 2: return active != 1
        default: return active != 2
        }
    }
}

/// An SO2R context: which radio this consumer serves and where the focus radio comes from.
public struct SO2RGate: Sendable {
    public var thisRadio: Int
    public var tracker: ActiveRadioTracker
    public init(thisRadio: Int, tracker: ActiveRadioTracker) { self.thisRadio = thisRadio; self.tracker = tracker }
    public var accepts: Bool { SO2RFilter.accept(activeRadio: tracker.value, thisRadio: thisRadio) }
}
