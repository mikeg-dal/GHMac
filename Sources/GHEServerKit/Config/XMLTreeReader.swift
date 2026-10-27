import Foundation
import GHEKit

/// A parsed XML element (read side). Only what the config formats need.
struct XMLTreeNode: Sendable, Equatable {
    var name: String
    var attributes: [String: String]
    var children: [XMLTreeNode]
    /// Direct character data of this element.
    var text: String

    /// "" when absent.
    func attribute(_ key: String) -> String { attributes[key] ?? "" }

    /// From this node: every descendant (not self) with that name, in document order.
    func descendants(named n: String) -> [XMLTreeNode] {
        var out: [XMLTreeNode] = []
        for c in children {
            if c.name == n { out.append(c) }
            out += c.descendants(named: n)
        }
        return out
    }
}

enum XMLTreeError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case empty

    var description: String {
        switch self {
        case .malformed(let m): "Malformed XML: \(m)"
        case .empty: "The file is empty."
        }
    }
}

/// Parses XML with Foundation's `XMLParser` (no DTD or external entity loading).
/// Bytes that are not valid UTF-8 are re-read as CP1252.
enum XMLTreeReader {
    static func parse(_ data: Data) throws -> XMLTreeNode {
        guard !data.isEmpty else { throw XMLTreeError.empty }
        var input = data
        if String(data: data, encoding: .utf8) == nil, declaresUTF8OrNothing(data) {
            input = Data(Windows1252.decode(data).utf8)
        }
        let builder = TreeBuilder()
        let parser = XMLParser(data: input)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let reason = builder.error ?? parser.parserError?.localizedDescription ?? "unknown error"
            throw XMLTreeError.malformed(reason)
        }
        return root
    }

    /// True when the XML declaration (if any) names UTF-8 or no encoding.
    private static func declaresUTF8OrNothing(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(200), as: UTF8.self).lowercased()
        guard head.hasPrefix("<?xml"), let end = head.range(of: "?>") else { return true }
        let decl = head[..<end.lowerBound]
        guard let enc = decl.range(of: "encoding") else { return true }
        let rest = decl[enc.upperBound...]
        return rest.contains("utf-8") || rest.contains("utf8")
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var stack: [XMLTreeNode] = []
        var root: XMLTreeNode?
        var error: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(XMLTreeNode(name: elementName, attributes: attributeDict, children: [], text: ""))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard let node = stack.popLast() else { return }
            if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if error == nil {
                error = "line \(parser.lineNumber): \(parseError.localizedDescription)"
            }
        }
    }
}
