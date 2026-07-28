import Foundation

/// Writes the INDX/TAGX/IDXT/CNCX structure KF8 uses for all four of its indices.
///
/// An index is a header record, one or more data records, and optionally a CNCX record holding
/// the strings entries refer to by byte offset. Within a data record each entry is a
/// length-prefixed name, one control byte, and then the tag values as varints — seven bits a
/// byte, **high bit set on the last one**, which is the opposite of most varint encodings and
/// the easiest thing here to get backwards.
///
/// The control byte is what says how many values follow: each tag definition owns a bitfield in
/// it, and the number stored there is the number of value *groups*, not values. Everything was
/// read off calibre's own AZW3 files rather than documentation.
enum INDXWriter {
    static let headerLength = 192
    /// Entry offsets inside a data record are 16-bit, so a record cannot grow past 64 KB.
    /// Leaving room for the IDXT block is what the margin is for.
    static let maxDataRecordSize = 0xF000

    struct TagDefinition {
        var tag: UInt8
        var valuesPerEntry: UInt8
        var mask: UInt8
    }

    struct Entry {
        var name: String
        /// Tag number → its values. A tag with no entry here is simply absent, and the control
        /// byte says so.
        var values: [UInt8: [Int]]
    }

    /// Returns the whole record run: header, data records, then the CNCX record if there is one.
    static func records(entries: [Entry], tagx: [TagDefinition], strings: [String] = []) -> [Data] {
        let encoded = entries.map { encode($0, tagx: tagx) }

        // Pack entries into data records, respecting the 16-bit offsets in IDXT.
        var groups: [[Data]] = []
        var current: [Data] = []
        var size = headerLength
        for entry in encoded {
            if !current.isEmpty, size + entry.count + (current.count + 1) * 2 + 8 > maxDataRecordSize {
                groups.append(current)
                current = []
                size = headerLength
            }
            current.append(entry)
            size += entry.count
        }
        if !current.isEmpty || groups.isEmpty { groups.append(current) }

        let cncx = strings.isEmpty ? nil : cncxRecord(strings)
        let header = headerRecord(
            entries: entries,
            tagx: tagx,
            dataRecordCount: groups.count,
            cncxRecordCount: cncx == nil ? 0 : 1
        )
        return [header] + groups.map(dataRecord) + (cncx.map { [$0] } ?? [])
    }

    /// Byte offsets into the CNCX record, in the same order as the strings handed in — what an
    /// entry stores to point at its label.
    static func stringOffsets(_ strings: [String]) -> [Int] {
        var offsets: [Int] = []
        var cursor = 0
        for text in strings {
            offsets.append(cursor)
            let bytes = truncate(text)
            cursor += varint(bytes.count).count + bytes.count
        }
        return offsets
    }

    // MARK: - Records

    private static func headerRecord(
        entries: [Entry],
        tagx: [TagDefinition],
        dataRecordCount: Int,
        cncxRecordCount: Int
    ) -> Data {
        var tagxBlock = Data()
        tagxBlock.append(contentsOf: Array("TAGX".utf8))
        tagxBlock.appendBE32(UInt32(12 + (tagx.count + 1) * 4))
        tagxBlock.appendBE32(1)  // one control byte is enough for every index we write
        for definition in tagx {
            tagxBlock.append(contentsOf: [definition.tag, definition.valuesPerEntry, definition.mask, 0])
        }
        tagxBlock.append(contentsOf: [0, 0, 0, 1])  // end of the control byte's definitions

        // The last entry's name follows TAGX; IDXT points at it, and the reader uses it as the
        // upper bound of a search.
        var tail = Data()
        let lastName = truncate(entries.last?.name ?? "")
        tail.append(UInt8(lastName.count))
        tail.append(contentsOf: lastName)
        tail.appendBE16(UInt16(entries.count))

        let nameOffset = headerLength + tagxBlock.count
        var body = tagxBlock
        body.append(tail)
        body.pad(to: 4)
        let idxtOffset = headerLength + body.count

        var header = fixedHeader(
            generation: 0,
            unknown: 2,
            idxtOffset: idxtOffset,
            count: dataRecordCount,
            codepage: 65001,
            language: 0xFFFF_FFFF
        )
        header.replaceSubrange(0x24..<0x28, with: bigEndian(UInt32(entries.count)))
        header.replaceSubrange(0x34..<0x38, with: bigEndian(UInt32(cncxRecordCount)))

        var record = Data(header)
        record.append(body)
        record.append(contentsOf: Array("IDXT".utf8))
        record.appendBE16(UInt16(nameOffset))
        record.appendBE16(0)
        record.pad(to: 4)
        return record
    }

    private static func dataRecord(_ entries: [Data]) -> Data {
        var body = Data()
        var offsets: [Int] = []
        for entry in entries {
            offsets.append(headerLength + body.count)
            body.append(entry)
        }
        body.pad(to: 4)
        let idxtOffset = headerLength + body.count

        var header = fixedHeader(
            generation: 1,
            unknown: 0,
            idxtOffset: idxtOffset,
            count: entries.count,
            codepage: 0xFFFF_FFFF,
            language: 0xFFFF_FFFF
        )
        header.replaceSubrange(0x24..<0x28, with: [0, 0, 0, 0])

        var record = Data(header)
        record.append(body)
        record.append(contentsOf: Array("IDXT".utf8))
        for offset in offsets { record.appendBE16(UInt16(offset)) }
        record.pad(to: 4)
        return record
    }

    private static func cncxRecord(_ strings: [String]) -> Data {
        var record = Data()
        for text in strings {
            let bytes = truncate(text)
            record.append(contentsOf: varint(bytes.count))
            record.append(contentsOf: bytes)
        }
        record.pad(to: 4)
        return record
    }

    private static func fixedHeader(
        generation: UInt32,
        unknown: UInt32,
        idxtOffset: Int,
        count: Int,
        codepage: UInt32,
        language: UInt32
    ) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: headerLength)
        for (index, byte) in Array("INDX".utf8).enumerated() { header[index] = byte }
        func put(_ offset: Int, _ value: UInt32) {
            header.replaceSubrange(offset..<(offset + 4), with: bigEndian(value))
        }
        put(0x04, UInt32(headerLength))
        put(0x0C, generation)
        put(0x10, unknown)
        put(0x14, UInt32(idxtOffset))
        put(0x18, UInt32(count))
        put(0x1C, codepage)
        put(0x20, language)
        return header
    }

    // MARK: - Entries

    private static func encode(_ entry: Entry, tagx: [TagDefinition]) -> Data {
        var control: UInt8 = 0
        var values = Data()

        for definition in tagx {
            guard let stored = entry.values[definition.tag], !stored.isEmpty else { continue }
            let groups = stored.count / max(1, Int(definition.valuesPerEntry))
            // The count sits in the definition's own bitfield, shifted down to where the mask
            // begins. A count too big for the field would silently truncate, so it is clamped.
            let shift = definition.mask.trailingZeroBitCount
            let capacity = Int(definition.mask >> UInt8(shift))
            control |= UInt8(min(groups, capacity) << shift) & definition.mask
            for value in stored.prefix(min(groups, capacity) * Int(definition.valuesPerEntry)) {
                values.append(contentsOf: varint(value))
            }
        }

        let name = truncate(entry.name)
        var record = Data()
        record.append(UInt8(name.count))
        record.append(contentsOf: name)
        record.append(control)
        record.append(values)
        return record
    }

    /// Seven bits a byte, most significant group first, high bit marking the final byte.
    static func varint(_ value: Int) -> [UInt8] {
        var groups: [UInt8] = []
        var remainder = max(0, value)
        repeat {
            groups.append(UInt8(remainder & 0x7F))
            remainder >>= 7
        } while remainder > 0
        groups.reverse()
        groups[groups.count - 1] |= 0x80
        return groups
    }

    /// Names and CNCX strings are length-prefixed with a single byte in the places that matter,
    /// so nothing may exceed 255 bytes — and cutting UTF-8 mid-character would corrupt the text.
    private static func truncate(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        guard bytes.count > 255 else { return bytes }
        bytes = Array(bytes.prefix(255))
        while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
        return bytes
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(value >> UInt32(8 * (3 - $0)) & 0xFF) }
    }
}
