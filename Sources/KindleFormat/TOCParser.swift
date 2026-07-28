import Foundation

/// Reads a table of contents out of whichever of the two files an EPUB happens to carry: the
/// EPUB 2 NCX or the EPUB 3 navigation document. Most EPUB 3 files still ship an NCX for older
/// readers, so the NCX is tried first — it is plain XML, where a nav document is XHTML and only
/// usually well-formed.
///
/// Nesting is preserved: the Kindle groups a nested table of contents under collapsible
/// headings, and flattening one turns four sections and sixteen chapters into twenty
/// undifferentiated lines.
enum TOCParser {
    struct Item {
        /// `href` relative to the file the TOC was read from, fragment included.
        var href: String
        var title: String
        /// 0 for a top-level entry, 1 for its children, and so on.
        var depth: Int
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
    /// navPoints nest, and how deeply is exactly what the NCX index needs.
    private var depth = 0

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
        case "navpoint":
            depth += 1
        case "navlabel":
            inLabel = true
            text = ""
        case "text":
            text = ""
        case "content":
            // The label always precedes the content element inside a navPoint.
            if let src = attributes["src"], let title = pendingTitle, !title.isEmpty {
                items.append(TOCParser.Item(href: src, title: title, depth: max(0, depth - 1)))
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
        switch elementName.lowercased() {
        case "navlabel":
            inLabel = false
            pendingTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "navpoint":
            depth = max(0, depth - 1)
        default:
            break
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
    /// An EPUB 3 nav document nests with <ol>, not with the anchors themselves.
    private var listDepth = 0

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
        case "ol" where inTOC:
            listDepth += 1
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
            if navDepth <= 0 { inTOC = false; listDepth = 0 }
        case "ol" where inTOC:
            listDepth = max(0, listDepth - 1)
        case "a":
            if let href = currentHref {
                let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    items.append(TOCParser.Item(href: href, title: title, depth: max(0, listDepth - 1)))
                }
            }
            currentHref = nil
        default:
            break
        }
    }
}
