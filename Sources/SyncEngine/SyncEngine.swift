import CalibreLibrary
import Foundation
import KindleFormat
import MTPKit

/// Formats the stock Kindle firmware can open from a sideloaded file, best first.
public let kindleReadableFormats = ["KFX", "AZW3", "AZW", "MOBI", "PRC", "PDF", "TXT"]

/// Formats Octavo can turn into a MOBI the Kindle opens, best first.
public let convertibleFormats = ["EPUB", "FB2", "CBZ"]

public struct SendItem: Sendable {
    public let book: Book
    /// The library format being sent — the source format when `needsConversion` is set.
    public let format: BookFormat
    public let filename: String
    public let reason: Reason
    /// The Kindle cannot read `format`; it is converted to MOBI before sending.
    public var needsConversion = false

    public enum Reason: String, Sendable {
        case new = "new"
        case changed = "changed"
        case missingOnDevice = "gone from device"
    }
}

public struct SyncPlan: Sendable {
    public var send: [SendItem] = []
    public var upToDate: [Book] = []
    /// Books whose only formats the Kindle cannot open (EPUB, CBZ, FB2…).
    public var unsupported: [Book] = []
    /// Files in documents/ that no library book claims.
    public var orphans: [MTPObject] = []

    public var totalBytes: Int64 { send.reduce(0) { $0 + $1.format.size } }
    public var isEmpty: Bool { send.isEmpty }
}

public enum SyncError: Error, LocalizedError {
    case noStorage
    case noDocumentsFolder
    case fileMissing(URL)
    case unsafeTarget(String)

    public var errorDescription: String? {
        switch self {
        case .noStorage: return "The device has no available storage"
        case .noDocumentsFolder: return "The device has no documents/ folder"
        case .fileMissing(let url): return "Book file not found: \(url.path(percentEncoded: false))"
        case .unsafeTarget(let name): return "Write refused: \(name)"
        }
    }
}

public final class SyncEngine {
    public let library: CalibreLibraryStore
    public let session: MTPSession
    public let storage: MTPStorage
    /// Every write goes under this handle. The storage root — where firmware update
    /// files live — is never a write target.
    public let documentsHandle: UInt32
    public var conversionCache = ConversionCache.default

    /// Where `octavo-sync --apply` and the app's "back up before first sync" setting both pull
    /// documents/ to, by default — one constant so the two agree without either hardcoding it.
    public static let defaultBackupDirectory = URL.homeDirectory
        .appending(path: "Library/Application Support/Octavo/device-backup")

    public init(library: CalibreLibraryStore, session: MTPSession) throws {
        self.library = library
        self.session = session

        guard let storage = try session.storages().first else { throw SyncError.noStorage }
        self.storage = storage
        guard let documents = try session.object(at: "documents", storageID: storage.id) else {
            throw SyncError.noDocumentsFolder
        }
        self.documentsHandle = documents.id
    }

    // MARK: - Manifest

    /// Reads our manifest, falling back to calibre's on the first run.
    public func loadManifest() throws -> DeviceManifest {
        if let object = try documentsChildren().first(where: { $0.filename == DeviceManifest.filename }),
           let manifest = try? DeviceManifest.decode(session.data(of: object.id)) {
            return manifest
        }
        if let calibre = try session.object(at: "metadata.calibre", storageID: storage.id),
           let bytes = try? session.data(of: calibre.id) {
            return DeviceManifest.adoptingCalibreManifest(bytes)
        }
        return DeviceManifest()
    }

    public func saveManifest(_ manifest: DeviceManifest) throws {
        var updated = manifest
        updated.adoptedFromCalibre = false
        let bytes = try updated.encoded()

        if let existing = try documentsChildren().first(where: { $0.filename == DeviceManifest.filename }) {
            try session.delete(handle: existing.id)
        }
        try session.sendFile(
            bytes,
            named: DeviceManifest.filename,
            storageID: storage.id,
            parent: documentsHandle
        )
    }

    public func documentsChildren() throws -> [MTPObject] {
        try session.children(storageID: storage.id, parent: documentsHandle)
    }

    // MARK: - Planning

    public func plan(books: [Book], manifest: DeviceManifest) throws -> SyncPlan {
        let onDevice = try documentsChildren().filter { !$0.isFolder }
        // calibre's manifest lowercases lpath, the filesystem does not.
        var byName: [String: MTPObject] = [:]
        for object in onDevice { byName[object.filename.lowercased()] = object }

        var plan = SyncPlan()
        var claimed = Set<UInt32>()

        for book in books {
            let readable = bestFormat(for: book)
            let convertible = readable == nil ? convertibleFormat(for: book) : nil
            guard let format = readable ?? convertible else {
                if !book.formats.isEmpty { plan.unsupported.append(book) }
                continue
            }
            let converts = readable == nil

            let entry = manifest.entries[book.uuid]
            let existing = entry.flatMap { byName[$0.filename.lowercased()] }
            if let existing { claimed.insert(existing.id) }

            let filename = entry?.filename
                ?? targetFilename(for: book, format: format, converted: converts)

            guard let entry, let existing else {
                plan.send.append(SendItem(
                    book: book, format: format, filename: filename,
                    reason: entry == nil ? .new : .missingOnDevice,
                    needsConversion: converts
                ))
                continue
            }

            if Self.isStale(entry: entry, deviceObject: existing, book: book, format: format) {
                plan.send.append(SendItem(
                    book: book, format: format, filename: filename,
                    reason: .changed, needsConversion: converts
                ))
            } else {
                plan.upToDate.append(book)
            }
        }

        plan.orphans = onDevice.filter {
            !claimed.contains($0.id) && $0.filename != DeviceManifest.filename
        }
        return plan
    }

    /// A device copy is stale when the file on the device is not the one we recorded,
    /// when the library file changed size, or when the book's metadata was edited after
    /// the copy was sent. Byte size alone is not enough: calibre rewrites EXTH metadata
    /// during transfer, so its copies differ from the library file by a few bytes.
    static func isStale(entry: DeviceManifest.Entry, deviceObject: MTPObject, book: Book, format: BookFormat) -> Bool {
        if entry.deviceSize > 0, entry.deviceSize != Int64(deviceObject.size) { return true }
        if let sourceSize = entry.sourceSize, sourceSize != format.size { return true }
        if let sourceModified = entry.sourceModified, book.lastModified > sourceModified.addingTimeInterval(1) {
            return true
        }
        return false
    }

    public func bestFormat(for book: Book) -> BookFormat? {
        for name in kindleReadableFormats {
            if let format = book.format(name) { return format }
        }
        return nil
    }

    /// The best source to convert when nothing on the book is directly readable.
    public func convertibleFormat(for book: Book) -> BookFormat? {
        for name in convertibleFormats {
            if let format = book.format(name) { return format }
        }
        return nil
    }

    /// calibre's naming, kept so the 31 books already on the device stay matched:
    /// "Title - Author.ext", ASCII-transliterated.
    public func targetFilename(for book: Book, format: BookFormat, converted: Bool = false) -> String {
        let title = Self.asciiSanitized(book.title)
        let author = Self.asciiSanitized(book.authorDisplay)
        let stem = "\(title) - \(author)".prefix(180)
        return "\(stem).\(converted ? "mobi" : format.format.lowercased())"
    }

    /// Kept as a thin alias so the sync engine and the library agree on naming.
    static func asciiSanitized(_ text: String) -> String {
        CalibreFunctions.filenameSafe(text)
    }

    // MARK: - Execution

    public struct Progress: Sendable {
        public let item: SendItem
        public let index: Int
        public let total: Int
    }

    /// Uploads everything in the plan. Only files inside documents/ are ever written.
    ///
    /// `shouldStop` is polled between files; returning true ends the run early and still
    /// saves the manifest, so everything already sent stays recorded. It is declared *after*
    /// `onProgress` because a trailing closure binds by forward scan — put it first and
    /// `octavo-sync`'s `execute(plan, manifest:) { progress in … }` would silently try to
    /// bind its progress closure to `shouldStop`.
    @discardableResult
    public func execute(
        _ plan: SyncPlan,
        manifest: DeviceManifest,
        onProgress: ((Progress) -> Void)? = nil,
        shouldStop: (() -> Bool)? = nil
    ) throws -> DeviceManifest {
        var updated = manifest

        for (index, item) in plan.send.enumerated() {
            if shouldStop?() == true { break }
            guard !item.filename.lowercased().hasSuffix(".bin") else {
                throw SyncError.unsafeTarget("\(item.filename) — .bin looks like a firmware update")
            }
            onProgress?(Progress(item: item, index: index, total: plan.send.count))

            // EPUB, FB2 and CBZ become a MOBI first; the result is cached on disk.
            let source = item.needsConversion
                ? try conversionCache.mobi(for: item.book, format: item.format, in: library.root)
                : item.book.url(of: item.format, in: library.root)
            guard let data = FileManager.default.contents(atPath: source.path(percentEncoded: false)) else {
                throw SyncError.fileMissing(source)
            }

            // Conversion is the slow non-USB step; checking again here means cancelling
            // during it does not still cost a full upload.
            if shouldStop?() == true { break }

            // Replacing a book means removing the old file first; .sdr sidecars with
            // reading progress and annotations are left untouched.
            if let existing = try documentsChildren().first(where: {
                $0.filename.caseInsensitiveCompare(item.filename) == .orderedSame
            }) {
                try session.delete(handle: existing.id)
            }

            try session.sendFile(
                Array(data),
                named: item.filename,
                storageID: storage.id,
                parent: documentsHandle,
                modified: item.book.lastModified
            )

            updated.entries[item.book.uuid] = DeviceManifest.Entry(
                filename: item.filename,
                deviceSize: Int64(data.count),
                sourceSize: item.format.size,
                sourceModified: item.book.lastModified,
                format: item.format.format,
                sentAt: Date()
            )
        }

        // Reached after a `break` too, so a cancelled run keeps what it managed to send.
        // When the cancel was caused by the cable being pulled this write itself fails —
        // harmless, because the next plan() re-reads the device and at worst re-sends a
        // handful of files, which is idempotent.
        try saveManifest(updated)
        return updated
    }

    /// Drops cached conversions no current book would produce — a book removed from the
    /// library, or one re-converted after its source file changed leaves its old cache entry
    /// behind otherwise, since `ConversionCache`'s key folds in size and modification date.
    public func pruneConversionCache(books: [Book]) {
        var wanted: Set<String> = []
        for book in books {
            guard bestFormat(for: book) == nil, let format = convertibleFormat(for: book) else { continue }
            wanted.insert(conversionCache.cachedURL(for: book, format: format).lastPathComponent)
        }
        conversionCache.prune(keeping: wanted)
    }

    /// Pulls every file in documents/ to disk. Run before the first write.
    public func backupDocuments(to directory: URL, onFile: ((String, Int, Int) -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try documentsChildren().filter { !$0.isFolder }
        for (index, file) in files.enumerated() {
            onFile?(file.filename, index, files.count)
            let destination = directory.appending(path: file.filename)
            guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else { continue }
            let bytes = try session.data(of: file.id)
            try Data(bytes).write(to: destination)
        }
    }
}
