import Foundation
import Testing
@testable import KindleFormat

/// Runs against the real calibre library when it is present: 28 EPUB, 30 AZW3, 13 CBZ,
/// one FB2 and one PDF are a better corpus than any fixture we could invent.
let corpusLibrary = URL.homeDirectory.appending(path: "Calibre Library")

func corpusFiles(withExtension ext: String) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: corpusLibrary, includingPropertiesForKeys: nil)
    else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == ext }
}

/// A reader for the structures `KF8Writer` emits — deliberately independent of the writer, and
/// **proved against calibre's own AZW3 files first** (see `KF8CorpusTests`). A validator that
/// agrees only with the code it is validating proves nothing; one that parses 30 files calibre
/// made is worth trusting on the 31st that we made.
///
/// It lives in the test target on purpose. Nothing the app ships needs to read a KF8 file.
struct KF8File {
    enum Failure: Error, CustomStringConvertible {
        case notAPalmDatabase
        case noMOBIHeader
        case missingRecord(Int)
        case badMagic(String, expected: String)

        var description: String {
            switch self {
            case .notAPalmDatabase: "not a PalmDB"
            case .noMOBIHeader: "no MOBI header in record 0"
            case .missingRecord(let index): "record \(index) is missing"
            case .badMagic(let found, let expected): "expected \(expected), found \(found)"
            }
        }
    }

    let data: Data
    /// One entry per record plus a final end-of-file offset, so `record(i)` is a plain slice.
    let bounds: [Int]
    /// The MOBI header, indexed from the "MOBI" magic the way `MOBIHeader` counts.
    let header: Data

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        guard data.count > 78 else { throw Failure.notAPalmDatabase }
        let count = Int(data.loadBE16(76))
        guard count > 0, data.count >= 78 + count * 8 else { throw Failure.notAPalmDatabase }

        var bounds = (0..<count).map { Int(data.loadBE32(78 + $0 * 8)) }
        bounds.append(data.count)
        guard bounds.allSatisfy({ $0 <= data.count }) else { throw Failure.notAPalmDatabase }
        self.bounds = bounds

        let record0 = data.subdata(in: bounds[0]..<bounds[1])
        guard record0.count > 16 + 4,
              String(decoding: record0[16..<20], as: UTF8.self) == "MOBI"
        else { throw Failure.noMOBIHeader }
        header = record0.subdata(in: 16..<record0.count)
    }

    // MARK: - Records

    var recordCount: Int { bounds.count - 1 }

    func record(_ index: Int) throws -> Data {
        guard index >= 0, index < recordCount else { throw Failure.missingRecord(index) }
        return data.subdata(in: bounds[index]..<bounds[index + 1])
    }

    // MARK: - Header fields

    private func field(_ offset: Int) -> UInt32 {
        offset + 4 <= header.count ? header.loadBE32(offset) : 0xFFFF_FFFF
    }

    var headerLength: Int { Int(field(MOBIHeader.headerLength)) }
    var fileVersion: UInt32 { field(MOBIHeader.fileVersion) }
    var codepage: UInt32 { field(MOBIHeader.codepage) }
    var firstNonBookIndex: Int { Int(field(MOBIHeader.firstNonBookIndex)) }
    var firstResourceIndex: Int { Int(field(MOBIHeader.firstImageIndex)) }
    var fdstIndex: Int { Int(field(MOBIHeader.fdstIndex)) }
    var fdstCount: Int { Int(field(MOBIHeader.fdstCount)) }
    var ncxIndex: Int { Int(field(MOBIHeader.ncxIndex)) }
    var chunkIndex: Int { Int(field(MOBIHeader.chunkIndex)) }
    var skeletonIndex: Int { Int(field(MOBIHeader.skeletonIndex)) }
    var guideIndex: Int { Int(field(MOBIHeader.guideIndex)) }

    /// Lives in the low half of the word at 0xE0, and says how many trailing bytes each text
    /// record carries past its content.
    var extraDataFlags: UInt16 { header.count > 0xE4 ? header.loadBE16(0xE2) : 0 }

    var title: String {
        let offset = Int(field(MOBIHeader.fullNameOffset)) - 16
        let length = Int(field(MOBIHeader.fullNameLength))
        guard offset >= 0, length > 0, offset + length <= header.count else { return "" }
        return String(decoding: header[offset..<(offset + length)], as: UTF8.self)
    }

    // PalmDOC header, which sits in front of the MOBI header.
    private var palmDoc: Data { data.subdata(in: bounds[0]..<(bounds[0] + 16)) }
    var compression: UInt16 { palmDoc.loadBE16(0) }
    var uncompressedTextLength: Int { Int(palmDoc.loadBE32(4)) }
    var textRecordCount: Int { Int(palmDoc.loadBE16(8)) }
    var textRecordSize: Int { Int(palmDoc.loadBE16(10)) }

    // MARK: - Text

    /// Records 1…n, trailing bytes stripped and decompressed: the whole flow area end to end.
    func rawText() throws -> Data {
        try textRecordContents().reduce(into: Data()) { $0.append($1) }
    }

    /// Each text record's content on its own — what `rawText` concatenates. Sizes matter:
    /// the reader finds a byte at flow offset N in record N / recordSize, so anything but
    /// exactly `textRecordSize` per record breaks every index in the file.
    func textRecordContents() throws -> [Data] {
        guard textRecordCount > 0 else { return [] }
        return try (1...textRecordCount).map { index in
            let payload = Self.stripTrailing(try record(index), flags: extraDataFlags)
            return compression == 2 ? PalmDoc.decompress(payload) : payload
        }
    }

    /// The multibyte-overlap block a record carries past its content: the bytes of a character
    /// straddling the end, copied from the record that follows.
    func overlapTrailer(of index: Int) throws -> Data {
        guard extraDataFlags & 1 == 1 else { return Data() }
        var payload = try record(index)
        var remaining = extraDataFlags >> 1
        while remaining != 0 {
            if remaining & 1 == 1 { payload = payload.dropLast(Self.backwardVarint(payload)) }
            remaining >>= 1
        }
        guard let last = payload.last else { return Data() }
        return payload.dropLast().suffix(Int(last & 0x03))
    }

    /// Trailing entries are counted by the high bits of the flags and are sized by a varint
    /// read *backwards* from the end; the multibyte-overlap byte the low bit selects comes last.
    static func stripTrailing(_ record: Data, flags: UInt16) -> Data {
        var result = record
        var remaining = flags >> 1
        while remaining != 0 {
            if remaining & 1 == 1 {
                let size = backwardVarint(result)
                guard size > 0, size <= result.count else { break }
                result = result.dropLast(size)
            }
            remaining >>= 1
        }
        if flags & 1 == 1, let last = result.last {
            result = result.dropLast(Int(last & 0x03) + 1)
        }
        return result
    }

    /// Reads the size of a trailing entry from the end of a record. The value counts the varint
    /// bytes themselves, which is what makes it self-delimiting.
    static func backwardVarint(_ record: Data) -> Int {
        var value = 0
        var shift = 0
        var index = record.count - 1
        while index >= 0, shift < 28 {
            let byte = record[record.startIndex + index]
            value |= Int(byte & 0x7F) << shift
            shift += 7
            index -= 1
            if byte & 0x80 != 0 { break }
        }
        return value
    }

    // MARK: - FDST

    /// Flow boundaries: flow 0 is the markup, 1…n are the stylesheets.
    func flowRanges() throws -> [Range<Int>] {
        let fdst = try record(fdstIndex)
        let magic = String(decoding: fdst.prefix(4), as: UTF8.self)
        guard magic == "FDST" else { throw Failure.badMagic(magic, expected: "FDST") }
        let count = Int(fdst.loadBE32(8))
        return (0..<count).map {
            Int(fdst.loadBE32(12 + $0 * 8))..<Int(fdst.loadBE32(16 + $0 * 8))
        }
    }

    func flows() throws -> [Data] {
        let text = try rawText()
        return try flowRanges().map { range in
            let clamped = min(range.lowerBound, text.count)..<min(range.upperBound, text.count)
            return text.subdata(in: clamped)
        }
    }

    // MARK: - Indices

    struct IndexTable {
        struct Entry {
            var name: String
            /// Tag number → its values, in the order the TAGX block declares them.
            var tags: [UInt8: [Int]]
        }

        var entries: [Entry]
        /// Strings the entries address by byte offset into the CNCX records.
        var strings: [Int: String]
        var tagx: [(tag: UInt8, valuesPerEntry: UInt8, mask: UInt8, end: UInt8)]
    }

    /// Reads an INDX set: a header record, one or more data records, then the CNCX records.
    func index(at position: Int) throws -> IndexTable {
        let head = try record(position)
        let magic = String(decoding: head.prefix(4), as: UTF8.self)
        guard magic == "INDX" else { throw Failure.badMagic(magic, expected: "INDX") }

        let headerLength = Int(head.loadBE32(0x04))
        let dataRecordCount = Int(head.loadBE32(0x18))

        // TAGX follows the fixed header.
        var tagx: [(tag: UInt8, valuesPerEntry: UInt8, mask: UInt8, end: UInt8)] = []
        var controlByteCount = 1
        if headerLength + 12 <= head.count,
           String(decoding: head[headerLength..<(headerLength + 4)], as: UTF8.self) == "TAGX" {
            let tagxLength = Int(head.loadBE32(headerLength + 4))
            controlByteCount = Int(head.loadBE32(headerLength + 8))
            var cursor = headerLength + 12
            while cursor + 4 <= headerLength + tagxLength {
                tagx.append((head[cursor], head[cursor + 1], head[cursor + 2], head[cursor + 3]))
                cursor += 4
            }
        }

        // CNCX records sit after the data records; entries address them by byte offset, with
        // the record number packed into the high bits.
        var strings: [Int: String] = [:]
        var cncxBase = 0
        var cncxRecord = position + 1 + dataRecordCount
        while cncxRecord < recordCount, let block = try? record(cncxRecord) {
            guard String(decoding: block.prefix(4), as: UTF8.self) != "INDX",
                  !["FLIS", "FCIS", "FDST"].contains(String(decoding: block.prefix(4), as: UTF8.self))
            else { break }
            var cursor = 0
            while cursor < block.count {
                let start = cursor
                guard let length = Self.forwardVarint(block, at: &cursor), length > 0,
                      cursor + length <= block.count else { break }
                strings[cncxBase + start] = String(
                    decoding: block[block.startIndex + cursor..<block.startIndex + cursor + length],
                    as: UTF8.self
                )
                cursor += length
            }
            cncxBase += block.count
            cncxRecord += 1
            break  // one CNCX record is all any index we write or read needs
        }

        var entries: [IndexTable.Entry] = []
        for offset in 0..<dataRecordCount {
            let block = try record(position + 1 + offset)
            entries.append(contentsOf: Self.entries(in: block, tagx: tagx, controlBytes: controlByteCount))
        }

        return IndexTable(entries: entries, strings: strings, tagx: tagx)
    }

    private static func entries(
        in block: Data,
        tagx: [(tag: UInt8, valuesPerEntry: UInt8, mask: UInt8, end: UInt8)],
        controlBytes: Int
    ) -> [IndexTable.Entry] {
        let idxtOffset = Int(block.loadBE32(0x14))
        let count = Int(block.loadBE32(0x18))
        guard idxtOffset + 4 + count * 2 <= block.count else { return [] }

        var result: [IndexTable.Entry] = []
        for index in 0..<count {
            var cursor = Int(block.loadBE16(idxtOffset + 4 + index * 2))
            guard cursor < block.count else { continue }
            let nameLength = Int(block[block.startIndex + cursor])
            cursor += 1
            guard cursor + nameLength <= block.count else { continue }
            let name = String(
                decoding: block[block.startIndex + cursor..<block.startIndex + cursor + nameLength],
                as: UTF8.self
            )
            cursor += nameLength

            let control = Array(block[block.startIndex + cursor..<min(block.endIndex, block.startIndex + cursor + controlBytes)])
            cursor += controlBytes

            var tags: [UInt8: [Int]] = [:]
            var controlIndex = 0
            for definition in tagx {
                if definition.end & 0x01 == 1 { controlIndex += 1; continue }
                guard controlIndex < control.count else { break }
                var mask = definition.mask
                var value = Int(control[controlIndex] & mask)
                guard value != 0 else { continue }

                var repeats: Int
                if value == Int(mask) {
                    // A saturated field means the repeat count itself is a varint in the stream,
                    // unless the mask is a single bit, in which case it just means "one".
                    repeats = mask.nonzeroBitCount > 1 ? (Self.forwardVarint(block, at: &cursor) ?? 0) : 1
                } else {
                    while mask & 0x01 == 0 { mask >>= 1; value >>= 1 }
                    repeats = value
                }

                var values: [Int] = []
                for _ in 0..<(repeats * Int(definition.valuesPerEntry)) {
                    guard let next = Self.forwardVarint(block, at: &cursor) else { break }
                    values.append(next)
                }
                tags[definition.tag] = values
            }
            result.append(IndexTable.Entry(name: name, tags: tags))
        }
        return result
    }

    /// Seven bits a byte, high bit set on the *last* byte.
    static func forwardVarint(_ data: Data, at cursor: inout Int) -> Int? {
        var value = 0
        while cursor < data.count {
            let byte = data[data.startIndex + cursor]
            cursor += 1
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 != 0 { return value }
        }
        return nil
    }
}
