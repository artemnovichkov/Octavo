import Foundation

/// A PTP/MTP bulk container: 12-byte header followed by an optional payload.
public struct PTPContainer: Sendable {
    public static let headerSize = 12

    public var type: PTPContainerType
    public var code: UInt16
    public var transactionID: UInt32
    public var payload: [UInt8]

    public init(type: PTPContainerType, code: UInt16, transactionID: UInt32, payload: [UInt8] = []) {
        self.type = type
        self.code = code
        self.transactionID = transactionID
        self.payload = payload
    }

    /// Command container carrying up to five 32-bit parameters.
    public init(command: PTPOperation, transactionID: UInt32, parameters: [UInt32] = []) {
        var writer = PTPWriter()
        for parameter in parameters.prefix(5) { writer.uint32(parameter) }
        self.init(type: .command, code: command.rawValue, transactionID: transactionID, payload: writer.bytes)
    }

    public var encoded: [UInt8] {
        var writer = PTPWriter()
        writer.uint32(UInt32(Self.headerSize + payload.count))
        writer.uint16(type.rawValue)
        writer.uint16(code)
        writer.uint32(transactionID)
        return writer.bytes + payload
    }

    /// Response/command parameters decoded from the payload.
    public var parameters: [UInt32] {
        var reader = PTPReader(payload)
        var result: [UInt32] = []
        while reader.remaining >= 4, let value = try? reader.uint32() { result.append(value) }
        return result
    }

    public var responseCode: PTPResponse? { PTPResponse(rawValue: code) }

    /// Parses a header, returning the container and the total length it declares.
    /// The payload is whatever of `bytes` follows the header — possibly less than declared
    /// for large data phases that span several bulk reads.
    public static func decode(_ bytes: [UInt8]) throws -> (container: PTPContainer, declaredLength: Int) {
        guard bytes.count >= headerSize else {
            throw MTPError.malformedContainer("got \(bytes.count) bytes, minimum is \(headerSize)")
        }
        var reader = PTPReader(bytes)
        let length = Int(try reader.uint32())
        let rawType = try reader.uint16()
        let code = try reader.uint16()
        let transactionID = try reader.uint32()
        guard let type = PTPContainerType(rawValue: rawType) else {
            throw MTPError.malformedContainer(String(format: "unknown container type 0x%04X", rawType))
        }
        guard length >= headerSize else {
            throw MTPError.malformedContainer("length \(length) is shorter than the header")
        }
        let container = PTPContainer(
            type: type,
            code: code,
            transactionID: transactionID,
            payload: Array(bytes[headerSize...])
        )
        return (container, length)
    }
}

extension MTPObject {
    /// Decodes an ObjectInfo dataset (PIMA 15740, §5.3.1).
    static func decode(objectInfo bytes: [UInt8], handle: UInt32) throws -> MTPObject {
        var reader = PTPReader(bytes)
        let storageID = try reader.uint32()
        let format = try reader.uint16()
        _ = try reader.uint16()  // protection status
        let compressedSize = try reader.uint32()
        _ = try reader.uint16()  // thumb format
        _ = try reader.uint32()  // thumb compressed size
        _ = try reader.uint32()  // thumb pix width
        _ = try reader.uint32()  // thumb pix height
        _ = try reader.uint32()  // image pix width
        _ = try reader.uint32()  // image pix height
        _ = try reader.uint32()  // image bit depth
        let parentID = try reader.uint32()
        _ = try reader.uint16()  // association type
        _ = try reader.uint32()  // association description
        _ = try reader.uint32()  // sequence number
        let filename = try reader.string()
        let created = try reader.string()
        let modified = try reader.string()
        _ = try? reader.string()  // keywords

        return MTPObject(
            id: handle,
            storageID: storageID,
            parentID: parentID,
            format: format,
            size: UInt64(compressedSize),
            filename: filename,
            modified: PTPDate.parse(modified) ?? PTPDate.parse(created)
        )
    }

    /// Encodes an ObjectInfo dataset for SendObjectInfo. Sizes above 4 GiB are not
    /// representable here; the 32-bit field is what the standard defines.
    static func encodeObjectInfo(
        storageID: UInt32,
        parentID: UInt32,
        format: UInt16,
        size: UInt64,
        filename: String,
        modified: Date
    ) -> [UInt8] {
        var writer = PTPWriter()
        writer.uint32(storageID)
        writer.uint16(format)
        writer.uint16(0)  // protection status
        writer.uint32(UInt32(clamping: size))
        writer.uint16(0)  // thumb format
        writer.uint32(0)  // thumb compressed size
        writer.uint32(0)  // thumb pix width
        writer.uint32(0)  // thumb pix height
        writer.uint32(0)  // image pix width
        writer.uint32(0)  // image pix height
        writer.uint32(0)  // image bit depth
        writer.uint32(parentID)
        writer.uint16(format == PTPObjectFormat.association.rawValue ? 1 : 0)
        writer.uint32(0)  // association description
        writer.uint32(0)  // sequence number
        writer.string(filename)
        writer.date(modified)  // created
        writer.date(modified)  // modified
        writer.string("")  // keywords
        return writer.bytes
    }
}

extension MTPStorage {
    static func decode(storageInfo bytes: [UInt8], id: UInt32) throws -> MTPStorage {
        var reader = PTPReader(bytes)
        _ = try reader.uint16()  // storage type
        _ = try reader.uint16()  // filesystem type
        _ = try reader.uint16()  // access capability
        let capacity = try reader.uint64()
        let free = try reader.uint64()
        _ = try reader.uint32()  // free space in objects
        let description = try reader.string()
        let volumeIdentifier = (try? reader.string()) ?? ""
        return MTPStorage(
            id: id,
            description: description,
            volumeIdentifier: volumeIdentifier,
            capacity: capacity,
            freeSpace: free
        )
    }
}

extension MTPDeviceInfo {
    static func decode(_ bytes: [UInt8]) throws -> MTPDeviceInfo {
        var reader = PTPReader(bytes)
        let standardVersion = try reader.uint16()
        let vendorExtensionID = try reader.uint32()
        _ = try reader.uint16()  // vendor extension version
        let vendorExtensionDescription = try reader.string()
        _ = try reader.uint16()  // functional mode
        let operations = try reader.uint16Array()
        _ = try reader.uint16Array()  // events supported
        _ = try reader.uint16Array()  // device properties supported
        _ = try reader.uint16Array()  // capture formats
        _ = try reader.uint16Array()  // playback formats
        let manufacturer = (try? reader.string()) ?? ""
        let model = (try? reader.string()) ?? ""
        let deviceVersion = (try? reader.string()) ?? ""
        let serial = (try? reader.string()) ?? ""
        return MTPDeviceInfo(
            standardVersion: standardVersion,
            vendorExtensionID: vendorExtensionID,
            vendorExtensionDescription: vendorExtensionDescription,
            operationsSupported: operations,
            manufacturer: manufacturer,
            model: model,
            deviceVersion: deviceVersion,
            serialNumber: serial
        )
    }
}
