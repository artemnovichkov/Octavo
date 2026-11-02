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

        metadata.cover = cover(in: archive, opfPath: opfPath, parser: parser)
        return metadata
    }

    /// Walks the cover candidates in order of how much the file is actually claiming, and
    /// takes the first one whose bytes are an image.
    ///
    /// Two of the candidates do not name an image at all. An EPUB 2 `<meta name="cover">` often
    /// points at the *cover page* rather than the picture on it, and the `<guide>` reference
    /// always does — so a candidate that turns out to be XHTML is read one more hop, to the
    /// first image it shows. Taking those bytes at face value used to write a page of HTML into
    /// `cover.jpg`; checking the magic is what keeps that out of the library.
    static func cover(in archive: ZipArchive, opfPath: String, parser: OPFParser) -> Data? {
        coverPath(in: archive, opfPath: opfPath, parser: parser)
            .flatMap { try? archive.contents(of: $0) }
    }

    /// The zip entry the cover lives at. The converter wants the path rather than the bytes,
    /// so it can fold the cover into the resource table it is already deduplicating by path.
    static func coverPath(in archive: ZipArchive, opfPath: String, parser: OPFParser) -> String? {
        let opfFolder = (opfPath as NSString).deletingLastPathComponent

        for href in parser.coverCandidates {
            let path = resolve(href, relativeTo: opfFolder)
            guard let data = try? archive.contents(of: path), !data.isEmpty else { continue }
            if isImage(data) { return path }

            guard let inner = firstImageHref(inMarkup: data) else { continue }
            let imagePath = resolve(inner, relativeTo: (path as NSString).deletingLastPathComponent)
            if let image = try? archive.contents(of: imagePath), isImage(image) { return imagePath }
        }
        return nil
    }

    /// Zip entry names carry no fragment and no percent-encoding, which hrefs may.
    static func resolve(_ href: String, relativeTo folder: String) -> String {
        let withoutFragment = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        return normalize(folder.isEmpty ? decoded : "\(folder)/\(decoded)")
    }

    /// `<img src>` or SVG `<image xlink:href>` — what a cover page wraps its picture in.
    /// The attribute is located inside the tag rather than by taking the tag's first quoted
    /// value: `<img class="coverimage" src="…">` would otherwise yield the class name.
    static func firstImageHref(inMarkup data: Data) -> String? {
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        for (tag, attribute) in [("img", "src"), ("image", "xlink:href"), ("image", "href")] {
            guard let tagRange = text.range(
                of: "<\(tag)\\b[^>]*\\b\(attribute)\\s*=\\s*\"[^\"]+\"",
                options: [.regularExpression, .caseInsensitive]
            ) else { continue }
            let tagText = text[tagRange]
            guard let valueRange = tagText.range(
                of: "\\b\(attribute)\\s*=\\s*\"[^\"]+\"",
                options: [.regularExpression, .caseInsensitive]
            ), let quoted = tagText[valueRange].range(of: "\"[^\"]+\"", options: .regularExpression)
            else { continue }
            return String(tagText[quoted].dropFirst().dropLast())
        }
        return nil
    }

    static func isImage(_ data: Data) -> Bool {
        let head = Array(data.prefix(12))
        guard head.count >= 4 else { return false }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return true }                    // JPEG
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }              // PNG
        if head.starts(with: Array("GIF8".utf8)) { return true }                    // GIF
        if head.count >= 12, head.starts(with: Array("RIFF".utf8)),
           Array(head[8..<12]) == Array("WEBP".utf8) { return true }                // WebP
        return false
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
    private var mediaTypes: [String: String?] = [:]  // id -> media-type
    private var spine: [String] = []  // itemref idrefs, in reading order
    private var spineTocID: String?
    private var coverID: String?
    private var coverProperty: String?
    private var guideCoverHref: String?
    private var navID: String?

    /// Reading order resolved to hrefs relative to the OPF.
    var spineHrefs: [String] { spine.compactMap { manifest[$0] } }

    /// Every href that might lead to the cover, most authoritative first: the EPUB 3
    /// `cover-image` property, the EPUB 2 `<meta name="cover">` id, the `<guide>` reference,
    /// then any image in the manifest whose own name says "cover". Only the first of those
    /// is guaranteed to be an image, which is why the caller checks the bytes.
    var coverCandidates: [String] {
        var hrefs: [String] = []
        func add(_ href: String?) {
            guard let href, !href.isEmpty, !hrefs.contains(href) else { return }
            hrefs.append(href)
        }
        add(coverProperty)
        add(coverID.flatMap { manifest[$0] })
        add(guideCoverHref)
        for (id, type) in mediaTypes where type?.hasPrefix("image/") == true {
            guard let href = manifest[id],
                  ((href as NSString).lastPathComponent).lowercased().contains("cover")
            else { continue }
            add(href)
        }
        return hrefs
    }

    /// The EPUB 2 NCX, named either by `<spine toc="…">` or by its media type.
    var ncxHref: String? {
        if let spineTocID, let href = manifest[spineTocID] { return href }
        return mediaTypes.first { $0.value == "application/x-dtbncx+xml" }.flatMap { manifest[$0.key] }
    }

    /// The EPUB 3 navigation document, if the manifest marks one.
    var navHref: String? { navID.flatMap { manifest[$0] } }

    /// Hrefs of every stylesheet in the manifest. Order is not meaningful here — what applies
    /// to a section is whatever that section's own `<link>` tags say.
    var stylesheetHrefs: [String] {
        mediaTypes.filter { $0.value == "text/css" }.compactMap { manifest[$0.key] }
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
                mediaTypes[id] = attributes["media-type"]?.lowercased()
                let properties = attributes["properties"] ?? ""
                if properties.contains("cover-image") { coverProperty = href }
                if properties.split(separator: " ").contains("nav") { navID = id }
            }
        case "reference":
            // The EPUB 2 guide. `type="cover"` names the cover *page*, not the image.
            if attributes["type"]?.lowercased() == "cover" { guideCoverHref = attributes["href"] }
        case "spine":
            spineTocID = attributes["toc"]
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
