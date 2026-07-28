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

    /// `source` is the library format being converted *from*, `target` the Kindle format being
    /// converted *to*. Only the extension carries the target, so switching it leaves the entries
    /// for the other one valid rather than orphaning the whole cache.
    public func cachedURL(for book: Book, source: BookFormat, target: ConversionTarget) -> URL {
        let stamp = Int(book.lastModified.timeIntervalSince1970)
        let key = "\(book.uuid)-\(source.format.lowercased())-\(source.size)-\(stamp)"
        return directory.appending(path: "\(key).\(target.fileExtension)")
    }

    /// Converts if needed and returns the converted file on disk.
    public func converted(
        for book: Book,
        source: BookFormat,
        target: ConversionTarget,
        in library: URL
    ) throws -> URL {
        let destination = cachedURL(for: book, source: source, target: target)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            return destination
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Converter.convert(book.url(of: source, in: library), to: destination, target: target)
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
