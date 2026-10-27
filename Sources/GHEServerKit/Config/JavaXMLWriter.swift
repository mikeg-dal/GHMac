import Foundation

/// A tiny element tree for writing XML exactly like JDK 8's DOM `Transformer` with `indent="yes"`
/// (the defaults): declaration `standalone="no"`, attributes sorted by name,
/// one element per line, zero indentation, childless elements self-closed.
struct JavaXMLElement: Sendable, Equatable {
    var name: String
    var attributes: [String: String]
    /// Text content (only used for elements without child elements, e.g. `<devicename>`).
    var text: String?
    var children: [JavaXMLElement]

    init(_ name: String, _ attributes: [String: String] = [:], text: String? = nil, children: [JavaXMLElement] = []) {
        self.name = name; self.attributes = attributes; self.text = text; self.children = children
    }
}

enum JavaXMLWriter {
    static let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="no"?>"#

    /// Serialises a whole document. `lineEnding` is Java's `line.separator`: "\n" (default)
    /// or "\r\n".
    static func document(_ root: JavaXMLElement, lineEnding: String = "\n") -> String {
        var out = declaration + lineEnding
        write(root, into: &out, lineEnding: lineEnding)
        return out
    }

    private static func write(_ e: JavaXMLElement, into out: inout String, lineEnding: String) {
        out += "<" + e.name
        // Java's attribute map is ordered by name (UTF-16 order; plain ASCII names here).
        for key in e.attributes.keys.sorted(by: { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }) {
            out += " " + key + "=\"" + escapeAttribute(e.attributes[key] ?? "") + "\""
        }
        if !e.children.isEmpty {
            out += ">" + lineEnding
            for c in e.children { write(c, into: &out, lineEnding: lineEnding) }
            out += "</" + e.name + ">" + lineEnding
        } else if let text = e.text, !text.isEmpty {
            out += ">" + escapeText(text, lineEnding: lineEnding) + "</" + e.name + ">" + lineEnding
        } else {
            out += "/>" + lineEnding
        }
    }

    /// Matches the JDK 8 serializer: `& < > "` as entities, TAB/LF/CR and other controls and
    /// supplementary characters as decimal references, everything else literal UTF-8.
    static func escapeAttribute(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if scalar.value < 0x20 || scalar.value > 0xFFFF {
                    out += "&#\(scalar.value);"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Text nodes: `& < >` as entities, TAB literal, LF as the line separator, CR, other controls and
    /// supplementary characters as decimal references.
    static func escapeText(_ s: String, lineEnding: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\t": out += "\t"
            case "\n": out += lineEnding
            default:
                if scalar.value < 0x20 || scalar.value > 0xFFFF {
                    out += "&#\(scalar.value);"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
