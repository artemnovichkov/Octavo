import Foundation

public enum EPUBReader {
    public enum EPUBError: Error {
        case noContainer
        case noOPF
    }

    public static func metadata(of url: URL) throws -> EbookMetadata {
        let archive = try ZipArchive(url: url)

        guard let containerData = try archive.contents(of: "META-INF/container.xml"),
              let opfPath = rootfilePath(in: containerData)
        else { throw EPUBError.noContainer }

        guard let opfData = try archive.contents(of: opfPath) else { throw EPUBError.noOPF }

        let parser = OPFParser(fallbackTitle: url.deletingPathExtension().lastPathComponent)
        var metadata = parser.parse(opfData)

        if let coverHref = parser.coverHref {
            let base = (opfPath as NSString).deletingLastPathComponent
            let resolved = base.isEmpty ? coverHref : "\(base)/\(coverHref)"
            metadata.cover = try? archive.contents(of: normalize(resolved))
        }
        return metadata
    }

    /// container.xml points at the OPF; a single regex beats spinning up a parser for it.
    static func rootfilePath(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "full-path=\"[^\"]+\"", options: .regularExpression) else { return nil }
        return String(text[range].dropFirst("full-path=\"".count).dropLast())
    }

    /// Collapses "OEBPS/../images/cover.jpg" so lookups match the zip entry names.
    static func normalize(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/") {
            if component == ".." { components.removeLast() } else if component != "." {
                components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }
}

/// Pulls Dublin Core metadata out of an OPF package document.
final class OPFParser: NSObject, XMLParserDelegate {
    private let fallbackTitle: String
    private var metadata: EbookMetadata
    private var currentElement = ""
    private var currentText = ""
    private var currentRole: String?

    private var manifest: [String: String] = [:]  // id -> href
    private var spine: [String] = []  // itemref idrefs, in reading order
    private var coverID: String?
    private var coverProperty: String?

    /// Reading order resolved to hrefs relative to the OPF.
    var spineHrefs: [String] { spine.compactMap { manifest[$0] } }

    var coverHref: String? {
        if let coverProperty { return coverProperty }
        return coverID.flatMap { manifest[$0] }
    }

    init(fallbackTitle: String) {
        self.fallbackTitle = fallbackTitle
        self.metadata = EbookMetadata(title: fallbackTitle)
    }

    func parse(_ data: Data) -> EbookMetadata {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        if metadata.title.isEmpty { metadata.title = fallbackTitle }
        return metadata
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        currentText = ""
        currentRole = attributes["opf:role"] ?? attributes["role"]

        switch currentElement {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = href
                if attributes["properties"]?.contains("cover-image") == true {
                    coverProperty = href
                }
            }
        case "itemref":
            if let idref = attributes["idref"] { spine.append(idref) }
        case "meta":
            let name = attributes["name"]?.lowercased()
            let property = attributes["property"]?.lowercased()
            let content = attributes["content"]

            if name == "cover" { coverID = content }
            if name == "calibre:series" { metadata.series = content }
            if name == "calibre:series_index", let content { metadata.seriesIndex = Double(content) }
            if property == "belongs-to-collection" { currentElement = "belongs-to-collection" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        switch elementName.lowercased() {
        case "dc:title", "title":
            if metadata.title == fallbackTitle || metadata.title.isEmpty { metadata.title = value }
        case "dc:creator", "creator":
            // Contributors also land in dc:creator in sloppy files; keep only authors.
            if currentRole == nil || currentRole == "aut" { metadata.authors.append(value) }
        case "dc:publisher", "publisher":
            metadata.publisher = value
        case "dc:date", "date":
            metadata.published = metadata.published ?? Self.parseDate(value)
        case "dc:description", "description":
            metadata.comments = value
        case "dc:subject", "subject":
            metadata.tags.append(value)
        case "dc:language", "language":
            metadata.language = value
        case "dc:identifier", "identifier":
            if metadata.isbn == nil, let isbn = Self.extractISBN(value) { metadata.isbn = isbn }
        case "belongs-to-collection":
            metadata.series = metadata.series ?? value
        default:
            break
        }
    }

    static func parseDate(_ raw: String) -> Date? {
        let formats = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "yyyy-MM", "yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    static func extractISBN(_ raw: String) -> String? {
        let digits = raw.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        guard digits.count == 10 || digits.count == 13 else { return nil }
        return digits
    }
}
