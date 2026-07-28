import AppKit
import CalibreLibrary
import Foundation
import KindleFormat
import MTPKit
import Observation
import SyncEngine

@MainActor
@Observable
final class AppModel {
    enum Filter: Hashable {
        case all
        case onDevice
        case notOnDevice
        case needsConversion
        case author(String)
        case series(String)
        case tag(String)

        var title: String {
            switch self {
            case .all: return "All books"
            case .onDevice: return "On device"
            case .notOnDevice: return "Not on device"
            case .needsConversion: return "Converted"
            case .author(let name), .series(let name), .tag(let name): return name
            }
        }

        /// Round-trips through `Preferences.lastFilter` so "remember the last filter" survives
        /// a relaunch. Facet filters are prefixed by kind since the name alone is ambiguous.
        var storageKey: String {
            switch self {
            case .all: return "all"
            case .onDevice: return "onDevice"
            case .notOnDevice: return "notOnDevice"
            case .needsConversion: return "needsConversion"
            case .author(let name): return "author:\(name)"
            case .series(let name): return "series:\(name)"
            case .tag(let name): return "tag:\(name)"
            }
        }

        init?(storageKey: String) {
            switch storageKey {
            case "all": self = .all
            case "onDevice": self = .onDevice
            case "notOnDevice": self = .notOnDevice
            case "needsConversion": self = .needsConversion
            default:
                guard let separator = storageKey.firstIndex(of: ":") else { return nil }
                let kind = storageKey[..<separator]
                let name = String(storageKey[storageKey.index(after: separator)...])
                switch kind {
                case "author": self = .author(name)
                case "series": self = .series(name)
                case "tag": self = .tag(name)
                default: return nil
                }
            }
        }
    }

    /// `needsSetup` is what tells "no library chosen yet" apart from "the library is broken":
    /// the first wants an offer to create one, the second an error and a retry.
    enum LibraryState {
        case needsSetup
        case loaded
        case failed(String)
    }

    struct SyncProgress: Sendable {
        var current: String
        var index: Int
        var total: Int
    }

    /// A sidebar facet row: a name (author/series/tag) plus how many books carry it.
    struct Facet: Identifiable, Hashable {
        let name: String
        let count: Int
        var id: String { name }
    }

    /// Device-derived counts for the sidebar's smart filters. `nil` (rather than all-zero) is
    /// what lets the sidebar tell "no Kindle connected" apart from "Kindle connected, 0 books".
    struct PlanCounts: Equatable {
        var onDevice: Int
        var notOnDevice: Int
        var needsConversion: Int
    }

    private(set) var books: [Book] = []
    private(set) var libraryState: LibraryState = .needsSetup
    private(set) var deviceState: DeviceController.State = .disconnected
    private(set) var plan: SyncPlan?
    /// Precomputed from `plan`. The table asks for a status once per row per redraw, which
    /// was three linear scans over the plan before this existed.
    private(set) var statuses: [Book.ID: BookStatus] = [:]
    /// Precomputed from `plan`, alongside `statuses`. `nil` while there is no plan, so the
    /// sidebar can show "unknown" rather than a false zero.
    private(set) var planCounts: PlanCounts?
    private(set) var syncProgress: SyncProgress?
    private(set) var isCancellingSync = false
    var lastSyncSummary: String?
    var importSummary: ImportSummary?
    /// A library the user picked that turned out not to be one. Transient, because the library
    /// they already had is untouched — the pick simply did not happen.
    var libraryAlert: String?

    /// The book being edited in `MetadataEditor`. Lives here rather than as view-local `@State`
    /// so both the table's context menu and Library ▸ Edit Metadata… drive the same sheet.
    var editingBook: Book?
    /// Books queued for the device-removal confirmation dialog; empty means the dialog is
    /// dismissed. Set directly by `requestRemoval` when confirmation is off.
    var pendingRemoval: [Book] = []
    /// Drives `ContentView`'s `.fileImporter`, from both the toolbar's Add button and
    /// File ▸ Add Books….
    var isImportingFiles = false
    /// Bumped to ask the search field to take focus (Edit ▸ Find). A counter rather than a
    /// bool so two Finds in a row without an intervening blur still refocus.
    var searchFocusRequests = 0

    var filter: Filter = .all {
        didSet {
            guard Preferences.shared.rememberLastFilter else { return }
            Preferences.shared.lastFilter = filter.storageKey
        }
    }
    var search: String = ""
    var selection: Set<Book.ID> = []
    var sortOrder: [KeyPathComparator<Book>] = [KeyPathComparator(\.sort)]

    /// Precomputed from `books` by `rebuildFacets()`, rather than recomputed on every access —
    /// `authors`/`series`/`tags` used to rebuild a `Set` and sort it once per redraw.
    private(set) var authorFacets: [Facet] = []
    private(set) var seriesFacets: [Facet] = []
    private(set) var tagFacets: [Facet] = []

    /// The library currently open, or the one that would be created while `needsSetup` — never
    /// read by the book views in that state, because there are no books to draw.
    private(set) var libraryRoot: URL
    private let device: DeviceController
    var store: CalibreLibraryStore?

    /// The device half needs the library too — it diffs against it — so connecting without one
    /// would report a *library* error in the device toolbar, where `.failed` is supposed to mean
    /// something the user can act on about the Kindle. Remember the Kindle is there instead, and
    /// connect once a library exists.
    private var deviceAttached = false
    private var hasLibrary: Bool { store != nil }

    /// Bumped on every detach. Async work started before a detach compares against it and
    /// bows out rather than overwriting the disconnected state with a stale error.
    private var deviceEpoch = 0
    private var connectTask: Task<Void, Never>?
    private var mtpDeadline: Task<Void, Never>?
    private var syncCancellation: CancellationFlag?
    /// Identifies the current sync so progress callbacks from an abandoned one cannot
    /// resurrect the progress overlay after it has been cleared.
    private var syncRun = 0
    /// Set once a backup has run for the current connection, so "back up before first sync"
    /// backs up once per plug-in rather than before every sync. Reset on detach.
    private var hasBackedUpThisSession = false

    /// `nil` means "resolve it": the remembered library, else calibre's own if it happens to be
    /// there, else nothing at all — which is the welcome screen, and writes nothing until the
    /// user chooses.
    init(libraryRoot: URL? = nil) {
        let resolved = libraryRoot ?? LibraryLocation.resolve()
        let root = resolved ?? LibraryLocation.suggested
        self.libraryRoot = root
        self.device = DeviceController(libraryRoot: root)
        if Preferences.shared.rememberLastFilter, let restored = Filter(storageKey: Preferences.shared.lastFilter) {
            filter = restored
        }
        if resolved != nil { loadLibrary() }
    }

    // MARK: - Library

    func loadLibrary() {
        do {
            let store = try CalibreLibraryStore(root: libraryRoot)
            self.store = store
            books = try store.books()
            libraryState = .loaded
        } catch {
            store = nil
            libraryState = .failed(error.localizedDescription)
            books = []
        }
        rebuildFacets()
    }

    /// Lays down a fresh calibre-format library — the path for someone who has never run calibre.
    func createLibrary(at url: URL) {
        do {
            // An existing library at the chosen spot is opened rather than refused: the user
            // asked to end up with a library there, and they now have one.
            if !CalibreLibraryStore.isLibrary(at: url) {
                try CalibreLibraryStore.create(at: url)
            }
            switchLibrary(to: url)
        } catch {
            // An alert, not `.failed`: a library that is already open stays open and usable.
            libraryAlert = error.localizedDescription
        }
    }

    func openLibrary(at url: URL) {
        guard CalibreLibraryStore.isLibrary(at: url) else {
            libraryAlert = """
                \(CalibreError.libraryNotFound(url).localizedDescription).
                A library is the folder holding metadata.db.
                """
            return
        }
        switchLibrary(to: url)
    }

    /// Everything derived from the old library has to go before the new one loads — the plan and
    /// the covers are keyed by book, and books do not survive the switch.
    private func switchLibrary(to url: URL) {
        libraryRoot = url
        LibraryLocation.remember(url)
        selection = []
        filter = .all
        setPlan(nil)
        CoverCache.shared.removeAll()
        loadLibrary()

        Task {
            await device.setLibraryRoot(url)
            // The session went with the old library. Reconnecting here is also what picks up a
            // Kindle that was plugged in while there was no library to diff it against.
            if deviceAttached { await connect() }
        }
    }

    /// Single pass over `books` feeding all three sidebar facet lists, sorted with
    /// `localizedStandardCompare` so Cyrillic and Latin names interleave sensibly rather than
    /// by raw codepoint.
    private func rebuildFacets() {
        func tally<S: Sequence>(_ keys: (Book) -> S) -> [Facet] where S.Element == String {
            var counts: [String: Int] = [:]
            for book in books {
                for key in keys(book) { counts[key, default: 0] += 1 }
            }
            return counts.map { Facet(name: $0.key, count: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        authorFacets = tally(\.authors)
        seriesFacets = tally { $0.series.map { [$0] } ?? [] }
        tagFacets = tally(\.tags)
    }

    var filteredBooks: [Book] {
        let sentFilenames = Set((plan?.upToDate ?? []).map(\.id))
        let converting = Set((plan?.send ?? []).filter(\.needsConversion).map(\.book.id))

        let matches = books.filter { book in
            switch filter {
            case .all: break
            case .onDevice: guard sentFilenames.contains(book.id) else { return false }
            case .notOnDevice: guard !sentFilenames.contains(book.id) else { return false }
            case .needsConversion: guard converting.contains(book.id) else { return false }
            case .author(let name): guard book.authors.contains(name) else { return false }
            case .series(let name): guard book.series == name else { return false }
            case .tag(let name): guard book.tags.contains(name) else { return false }
            }

            guard !search.isEmpty else { return true }
            let needle = search.lowercased()
            return book.title.lowercased().contains(needle)
                || book.authorDisplay.lowercased().contains(needle)
                || (book.series?.lowercased().contains(needle) ?? false)
                || book.tags.contains { $0.lowercased().contains(needle) }
        }
        return sortOrder.isEmpty ? matches : matches.sorted(using: sortOrder)
    }

    func status(of book: Book) -> BookStatus {
        statuses[book.id] ?? .unknown
    }

    /// Single source of truth for `plan` so the status lookup table never drifts from it.
    private func setPlan(_ newPlan: SyncPlan?) {
        plan = newPlan
        guard let newPlan else {
            statuses = [:]
            planCounts = nil
            return
        }
        var table: [Book.ID: BookStatus] = [:]
        for book in newPlan.upToDate { table[book.id] = .synced }
        for item in newPlan.send { table[item.book.id] = item.needsConversion ? .willConvert : .pending }
        for book in newPlan.unsupported { table[book.id] = .unsupported }
        statuses = table
        planCounts = PlanCounts(
            onDevice: newPlan.upToDate.count,
            notOnDevice: newPlan.send.count,
            needsConversion: newPlan.send.filter(\.needsConversion).count
        )
    }

    func save(_ book: Book) {
        guard let store else { return }
        do {
            try store.update(book)
            loadLibrary()
        } catch {
            libraryState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Device

    /// Consumes IOKit hotplug notifications for as long as the caller's task lives. The
    /// watcher's initial drain reports an already-connected Kindle, so this is also what
    /// connects on launch — there is no separate startup path.
    func watchDevice() async {
        for await event in USBWatcher.events() {
            switch event {
            case .deviceAttached: deviceAppeared()
            case .mtpReady: mtpBecameReady()
            case .detached: await handleDetach()
            }
        }
    }

    private func deviceAppeared() {
        deviceAttached = true
        guard hasLibrary, !isConnected else { return }
        deviceState = .connecting
        // A Kindle that is charge-only or locked publishes no MTP interface at all, so
        // .mtpReady may never arrive. Fall back rather than spin forever on "Connecting…".
        mtpDeadline?.cancel()
        mtpDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.mtpDeadlineExpired()
        }
    }

    private func mtpDeadlineExpired() {
        guard case .connecting = deviceState else { return }
        // One last look, in case the interface appeared without a notification reaching us.
        let hasMTP = USBDiscovery.devices()
            .filter(\.isKindle)
            .contains { $0.interfaces.contains(where: \.looksLikeMTP) }
        if hasMTP {
            mtpBecameReady()
        } else {
            deviceState = .waitingForMTP
        }
    }

    private func mtpBecameReady() {
        deviceAttached = true
        mtpDeadline?.cancel()
        mtpDeadline = nil
        guard hasLibrary, !isConnected else { return }
        deviceState = .connecting

        // Cancel-and-replace rather than a debounce timer: kIOMatchedNotification can
        // legitimately fire more than once, and a duplicate then costs one cheap snapshot.
        connectTask?.cancel()
        connectTask = Task { [weak self] in await self?.attemptConnect() }
    }

    /// "Matched" means the drivers started, not that the responder answers yet, so the
    /// first attempt waits a beat and a couple of retries cover a slow device.
    private func attemptConnect() async {
        let epoch = deviceEpoch
        let delays: [Duration] = [.milliseconds(250), .milliseconds(750), .milliseconds(1500)]

        for (attempt, delay) in delays.enumerated() {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, epoch == deviceEpoch else { return }

            do {
                let snapshot = try await device.connect()
                guard epoch == deviceEpoch else { return }
                deviceState = .connected(snapshot)
                await refreshPlan()
                await autoSyncIfEnabled(epoch: epoch)
                return
            } catch {
                guard epoch == deviceEpoch else { return }
                // Another process holds the interface. Retrying cannot help and the message
                // names the culprit, so surface it at once.
                if case MTPError.interfaceBusy = error {
                    deviceState = .failed(error.localizedDescription)
                    return
                }
                if attempt == delays.count - 1 {
                    deviceState = Self.meansMTPNotUp(error)
                        ? .waitingForMTP
                        : .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Errors that mean "the Kindle simply is not offering MTP yet" rather than a fault.
    private static func meansMTPNotUp(_ error: Error) -> Bool {
        switch error {
        case MTPError.deviceNotFound, MTPError.noMTPInterface, MTPError.endpointsNotFound: return true
        default: return false
        }
    }

    private func handleDetach() async {
        deviceAttached = false
        deviceEpoch += 1
        hasBackedUpThisSession = false
        mtpDeadline?.cancel()
        mtpDeadline = nil
        connectTask?.cancel()
        connectTask = nil
        syncCancellation?.cancel()

        // Written before the await: the actor can be blocked inside a synchronous execute()
        // for tens of seconds, and the toolbar must not keep claiming to be connected.
        let wasSyncing = syncProgress != nil
        deviceState = .disconnected
        setPlan(nil)
        syncProgress = nil
        isCancellingSync = false
        if wasSyncing { lastSyncSummary = "Sync interrupted — Kindle disconnected" }

        await device.disconnect()
    }

    var isConnected: Bool {
        if case .connected = deviceState { return true }
        return false
    }

    /// Refresh (a Kindle already connected) or connect (one that isn't) — one action for the
    /// toolbar button and the status popover's retry, which both mean "the user asked, so a
    /// failure here is a real error" rather than the watcher's quieter `.waitingForMTP`.
    func refreshOrConnect() async {
        loadLibrary()
        if isConnected {
            await refreshPlan()
        } else {
            await connect()
        }
    }

    /// A connect the user asked for. Unlike the watcher path this reports a real error when
    /// it fails, because someone is waiting on an answer.
    func connect() async {
        guard hasLibrary else { return }
        let epoch = deviceEpoch
        deviceState = .connecting
        do {
            let snapshot = try await device.connect()
            guard epoch == deviceEpoch else { return }
            deviceState = .connected(snapshot)
            await refreshPlan()
            await autoSyncIfEnabled(epoch: epoch)
        } catch {
            guard epoch == deviceEpoch else { return }
            deviceState = .failed(error.localizedDescription)
        }
    }

    /// Fires a sync right after a connect, when the user has asked for that in Settings ▸ Sync
    /// and there is actually something to send — an empty plan would just flash the overlay.
    private func autoSyncIfEnabled(epoch: Int) async {
        guard epoch == deviceEpoch, Preferences.shared.autoSyncOnConnect else { return }
        guard let plan, !plan.isEmpty else { return }
        await sync()
    }

    func disconnect() async {
        await handleDetach()
    }

    func refreshPlan() async {
        guard isConnected else { return }
        let epoch = deviceEpoch
        do {
            let fresh = try await device.plan(books: books, target: Preferences.shared.conversionTarget)
            guard epoch == deviceEpoch else { return }
            setPlan(fresh)
        } catch {
            guard epoch == deviceEpoch else { return }
            deviceState = .failed(error.localizedDescription)
        }
    }

    func cancelSync() {
        guard syncProgress != nil else { return }
        syncCancellation?.cancel()
        isCancellingSync = true
    }

    func sync() async {
        guard isConnected, syncProgress == nil else { return }
        let epoch = deviceEpoch
        syncRun += 1
        let run = syncRun
        let flag = CancellationFlag()
        syncCancellation = flag
        isCancellingSync = false

        let books = self.books
        syncProgress = SyncProgress(current: "Preparing…", index: 0, total: plan?.send.count ?? 0)
        defer {
            syncProgress = nil
            syncCancellation = nil
            isCancellingSync = false
        }

        if Preferences.shared.backupBeforeFirstSync, !hasBackedUpThisSession {
            do {
                try await device.backupDocuments(to: Preferences.shared.backupDirectory) { [weak self] name, index, total in
                    Task { @MainActor in
                        guard let self, self.syncRun == run else { return }
                        self.syncProgress = SyncProgress(current: "Backing up \(name)", index: index, total: total)
                    }
                }
                guard epoch == deviceEpoch else { return }
                hasBackedUpThisSession = true
            } catch {
                // The whole point of a backup is to have one before writing anything, so a
                // failure here ends the sync rather than proceeding without it.
                guard epoch == deviceEpoch else { return }
                deviceState = .failed(error.localizedDescription)
                return
            }
        }

        do {
            let done = try await device.sync(
                books: books,
                target: Preferences.shared.conversionTarget,
                pruneCache: Preferences.shared.pruneCacheAfterSync,
                shouldStop: { flag.isCancelled }
            ) { [weak self] progress in
                Task { @MainActor in
                    // Progress hops are enqueued, not awaited, so one can land after this
                    // run has already finished and strand the overlay. Drop those.
                    guard let self, self.syncRun == run else { return }
                    self.syncProgress = SyncProgress(
                        current: progress.item.filename,
                        index: progress.index,
                        total: progress.total
                    )
                }
            }
            guard epoch == deviceEpoch else { return }
            lastSyncSummary = flag.isCancelled
                ? "Sync cancelled"
                : (done.send.isEmpty ? "Everything was up to date" : "Books sent: \(done.send.count)")
            deviceState = .connected(try await device.snapshot())
            await refreshPlan()
        } catch {
            guard epoch == deviceEpoch else { return }
            deviceState = .failed(error.localizedDescription)
        }
    }

    /// Removes a book's file from the device. `.sdr` folders — reading progress, highlights —
    /// are never touched.
    func removeFromDevice(_ books: [Book]) async {
        guard isConnected, !books.isEmpty else { return }
        let epoch = deviceEpoch
        do {
            let removed = try await device.remove(bookUUIDs: books.map(\.uuid))
            guard epoch == deviceEpoch else { return }
            lastSyncSummary = removed > 0
                ? "Removed from device: \(removed)"
                : "Those books were not on the device"
            await refreshPlan()
        } catch {
            guard epoch == deviceEpoch else { return }
            deviceState = .failed(error.localizedDescription)
        }
    }

    /// Queues the device-removal confirmation, or skips straight to it when the user has
    /// turned that dialog off in Settings ▸ General.
    func requestRemoval(_ books: [Book]) {
        guard !books.isEmpty else { return }
        if Preferences.shared.confirmDeviceRemoval {
            pendingRemoval = books
        } else {
            Task { await removeFromDevice(books) }
        }
    }

    /// The current table selection resolved against `books` — what the Library and Device
    /// menus act on, same as the table's own context menu.
    var selectedBooks: [Book] {
        books.filter { selection.contains($0.id) }
    }

    func revealInFinder(_ books: [Book]) {
        let urls = books.map { libraryRoot.appending(path: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Pulls documents/ down to `Preferences.shared.backupDirectory`, reported through the same
    /// overlay a sync uses. Device ▸ Back Up Device… — separate from the "back up before first
    /// sync" setting, which runs the same call from inside `sync()` instead.
    func backUpDevice() async {
        guard isConnected, syncProgress == nil else { return }
        let epoch = deviceEpoch
        syncRun += 1
        let run = syncRun
        let directory = Preferences.shared.backupDirectory
        syncProgress = SyncProgress(current: "Preparing…", index: 0, total: 0)
        defer { syncProgress = nil }

        do {
            try await device.backupDocuments(to: directory) { [weak self] name, index, total in
                Task { @MainActor in
                    guard let self, self.syncRun == run else { return }
                    self.syncProgress = SyncProgress(current: name, index: index, total: total)
                }
            }
            guard epoch == deviceEpoch else { return }
            hasBackedUpThisSession = true
            lastSyncSummary = "Backed up to \(directory.path(percentEncoded: false))"
        } catch {
            guard epoch == deviceEpoch else { return }
            deviceState = .failed(error.localizedDescription)
        }
    }
}

enum BookStatus {
    case synced
    case pending
    case willConvert
    case unsupported
    case unknown

    var symbol: String {
        switch self {
        case .synced: return "checkmark.circle.fill"
        case .pending: return "arrow.up.circle"
        case .willConvert: return "wand.and.sparkles"
        case .unsupported: return "exclamationmark.triangle"
        case .unknown: return "circle.dotted"
        }
    }

    var help: String {
        switch self {
        case .synced: return "On device"
        case .pending: return "Will be sent"
        case .willConvert: return "Will be converted and sent"
        case .unsupported: return "The Kindle cannot open this format and it cannot be converted"
        case .unknown: return "Device not connected"
        }
    }
}

// MARK: - Import

extension AppModel {
    struct ImportSummary: Sendable {
        var added: [String] = []
        var formatsAdded: [String] = []
        var duplicates: [String] = []
        var failures: [String] = []

        var isEmpty: Bool {
            added.isEmpty && formatsAdded.isEmpty && duplicates.isEmpty && failures.isEmpty
        }

        var message: String {
            var lines: [String] = []
            if !added.isEmpty { lines.append("Added: \(added.count)") }
            if !formatsAdded.isEmpty { lines.append("Formats added to existing books: \(formatsAdded.count)") }
            if !duplicates.isEmpty {
                lines.append("Already in the library: \(duplicates.count)\n  " + duplicates.prefix(5).joined(separator: "\n  "))
            }
            if !failures.isEmpty {
                lines.append("Failed: \(failures.count)\n  " + failures.prefix(5).joined(separator: "\n  "))
            }
            return lines.joined(separator: "\n")
        }
    }

    static let importableExtensions = ["epub", "azw3", "azw", "mobi", "prc", "pdf", "cbz", "fb2", "txt"]

    /// Reads metadata out of each file, then files it into the calibre library.
    /// A book that is already there gains the new format instead of a second entry.
    func importFiles(_ urls: [URL]) {
        guard let store else { return }
        var summary = ImportSummary()

        for url in urls where Self.importableExtensions.contains(url.pathExtension.lowercased()) {
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            let metadata = EbookReader.metadata(of: url)
            let newBook = NewBook(
                title: metadata.title,
                authors: metadata.authors,
                publisher: metadata.publisher,
                published: metadata.published,
                comments: metadata.comments,
                isbn: metadata.isbn,
                tags: metadata.tags,
                series: metadata.series,
                seriesIndex: metadata.seriesIndex ?? 1,
                cover: metadata.cover
            )

            do {
                let format = url.pathExtension.uppercased()
                if let existing = try store.duplicate(ofTitle: newBook.title, authors: newBook.authors) {
                    if existing.format(format) == nil {
                        _ = try store.addFormat(fileAt: url, to: existing)
                        summary.formatsAdded.append("\(existing.title) (+\(format))")
                    } else {
                        summary.duplicates.append(existing.title)
                    }
                } else {
                    let book = try store.add(fileAt: url, metadata: newBook)
                    summary.added.append(book.title)
                }
            } catch {
                summary.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        importSummary = summary
        loadLibrary()
        Task { await refreshPlan() }
    }
}
