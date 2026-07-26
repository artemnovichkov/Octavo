import Foundation

/// Reads and writes a calibre library in place — same metadata.db, same folder layout,
/// so calibre keeps working alongside Octavo. calibre itself need not be installed: `create`
/// lays down the same schema, so a library Octavo made is one calibre can open later.
public final class CalibreLibraryStore {
    public let root: URL
    public let isReadOnly: Bool
    let database: SQLiteDatabase

    public static let defaultLocation = URL.homeDirectory.appending(path: "Calibre Library")

    /// A library is a folder with a metadata.db in it — the same test calibre applies.
    public static func isLibrary(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: databaseURL(in: root).path(percentEncoded: false))
    }

    static func databaseURL(in root: URL) -> URL { root.appending(path: "metadata.db") }

    public init(root: URL = defaultLocation, readOnly: Bool = false) throws {
        guard Self.isLibrary(at: root) else { throw CalibreError.libraryNotFound(root) }
        self.root = root
        self.isReadOnly = readOnly
        self.database = try SQLiteDatabase(
            path: Self.databaseURL(in: root).path(percentEncoded: false),
            readOnly: readOnly
        )
        CalibreFunctions.register(on: database)
    }

    /// Creates an empty library at `root` and opens it.
    ///
    /// The schema is calibre's own (`CalibreSchema`), applied through `execute` because that is
    /// the only multi-statement path — `prepare` would silently drop everything after the first
    /// statement. The functions are registered before the script so `uuid4()` is available for
    /// the library identity row calibre expects to find.
    @discardableResult
    public static func create(at root: URL) throws -> CalibreLibraryStore {
        guard !isLibrary(at: root) else { throw CalibreError.libraryExists(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let databaseURL = databaseURL(in: root)
        do {
            let database = try SQLiteDatabase(path: databaseURL.path(percentEncoded: false), readOnly: false)
            CalibreFunctions.register(on: database)
            try database.execute(CalibreSchema.sql)
            try database.run("INSERT INTO library_id (uuid) VALUES (uuid4())")
        } catch {
            // Half-written file would otherwise pass the isLibrary check for ever after.
            try? FileManager.default.removeItem(at: databaseURL)
            throw error
        }
        return try CalibreLibraryStore(root: root)
    }

    // MARK: - Reading

    public func books() throws -> [Book] {
        let authors = try relatedStrings(
            "SELECT bal.book, a.name FROM books_authors_link bal JOIN authors a ON a.id = bal.author ORDER BY bal.id"
        )
        let tags = try relatedStrings(
            "SELECT btl.book, t.name FROM books_tags_link btl JOIN tags t ON t.id = btl.tag ORDER BY t.name"
        )
        let publishers = try relatedStrings(
            "SELECT bpl.book, p.name FROM books_publishers_link bpl JOIN publishers p ON p.id = bpl.publisher"
        )
        let series = try relatedStrings(
            "SELECT bsl.book, s.name FROM books_series_link bsl JOIN series s ON s.id = bsl.series"
        )

        var comments: [Int64: String] = [:]
        for row in try database.query("SELECT book, text FROM comments", [], { ($0.int(0), $0.string(1)) }) {
            comments[row.0] = row.1
        }

        var identifiers: [Int64: [String: String]] = [:]
        for row in try database.query("SELECT book, type, val FROM identifiers", [], { ($0.int(0), $0.string(1), $0.string(2)) }) {
            guard let type = row.1, let value = row.2 else { continue }
            identifiers[row.0, default: [:]][type] = value
        }

        var formats: [Int64: [BookFormat]] = [:]
        for row in try database.query(
            "SELECT book, format, name, uncompressed_size FROM data",
            [],
            { ($0.int(0), $0.string(1), $0.string(2), $0.int(3)) }
        ) {
            guard let format = row.1, let name = row.2 else { continue }
            formats[row.0, default: []].append(BookFormat(format: format, name: name, size: row.3))
        }

        return try database.query(
            """
            SELECT id, uuid, title, sort, author_sort, series_index, pubdate, timestamp,
                   last_modified, has_cover, path
            FROM books ORDER BY sort COLLATE NOCASE
            """
        ) { row in
            let id = row.int(0)
            return Book(
                id: id,
                uuid: row.string(1) ?? "",
                title: row.string(2) ?? "",
                sort: row.string(3) ?? "",
                authors: authors[id] ?? [],
                authorSort: row.string(4) ?? "",
                series: series[id]?.first,
                seriesIndex: row.double(5),
                tags: tags[id] ?? [],
                publisher: publishers[id]?.first,
                pubdate: CalibreDate.parse(row.string(6)),
                timestamp: CalibreDate.parse(row.string(7)) ?? Date(),
                lastModified: CalibreDate.parse(row.string(8)) ?? Date(),
                comments: comments[id],
                identifiers: identifiers[id] ?? [:],
                hasCover: row.bool(9),
                path: row.string(10) ?? "",
                formats: formats[id] ?? []
            )
        }
    }

    private func relatedStrings(_ sql: String) throws -> [Int64: [String]] {
        var result: [Int64: [String]] = [:]
        for row in try database.query(sql, [], { ($0.int(0), $0.string(1)) }) {
            guard let value = row.1 else { continue }
            result[row.0, default: []].append(value)
        }
        return result
    }

    // MARK: - Writing

    /// Copies metadata.db aside before the first write of a session.
    public func backup(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = directory.appending(path: "metadata-\(stamp).db")
        try FileManager.default.copyItem(at: root.appending(path: "metadata.db"), to: destination)
        return destination
    }

    /// Writes the editable metadata fields back to calibre's tables.
    public func update(_ book: Book) throws {
        guard !isReadOnly else { throw CalibreError.readOnly }

        try database.transaction {
            try database.run(
                """
                UPDATE books SET title = ?, author_sort = ?, series_index = ?, pubdate = ?,
                                 last_modified = ?, has_cover = ?
                WHERE id = ?
                """,
                [
                    .text(book.title),
                    // author_sort always follows the author list, the way calibre's editor does it.
                    .text(CalibreFunctions.authorSort(of: book.authors)),
                    .real(book.seriesIndex),
                    .text(book.pubdate.map(CalibreDate.format)),
                    .text(CalibreDate.format(Date())),
                    .integer(book.hasCover ? 1 : 0),
                    .integer(book.id),
                ]
            )

            try relink(
                book: book.id, values: book.authors,
                table: "authors", link: "books_authors_link", column: "author",
                sortColumn: "sort", sort: CalibreFunctions.authorSort
            )
            try relink(
                book: book.id, values: book.tags,
                table: "tags", link: "books_tags_link", column: "tag"
            )
            try relink(
                book: book.id, values: book.publisher.map { [$0] } ?? [],
                table: "publishers", link: "books_publishers_link", column: "publisher",
                sortColumn: "sort", sort: CalibreFunctions.titleSort
            )
            // series rows carry a title_sort() trigger; the function is registered above.
            try relink(
                book: book.id, values: book.series.map { [$0] } ?? [],
                table: "series", link: "books_series_link", column: "series"
            )

            try database.run("DELETE FROM comments WHERE book = ?", [.integer(book.id)])
            if let comments = book.comments, !comments.isEmpty {
                try database.run(
                    "INSERT INTO comments (book, text) VALUES (?, ?)",
                    [.integer(book.id), .text(comments)]
                )
            }

            try database.run("DELETE FROM identifiers WHERE book = ?", [.integer(book.id)])
            for (type, value) in book.identifiers.sorted(by: { $0.key < $1.key }) {
                try database.run(
                    "INSERT INTO identifiers (book, type, val) VALUES (?, ?, ?)",
                    [.integer(book.id), .text(type), .text(value)]
                )
            }
        }

        // Keep the on-disk metadata.opf in step with the database.
        if let stored = try books().first(where: { $0.id == book.id }) {
            try? writeOPF(for: stored)
        }
    }

    /// Replaces a book's links to a many-to-many table, creating missing rows.
    private func relink(
        book: Int64,
        values: [String],
        table: String,
        link: String,
        column: String,
        sortColumn: String? = nil,
        sort: ((String) -> String)? = nil
    ) throws {
        try database.run("DELETE FROM \(link) WHERE book = ?", [.integer(book)])
        for value in values where !value.isEmpty {
            let existing = try database.query(
                "SELECT id FROM \(table) WHERE name = ? COLLATE NOCASE", [.text(value)]
            ) { $0.int(0) }.first

            let id: Int64
            if let existing {
                id = existing
            } else if let sortColumn, let sort {
                id = try database.run(
                    "INSERT INTO \(table) (name, \(sortColumn)) VALUES (?, ?)",
                    [.text(value), .text(sort(value))]
                )
            } else {
                id = try database.run("INSERT INTO \(table) (name) VALUES (?)", [.text(value)])
            }

            try database.run(
                "INSERT INTO \(link) (book, \(column)) VALUES (?, ?)",
                [.integer(book), .integer(id)]
            )
        }
    }
}

public enum CalibreError: Error, LocalizedError {
    case libraryNotFound(URL)
    case libraryExists(URL)
    case readOnly
    case fileNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .libraryNotFound(let url):
            return "No library at \(url.path(percentEncoded: false))"
        case .libraryExists(let url):
            return "There is already a library at \(url.path(percentEncoded: false))"
        case .readOnly:
            return "The library is open read-only"
        case .fileNotFound(let url):
            return "File not found: \(url.path(percentEncoded: false))"
        }
    }
}

enum CalibreDate {
    /// calibre stores timestamps as "2025-12-04 03:13:34.651205+00:00".
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: normalized) { return date }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX"
        return fallback.date(from: raw)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date).replacingOccurrences(of: "T", with: " ")
    }
}
