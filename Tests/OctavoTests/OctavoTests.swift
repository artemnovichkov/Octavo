import CalibreLibrary
import Foundation
import KindleFormat
import Testing
@testable import Octavo

/// `Filter.storageKey` is what "remember the last filter across launches" round-trips through
/// `Preferences.lastFilter` — a typo here would silently fall back to `.all` on every relaunch.
@Test func filterStorageKeyRoundTrips() {
    let filters: [AppModel.Filter] = [
        .all, .onDevice, .notOnDevice, .needsConversion,
        .author("Ursula K. Le Guin"), .series("Earthsea"), .tag("sci-fi"),
        .author("Путь: джедая"),
    ]
    for filter in filters {
        #expect(AppModel.Filter(storageKey: filter.storageKey) == filter)
    }
}

@Test func filterStorageKeyRejectsGarbage() {
    #expect(AppModel.Filter(storageKey: "") == nil)
    #expect(AppModel.Filter(storageKey: "nonsense") == nil)
    #expect(AppModel.Filter(storageKey: "author") == nil)
    #expect(AppModel.Filter(storageKey: "bogus:Name") == nil)
}

/// The way out for a library built before the cover parsers learned where else a cover hides:
/// a book imported without one gains it from its own file, without being re-added.
@MainActor
@Test func rescanFindsCoversTheImporterMissed() async throws {
    // Any corpus EPUB that does hold a cover will do — bail out where there is no library.
    guard let walker = FileManager.default.enumerator(
        at: URL.homeDirectory.appending(path: "Calibre Library"), includingPropertiesForKeys: nil
    ) else { return }
    let epubs = walker.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "epub" }
    guard let source = epubs.first(where: { EbookReader.metadata(of: $0).cover != nil }) else { return }

    let root = URL.temporaryDirectory.appending(path: "octavo-rescan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CalibreLibraryStore.create(at: root)
    // Imported the way the old reader would have: no cover recorded, file untouched.
    _ = try store.add(fileAt: source, metadata: NewBook(title: "Обложка потерялась", authors: ["Автор"]))

    let model = AppModel(libraryRoot: root)
    #expect(model.books.count == 1)
    #expect(model.books[0].hasCover == false)

    model.rescanCovers()
    await model.coverScanTask?.value

    #expect(model.books[0].hasCover)
    let cover = try #require(model.books[0].coverURL(in: root))
    #expect(try Data(contentsOf: cover).count > 0)
    #expect(model.coverScan == nil)
}

/// A book can hold an EPUB with no cover and an AZW3 with one, so one format is not enough
/// to call it coverless.
@Test func firstCoverTriesEveryFormat() {
    let missing = URL.temporaryDirectory.appending(path: "octavo-missing-\(UUID().uuidString).epub")
    #expect(AppModel.firstCover(in: [missing]) == nil)
    #expect(AppModel.firstCover(in: []) == nil)
}
