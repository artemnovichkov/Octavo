import Foundation

/// Reads a table of contents out of whichever of the two files an EPUB happens to carry: the
/// EPUB 2 NCX or the EPUB 3 navigation document. Most EPUB 3 files still ship an NCX for older
/// readers, so the NCX is tried first — it is plain XML, where a nav document is XHTML and only
/// usually well-formed.
///
/// The result is deliberately flat. A KF8 NCX index can express a hierarchy, but a flat one is
/// valid and is what the Kindle's TOC button needs; nesting can come later without changing
/// anything here but the parser.
enum TOCParser {
    struct Item {
        /// `href` relative to the file the TOC was read from, fragment included.
        var href: String
        var title: String
    }

    static func parse(ncx data: Data) -> [Item] {
        let parser = NCXParser()
        return parser.parse(data)
    }

    static func parse(nav data: Data) -> [Item] {
        let parser = NavParser()
        return parser.parse(data)
    }
}

private final class NCXParser: NSObject, XMLParserDelegate {
    private var items: [TOCParser.Item] = []
    private var text = ""
    private var pendingTitle: String?
    private var inLabel = false

    func parse(_ data: Data) -> [TOCParser.Item] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "navlabel":
            inLabel = true
            text = ""
        case "text":
            text = ""
        case "content":
            // The label always precedes the content element inside a navPoint.
            if let src = attributes["src"], let title = pendingTitle, !title.isEmpty {
                items.append(TOCParser.Item(href: src, title: title))
            }
            pendingTitle = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inLabel { text += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName.lowercased() == "navlabel" {
            inLabel = false
            pendingTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// EPUB 3 `<nav epub:type="toc">`: every `<a href>` inside it, in document order.
private final class NavParser: NSObject, XMLParserDelegate {
    private var items: [TOCParser.Item] = []
    private var navDepth = 0
    private var inTOC = false
    private var currentHref: String?
    private var text = ""

    func parse(_ data: Data) -> [TOCParser.Item] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "nav":
            let type = attributes["epub:type"] ?? attributes["type"] ?? ""
            // A nav document also holds landmarks and a page list; only the toc is wanted.
            if type.split(separator: " ").contains("toc") {
                inTOC = true
                navDepth = 0
            }
            if inTOC { navDepth += 1 }
        case "a" where inTOC:
            currentHref = attributes["href"]
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentHref != nil { text += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName.lowercased() {
        case "nav" where inTOC:
            navDepth -= 1
            if navDepth <= 0 { inTOC = false }
        case "a":
            if let href = currentHref {
                let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { items.append(TOCParser.Item(href: href, title: title)) }
            }
            currentHref = nil
        default:
            break
        }
    }
}
