import Foundation

/// Little-endian cursor over a PTP dataset payload.
public struct PTPReader {
    public let data: [UInt8]
    public private(set) var offset: Int

    public init(_ data: [UInt8], offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public var remaining: Int { data.count - offset }

    public mutating func uint8() throws -> UInt8 {
        guard remaining >= 1 else { throw MTPError.truncatedData }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func uint16() throws -> UInt16 {
        guard remaining >= 2 else { throw MTPError.truncatedData }
        defer { offset += 2 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    public mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw MTPError.truncatedData }
        defer { offset += 4 }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
        return value
    }

    public mutating func uint64() throws -> UInt64 {
        guard remaining >= 8 else { throw MTPError.truncatedData }
        defer { offset += 8 }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[offset + i]) << (8 * UInt64(i)) }
        return value
    }

    /// PTP string: byte count of UTF-16 characters (including the NUL), then UTF-16LE.
    public mutating func string() throws -> String {
        let count = Int(try uint8())
        guard count > 0 else { return "" }
        guard remaining >= count * 2 else { throw MTPError.truncatedData }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count {
            let unit = try uint16()
            if unit == 0 { break }
            units.append(unit)
        }
        // Skip any units left after an early NUL.
        let consumed = units.count + 1
        if consumed < count { offset += (count - consumed) * 2 }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func array<T>(_ element: (inout PTPReader) throws -> T) throws -> [T] {
        let count = Int(try uint32())
        guard count <= remaining else { throw MTPError.truncatedData }
        var result: [T] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try element(&self)) }
        return result
    }

    public mutating func uint16Array() throws -> [UInt16] {
        try array { try $0.uint16() }
    }

    public mutating func uint32Array() throws -> [UInt32] {
        try array { try $0.uint32() }
    }

    public mutating func skip(_ count: Int) throws {
        guard remaining >= count else { throw MTPError.truncatedData }
        offset += count
    }
}

/// Little-endian builder for PTP dataset payloads.
public struct PTPWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func uint8(_ value: UInt8) { bytes.append(value) }

    public mutating func uint16(_ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8(value >> 8 & 0xFF))
    }

    public mutating func uint32(_ value: UInt32) {
        for i in 0..<4 { bytes.append(UInt8(value >> (8 * UInt32(i)) & 0xFF)) }
    }

    public mutating func uint64(_ value: UInt64) {
        for i in 0..<8 { bytes.append(UInt8(value >> (8 * UInt64(i)) & 0xFF)) }
    }

    public mutating func string(_ value: String) {
        guard !value.isEmpty else {
            bytes.append(0)
            return
        }
        let units = Array(value.utf16.prefix(254))
        bytes.append(UInt8(units.count + 1))
        for unit in units { uint16(unit) }
        uint16(0)
    }

    /// PTP date string: "YYYYMMDDThhmmss".
    public mutating func date(_ value: Date) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        string(formatter.string(from: value))
    }
}

enum PTPDate {
    /// Parses "YYYYMMDDThhmmss", optionally with fractional seconds and a Z/±hhmm suffix.
    static func parse(_ raw: String) -> Date? {
        guard raw.count >= 15 else { return nil }
        let core = String(raw.prefix(15))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = raw.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : TimeZone.current
        return formatter.date(from: core)
    }
}
