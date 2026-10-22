import Foundation

/// A small XML tree for Sonos responses. Element names are kept without prefixes
/// ("s:Envelope" -> "Envelope").
public struct XNode: Sendable {
    public var name: String
    public var attributes: [String: String] = [:]
    public var children: [XNode] = []
    public var text: String = ""

    public subscript(attribute: String) -> String? { attributes[attribute] }

    public func first(_ name: String) -> XNode? { children.first { $0.name == name } }

    /// All elements with a matching name, self included (document order).
    public func descendants(_ name: String) -> [XNode] {
        var out: [XNode] = []
        func walk(_ n: XNode) {
            if n.name == name { out.append(n) }
            n.children.forEach(walk)
        }
        walk(self)
        return out
    }

    public static func parse(_ data: Data) throws -> XNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.stack.first else {
            throw SonosError.badResponse(parser.parserError?.localizedDescription ?? "Could not parse XML")
        }
        return root
    }

    public static func parse(_ text: String) throws -> XNode { try parse(Data(text.utf8)) }
}

private final class Builder: NSObject, XMLParserDelegate {
    var stack = [XNode(name: "#document")]

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append(XNode(name: Self.local(elementName), attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let node = stack.removeLast()
        stack[stack.count - 1].children.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack[stack.count - 1].text += string
    }
}
