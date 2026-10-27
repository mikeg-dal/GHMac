import Foundation
import GHEKit

/// WIO profile XML (`wioProfiles/*.xml`): read and write.
public enum WioProfileXML {
    public struct ParseResult: Sendable, Equatable {
        /// nil when `errors` is non-empty: a bad profile is reported and skipped, never half-built.
        public var profile: WioProfile?
        public var errors: [String]
        /// Tolerated oddities (unknown display type, out-of-order `order`, unknown pin state...).
        public var warnings: [String]
    }

    public static func displayTypeName(_ t: SwitchDisplayType) -> String {
        switch t {
        case .buttons: "SWITCH"
        case .map: "HEADING"
        case .band: "BANDSWITCH"
        case .bank: "ON_OFF_BANK"
        }
    }

    public static func displayType(named s: String) -> SwitchDisplayType? {
        switch s {
        case "SWITCH": .buttons
        case "HEADING": .map
        case "BANDSWITCH": .band
        case "ON_OFF_BANK": .bank
        default: nil
        }
    }

    static func pinState(named s: String) -> Int8? {
        switch s {
        case "on": 1
        case "off": 0
        case "dont-care": -1
        case "momentary": 2
        default: nil
        }
    }

    static func pinStateName(_ v: Int8) -> String {
        switch v {
        case -1: "dont-care"
        case 1: "on"
        case 2: "momentary"
        default: "off"
        }
    }

    // MARK: Read

    public static func load(from url: URL) -> ParseResult {
        do {
            return parse(try Data(contentsOf: url))
        } catch {
            return ParseResult(profile: nil, errors: ["\(url.lastPathComponent): \(error.localizedDescription)"], warnings: [])
        }
    }

    /// Every problem becomes an error and no profile is returned.
    /// Positions are sorted by `order`.
    public static func parse(_ data: Data) -> ParseResult {
        var errors: [String] = []
        var warnings: [String] = []
        let root: XMLTreeNode
        do {
            root = try XMLTreeReader.parse(data)
        } catch {
            return ParseResult(profile: nil, errors: ["\(error)"], warnings: [])
        }
        guard let nameNode = root.descendants(named: "devicename").first else {
            return ParseResult(profile: nil, errors: ["Missing <devicename>."], warnings: [])
        }
        let deviceName = nameNode.text
        if deviceName.isEmpty { errors.append("<devicename> is empty.") }

        let dtString = root.attribute("displayType")
        var dtype = SwitchDisplayType.buttons
        if let t = Self.displayType(named: dtString) {
            dtype = t
        } else {
            warnings.append("Unknown displayType \"\(dtString)\"; using SWITCH.")
        }
        let virtual = root.attribute("virtualSwitch") == "true"

        var entries: [(order: Int, index: Int, position: WioProfile.Position)] = []
        for (index, e) in root.descendants(named: "position").enumerated() {
            let name = e.attribute("name")
            let label = "Position \(index + 1) (\"\(name)\")"
            func int(_ key: String) -> Int? {
                if let v = JavaString.parseInt(e.attribute(key)) { return v }
                errors.append("\(label): \(key) \"\(e.attribute(key))\" is not a whole number.")
                return nil
            }
            func dbl(_ key: String) -> Double? {
                if let v = JavaDouble.parse(e.attribute(key)) { return v }
                errors.append("\(label): \(key) \"\(e.attribute(key))\" is not a number.")
                return nil
            }
            let order = int("order"), heading = int("heading"), beamwidth = int("beamwidth")
            let lower = dbl("lowerFreq"), upper = dbl("upperFreq")
            let pins = readPins(e, label: label, errors: &errors, warnings: &warnings)
            let reals = e.descendants(named: "real").map {
                WioProfile.VirtualEntry(target: $0.attribute("name"), action: $0.attribute("position"))
            }
            guard let order, let heading, let beamwidth, let lower, let upper, let pins else { continue }
            let position = WioProfile.Position(
                name: name, heading: heading, beamwidth: beamwidth,
                bidirectional: JavaString.parseBool(e.attribute("bidirectional")),
                lowerMHz: lower, upperMHz: upper, pins: pins, virtualEntries: reals)
            entries.append((order, index, position))
        }

        let sorted = entries.sorted { ($0.order, $0.index) < ($1.order, $1.index) }
        if entries.map(\.order) != Array(0..<entries.count) && errors.isEmpty {
            warnings.append("Position order values are not 0…\(sorted.count - 1) in document order; sorted by order.")
        }
        var seen = Set<String>()
        for e in sorted where !seen.insert(e.position.name).inserted {
            warnings.append("Position name \"\(e.position.name)\" is used more than once.")
        }
        guard errors.isEmpty else { return ParseResult(profile: nil, errors: errors, warnings: warnings) }
        let profile = WioProfile(name: deviceName, displayType: dtype,
                                 matrixLockout: root.attribute("matrixlockout") == "true",
                                 virtualSwitch: virtual, positions: sorted.map(\.position))
        return ParseResult(profile: profile, errors: [], warnings: warnings)
    }

    /// Pins indexed by number. The array grows to fit (unset pins stay `off`).
    private static func readPins(_ e: XMLTreeNode, label: String, errors: inout [String], warnings: inout [String]) -> [Int8]? {
        let pinNodes = e.descendants(named: "pin")
        var pins = [Int8](repeating: 0, count: pinNodes.count)
        var ok = true
        for p in pinNodes {
            guard let n = JavaString.parseInt(p.attribute("number")), (0..<64).contains(n) else {
                errors.append("\(label): pin number \"\(p.attribute("number"))\" is invalid.")
                ok = false
                continue
            }
            if n >= pins.count { pins += [Int8](repeating: 0, count: n + 1 - pins.count) }
            let st = p.attribute("state")
            if let v = pinState(named: st) {
                pins[n] = v
            } else {
                warnings.append("\(label): pin \(n) state \"\(st)\" is unknown; treated as off.")
            }
        }
        return ok ? pins : nil
    }

    // MARK: Write

    /// Serialises like `WioSwitchModel.toXML()`: alphabetical attributes, no indentation, pins 7→0,
    /// `<real>` entries (and no pins) for virtual switches. Always UTF-8 bytes.
    public static func serialize(_ profile: WioProfile, lineEnding: String = "\n") -> Data {
        var positions: [JavaXMLElement] = []
        for (i, p) in profile.positions.enumerated() {
            let attrs = [
                "order": String(i),
                "name": p.name,
                "bidirectional": p.bidirectional ? "true" : "false",
                "heading": String(p.heading),
                "beamwidth": String(p.beamwidth),
                "lowerFreq": JavaDouble.string(p.lowerMHz),
                "upperFreq": JavaDouble.string(p.upperMHz),
            ]
            var children: [JavaXMLElement] = []
            if profile.virtualSwitch {
                children = p.virtualEntries.map { JavaXMLElement("real", ["name": $0.target, "position": $0.action]) }
            } else {
                // An unknown position is 8 zero pins.
                let pins = p.pins.isEmpty ? [Int8](repeating: 0, count: 8) : p.pins
                children = pins.indices.reversed().map {
                    JavaXMLElement("pin", ["number": String($0), "state": pinStateName(pins[$0])])
                }
            }
            positions.append(JavaXMLElement("position", attrs, children: children))
        }
        let root = JavaXMLElement("WioDevice", [
            "displayType": displayTypeName(profile.displayType),
            "matrixlockout": profile.matrixLockout ? "true" : "false",
            "virtualSwitch": profile.virtualSwitch ? "true" : "false",
        ], children: [
            JavaXMLElement("devicename", text: profile.name),
            JavaXMLElement("positions", children: positions),
        ])
        return Data(JavaXMLWriter.document(root, lineEnding: lineEnding).utf8)
    }

    public static func write(_ profile: WioProfile, to url: URL) throws {
        try AtomicFile.write(serialize(profile), to: url)
    }
}
