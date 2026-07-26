import Foundation

/// Drives PTP transactions over a claimed transport: command phase, optional data
/// phase, response phase.
public final class MTPSession {
    public let transport: MTPTransport
    private var transactionID: UInt32 = 0
    private var sessionOpen = false

    public init(transport: MTPTransport) {
        self.transport = transport
    }

    deinit {
        if sessionOpen { try? close() }
    }

    private func nextTransactionID() -> UInt32 {
        transactionID &+= 1
        return transactionID
    }

    // MARK: - Transactions

    /// Command with no data phase.
    @discardableResult
    public func execute(
        _ operation: PTPOperation,
        _ parameters: [UInt32] = [],
        transactionID overrideID: UInt32? = nil
    ) throws -> [UInt32] {
        let id = overrideID ?? nextTransactionID()
        try transport.write(PTPContainer(command: operation, transactionID: id, parameters: parameters).encoded)
        return try readResponse(for: operation).parameters
    }

    /// Command whose response carries a data phase from the device.
    public func receive(_ operation: PTPOperation, _ parameters: [UInt32] = []) throws -> [UInt8] {
        let id = nextTransactionID()
        try transport.write(PTPContainer(command: operation, transactionID: id, parameters: parameters).encoded)

        let first = try transport.read()
        let (container, declaredLength) = try PTPContainer.decode(first)

        if container.type == .response {
            try check(container, operation)
            return []
        }
        guard container.type == .data else {
            throw MTPError.malformedContainer("expected a data phase, got \(container.type)")
        }

        var payload = container.payload
        let expectedPayload = declaredLength - PTPContainer.headerSize
        while payload.count < expectedPayload {
            let chunk = try transport.read()
            guard !chunk.isEmpty else { throw MTPError.truncatedData }
            payload.append(contentsOf: chunk)
        }
        if payload.count > expectedPayload { payload.removeLast(payload.count - expectedPayload) }

        _ = try readResponse(for: operation)
        return payload
    }

    /// Command followed by a data phase we send to the device.
    @discardableResult
    public func send(
        _ operation: PTPOperation,
        _ parameters: [UInt32] = [],
        payload: [UInt8],
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> [UInt32] {
        let id = nextTransactionID()
        try transport.write(PTPContainer(command: operation, transactionID: id, parameters: parameters).encoded)

        let data = PTPContainer(type: .data, code: operation.rawValue, transactionID: id, payload: payload)
        try transport.write(data.encoded)
        progress?(payload.count, payload.count)

        return try readResponse(for: operation).parameters
    }

    private func readResponse(for operation: PTPOperation) throws -> PTPContainer {
        var attempts = 0
        while attempts < 4 {
            attempts += 1
            let bytes = try transport.read()
            guard !bytes.isEmpty else { continue }
            let (container, _) = try PTPContainer.decode(bytes)
            switch container.type {
            case .response:
                try check(container, operation)
                return container
            case .event:
                continue  // asynchronous event, not our answer
            default:
                throw MTPError.malformedContainer("expected a response phase, got \(container.type)")
            }
        }
        throw MTPError.truncatedData
    }

    private func check(_ container: PTPContainer, _ operation: PTPOperation) throws {
        guard let response = container.responseCode else {
            throw MTPError.unexpectedResponseCode(container.code)
        }
        guard response == .ok else {
            throw MTPError.operationFailed(operation, response)
        }
    }

    // MARK: - Operations

    public func open() throws {
        guard !sessionOpen else { return }
        // OpenSession is the one operation that must carry transaction ID 0; the
        // counter starts at 1 only once a session exists (PIMA 15740, §9.3.1).
        do {
            try execute(.openSession, [1], transactionID: 0)
        } catch MTPError.operationFailed(_, .sessionAlreadyOpen) {
            // Device kept a session from a previous run; reuse it.
        }
        transactionID = 0
        sessionOpen = true
    }

    public func close() throws {
        guard sessionOpen else { return }
        sessionOpen = false
        try execute(.closeSession)
    }

    public func deviceInfo() throws -> MTPDeviceInfo {
        try MTPDeviceInfo.decode(receive(.getDeviceInfo))
    }

    public func storages() throws -> [MTPStorage] {
        var reader = PTPReader(try receive(.getStorageIDs))
        let ids = try reader.uint32Array()
        return try ids.map { id in
            try MTPStorage.decode(storageInfo: receive(.getStorageInfo, [id]), id: id)
        }
    }

    /// Object handles directly under `parent` (`0xFFFFFFFF` means the storage root).
    public func objectHandles(storageID: UInt32, parent: UInt32 = 0xFFFF_FFFF) throws -> [UInt32] {
        var reader = PTPReader(try receive(.getObjectHandles, [storageID, 0, parent]))
        return try reader.uint32Array()
    }

    public func objectInfo(handle: UInt32) throws -> MTPObject {
        try MTPObject.decode(objectInfo: receive(.getObjectInfo, [handle]), handle: handle)
    }

    public func children(storageID: UInt32, parent: UInt32 = 0xFFFF_FFFF) throws -> [MTPObject] {
        try objectHandles(storageID: storageID, parent: parent).compactMap { try? objectInfo(handle: $0) }
    }

    /// Resolves a slash-separated path from the storage root, e.g. "documents".
    public func object(at path: String, storageID: UInt32) throws -> MTPObject? {
        var parent: UInt32 = 0xFFFF_FFFF
        var found: MTPObject?
        for component in path.split(separator: "/").map(String.init) {
            guard let match = try children(storageID: storageID, parent: parent)
                .first(where: { $0.filename.caseInsensitiveCompare(component) == .orderedSame })
            else { return nil }
            found = match
            parent = match.id
        }
        return found
    }

    public func data(of handle: UInt32) throws -> [UInt8] {
        try receive(.getObject, [handle])
    }

    public func delete(handle: UInt32) throws {
        try execute(.deleteObject, [handle, 0])
    }

    /// Uploads a file. Returns the handle the device assigned.
    @discardableResult
    public func sendFile(
        _ bytes: [UInt8],
        named filename: String,
        storageID: UInt32,
        parent: UInt32,
        modified: Date = Date(),
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> UInt32 {
        let info = MTPObject.encodeObjectInfo(
            storageID: storageID,
            parentID: parent,
            format: PTPObjectFormat.undefined.rawValue,
            size: UInt64(bytes.count),
            filename: filename,
            modified: modified
        )
        let result = try send(.sendObjectInfo, [storageID, parent], payload: info)
        try send(.sendObject, payload: bytes, progress: progress)
        return result.count >= 3 ? result[2] : 0
    }

    @discardableResult
    public func createFolder(named name: String, storageID: UInt32, parent: UInt32) throws -> UInt32 {
        let info = MTPObject.encodeObjectInfo(
            storageID: storageID,
            parentID: parent,
            format: PTPObjectFormat.association.rawValue,
            size: 0,
            filename: name,
            modified: Date()
        )
        let result = try send(.sendObjectInfo, [storageID, parent], payload: info)
        return result.count >= 3 ? result[2] : 0
    }
}
