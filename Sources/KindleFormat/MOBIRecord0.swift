import Foundation

/// Record 0 of a PalmDB book: the PalmDOC header, the MOBI header, the EXTH block and the
/// full title. MOBI 6 and KF8 differ only in the header's length, the version numbers and
/// which record-index fields are meaningful, so both writers build it from here.
///
/// The MOBI header is addressed by offset rather than written sequentially: a field landing
/// four bytes off makes the Kindle read garbage. Values mirror calibre-produced reference
/// files for books from this library.
enum MOBIRecord0 {
    struct Layout {
        var headerLength: Int
        var fileVersion: UInt32
        var minReaderVersion: UInt32

        static let mobi6 = Layout(headerLength: 232, fileVersion: 6, minReaderVersion: 6)
        /// KF8 spends its extra 32 bytes on the chunk/skeleton/guide index pointers.
        static let kf8 = Layout(headerLength: 264, fileVersion: 8, minReaderVersion: 8)
    }

    struct Text {
        var uncompressedLength: Int
        var recordCount: Int
        var recordSize: Int
        var compression: UInt16
    }

    /// - Parameters:
    ///   - fields: MOBI header offset → 32-bit value, applied over the shared defaults.
    ///   - halfFields: the same for the two 16-bit fields MOBI 6 uses at 0xB0/0xB2.
    static func build(
        layout: Layout,
        text: Text,
        metadata: EbookMetadata,
        exth: Data,
        fields: [Int: UInt32],
        halfFields: [Int: UInt16] = [:]
    ) -> Data {
        let titleBytes = Array(metadata.title.utf8)
        // The full name sits right after EXTH inside record 0.
        let fullNameOffset = 16 + layout.headerLength + exth.count

        var record = Data()

        // PalmDOC header
        record.appendBE16(text.compression)
        record.appendBE16(0)  // unused
        record.appendBE32(UInt32(text.uncompressedLength))
        record.appendBE16(UInt16(text.recordCount))
        record.appendBE16(UInt16(text.recordSize))
        record.appendBE16(0)  // encryption
        record.appendBE16(0)  // unused

        var mobi = [UInt8](repeating: 0, count: layout.headerLength)

        func put32(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { mobi[offset + i] = UInt8(value >> UInt32(8 * (3 - i)) & 0xFF) }
        }
        func put16(_ offset: Int, _ value: UInt16) {
            mobi[offset] = UInt8(value >> 8 & 0xFF)
            mobi[offset + 1] = UInt8(value & 0xFF)
        }

        for (index, byte) in Array("MOBI".utf8).enumerated() { mobi[index] = byte }
        put32(0x04, UInt32(layout.headerLength))
        put32(0x08, 2)  // book
        put32(0x0C, 65001)  // UTF-8
        put32(0x10, UInt32.random(in: 1...UInt32.max))  // unique id
        put32(0x14, layout.fileVersion)

        // 0x18…0x3C are index records neither writer emits.
        for offset in stride(from: 0x18, through: 0x3C, by: 4) { put32(offset, 0xFFFF_FFFF) }

        put32(0x44, UInt32(fullNameOffset))
        put32(0x48, UInt32(titleBytes.count))
        put32(0x4C, locale(for: metadata.language))
        put32(0x58, layout.minReaderVersion)
        put32(0x70, 0x50)  // EXTH present

        put32(0x94, 0xFFFF_FFFF)
        put32(0x98, 0xFFFF_FFFF)  // DRM offset: none. Writing 0 here makes the Kindle
        put32(0x9C, 0)            // treat the book as encrypted and refuse to open it.
        put32(0xA0, 0)  // DRM size
        put32(0xA4, 0)  // DRM flags

        put32(0xD0, 0xFFFF_FFFF)
        put32(0xD8, 0xFFFF_FFFF)
        put32(0xDC, 0xFFFF_FFFF)

        // 0xE0 straddles two fields; its low half at 0xE2 is the extra-record-data flags,
        // which say what each text record carries past its content. Bit 0 is the
        // multibyte-overlap trailer `textRecords` appends to every record. Bit 1 would be a
        // trailing byte sequence, which neither writer emits — TBS feeds the progress
        // machinery, not rendering.
        //
        // This field and `textRecords` have to agree exactly. Claiming trailers that are not
        // there costs a few bytes off the end of every record; omitting the claim for trailers
        // that are there feeds the reader four bytes of garbage per record.
        put32(0xE0, 1)
        put32(0xE4, 0xFFFF_FFFF)  // no NCX index; 0 would point at the header record
        if layout.headerLength > 0xE8 {
            put32(0xE8, 0xFFFF_FFFF)  // chunk index
            put32(0xEC, 0xFFFF_FFFF)  // skeleton index
            put32(0xF0, 0xFFFF_FFFF)  // DATP index
            put32(0xF4, 0xFFFF_FFFF)  // guide index
            put32(0xF8, 0xFFFF_FFFF)
            put32(0x100, 0xFFFF_FFFF)
        }

        for (offset, value) in fields { put32(offset, value) }
        for (offset, value) in halfFields { put16(offset, value) }

        record.append(contentsOf: mobi)
        precondition(record.count == 16 + layout.headerLength, "MOBI header length mismatch")

        record.append(exth)
        record.append(contentsOf: titleBytes)
        record.append(contentsOf: [0, 0])  // terminator after the title
        record.pad(to: 4)
        return record
    }

    // MARK: - EXTH

    /// - Parameters:
    ///   - coverIndex: position of the cover among the image records, which is what 201/202 mean.
    ///   - extra: format-specific entries, appended after the metadata ones.
    static func exth(
        metadata: EbookMetadata,
        coverIndex: Int?,
        extra: [(UInt32, Data)] = []
    ) -> Data {
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
        if let coverIndex {
            addUInt(201, UInt32(coverIndex))
            addUInt(202, UInt32(coverIndex))
        }

        entries.append(contentsOf: extra)

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

    static func uintEntry(_ type: UInt32, _ value: UInt32) -> (UInt32, Data) {
        var payload = Data()
        payload.appendBE32(value)
        return (type, payload)
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

    /// Fixed structures shared by both formats; the bytes match what calibre emits.
    static func flisRecord() -> Data {
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

    /// 52 bytes, matching calibre's byte for byte. The earlier version was 44 — two fields
    /// short and with a wrong constant — which is the sort of thing the device notices and
    /// nothing on the Mac does.
    static func fcisRecord(textLength: Int) -> Data {
        var record = Data()
        record.append(contentsOf: Array("FCIS".utf8))
        record.appendBE32(20)
        record.appendBE32(16)
        record.appendBE32(2)
        record.appendBE32(0)
        record.appendBE32(UInt32(textLength))
        record.appendBE32(0)
        record.appendBE32(40)
        record.appendBE32(0)
        record.appendBE32(40)
        record.appendBE32(8)
        record.appendBE16(1)
        record.appendBE16(1)
        record.appendBE32(0)
        return record
    }

    static func eofRecord() -> Data { Data([0xE9, 0x8E, 0x0D, 0x0A]) }

    // MARK: - Text records

    /// Splits UTF-8 text into PalmDoc-compressed records of **exactly** `size` uncompressed
    /// bytes, plus a multibyte-overlap trailer on each.
    ///
    /// Exactly, not at most, and this is not cosmetic. Every offset a KF8 index records is an
    /// absolute byte offset into the flow, and the reader turns one into a record number by
    /// dividing by `size`. Shortening records to land on character boundaries breaks that
    /// arithmetic for every record after the first split character — which on a Cyrillic book
    /// means almost immediately, and shows up as text rendered from the middle of a tag and a
    /// position map the device cannot page through.
    ///
    /// The overlap trailer is how the format squares fixed-size records with variable-width
    /// characters: when a character straddles the end of a record, that record repeats the
    /// bytes belonging to the next one, followed by a count. A reader that jumped straight to
    /// this record can then complete the character without fetching its neighbour. Verified
    /// against calibre's own files — all 394 full records there are 4096 bytes to the byte.
    static func textRecords(_ text: Data, size: Int, compress: Bool) -> [Data] {
        let bytes = [UInt8](text)
        guard !bytes.isEmpty else { return [Data([0])] }

        var records: [Data] = []
        var offset = 0

        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            let chunk = Data(bytes[offset..<end])
            var record = compress ? PalmDoc.compress(chunk) : chunk

            // Continuation bytes are 0b10xxxxxx. At most three can follow a lead byte, which
            // is also all the count byte's low two bits can express.
            var overlap = 0
            while end + overlap < bytes.count, overlap < 3, bytes[end + overlap] & 0xC0 == 0x80 {
                overlap += 1
            }
            record.append(contentsOf: bytes[end..<(end + overlap)])
            record.append(UInt8(overlap))

            records.append(record)
            offset = end
        }

        return records
    }
}
