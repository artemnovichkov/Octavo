import Foundation
@testable import MTPKit

/// An in-memory stand-in for a connected Kindle. `SyncEngine` talks to `MTPDeviceSession`
/// rather than the USB session, so the whole plan/execute path — selection scoping, staleness,
/// retargeting, the manifest round-trip — runs here with no device and no cable.
final class FakeKindle: MTPDeviceSession {
    struct Entry {
        var handle: UInt32
        var parent: UInt32
        var name: String
        var bytes: [UInt8]
        var isFolder: Bool
        var modified: Date?
    }

    static let storageID: UInt32 = 0x0001_0001
    private static let root: UInt32 = 0xFFFF_FFFF

    private(set) var entries: [Entry] = []
    private var nextHandle: UInt32 = 100
    let documentsHandle: UInt32

    /// Every filename handed to `sendFile`, in order — what a test asserts a sync actually sent.
    var sentFilenames: [String] = []
    var deletedFilenames: [String] = []

    init() {
        documentsHandle = 10
        entries.append(Entry(handle: 10, parent: Self.root, name: "documents",
                             bytes: [], isFolder: true, modified: nil))
    }

    /// Puts a file in documents/ the way a previous sync (or calibre) would have left it.
    @discardableResult
    func place(_ name: String, bytes: [UInt8] = Array("book".utf8), inDocuments: Bool = true) -> UInt32 {
        nextHandle += 1
        entries.append(Entry(handle: nextHandle, parent: inDocuments ? documentsHandle : Self.root,
                             name: name, bytes: bytes, isFolder: false, modified: Date()))
        return nextHandle
    }

    func bytes(of name: String) -> [UInt8]? {
        entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.bytes
    }

    var documentFilenames: [String] {
        entries.filter { $0.parent == documentsHandle && !$0.isFolder }.map(\.name).sorted()
    }

    // MARK: - MTPDeviceSession

    func storages() throws -> [MTPStorage] {
        [MTPStorage(id: Self.storageID, description: "Kindle", volumeIdentifier: "fake",
                    capacity: 8_000_000_000, freeSpace: 4_000_000_000)]
    }

    func children(storageID: UInt32, parent: UInt32) throws -> [MTPObject] {
        entries.filter { $0.parent == parent }.map(object(from:))
    }

    func object(at path: String, storageID: UInt32) throws -> MTPObject? {
        var parent = Self.root
        var found: MTPObject?
        for component in path.split(separator: "/").map(String.init) {
            guard let match = entries.first(where: {
                $0.parent == parent && $0.name.caseInsensitiveCompare(component) == .orderedSame
            }) else { return nil }
            found = object(from: match)
            parent = match.handle
        }
        return found
    }

    func data(of handle: UInt32) throws -> [UInt8] {
        guard let entry = entries.first(where: { $0.handle == handle }) else {
            throw MTPError.deviceNotFound
        }
        return entry.bytes
    }

    func delete(handle: UInt32) throws {
        guard let index = entries.firstIndex(where: { $0.handle == handle }) else { return }
        deletedFilenames.append(entries[index].name)
        entries.remove(at: index)
    }

    @discardableResult
    func sendFile(
        _ bytes: [UInt8],
        named filename: String,
        storageID: UInt32,
        parent: UInt32,
        modified: Date,
        progress: ((Int, Int) -> Void)?
    ) throws -> UInt32 {
        sentFilenames.append(filename)
        nextHandle += 1
        entries.append(Entry(handle: nextHandle, parent: parent, name: filename,
                             bytes: bytes, isFolder: false, modified: modified))
        return nextHandle
    }

    private func object(from entry: Entry) -> MTPObject {
        MTPObject(
            id: entry.handle,
            storageID: Self.storageID,
            parentID: entry.parent,
            format: entry.isFolder ? PTPObjectFormat.association.rawValue : PTPObjectFormat.undefined.rawValue,
            size: UInt64(entry.bytes.count),
            filename: entry.name,
            modified: entry.modified
        )
    }
}
