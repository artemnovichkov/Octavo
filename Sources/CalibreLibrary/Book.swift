import Foundation

public struct BookFormat: Sendable, Hashable {
    /// Uppercase, as calibre stores it: AZW3, EPUB, PDF…
    public let format: String
    /// Filename inside the book folder, without extension.
    public let name: String
    public let size: Int64

    public init(format: String, name: String, size: Int64) {
        self.format = format
        self.name = name
        self.size = size
    }

    public var filename: String { "\(name).\(format.lowercased())" }
}

public struct Book: Identifiable, Sendable, Hashable {
    public let id: Int64
    public var uuid: String
    public var title: String
    public var sort: String
    public var authors: [String]
    public var authorSort: String
    public var series: String?
    public var seriesIndex: Double
    public var tags: [String]
    public var publisher: String?
    public var pubdate: Date?
    public var timestamp: Date
    public var lastModified: Date
    public var comments: String?
    public var identifiers: [String: String]
    public var hasCover: Bool
    /// Book folder relative to the library root, e.g. "Gergely Orosz/The Software… (38)".
    public var path: String
    public var formats: [BookFormat]

    public init(
        id: Int64,
        uuid: String,
        title: String,
        sort: String,
        authors: [String],
        authorSort: String,
        series: String? = nil,
        seriesIndex: Double = 1,
        tags: [String] = [],
        publisher: String? = nil,
        pubdate: Date? = nil,
        timestamp: Date = Date(),
        lastModified: Date = Date(),
        comments: String? = nil,
        identifiers: [String: String] = [:],
        hasCover: Bool = false,
        path: String,
        formats: [BookFormat] = []
    ) {
        self.id = id
        self.uuid = uuid
        self.title = title
        self.sort = sort
        self.authors = authors
        self.authorSort = authorSort
        self.series = series
        self.seriesIndex = seriesIndex
        self.tags = tags
        self.publisher = publisher
        self.pubdate = pubdate
        self.timestamp = timestamp
        self.lastModified = lastModified
        self.comments = comments
        self.identifiers = identifiers
        self.hasCover = hasCover
        self.path = path
        self.formats = formats
    }

    public var authorDisplay: String {
        authors.isEmpty ? "Unknown" : authors.joined(separator: ", ")
    }

    public var isbn: String? { identifiers["isbn"] }

    public func url(of format: BookFormat, in library: URL) -> URL {
        library.appending(path: path).appending(path: format.filename)
    }

    public func coverURL(in library: URL) -> URL? {
        guard hasCover else { return nil }
        return library.appending(path: path).appending(path: "cover.jpg")
    }

    public func format(_ name: String) -> BookFormat? {
        formats.first { $0.format.caseInsensitiveCompare(name) == .orderedSame }
    }
}
