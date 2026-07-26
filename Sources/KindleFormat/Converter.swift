import Foundation

/// Turns formats the Kindle cannot open into a MOBI it can.
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
    public static func convert(_ source: URL, to destination: URL) throws -> URL {
        let data: Data
        switch source.pathExtension.lowercased() {
        case "epub":
            data = try convertEPUB(source)
        case "cbz":
            data = try convertComic(source)
        case "fb2":
            data = try convertFB2(source)
        default:
            throw ConversionError.unsupported(source.pathExtension)
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    // MARK: - EPUB

    static func convertEPUB(_ url: URL) throws -> Data {
        let archive = try ZipArchive(url: url)
        guard let containerData = try archive.contents(of: "META-INF/container.xml"),
              let opfPath = EPUBReader.rootfilePath(in: containerData),
              let opfData = try archive.contents(of: opfPath)
        else { throw EPUBReader.EPUBError.noContainer }

        let parser = OPFParser(fallbackTitle: url.deletingPathExtension().lastPathComponent)
        let metadata = parser.parse(opfData)
        let base = (opfPath as NSString).deletingLastPathComponent

        func resolve(_ href: String) -> String {
            let raw = base.isEmpty ? href : "\(base)/\(href)"
            return EPUBReader.normalize(raw.removingPercentEncoding ?? raw)
        }

        var images: [Data] = []
        var imageIndexByPath: [String: Int] = [:]

        func imageIndex(for path: String) -> Int? {
            if let existing = imageIndexByPath[path] { return existing }
            guard let data = try? archive.contents(of: path), !data.isEmpty else { return nil }
            images.append(data)
            imageIndexByPath[path] = images.count
            return images.count
        }

        // The cover goes first so EXTH 201 can address it as image 0.
        var coverIndex: Int?
        if let coverHref = parser.coverHref, let index = imageIndex(for: resolve(coverHref)) {
            coverIndex = index - 1
        }

        var html = ""
        for href in parser.spineHrefs {
            let path = resolve(href)
            guard let data = try? archive.contents(of: path) else { continue }
            let document = String(decoding: data, as: UTF8.self)
            let bodyHTML = HTMLFlattener.body(of: document)
            let documentBase = (path as NSString).deletingLastPathComponent

            let rewritten = HTMLFlattener.rewriteImages(in: bodyHTML) { src in
                let resolved = EPUBReader.normalize(
                    documentBase.isEmpty ? src : "\(documentBase)/\(src)"
                )
                return imageIndex(for: resolved.removingPercentEncoding ?? resolved)
            }
            if !html.isEmpty { html += "<mbp:pagebreak/>" }
            html += rewritten
        }

        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.emptyBook
        }

        return MOBIWriter.write(MOBIWriter.Input(
            html: html,
            images: images,
            metadata: metadata,
            coverIndex: coverIndex
        ))
    }

    // MARK: - CBZ

    static func convertComic(_ url: URL) throws -> Data {
        let archive = try ZipArchive(url: url)
        let pages = archive.entries
            .filter { ["jpg", "jpeg", "png", "gif"].contains(($0.path as NSString).pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !pages.isEmpty else { throw ConversionError.emptyBook }

        var images: [Data] = []
        var html = ""
        for (index, page) in pages.enumerated() {
            guard let data = try? archive.contents(of: page), !data.isEmpty else { continue }
            images.append(data)
            if index > 0 { html += "<mbp:pagebreak/>" }
            html += "<div align=\"center\"><img recindex=\"\(String(format: "%05d", images.count))\"/></div>"
        }
        guard !images.isEmpty else { throw ConversionError.emptyBook }

        var metadata = EbookMetadata(title: url.deletingPathExtension().lastPathComponent)
        metadata.cover = images.first

        return MOBIWriter.write(MOBIWriter.Input(
            html: html,
            images: images,
            metadata: metadata,
            coverIndex: 0
        ))
    }

    // MARK: - FB2

    static func convertFB2(_ url: URL) throws -> Data {
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
        return MOBIWriter.write(MOBIWriter.Input(html: html, images: [], metadata: metadata))
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
