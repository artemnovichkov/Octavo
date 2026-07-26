import Foundation

/// Everything Octavo can learn about a book from the file itself.
public struct EbookMetadata: Sendable {
    public var title: String
    public var authors: [String] = []
    public var publisher: String?
    public var published: Date?
    public var comments: String?
    public var isbn: String?
    public var tags: [String] = []
    public var language: String?
    public var series: String?
    public var seriesIndex: Double?
    public var cover: Data?

    public init(title: String) {
        self.title = title
    }
}

public enum EbookReader {
    /// Formats Octavo can pull metadata out of. Anything else falls back to the filename.
    public static func metadata(of url: URL) -> EbookMetadata {
        let fallback = EbookMetadata(title: url.deletingPathExtension().lastPathComponent)
        switch url.pathExtension.lowercased() {
        case "epub":
            return (try? EPUBReader.metadata(of: url)) ?? fallback
        case "azw3", "azw", "mobi", "prc":
            return (try? MOBIReader.metadata(of: url)) ?? fallback
        case "fb2":
            return (try? FB2Reader.metadata(of: url)) ?? fallback
        case "cbz":
            return (try? ComicReader.metadata(of: url)) ?? fallback
        case "pdf":
            return PDFReader.metadata(of: url) ?? fallback
        default:
            return fallback
        }
    }
}

enum ComicReader {
    /// CBZ carries no metadata beyond the filename; the first page makes a decent cover.
    static func metadata(of url: URL) throws -> EbookMetadata {
        var result = EbookMetadata(title: url.deletingPathExtension().lastPathComponent)
        let archive = try ZipArchive(url: url)
        let pages = archive.entries
            .filter { ["jpg", "jpeg", "png"].contains(($0.path as NSString).pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if let first = pages.first {
            result.cover = try? archive.contents(of: first)
        }
        return result
    }
}
