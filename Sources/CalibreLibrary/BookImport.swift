import Foundation

/// Metadata for a book being added to the library. Reading it out of the file itself is
/// the caller's job, which keeps CalibreLibrary free of format parsers.
public struct NewBook: Sendable {
    public var title: String
    public var authors: [String]
    public var publisher: String?
    public var published: Date?
    public var comments: String?
    public var isbn: String?
    public var tags: [String]
    public var series: String?
    public var seriesIndex: Double
    public var cover: Data?

    public init(
        title: String,
        authors: [String] = [],
        publisher: String? = nil,
        published: Date? = nil,
        comments: String? = nil,
        isbn: String? = nil,
        tags: [String] = [],
        series: String? = nil,
        seriesIndex: Double = 1,
        cover: Data? = nil
    ) {
        self.title = title
        self.authors = authors.isEmpty ? ["Unknown"] : authors
        self.publisher = publisher
        self.published = published
        self.comments = comments
        self.isbn = isbn
        self.tags = tags
        self.series = series
        self.seriesIndex = seriesIndex
        self.cover = cover
    }
}

extension CalibreLibraryStore {
    /// Adds a file to the library the way calibre lays it out:
    /// `<Author>/<Title> (<book id>)/<Title> - <Author>.<ext>` plus cover.jpg and metadata.opf.
    @discardableResult
    public func add(fileAt source: URL, metadata: NewBook) throws -> Book {
        guard !isReadOnly else { throw CalibreError.readOnly }
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw CalibreError.fileNotFound(source)
        }

        let format = source.pathExtension.uppercased()
        let now = Date()
        let authorSort = CalibreFunctions.authorSort(of: metadata.authors)

        // The book id is part of the folder name, so the row comes first and the path
        // is filled in once the id exists.
        let id = try database.transaction {
            try database.run(
                """
                INSERT INTO books (title, author_sort, timestamp, pubdate, series_index,
                                   last_modified, path, has_cover)
                VALUES (?, ?, ?, ?, ?, ?, '', ?)
                """,
                [
                    .text(metadata.title),
                    .text(authorSort),
                    .text(CalibreDate.format(now)),
                    .text(CalibreDate.format(metadata.published ?? now)),
                    .real(metadata.seriesIndex),
                    .text(CalibreDate.format(now)),
                    .integer(metadata.cover != nil ? 1 : 0),
                ]
            )
        }

        let folder = Self.bookFolder(title: metadata.title, author: metadata.authors[0], id: id)
        let directory = root.appending(path: folder)
        let stem = Self.fileStem(title: metadata.title, authors: metadata.authors)
        let destination = directory.appending(path: "\(stem).\(format.lowercased())")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            if let cover = metadata.cover {
                try? cover.write(to: directory.appending(path: "cover.jpg"))
            }

            try database.transaction {
                try database.run("UPDATE books SET path = ? WHERE id = ?", [.text(folder), .integer(id)])
                try database.run(
                    "INSERT INTO data (book, format, uncompressed_size, name) VALUES (?, ?, ?, ?)",
                    [.integer(id), .text(format), .integer(Self.fileSize(of: destination)), .text(stem)]
                )
            }
        } catch {
            // Never leave a row pointing at files that were not created.
            try? database.run("DELETE FROM books WHERE id = ?", [.integer(id)])
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        guard var book = try books().first(where: { $0.id == id }) else {
            throw CalibreError.fileNotFound(destination)
        }
        book.authors = metadata.authors
        book.tags = metadata.tags
        book.publisher = metadata.publisher
        book.series = metadata.series
        book.seriesIndex = metadata.seriesIndex
        book.comments = metadata.comments
        if let isbn = metadata.isbn { book.identifiers["isbn"] = isbn }
        try update(book)

        let stored = try books().first { $0.id == id } ?? book
        try writeOPF(for: stored)
        return stored
    }

    /// Adds another format to a book that is already in the library.
    @discardableResult
    public func addFormat(fileAt source: URL, to book: Book) throws -> Book {
        guard !isReadOnly else { throw CalibreError.readOnly }
        let format = source.pathExtension.uppercased()
        let directory = root.appending(path: book.path)
        let stem = Self.fileStem(title: book.title, authors: book.authors)
        let destination = directory.appending(path: "\(stem).\(format.lowercased())")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)

        try database.run(
            """
            INSERT INTO data (book, format, uncompressed_size, name) VALUES (?, ?, ?, ?)
            ON CONFLICT(book, format) DO UPDATE SET uncompressed_size = excluded.uncompressed_size,
                                                    name = excluded.name
            """,
            [.integer(book.id), .text(format), .integer(Self.fileSize(of: destination)), .text(stem)]
        )
        try database.run(
            "UPDATE books SET last_modified = ? WHERE id = ?",
            [.text(CalibreDate.format(Date())), .integer(book.id)]
        )

        let stored = try books().first { $0.id == book.id } ?? book
        try writeOPF(for: stored)
        return stored
    }

    /// A book already in the library with the same title and author.
    public func duplicate(ofTitle title: String, authors: [String]) throws -> Book? {
        let sort = CalibreFunctions.authorSort(of: authors.isEmpty ? ["Unknown"] : authors)
        return try books().first {
            $0.title.caseInsensitiveCompare(title) == .orderedSame
                && $0.authorSort.caseInsensitiveCompare(sort) == .orderedSame
        }
    }

    static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Naming

    static func bookFolder(title: String, author: String, id: Int64) -> String {
        // calibre keeps the folder name short enough to survive every filesystem.
        let authorPart = CalibreFunctions.filenameSafe(author).prefix(60)
        let titlePart = CalibreFunctions.filenameSafe(title).prefix(60)
        return "\(authorPart.isEmpty ? "Unknown" : String(authorPart))/\(titlePart.isEmpty ? "Unknown" : String(titlePart)) (\(id))"
    }

    static func fileStem(title: String, authors: [String]) -> String {
        let titlePart = CalibreFunctions.filenameSafe(title).prefix(42)
        let authorPart = CalibreFunctions.filenameSafe(authors.joined(separator: ", ")).prefix(40)
        return "\(titlePart) - \(authorPart)"
    }
}
