import CalibreLibrary
import Foundation
import KindleFormat
import Testing
@testable import MTPKit
@testable import SyncEngine

/// The "send only what I picked" path, end to end, against `FakeKindle` — no cable, no Kindle.
/// It is the half of a sync that has nothing to do with USB: scope the plan to a selection,
/// upload exactly those files, record exactly those in the manifest.

private func makeLibrary() throws -> (CalibreLibraryStore, URL) {
    let root = URL.temporaryDirectory.appending(path: "octavo-selection-\(UUID().uuidString)")
    return (try CalibreLibraryStore.create(at: root), root)
}

/// `add(fileAt:)` never parses what it imports, so a few bytes named .azw3 is a valid book —
/// and .azw3 is already Kindle-readable, which keeps conversion out of these tests.
private func makeSource(_ name: String) throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "octavo-src-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try Data("a book's worth of bytes: \(name)".utf8).write(to: url)
    return url
}

private func makeEngine(books titles: [String]) throws -> (SyncEngine, FakeKindle, [Book], URL) {
    let (store, root) = try makeLibrary()
    var books: [Book] = []
    for title in titles {
        let source = try makeSource("\(title).azw3")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        books.append(try store.add(fileAt: source, metadata: NewBook(title: title, authors: ["Автор"])))
    }
    let kindle = FakeKindle()
    let engine = try SyncEngine(library: store, session: kindle)
    return (engine, kindle, books, root)
}

private func sentBooks(_ kindle: FakeKindle) -> [String] {
    kindle.sentFilenames.filter { $0 != DeviceManifest.filename }
}

@Test func planWithoutSelectionSendsEverything() throws {
    let (engine, _, books, root) = try makeEngine(books: ["One", "Two", "Three"])
    defer { try? FileManager.default.removeItem(at: root) }

    let plan = try engine.plan(books: books, manifest: DeviceManifest())
    #expect(plan.send.count == 3)
}

/// The Reddit report: picking ten books and getting the whole library. A scoped plan must
/// contain the selection and nothing else, however many books the library holds.
@Test func planScopedToSelectionSendsOnlyThose() throws {
    let (engine, _, books, root) = try makeEngine(books: ["One", "Two", "Three", "Four"])
    defer { try? FileManager.default.removeItem(at: root) }

    let chosen: Set<Book.ID> = [books[1].id, books[3].id]
    let plan = try engine.plan(books: books, manifest: DeviceManifest(), only: chosen)

    #expect(plan.send.count == 2)
    #expect(Set(plan.send.map(\.book.id)) == chosen)
}

@Test func executingAScopedPlanUploadsOnlyTheSelection() throws {
    let (engine, kindle, books, root) = try makeEngine(books: ["One", "Two", "Three", "Four"])
    defer { try? FileManager.default.removeItem(at: root) }

    let chosen: Set<Book.ID> = [books[0].id, books[2].id]
    let plan = try engine.plan(books: books, manifest: DeviceManifest(), only: chosen)
    let manifest = try engine.execute(plan, manifest: DeviceManifest())

    #expect(sentBooks(kindle).count == 2)
    #expect(Set(manifest.entries.keys) == Set([books[0].uuid, books[2].uuid]))

    // And the unselected books are still waiting afterwards, rather than quietly marked done.
    let next = try engine.plan(books: books, manifest: try engine.loadManifest())
    #expect(Set(next.send.map(\.book.id)) == Set([books[1].id, books[3].id]))
    #expect(next.upToDate.count == 2)
}

/// A selection whose books are all already on the device sends nothing at all. The toolbar
/// reads this as "the selection has nothing to send" and falls back to the whole library;
/// the engine itself must never widen the scope on its own.
@Test func scopedPlanOfSyncedBooksIsEmpty() throws {
    let (engine, kindle, books, root) = try makeEngine(books: ["One", "Two", "Three"])
    defer { try? FileManager.default.removeItem(at: root) }

    let chosen: Set<Book.ID> = [books[0].id]
    let first = try engine.plan(books: books, manifest: DeviceManifest(), only: chosen)
    let manifest = try engine.execute(first, manifest: DeviceManifest())
    kindle.sentFilenames.removeAll()

    let again = try engine.plan(books: books, manifest: manifest, only: chosen)
    #expect(again.send.isEmpty)
    _ = try engine.execute(again, manifest: manifest)
    #expect(sentBooks(kindle).isEmpty)
}

/// Scoping narrows the send list only. Orphan detection still answers for the whole library,
/// or every book outside the selection would look like a stray file.
@Test func scopedPlanDoesNotTurnUnselectedBooksIntoOrphans() throws {
    let (engine, kindle, books, root) = try makeEngine(books: ["One", "Two", "Three"])
    defer { try? FileManager.default.removeItem(at: root) }

    let everything = try engine.plan(books: books, manifest: DeviceManifest())
    let manifest = try engine.execute(everything, manifest: DeviceManifest())
    kindle.place("someone-elses-book.azw3")

    let scoped = try engine.plan(books: books, manifest: manifest, only: [books[0].id])
    #expect(scoped.orphans.map(\.filename) == ["someone-elses-book.azw3"])
}

/// Cancelling keeps what was already uploaded and leaves the rest pending. `shouldStop` is
/// polled again after the conversion step, so the book that was in flight when the user hit
/// Cancel is not uploaded — it is simply still pending next time.
@Test func cancellingMidRunKeepsWhatWasSent() throws {
    let (engine, kindle, books, root) = try makeEngine(books: ["One", "Two", "Three"])
    defer { try? FileManager.default.removeItem(at: root) }

    let plan = try engine.plan(books: books, manifest: DeviceManifest())
    // Trailing-closure position binds to `onProgress`, so `shouldStop` is named.
    let manifest = try engine.execute(plan, manifest: DeviceManifest(), shouldStop: {
        sentBooks(kindle).count >= 1
    })
    #expect(sentBooks(kindle).count == 1)
    #expect(manifest.entries.count == 1)

    let next = try engine.plan(books: books, manifest: manifest)
    #expect(next.send.count == 2)
}

/// `.bin` in documents/ is what the Kindle treats as a firmware image. A plan that would
/// write one is refused before any upload happens.
@Test func refusesToWriteABinFile() throws {
    let (engine, kindle, books, root) = try makeEngine(books: ["One"])
    defer { try? FileManager.default.removeItem(at: root) }

    var plan = try engine.plan(books: books, manifest: DeviceManifest())
    let item = plan.send[0]
    plan.send = [SendItem(book: item.book, format: item.format, filename: "update.bin", reason: .new)]

    #expect(throws: SyncError.self) {
        try engine.execute(plan, manifest: DeviceManifest())
    }
    #expect(sentBooks(kindle).isEmpty)
}
