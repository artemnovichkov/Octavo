import Compression
import Foundation

/// Minimal read-only ZIP reader — enough for EPUB and CBZ. Writing is not needed:
/// nothing in Octavo produces a zip.
public struct ZipArchive {
    public struct Entry: Sendable {
        public let path: String
        public let compressedSize: Int
        public let uncompressedSize: Int
        let method: UInt16
        let localHeaderOffset: Int
    }

    public enum ZipError: Error, LocalizedError {
        case notAZip
        case unsupportedCompression(UInt16)
        case zip64Unsupported
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .notAZip: return "The file is not a zip archive"
            case .unsupportedCompression(let method): return "Unsupported zip compression: method \(method)"
            case .zip64Unsupported: return "zip64 archives are not supported"
            case .corrupt(let detail): return "Corrupt zip: \(detail)"
            }
        }
    }

    public let entries: [Entry]
    private let data: Data

    public init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    public init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public func entry(at path: String) -> Entry? {
        entries.first { $0.path == path }
    }

    public func contents(of entry: Entry) throws -> Data {
        // The central directory's name/extra lengths may differ from the local header's,
        // so the payload offset has to come from the local header.
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.load32(header) == 0x0403_4B50 else {
            throw ZipError.corrupt("no local header for \(entry.path)")
        }
        let nameLength = Int(data.load16(header + 26))
        let extraLength = Int(data.load16(header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { throw ZipError.corrupt("truncated data for \(entry.path)") }

        let payload = data.subdata(in: start..<end)
        switch entry.method {
        case 0:
            return payload
        case 8:
            return try Self.inflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupportedCompression(entry.method)
        }
    }

    public func contents(of path: String) throws -> Data? {
        guard let entry = entry(at: path) else { return nil }
        return try contents(of: entry)
    }

    // MARK: - Parsing

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count > 22 else { throw ZipError.notAZip }

        // End of central directory lives in the last 64 KiB (comment can pad it).
        let searchStart = max(0, data.count - 65_557)
        var eocd = -1
        var index = data.count - 22
        while index >= searchStart {
            if data.load32(index) == 0x0605_4B50 {
                eocd = index
                break
            }
            index -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let count = Int(data.load16(eocd + 10))
        let directorySize = Int(data.load32(eocd + 12))
        let directoryOffset = Int(data.load32(eocd + 16))
        guard directoryOffset != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF else {
            throw ZipError.zip64Unsupported
        }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var cursor = directoryOffset

        for _ in 0..<count {
            guard cursor + 46 <= data.count, data.load32(cursor) == 0x0201_4B50 else {
                throw ZipError.corrupt("broken central directory")
            }
            let method = data.load16(cursor + 10)
            let compressedSize = Int(data.load32(cursor + 20))
            let uncompressedSize = Int(data.load32(cursor + 24))
            let nameLength = Int(data.load16(cursor + 28))
            let extraLength = Int(data.load16(cursor + 30))
            let commentLength = Int(data.load16(cursor + 32))
            let localOffset = Int(data.load32(cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw ZipError.corrupt("file name out of bounds") }
            let name = String(decoding: data.subdata(in: nameStart..<nameStart + nameLength), as: UTF8.self)

            entries.append(Entry(
                path: name,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                method: method,
                localHeaderOffset: localOffset
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// zip stores raw DEFLATE, which is what COMPRESSION_ZLIB means in Apple's API.
    static func inflate(_ payload: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)

        let written = output.withUnsafeMutableBytes { destination -> Int in
            payload.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase, expectedSize,
                    sourceBase, payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw ZipError.corrupt("decompression failed") }
        return output.prefix(written)
    }
}

extension Data {
    func load16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func load32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(self[startIndex + offset + i]) << (8 * UInt32(i)) }
        return value
    }

    /// MOBI and PalmDB are big-endian, unlike zip.
    func loadBE16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) << 8 | UInt16(self[startIndex + offset + 1])
    }

    func loadBE32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 { value = value << 8 | UInt32(self[startIndex + offset + i]) }
        return value
    }
}
