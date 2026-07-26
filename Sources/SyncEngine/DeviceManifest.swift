import Foundation

/// What Octavo believes is on the device, keyed by calibre book uuid.
/// Stored on the device itself at `documents/.octavo.json`, so the mapping survives
/// renames in the library and a reinstall of the app.
public struct DeviceManifest: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var filename: String
        /// Size of the file as it sits on the device. calibre rewrites metadata during
        /// transfer, so this is not always the size of the library file.
        public var deviceSize: Int64
        /// Size of the library file we uploaded. Absent for entries adopted from calibre.
        public var sourceSize: Int64?
        /// `books.last_modified` at the time the book was sent.
        public var sourceModified: Date?
        public var format: String
        public var sentAt: Date

        public init(
            filename: String,
            deviceSize: Int64,
            sourceSize: Int64? = nil,
            sourceModified: Date? = nil,
            format: String,
            sentAt: Date
        ) {
            self.filename = filename
            self.deviceSize = deviceSize
            self.sourceSize = sourceSize
            self.sourceModified = sourceModified
            self.format = format
            self.sentAt = sentAt
        }
    }

    public static let filename = ".octavo.json"

    public var entries: [String: Entry]
    public var adoptedFromCalibre: Bool

    public init(entries: [String: Entry] = [:], adoptedFromCalibre: Bool = false) {
        self.entries = entries
        self.adoptedFromCalibre = adoptedFromCalibre
    }

    public static func decode(_ bytes: [UInt8]) throws -> DeviceManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeviceManifest.self, from: Data(bytes))
    }

    public func encoded() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return Array(try encoder.encode(self))
    }

    /// calibre leaves its own manifest in the storage root. Reusing it means a first sync
    /// after dropping calibre doesn't re-upload books that are already on the device.
    public static func adoptingCalibreManifest(_ bytes: [UInt8]) -> DeviceManifest {
        struct CalibreEntry: Decodable {
            let uuid: String?
            let lpath: String?
            let size: Int64?
            let last_modified: String?
        }

        guard let records = try? JSONDecoder().decode([CalibreEntry].self, from: Data(bytes)) else {
            return DeviceManifest()
        }

        var entries: [String: Entry] = [:]
        for record in records {
            guard let uuid = record.uuid, !uuid.isEmpty,
                  let lpath = record.lpath,
                  lpath.hasPrefix("documents/")
            else { continue }
            let filename = String(lpath.dropFirst("documents/".count))
            guard !filename.contains("/") else { continue }  // book files live flat in documents/
            entries[uuid] = Entry(
                filename: filename,
                deviceSize: record.size ?? 0,
                sourceModified: record.last_modified.flatMap(parseCalibreDate),
                format: (filename as NSString).pathExtension.uppercased(),
                sentAt: Date.distantPast
            )
        }
        return DeviceManifest(entries: entries, adoptedFromCalibre: true)
    }

    /// calibre writes "2025-12-04T18:11:43.847151+00:00" — the same value as
    /// `books.last_modified` in metadata.db.
    static func parseCalibreDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }()
    }
}
