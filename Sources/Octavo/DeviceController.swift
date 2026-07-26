import CalibreLibrary
import Foundation
import MTPKit
import SyncEngine

/// Owns the USB transport and the MTP session. Everything USB happens inside this actor,
/// which is why the non-Sendable transport never crosses a concurrency boundary.
actor DeviceController {
    struct Snapshot: Sendable, Equatable {
        var name: String
        var freeSpace: UInt64
        var capacity: UInt64
        var booksOnDevice: Int
    }

    enum State: Sendable, Equatable {
        case disconnected
        case connecting
        /// On the bus, but exposing no MTP interface — charge-only, or the screen is locked.
        /// Informational, not an error, which is what keeps `.failed` meaningful.
        case waitingForMTP
        case connected(Snapshot)
        case failed(String)

        var snapshot: Snapshot? {
            if case .connected(let snapshot) = self { return snapshot }
            return nil
        }
    }

    private var transport: MTPTransport?
    private var session: MTPSession?
    private var engine: SyncEngine?
    private var libraryRoot: URL

    init(libraryRoot: URL) {
        self.libraryRoot = libraryRoot
    }

    /// The engine holds a store open against the old root, so the session goes with it — the
    /// next connect() builds both again.
    func setLibraryRoot(_ url: URL) {
        guard url != libraryRoot else { return }
        disconnect()
        libraryRoot = url
    }

    var isConnected: Bool { engine != nil }

    func connect() throws -> Snapshot {
        if let engine, let snapshot = try? snapshot(of: engine) { return snapshot }

        disconnect()
        let transport = try MTPTransport.openKindle()
        let session = MTPSession(transport: transport)
        try session.open()

        let library = try CalibreLibraryStore(root: libraryRoot, readOnly: true)
        let engine = try SyncEngine(library: library, session: session)

        self.transport = transport
        self.session = session
        self.engine = engine
        return try snapshot(of: engine)
    }

    func disconnect() {
        try? session?.close()
        // Explicit rather than waiting for deinit: after a surprise removal the transport
        // may still be referenced, and invalidate() is idempotent.
        transport?.invalidate()
        session = nil
        transport = nil
        engine = nil
    }

    /// Fresh device figures without rebuilding the session.
    func snapshot() throws -> Snapshot {
        try snapshot(of: requireEngine())
    }

    private func snapshot(of engine: SyncEngine) throws -> Snapshot {
        let files = try engine.documentsChildren().filter { !$0.isFolder }
        // engine.storage is captured once at SyncEngine.init, so free space would never
        // move after a transfer. Re-query, falling back to the frozen copy.
        let storage = (try? engine.session.storages().first { $0.id == engine.storage.id })
            ?? engine.storage
        return Snapshot(
            name: transport?.device.product ?? "Kindle",
            freeSpace: storage.freeSpace,
            capacity: storage.capacity,
            booksOnDevice: files.count
        )
    }

    func plan(books: [Book]) throws -> SyncPlan {
        let engine = try requireEngine()
        return try engine.plan(books: books, manifest: engine.loadManifest())
    }

    /// Sends the planned books. Progress is reported through an isolated callback so the
    /// UI can update while the transfer runs.
    func sync(
        books: [Book],
        shouldStop: @Sendable @escaping () -> Bool,
        progress: @Sendable @escaping (SyncEngine.Progress) -> Void
    ) throws -> SyncPlan {
        let engine = try requireEngine()
        let manifest = try engine.loadManifest()
        let plan = try engine.plan(books: books, manifest: manifest)
        guard !plan.isEmpty || manifest.adoptedFromCalibre else { return plan }
        _ = try engine.execute(plan, manifest: manifest, onProgress: progress, shouldStop: shouldStop)
        return plan
    }

    func backupDocuments(to directory: URL, progress: @Sendable @escaping (String, Int, Int) -> Void) throws {
        try requireEngine().backupDocuments(to: directory, onFile: progress)
    }

    func delete(filename: String) throws {
        let engine = try requireEngine()
        guard let object = try engine.documentsChildren().first(where: {
            $0.filename.caseInsensitiveCompare(filename) == .orderedSame && !$0.isFolder
        }) else { return }
        try engine.session.delete(handle: object.id)
    }

    /// Deletes the device copies of the given books and forgets them in the manifest, so the
    /// next plan sees them as absent rather than stale. `delete(filename:)` only ever matches
    /// non-folder entries, which is what keeps `.sdr` reading-progress sidecars safe.
    @discardableResult
    func remove(bookUUIDs: [String]) throws -> Int {
        let engine = try requireEngine()
        var manifest = try engine.loadManifest()
        var removed = 0
        for uuid in bookUUIDs {
            guard let entry = manifest.entries[uuid] else { continue }
            try delete(filename: entry.filename)
            manifest.entries[uuid] = nil
            removed += 1
        }
        if removed > 0 { try engine.saveManifest(manifest) }
        return removed
    }

    private func requireEngine() throws -> SyncEngine {
        if let engine { return engine }
        _ = try connect()
        guard let engine else { throw MTPError.deviceNotFound }
        return engine
    }
}
