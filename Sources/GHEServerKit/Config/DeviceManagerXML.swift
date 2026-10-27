import Foundation
import GHEKit

/// `DeviceManager.xml`: 100 `<panel>` rows.
public enum DeviceManagerXML {
    public static let fileName = "DeviceManager.xml"
    public static let slotCount = 100

    /// Attributes the port models; everything else on a `<panel>` goes to `extraAttributes`.
    static let knownAttributes: Set<String> = [
        "name", "order", "port", "deviceType", "wioAddress", "subType", "basePTT",
        "fixedHeading", "cloneOffset", "initialState",
    ]

    public struct LoadResult: Sendable, Equatable {
        /// Always `slotCount` entries; `panels[i].order == i`.
        public var panels: [DevicePanelConfig]
        /// Problems that were tolerated (bad `order`, duplicate rows, unparsable numbers...).
        public var warnings: [String]
        /// Every non-empty `port` value in document order, for the port list.
        public var referencedPorts: [String]
    }

    /// 100 blank rows for a fresh install.
    public static func blankPanels() -> [DevicePanelConfig] {
        (0..<slotCount).map { DevicePanelConfig(order: $0) }
    }

    /// Reads a file; a missing file gives blank rows.
    public static func load(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(panels: blankPanels(), warnings: [], referencedPorts: [])
        }
        return parse(data)
    }

    /// Tolerant. A missing or empty `order` falls back to the document index,
    /// a non-numeric one too (with a warning), and rows outside 0…99 are skipped with a warning.
    /// A malformed document gives blank rows plus a warning instead of aborting startup.
    public static func parse(_ data: Data) -> LoadResult {
        var panels = blankPanels()
        var warnings: [String] = []
        var ports: [String] = []
        let root: XMLTreeNode
        do {
            root = try XMLTreeReader.parse(data)
        } catch {
            return LoadResult(panels: panels, warnings: ["DeviceManager.xml could not be read: \(error)"],
                              referencedPorts: [])
        }
        var filled = Set<Int>()
        for (i, e) in root.descendants(named: "panel").enumerated() {
            let orderStr = e.attribute("order")
            var order = i
            if !orderStr.isEmpty {
                if let o = JavaString.parseInt(orderStr) {
                    order = o
                } else {
                    warnings.append("Row \(i + 1): order \"\(orderStr)\" is not a number; using \(i).")
                }
            }
            guard (0..<slotCount).contains(order) else {
                warnings.append("Row \(i + 1): order \(order) is outside 0…\(slotCount - 1); row ignored.")
                continue
            }
            if !filled.insert(order).inserted {
                warnings.append("Row \(i + 1): order \(order) appears more than once; the later row wins.")
            }
            let port = e.attribute("port")
            if !port.isEmpty && !ports.contains(port) { ports.append(port) }
            panels[order] = panel(from: e, order: order, row: i, warnings: &warnings)
        }
        return LoadResult(panels: panels, warnings: warnings, referencedPorts: ports)
    }

    private static func panel(from e: XMLTreeNode, order: Int, row: Int, warnings: inout [String]) -> DevicePanelConfig {
        var p = DevicePanelConfig(order: order)
        // Names are kept verbatim.
        p.name = e.attribute("name")
        let type = e.attribute("deviceType")
        switch type {
        case "WIO 8", "WIO 6": p.deviceType = DeviceType.gheBase.rawValue   // legacy types
        case "": p.deviceType = DeviceType.rt21.rawValue
        default: p.deviceType = type
        }
        let port = e.attribute("port")
        p.port = port.isEmpty ? DevicePanelConfig.notApplicable : port
        let sub = e.attribute("subType")
        p.subType = sub.isEmpty ? DevicePanelConfig.notApplicable : sub
        let wio = e.attribute("wioAddress")
        if let a = JavaString.parseInt(wio), (0...255).contains(a) {
            p.wioAddress = a
        } else if !wio.isEmpty && wio != DevicePanelConfig.notApplicable {
            warnings.append("Row \(row + 1): WIO address \"\(wio)\" is not 0…255; using N/A.")
        }
        p.basePTT = e.attribute("basePTT") == "true"
        p.initialState = e.attribute("initialState") == "true"
        p.fixedHeading = double(e, "fixedHeading", row: row, warnings: &warnings)
        p.cloneOffset = double(e, "cloneOffset", row: row, warnings: &warnings)
        for (k, v) in e.attributes where !knownAttributes.contains(k) { p.extraAttributes[k] = v }
        return p
    }

    private static func double(_ e: XMLTreeNode, _ key: String, row: Int, warnings: inout [String]) -> Double? {
        let s = e.attribute(key)
        guard !s.isEmpty else { return nil }
        guard let v = JavaDouble.parse(s) else {
            warnings.append("Row \(row + 1): \(key) \"\(s)\" is not a number; ignored.")
            return nil
        }
        return v
    }

    // MARK: Write

    /// Serialises all 100 rows. Each config goes to the row given by its
    /// `order` (rows not supplied are blank). `fixedHeading` is written only for Fixed Antenna and
    /// `cloneOffset` only for Cloned Antenna, as Java double strings (nil → the "ask on connect" sentinel).
    /// Unknown attributes read from the file (e.g. `busAddress`) are written back too.
    public static func serialize(_ panels: [DevicePanelConfig], lineEnding: String = "\n") -> Data {
        var rows = blankPanels()
        for p in panels where (0..<slotCount).contains(p.order) { rows[p.order] = p }
        let children = rows.enumerated().map { i, p in element(for: p, order: i) }
        let root = JavaXMLElement("DeviceManager", children: children)
        return Data(JavaXMLWriter.document(root, lineEnding: lineEnding).utf8)
    }

    static func element(for p: DevicePanelConfig, order: Int) -> JavaXMLElement {
        var a: [String: String] = [:]
        for (k, v) in p.extraAttributes where !knownAttributes.contains(k) { a[k] = v }
        a["name"] = p.name
        a["order"] = String(order)
        a["port"] = p.port
        a["deviceType"] = p.deviceType
        a["wioAddress"] = p.wioAddress.map(String.init) ?? DevicePanelConfig.notApplicable
        a["subType"] = p.subType
        a["basePTT"] = p.basePTT ? "true" : "false"
        if p.deviceType == DeviceType.fixedAntenna.rawValue {
            a["fixedHeading"] = JavaDouble.string(p.fixedHeading ?? DevicePanelConfig.fixedHeadingUnset)
        }
        if p.deviceType == DeviceType.clonedAntenna.rawValue {
            a["cloneOffset"] = JavaDouble.string(p.cloneOffset ?? DevicePanelConfig.cloneOffsetUnset)
        }
        a["initialState"] = p.initialState ? "true" : "false"
        return JavaXMLElement("panel", a)
    }

    /// Writes atomically, creating the folder if needed.
    public static func write(_ panels: [DevicePanelConfig], to url: URL) throws {
        try AtomicFile.write(serialize(panels), to: url)
    }
}
