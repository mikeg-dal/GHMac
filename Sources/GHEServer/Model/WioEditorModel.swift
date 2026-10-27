import Foundation
import Observation
import GHEKit
import GHEServerKit

/// One WIO Profile Editor window's document.
@Observable
final class WioEditorModel {
    /// Output state of one pin. No blank item.
    enum PinState: Int8, CaseIterable, Identifiable {
        case notConnected = -1, on = 1, off = 0, momentary = 2   // Menu order
        var id: Int8 { rawValue }
        var title: String {
            switch self {
            case .notConnected: "N/C"
            case .on: "ON"
            case .off: "OFF"
            case .momentary: "MOM"
            }
        }
    }

    /// One position row. Numbers are kept as text and validated inline.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var bidirectional = false
        var degrees = "0"
        var beamwidth = "0"
        var outputs: [PinState] = Array(repeating: .notConnected, count: 8)   // First item
        var lower = "0.0"
        var upper = "0.0"
        var virtualEntries: [WioProfile.VirtualEntry] = []
    }

    static let defaultRowCount = 28

    var deviceType = "" { didSet { markDirty(oldValue != deviceType) } }
    var matrixLockout = false { didSet { markDirty(oldValue != matrixLockout) } }
    var virtualSwitch = false {
        didSet {
            guard oldValue != virtualSwitch else { return }
            // On/Off banks can't be virtual (release notes).
            if virtualSwitch && displayType == .bank { displayType = .buttons }
            markDirty(true)
        }
    }
    var displayType: SwitchDisplayType = .buttons {
        didSet {
            guard oldValue != displayType else { return }
            // A disabled Matrix Lockout is cleared, not kept.
            if !matrixLockoutEnabled { matrixLockout = false }
            markDirty(true)
        }
    }
    var rows: [Row] = (0..<WioEditorModel.defaultRowCount).map { _ in Row() } {
        didSet { markDirty(oldValue != rows) }
    }
    private(set) var fileURL: URL?
    private(set) var isDirty = false
    /// True once anything was saved in this window (for the reconnect notice).
    private(set) var savedThisSession = false
    private var suppressDirty = false

    init() {}

    // MARK: Display-type rules

    var degreesEnabled: Bool { displayType == .map }
    var frequencyEnabled: Bool { displayType == .band }
    var matrixLockoutEnabled: Bool { displayType == .buttons || displayType == .band }
    var virtualEnabled: Bool { displayType != .bank }
    var outputsEnabled: Bool { !virtualSwitch }

    var title: String {
        "Wio Profile Editor" + (fileURL.map { " -- \($0.lastPathComponent)" } ?? "")
    }

    private func markDirty(_ changed: Bool) {
        if changed && !suppressDirty { isDirty = true }
    }

    func addRows(_ n: Int = 4) {
        rows += (0..<n).map { _ in Row() }
    }

    // MARK: Validation

    func degreesError(_ r: Row) -> Bool { degreesEnabled && Int(JavaString.trim(r.degrees)) == nil }
    func beamwidthError(_ r: Row) -> Bool { degreesEnabled && Int(JavaString.trim(r.beamwidth)) == nil }
    func frequencyError(_ text: String) -> Bool { frequencyEnabled && JavaDouble.parse(JavaString.trim(text)) == nil }

    /// Builds the profile from the non-empty rows, or returns every problem found.
    func makeProfile() -> Result<WioProfile, ProfileProblems> {
        var problems: [String] = []
        let type = JavaString.trim(deviceType)
        if type.isEmpty { problems.append("Enter a Device Type (it becomes the Device Manager subtype).") }
        if WioProfileStore.builtInSubtypes.contains(type) {
            problems.append("“\(type)” is a built-in subtype; choose another Device Type.")
        }
        var positions: [WioProfile.Position] = []
        var seen = Set<String>()
        for (i, r) in rows.enumerated() {
            let name = JavaString.trim(r.name)
            guard !name.isEmpty else { continue }
            let n = i + 1
            if !seen.insert(name).inserted { problems.append("Row \(n): the name “\(name)” is used twice.") }
            let deg = Int(JavaString.trim(r.degrees)), bw = Int(JavaString.trim(r.beamwidth))
            if degreesEnabled && deg == nil { problems.append("Row \(n): Degrees is not a valid integer.") }
            if degreesEnabled && bw == nil { problems.append("Row \(n): Beamwidth is not a valid integer.") }
            let lo = JavaDouble.parse(JavaString.trim(r.lower)), hi = JavaDouble.parse(JavaString.trim(r.upper))
            if frequencyEnabled && (lo == nil || hi == nil) { problems.append("Row \(n): Lower/Upper MHz must be numbers.") }
            if frequencyEnabled, let lo, let hi, lo > hi { problems.append("Row \(n): Lower MHz is above Upper MHz.") }
            positions.append(WioProfile.Position(
                name: name, heading: deg ?? 0, beamwidth: bw ?? 0, bidirectional: r.bidirectional,
                lowerMHz: lo ?? 0, upperMHz: hi ?? 0,
                pins: virtualSwitch ? [] : r.outputs.map(\.rawValue),
                virtualEntries: virtualSwitch ? r.virtualEntries : []))
        }
        if positions.isEmpty { problems.append("Enter at least one position name.") }
        if !problems.isEmpty { return .failure(ProfileProblems(messages: problems)) }
        return .success(WioProfile(name: type, displayType: displayType, matrixLockout: matrixLockoutEnabled && matrixLockout,
                                   virtualSwitch: virtualEnabled && virtualSwitch, positions: positions))
    }

    struct ProfileProblems: Error { let messages: [String] }

    // MARK: Load (a full reset, any number of rows)

    func load(_ p: WioProfile, from url: URL?) {
        suppressDirty = true
        defer { suppressDirty = false }
        deviceType = p.name
        displayType = p.displayType
        virtualSwitch = p.virtualSwitch
        matrixLockout = p.matrixLockout
        var newRows = p.positions.map { pos -> Row in
            var r = Row()
            r.name = pos.name
            r.bidirectional = pos.bidirectional
            r.degrees = String(pos.heading)
            r.beamwidth = String(pos.beamwidth)
            r.lower = JavaDouble.string(pos.lowerMHz)
            r.upper = JavaDouble.string(pos.upperMHz)
            r.outputs = (0..<8).map { i in i < pos.pins.count ? PinState(rawValue: pos.pins[i]) ?? .off : .off }
            r.virtualEntries = pos.virtualEntries
            return r
        }
        while newRows.count < Self.defaultRowCount { newRows.append(Row()) }
        rows = newRows
        fileURL = url
        isDirty = false
    }

    func didSave(to url: URL) {
        fileURL = url
        isDirty = false
        savedThisSession = true
    }
}
