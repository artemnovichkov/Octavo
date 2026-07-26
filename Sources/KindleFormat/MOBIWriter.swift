import Foundation

/// Builds a MOBI 6 file — the format the stock Kindle firmware still indexes and opens
/// from a sideloaded file. MOBI 6 needs no INDX/TAGX index structures at all: one
/// flattened HTML stream plus image records is a complete book.
///
/// Layout and header values were taken from a reference file produced by calibre for
/// this library, not from memory.
public struct MOBIWriter {
    public struct Input {
        /// Flattened book markup, without the <html>/<body> wrapper.
        public var html: String
        /// Images in the order they are referenced; `recindex` is the 1-based position.
        public var images: [Data]
        public var metadata: EbookMetadata
        /// Index into `images`, if one of them is the cover.
        public var coverIndex: Int?

        public init(html: String, images: [Data], metadata: EbookMetadata, coverIndex: Int? = nil) {
            self.html = html
            self.images = images
            self.metadata = metadata
            self.coverIndex = coverIndex
        }
    }

    static let textRecordSize = 4096

    public static func write(_ input: Input) -> Data {
        let text = Data("<html><head></head><body>\(input.html)</body></html>".utf8)

        var textRecords: [Data] = []
        var offset = 0
        while offset < text.count {
            let end = min(offset + textRecordSize, text.count)
            textRecords.append(text.subdata(in: offset..<end))
            offset = end
        }
        if textRecords.isEmpty { textRecords.append(Data()) }

        // Record 0 is the header; text records follow, then images, then the trailing
        // bookkeeping records.
        let firstImageIndex = 1 + textRecords.count
        let firstNonBookIndex = firstImageIndex
        let flisIndex = firstImageIndex + input.images.count
        let fcisIndex = flisIndex + 1

        let header = makeRecord0(
            input: input,
            textLength: text.count,
            textRecordCount: textRecords.count,
            firstNonBookIndex: firstNonBookIndex,
            firstImageIndex: firstImageIndex,
            lastContentIndex: flisIndex - 1,
            flisIndex: flisIndex,
            fcisIndex: fcisIndex
        )

        var database = PalmDatabase(name: input.metadata.title)
        database.records = [header] + textRecords + input.images + [flisRecord(), fcisRecord(textLength: text.count), eofRecord()]
        return database.serialized()
    }

    // MARK: - Record 0

    private static func makeRecord0(
        input: Input,
        textLength: Int,
        textRecordCount: Int,
        firstNonBookIndex: Int,
        firstImageIndex: Int,
        lastContentIndex: Int,
        flisIndex: Int,
        fcisIndex: Int
    ) -> Data {
        let titleBytes = Array(input.metadata.title.utf8)
        let exth = makeEXTH(input: input, firstImageIndex: firstImageIndex)

        // full name sits right after EXTH inside record 0
        let mobiHeaderLength = 232
        let fullNameOffset = 16 + mobiHeaderLength + exth.count

        var record = Data()

        // PalmDOC header
        record.appendBE16(1)  // compression: 1 = none
        record.appendBE16(0)  // unused
        record.appendBE32(UInt32(textLength))
        record.appendBE16(UInt16(textRecordCount))
        record.appendBE16(UInt16(textRecordSize))
        record.appendBE16(0)  // encryption
        record.appendBE16(0)  // unused

        // The MOBI header is addressed by offset rather than written sequentially: a
        // field landing four bytes off makes the Kindle read garbage. The values mirror
        // a calibre-produced reference file for the same book.
        var mobi = [UInt8](repeating: 0, count: mobiHeaderLength)

        func put32(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { mobi[offset + i] = UInt8(value >> UInt32(8 * (3 - i)) & 0xFF) }
        }
        func put16(_ offset: Int, _ value: UInt16) {
            mobi[offset] = UInt8(value >> 8 & 0xFF)
            mobi[offset + 1] = UInt8(value & 0xFF)
        }

        for (index, byte) in Array("MOBI".utf8).enumerated() { mobi[index] = byte }
        put32(0x04, UInt32(mobiHeaderLength))
        put32(0x08, 2)  // book
        put32(0x0C, 65001)  // UTF-8
        put32(0x10, UInt32.random(in: 1...UInt32.max))  // unique id
        put32(0x14, 6)  // file version

        // 0x18…0x3C are index records we do not emit.
        for offset in stride(from: 0x18, through: 0x3C, by: 4) { put32(offset, 0xFFFF_FFFF) }

        put32(0x40, UInt32(firstNonBookIndex))
        put32(0x44, UInt32(fullNameOffset))
        put32(0x48, UInt32(titleBytes.count))
        put32(0x4C, locale(for: input.metadata.language))
        put32(0x58, 6)  // minimum reader version
        put32(0x5C, UInt32(firstImageIndex))
        put32(0x70, 0x50)  // EXTH present

        put32(0x94, 0xFFFF_FFFF)
        put32(0x98, 0xFFFF_FFFF)  // DRM offset: none. Writing 0 here makes the Kindle
        put32(0x9C, 0)            // treat the book as encrypted and refuse to open it.
        put32(0xA0, 0)  // DRM size
        put32(0xA4, 0)  // DRM flags

        put16(0xB0, 1)  // first content record
        put16(0xB2, UInt16(lastContentIndex))
        put32(0xB4, 1)
        put32(0xB8, UInt32(fcisIndex))
        put32(0xBC, 1)  // FCIS count
        put32(0xC0, UInt32(flisIndex))
        put32(0xC4, 1)  // FLIS count
        put32(0xD0, 0xFFFF_FFFF)
        put32(0xD8, 0xFFFF_FFFF)
        put32(0xDC, 0xFFFF_FFFF)
        put32(0xE0, 3)
        put32(0xE4, 0xFFFF_FFFF)  // no NCX index; 0 would point at the header record

        record.append(contentsOf: mobi)
        precondition(record.count == 16 + mobiHeaderLength, "MOBI header length mismatch")

        record.append(exth)
        record.append(contentsOf: titleBytes)
        record.append(contentsOf: [0, 0])  // terminator after the title
        record.pad(to: 4)
        return record
    }

    // MARK: - EXTH

    private static func makeEXTH(input: Input, firstImageIndex: Int) -> Data {
        var entries: [(UInt32, Data)] = []

        func add(_ type: UInt32, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            entries.append((type, Data(text.utf8)))
        }
        func addUInt(_ type: UInt32, _ value: UInt32) {
            var payload = Data()
            payload.appendBE32(value)
            entries.append((type, payload))
        }

        let metadata = input.metadata
        for author in metadata.authors { add(100, author) }
        add(101, metadata.publisher)
        add(103, metadata.comments)
        add(104, metadata.isbn)
        for tag in metadata.tags { add(105, tag) }
        if let published = metadata.published {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            add(106, formatter.string(from: published))
        }
        add(108, "Octavo")
        add(501, "EBOK")
        add(503, metadata.title)
        add(524, metadata.language)

        // 201/202 address the cover relative to the first image record.
        if let coverIndex = input.coverIndex {
            addUInt(201, UInt32(coverIndex))
            addUInt(202, UInt32(coverIndex))
        }

        var body = Data()
        for (type, payload) in entries {
            body.appendBE32(type)
            body.appendBE32(UInt32(payload.count + 8))
            body.append(payload)
        }

        var exth = Data()
        exth.append(contentsOf: Array("EXTH".utf8))
        exth.appendBE32(UInt32(12 + body.count))
        exth.appendBE32(UInt32(entries.count))
        exth.append(body)
        exth.pad(to: 4)
        return exth
    }

    private static func locale(for language: String?) -> UInt32 {
        switch language?.lowercased().prefix(2) {
        case "ru": return 25
        case "en": return 9
        case "de": return 7
        case "fr": return 12
        case "es": return 10
        default: return 0
        }
    }

    // MARK: - Trailing records

    /// Fixed structures; the bytes match what calibre emits.
    private static func flisRecord() -> Data {
        var record = Data()
        record.append(contentsOf: Array("FLIS".utf8))
        record.appendBE32(8)
        record.appendBE16(65)
        record.appendBE16(0)
        record.appendBE32(0)
        record.appendBE32(0xFFFF_FFFF)
        record.appendBE16(1)
        record.appendBE16(3)
        record.appendBE32(3)
        record.appendBE32(1)
        record.appendBE32(0xFFFF_FFFF)
        return record
    }

    private static func fcisRecord(textLength: Int) -> Data {
        var record = Data()
        record.append(contentsOf: Array("FCIS".utf8))
        record.appendBE32(20)
        record.appendBE32(16)
        record.appendBE32(1)
        record.appendBE32(0)
        record.appendBE32(UInt32(textLength))
        record.appendBE32(0)
        record.appendBE32(32)
        record.appendBE32(8)
        record.appendBE16(1)
        record.appendBE16(1)
        record.appendBE32(0)
        return record
    }

    private static func eofRecord() -> Data {
        Data([0xE9, 0x8E, 0x0D, 0x0A])
    }
}
