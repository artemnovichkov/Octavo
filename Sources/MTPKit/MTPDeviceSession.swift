import Foundation

/// The slice of `MTPSession` the sync engine actually uses. Extracted as a protocol so the
/// whole plan/execute path can be exercised against an in-memory device: everything above
/// the USB transport is ordinary logic, and tying it to real hardware meant none of it could
/// be tested without a Kindle plugged in.
public protocol MTPDeviceSession: AnyObject {
    func storages() throws -> [MTPStorage]
    func children(storageID: UInt32, parent: UInt32) throws -> [MTPObject]
    func object(at path: String, storageID: UInt32) throws -> MTPObject?
    func data(of handle: UInt32) throws -> [UInt8]
    func delete(handle: UInt32) throws
    @discardableResult
    func sendFile(
        _ bytes: [UInt8],
        named filename: String,
        storageID: UInt32,
        parent: UInt32,
        modified: Date,
        progress: ((Int, Int) -> Void)?
    ) throws -> UInt32
}

extension MTPSession: MTPDeviceSession {}
