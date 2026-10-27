import Foundation
import GHEKit

/// Writes flat `<root><child a=".."/>…</root>` documents exactly like JDK 8's DOM `Transformer` with
/// `indent="yes"` (used for presetFrames.xml and phidgets.xml): `standalone="no"`
/// declaration, attributes sorted by name, one element per line, no indentation, empty root self-closed.
enum ClientXMLWriter {
    static let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="no"?>"#

    static func document(root: String, children: [(name: String, attributes: [String: String])],
                         lineEnding: String = "\n") -> Data {
        var out = declaration + lineEnding
        if children.isEmpty {
            out += "<\(root)/>" + lineEnding
        } else {
            out += "<\(root)>" + lineEnding
            for c in children {
                out += "<" + c.name
                for key in c.attributes.keys.sorted(by: { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }) {
                    out += " \(key)=\"\(escapeAttribute(c.attributes[key] ?? ""))\""
                }
                out += "/>" + lineEnding
            }
            out += "</\(root)>" + lineEnding
        }
        return Data(out.utf8)
    }

    /// JDK 8 serializer escaping for attribute values.
    static func escapeAttribute(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if scalar.value < 0x20 || scalar.value > 0xFFFF { out += "&#\(scalar.value);" } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}

/// Reads every element with a given tag name (any depth, like `getElementsByTagName`) and returns
/// their attributes in document order. Returns nil when the data is not well-formed XML.
enum ClientXMLReader {
    static func elements(named tag: String, in data: Data) -> [[String: String]]? {
        let delegate = Collector(tag: tag)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.found
    }

    private final class Collector: NSObject, XMLParserDelegate {
        let tag: String
        var found: [[String: String]] = []
        init(tag: String) { self.tag = tag }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == tag { found.append(attributeDict) }
        }
    }
}

// MARK: - presetFrames.xml

/// One preset-buttons window. `name` is `"<short> preset selection"` or `"Global preset selection"`.
public struct PresetFrameState: Sendable, Hashable {
    public static let globalName = "Global preset selection"
    public static func name(forRotorShortName short: String) -> String { short + " preset selection" }

    public var name: String
    public var visible: Bool
    public var keepVisible: Bool
    public var x: Int, y: Int, width: Int, height: Int

    public init(name: String, visible: Bool = false, keepVisible: Bool = false,
                x: Int = 0, y: Int = 0, width: Int = 400, height: Int = 400) {
        self.name = name; self.visible = visible; self.keepVisible = keepVisible
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum PresetFramesXML {
    /// Frames in file order. Elements with unparsable numbers are skipped.
    public static func decode(_ data: Data) -> [PresetFrameState] {
        (ClientXMLReader.elements(named: "presetFrame", in: data) ?? []).compactMap { a in
            guard let x = a["x"].flatMap(JavaString.parseInt), let y = a["y"].flatMap(JavaString.parseInt),
                  let w = a["width"].flatMap(JavaString.parseInt), let h = a["height"].flatMap(JavaString.parseInt)
            else { return nil }
            return PresetFrameState(name: a["name"] ?? "", visible: JavaString.parseBool(a["visible"] ?? ""),
                                    keepVisible: JavaString.parseBool(a["keepVisible"] ?? ""),
                                    x: x, y: y, width: w, height: h)
        }
    }

    public static func encode(_ frames: [PresetFrameState], lineEnding: String = "\n") -> Data {
        ClientXMLWriter.document(root: "presetFrames", children: frames.map { f in
            ("presetFrame", ["name": f.name, "visible": String(f.visible), "keepVisible": String(f.keepVisible),
                             "x": String(f.x), "y": String(f.y), "width": String(f.width), "height": String(f.height)])
        }, lineEnding: lineEnding)
    }
}

public struct PresetFramesStore: Sendable {
    public let url: URL
    public init(directory: AppDirectories) { url = directory.file(ClientFileName.presetFrames) }

    public func load() -> [PresetFrameState] {
        (try? Data(contentsOf: url)).map(PresetFramesXML.decode) ?? []
    }

    /// The first frame with that name, like `PresetEntryFrame.loadSettings`.
    public func frame(named name: String) -> PresetFrameState? { load().first { $0.name == name } }

    public func save(_ frames: [PresetFrameState]) throws {
        try AtomicFile.write(PresetFramesXML.encode(frames), to: url)
    }
}

// MARK: - phidgets.xml

/// E-Knob assignment: target name (full name without U+001E) ↔ Phidget serial number.
public struct PhidgetAssignment: Sendable, Hashable {
    public var name: String
    public var serial: Int
    public init(name: String, serial: Int) { self.name = name; self.serial = serial }
}

public enum PhidgetsXML {
    public static func decode(_ data: Data) -> [PhidgetAssignment] {
        (ClientXMLReader.elements(named: "phidget", in: data) ?? []).compactMap { a in
            guard let sn = a["sn"].flatMap(JavaString.parseInt) else { return nil }
            return PhidgetAssignment(name: a["name"] ?? "", serial: sn)
        }
    }

    public static func encode(_ list: [PhidgetAssignment], lineEnding: String = "\n") -> Data {
        ClientXMLWriter.document(root: "phidgets", children: list.map { ("phidget", ["name": $0.name, "sn": String($0.serial)]) },
                                 lineEnding: lineEnding)
    }
}

public struct PhidgetAssignmentStore: Sendable {
    public let url: URL
    public init(directory: AppDirectories) { url = directory.file(ClientFileName.phidgets) }

    public func load() -> [PhidgetAssignment] { (try? Data(contentsOf: url)).map(PhidgetsXML.decode) ?? [] }

    public func save(_ list: [PhidgetAssignment]) throws {
        try AtomicFile.write(PhidgetsXML.encode(list), to: url)
    }
}
