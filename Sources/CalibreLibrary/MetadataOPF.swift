import Foundation

extension CalibreLibraryStore {
    /// calibre keeps a metadata.opf next to every book and rebuilds its database from
    /// those files when asked to. Octavo writes one on every change so the library stays
    /// self-describing even if metadata.db is lost.
    public func writeOPF(for book: Book) throws {
        let directory = root.appending(path: book.path)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        let opf = Self.opf(for: book)
        try Data(opf.utf8).write(to: directory.appending(path: "metadata.opf"), options: .atomic)
    }

    static func opf(for book: Book) -> String {
        var metadata = """
            <dc:title>\(escape(book.title))</dc:title>
        """

        for author in book.authors {
            metadata += """

                    <dc:creator opf:file-as="\(escape(CalibreFunctions.authorSort(author)))" opf:role="aut">\(escape(author))</dc:creator>
            """
        }

        if let publisher = book.publisher {
            metadata += "\n        <dc:publisher>\(escape(publisher))</dc:publisher>"
        }
        if let comments = book.comments, !comments.isEmpty {
            metadata += "\n        <dc:description>\(escape(comments))</dc:description>"
        }
        if let pubdate = book.pubdate {
            metadata += "\n        <dc:date>\(iso(pubdate))</dc:date>"
        }
        metadata += "\n        <dc:identifier id=\"uuid_id\" opf:scheme=\"uuid\">\(escape(book.uuid))</dc:identifier>"
        for (scheme, value) in book.identifiers.sorted(by: { $0.key < $1.key }) {
            metadata += "\n        <dc:identifier opf:scheme=\"\(escape(scheme.uppercased()))\">\(escape(value))</dc:identifier>"
        }
        for tag in book.tags {
            metadata += "\n        <dc:subject>\(escape(tag))</dc:subject>"
        }

        metadata += "\n        <meta name=\"calibre:timestamp\" content=\"\(iso(book.timestamp))\"/>"
        metadata += "\n        <meta name=\"calibre:title_sort\" content=\"\(escape(book.sort))\"/>"
        if let series = book.series {
            metadata += "\n        <meta name=\"calibre:series\" content=\"\(escape(series))\"/>"
            metadata += "\n        <meta name=\"calibre:series_index\" content=\"\(book.seriesIndex.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))))\"/>"
        }

        return """
        <?xml version='1.0' encoding='utf-8'?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uuid_id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                \(metadata)
            </metadata>
            <guide>
                <reference type="cover" title="Cover" href="cover.jpg"/>
            </guide>
        </package>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
