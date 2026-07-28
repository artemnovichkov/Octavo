import Foundation

/// Turns formats the Kindle cannot open into one it can.
///
/// Reading and writing are kept apart: each source format is read into a `BookDocument`, and
/// each target format is written from one. That is what lets AZW3 keep the spine and the
/// stylesheets — which MOBI 6 has nowhere to put — without the EPUB reader knowing either
/// format exists.
public enum Converter {
    public enum ConversionError: Error, LocalizedError {
        case unsupported(String)
        case emptyBook

        public var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "Nothing to convert: format \(ext)"
            case .emptyBook: return "No text found in the book"
            }
        }
    }

    public static let convertibleExtensions = ["epub", "cbz", "fb2"]

    public static func canConvert(_ url: URL) -> Bool {
        convertibleExtensions.contains(url.pathExtension.lowercased())
    }

    /// Converts and writes the result next to the requested destination.
    @discardableResult
    public static func convert(
        _ source: URL,
        to destination: URL,
        target: ConversionTarget = .default
    ) throws -> URL {
        let document = try read(source)
        try write(document, to: destination, target: target)
        return destination
    }

    static func read(_ source: URL) throws -> BookDocument {
        switch source.pathExtension.lowercased() {
        case "epub": return try readEPUB(source)
        case "cbz": return try readComic(source)
        case "fb2": return try readFB2(source)
        default: throw ConversionError.unsupported(source.pathExtension)
        }
    }

    static func write(_ document: BookDocument, to destination: URL, target: ConversionTarget) throws {
        guard !document.isEmpty else { throw ConversionError.emptyBook }
        let data = switch target {
        case .azw3: KF8Writer.write(document)
        case .mobi: MOBIWriter.write(document)
        }
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - EPUB

    static func readEPUB(_ url: URL) throws -> BookDocument {
        let archive = try ZipArchive(url: url)
        guard let containerData = try archive.contents(of: "META-INF/container.xml"),
              let opfPath = EPUBReader.rootfilePath(in: containerData),
              let opfData = try archive.contents(of: opfPath)
        else { throw EPUBReader.EPUBError.noContainer }

        let parser = OPFParser(fallbackTitle: url.deletingPathExtension().lastPathComponent)
        var document = BookDocument(metadata: parser.parse(opfData))
        let base = (opfPath as NSString).deletingLastPathComponent

        func resolve(_ href: String, from directory: String) -> String {
            let joined = directory.isEmpty ? href : "\(directory)/\(href)"
            let normalized = EPUBReader.normalize(joined)
            return normalized.removingPercentEncoding ?? normalized
        }

        var resourceIndexByPath: [String: Int] = [:]
        func resourceIndex(for path: String) -> Int? {
            if let existing = resourceIndexByPath[path] { return existing }
            guard let data = try? archive.contents(of: path), !data.isEmpty else { return nil }
            document.resources.append(data)
            resourceIndexByPath[path] = document.resources.count - 1
            return document.resources.count - 1
        }

        // The cover is pulled first so it lands at resource 0, which is what EXTH 201 records.
        if let coverHref = parser.coverHref {
            document.coverResourceIndex = resourceIndex(for: resolve(coverHref, from: base))
        }

        var stylesheetIndexByPath: [String: Int] = [:]
        func stylesheetIndex(for path: String) -> Int? {
            if let existing = stylesheetIndexByPath[path] { return existing }
            guard let data = try? archive.contents(of: path), !data.isEmpty else { return nil }
            document.stylesheets.append(String(decoding: data, as: UTF8.self))
            stylesheetIndexByPath[path] = document.stylesheets.count - 1
            return document.stylesheets.count - 1
        }

        var sectionIndexByPath: [String: Int] = [:]
        for href in parser.spineHrefs {
            let path = resolve(href, from: base)
            guard let data = try? archive.contents(of: path) else { continue }
            let directory = (path as NSString).deletingLastPathComponent
            let xhtml = String(decoding: data, as: UTF8.self)

            var section = BookDocument.Section(path: path, xhtml: xhtml)
            // Keyed by the attribute value verbatim: a writer rewrites what it finds in the
            // markup, and should never have to redo path resolution to know what it maps to.
            for src in Markup.attributeValues(in: xhtml, tag: "img", attribute: "src")
                + Markup.attributeValues(in: xhtml, tag: "image", attribute: "xlink:href")
            {
                if let index = resourceIndex(for: resolve(src, from: directory)) {
                    section.resources[src] = index
                }
            }
            for href in Markup.attributeValues(in: xhtml, tag: "link", attribute: "href") {
                guard href.lowercased().hasSuffix(".css") else { continue }
                if let index = stylesheetIndex(for: resolve(href, from: directory)) {
                    section.stylesheets.append(index)
                }
            }

            sectionIndexByPath[path] = document.sections.count
            document.sections.append(section)
        }

        // Links are resolved in a second pass: a section can point at one that follows it, so
        // the whole spine has to be indexed first.
        for index in document.sections.indices {
            let directory = (document.sections[index].path as NSString).deletingLastPathComponent
            for href in Markup.attributeValues(in: document.sections[index].xhtml, tag: "a", attribute: "href") {
                let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let anchor = parts.count > 1 ? String(parts[1]) : nil
                let file = String(parts[0])
                // An empty file part is a link inside this very section.
                guard let target = file.isEmpty
                    ? index
                    : sectionIndexByPath[resolve(file, from: directory)]
                else { continue }
                document.sections[index].links[href] = BookDocument.LinkTarget(section: target, anchor: anchor)
            }
        }

        document.toc = readTOC(archive: archive, parser: parser, base: base) { href in
            sectionIndexByPath[resolve(href, from: base)]
        }
        return document
    }

    /// NCX first, then the EPUB 3 navigation document: most EPUB 3 files ship both, and the NCX
    /// is real XML where a nav document only usually is.
    private static func readTOC(
        archive: ZipArchive,
        parser: OPFParser,
        base: String,
        sectionIndex: (String) -> Int?
    ) -> [BookDocument.TOCEntry] {
        var items: [TOCParser.Item] = []
        if let ncxHref = parser.ncxHref,
           let data = try? archive.contents(of: EPUBReader.normalize(base.isEmpty ? ncxHref : "\(base)/\(ncxHref)")) {
            items = TOCParser.parse(ncx: data)
        }
        if items.isEmpty, let navHref = parser.navHref,
           let data = try? archive.contents(of: EPUBReader.normalize(base.isEmpty ? navHref : "\(base)/\(navHref)")) {
            items = TOCParser.parse(nav: data)
        }

        return items.compactMap { item in
            let parts = item.href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard let index = sectionIndex(String(parts[0])) else { return nil }
            let anchor = parts.count > 1 ? String(parts[1]) : nil
            return BookDocument.TOCEntry(title: item.title, sectionIndex: index, anchor: anchor)
        }
    }

    // MARK: - CBZ

    static func readComic(_ url: URL) throws -> BookDocument {
        let archive = try ZipArchive(url: url)
        let pages = archive.entries
            .filter { ["jpg", "jpeg", "png", "gif"].contains(($0.path as NSString).pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !pages.isEmpty else { throw ConversionError.emptyBook }

        var document = BookDocument(
            metadata: EbookMetadata(title: url.deletingPathExtension().lastPathComponent)
        )

        // One section per page: MOBI 6 joins them back into one stream, KF8 gets a skeleton
        // each, which is the natural unit for a comic anyway.
        for page in pages {
            guard let data = try? archive.contents(of: page), !data.isEmpty else { continue }
            document.resources.append(data)
            let index = document.resources.count - 1
            document.sections.append(BookDocument.Section(
                path: page.path,
                xhtml: "<html><body><div align=\"center\"><img src=\"\(page.path)\"/></div></body></html>",
                resources: [page.path: index]
            ))
        }
        guard !document.resources.isEmpty else { throw ConversionError.emptyBook }

        document.coverResourceIndex = 0
        document.metadata.cover = document.resources.first
        return document
    }

    // MARK: - FB2

    static func readFB2(_ url: URL) throws -> BookDocument {
        let metadata = try FB2Reader.metadata(of: url)
        let raw = try Data(contentsOf: url)
        let text = String(decoding: raw, as: UTF8.self)

        // FB2 is XML with its own tag set; mapping the handful of block tags Kindle
        // understands is enough for a readable book.
        var html = HTMLFlattener.stripTag(text, "description")
        html = html.replacingOccurrences(of: "<body>", with: "")
            .replacingOccurrences(of: "</body>", with: "")
        for (fb2, replacement) in [
            ("<section>", "<div>"), ("</section>", "</div>"),
            ("<title>", "<h2>"), ("</title>", "</h2>"),
            ("<subtitle>", "<h3>"), ("</subtitle>", "</h3>"),
            ("<empty-line/>", "<br/>"),
            ("<strong>", "<b>"), ("</strong>", "</b>"),
            ("<emphasis>", "<i>"), ("</emphasis>", "</i>"),
        ] {
            html = html.replacingOccurrences(of: fb2, with: replacement)
        }
        html = HTMLFlattener.stripTag(html, "binary")
        html = html.replacingOccurrences(of: "<\\?xml[^>]*\\?>", with: "", options: .regularExpression)
        html = html.replacingOccurrences(of: "<FictionBook[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "</FictionBook>", with: "")

        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.emptyBook
        }

        var document = BookDocument(metadata: metadata)
        document.sections = [BookDocument.Section(
            path: url.lastPathComponent,
            xhtml: "<html><body>\(html)</body></html>"
        )]
        return document
    }
}

enum HTMLFlattener {
    /// Everything between <body> and </body>, or the whole document when there is no body.
    static func body(of document: String) -> String {
        guard let start = document.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]),
              let end = document.range(of: "</body>", options: [.caseInsensitive, .backwards])
        else { return stripTag(document, "head") }
        return String(document[start.upperBound..<end.lowerBound])
    }

    /// Replaces `<img src="...">` with the `recindex` form MOBI uses. Images that cannot
    /// be resolved are dropped rather than left pointing at nothing.
    static func rewriteImages(in html: String, index: (String) -> Int?) -> String {
        let pattern = "<img[^>]*?src=[\"']([^\"']+)[\"'][^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return html }

        let source = html as NSString
        var result = ""
        var cursor = 0

        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let src = source.substring(with: match.range(at: 1))
            if let recindex = index(src) {
                result += "<img recindex=\"\(String(format: "%05d", recindex))\"/>"
            }
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    static func stripTag(_ html: String, _ tag: String) -> String {
        html.replacingOccurrences(
            of: "<\(tag)[^>]*>.*?</\(tag)>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}
