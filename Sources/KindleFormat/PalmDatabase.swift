import Foundation

/// Builds the PalmDB container every MOBI file lives in: a 78-byte header, one 8-byte
/// entry per record, then the record payloads.
struct PalmDatabase {
    var name: String
    var type: String = "BOOK"
    var creator: String = "MOBI"
    var records: [Data] = []

    static let headerSize = 78
    static let recordEntrySize = 8

    func serialized() -> Data {
        var output = Data()

        // Name is 32 bytes, NUL padded, ASCII only.
        var nameBytes = Array(CalibreASCII.transliterate(name).prefix(31).utf8)
        nameBytes.append(contentsOf: [UInt8](repeating: 0, count: 32 - nameBytes.count))
        output.append(contentsOf: nameBytes)

        output.appendBE16(0)  // attributes
        output.appendBE16(0)  // version

        // Palm timestamps count seconds since 1904.
        let stamp = UInt32(Date().timeIntervalSince1970 + 2_082_844_800)
        output.appendBE32(stamp)  // created
        output.appendBE32(stamp)  // modified
        output.appendBE32(0)  // backed up
        output.appendBE32(0)  // modification number
        output.appendBE32(0)  // app info
        output.appendBE32(0)  // sort info
        output.append(contentsOf: Array(type.utf8))
        output.append(contentsOf: Array(creator.utf8))
        output.appendBE32(stamp)  // unique id seed
        output.appendBE32(0)  // next record list
        output.appendBE16(UInt16(records.count))

        // Record offsets follow the header; payloads start after the table.
        var offset = Self.headerSize + records.count * Self.recordEntrySize + 2  // +2 gap Palm expects
        for (index, record) in records.enumerated() {
            output.appendBE32(UInt32(offset))
            output.append(0)  // attributes
            // Unique id is three bytes wide, not one: a KF8 book runs to several hundred
            // records, and truncating to a byte made them collide past 256.
            output.append(contentsOf: [
                UInt8(index >> 16 & 0xFF), UInt8(index >> 8 & 0xFF), UInt8(index & 0xFF),
            ])
            offset += record.count
        }
        output.appendBE16(0)  // two-byte gap before the first record

        for record in records { output.append(record) }
        return output
    }
}

enum CalibreASCII {
    /// PalmDB names must be plain ASCII.
    static func transliterate(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let stripped = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        let ascii = String(stripped.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 })
        return ascii.isEmpty ? "Book" : ascii
    }
}

extension Data {
    mutating func appendBE16(_ value: UInt16) {
        append(UInt8(value >> 8 & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8(value >> UInt32(shift) & 0xFF))
        }
    }

    mutating func pad(to multiple: Int) {
        let remainder = count % multiple
        if remainder != 0 { append(contentsOf: [UInt8](repeating: 0, count: multiple - remainder)) }
    }
}
