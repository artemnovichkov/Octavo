import CalibreLibrary
import Foundation
import KindleFormat

/// Converted books are kept on disk so a second sync does not redo the work. The key
/// includes the source size and modification date, so editing the book in the library
/// invalidates the cached copy by itself.
public struct ConversionCache: Sendable {
    public let directory: URL

    public static let `default` = ConversionCache(
        directory: URL.cachesDirectory.appending(path: "Octavo/converted")
    )

    public init(directory: URL) {
        self.directory = directory
    }

    public func cachedURL(for book: Book, format: BookFormat) -> URL {
        let stamp = Int(book.lastModified.timeIntervalSince1970)
        let key = "\(book.uuid)-\(format.format.lowercased())-\(format.size)-\(stamp)"
        return directory.appending(path: "\(key).mobi")
    }

    /// Converts if needed and returns the MOBI on disk.
    public func mobi(for book: Book, format: BookFormat, in library: URL) throws -> URL {
        let destination = cachedURL(for: book, format: format)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            return destination
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = book.url(of: format, in: library)
        return try Converter.convert(source, to: destination)
    }

    /// Drops cached files that no current book claims.
    public func prune(keeping wanted: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where !wanted.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
