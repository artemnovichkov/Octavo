import Foundation
import Testing
@testable import CalibreLibrary

/// Works on a throwaway copy of the real library — never touches the original.
private func makeLibraryCopy() throws -> URL? {
    let source = CalibreLibraryStore.defaultLocation.appending(path: "metadata.db")
    guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { return nil }
    let directory = URL.temporaryDirectory.appending(path: "octavo-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: directory.appending(path: "metadata.db"))
    return directory
}

/// An empty library built from the embedded schema — no calibre, no real library needed.
private func makeEmptyLibrary() -> URL {
    URL.temporaryDirectory.appending(path: "octavo-test-\(UUID().uuidString)")
}

/// The importer never parses the file, it only copies it and records its size, so any bytes do.
private func makeSampleFile(_ name: String) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "octavo-sample-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let file = url.appending(path: name)
    try Data("not-a-real-book".utf8).write(to: file)
    return file
}

@Test func titleSortMovesLeadingArticle() {
    #expect(CalibreFunctions.titleSort("The Hobbit") == "Hobbit, The")
    #expect(CalibreFunctions.titleSort("An Awesome Book") == "Awesome Book, An")
    #expect(CalibreFunctions.titleSort("Путь джедая") == "Путь джедая")
    #expect(CalibreFunctions.titleSort("Theory of Everything") == "Theory of Everything")
}

@Test func authorSortInvertsName() {
    #expect(CalibreFunctions.authorSort("Gergely Orosz") == "Orosz, Gergely")
    #expect(CalibreFunctions.authorSort("Unknown") == "Unknown")
    #expect(CalibreFunctions.authorSort(of: ["Rid Khastinghs", "Erin Mieiier"]) == "Khastinghs, Rid & Mieiier, Erin")
}

@Test func readsRealLibrary() throws {
    guard let library = try makeLibraryCopy() else { return }
    defer { try? FileManager.default.removeItem(at: library) }

    let store = try CalibreLibraryStore(root: library, readOnly: true)
    let books = try store.books()
    #expect(!books.isEmpty)
    #expect(books.allSatisfy { !$0.uuid.isEmpty })
    #expect(books.contains { !$0.formats.isEmpty })
    #expect(books.contains { $0.format("AZW3") != nil })
}

/// The whole point of the embedded schema: a usable library on a machine that has never
/// seen calibre. Covers both registered SQL functions and the insert triggers that call them.
@Test func createsLibraryFromScratch() throws {
    let library = makeEmptyLibrary()
    defer { try? FileManager.default.removeItem(at: library) }

    #expect(CalibreLibraryStore.isLibrary(at: library) == false)
    let store = try CalibreLibraryStore.create(at: library)
    #expect(CalibreLibraryStore.isLibrary(at: library))
    #expect(try store.books().isEmpty)

    // calibre identifies a library by this row, and reads the schema version to decide
    // whether it needs migrating — 26 is what calibre 8 writes itself.
    #expect(try store.database.query("SELECT uuid FROM library_id", [], { $0.string(0) }).count == 1)
    #expect(try store.database.query("PRAGMA user_version", [], { $0.int(0) }).first == 26)

    let sample = try makeSampleFile("sample.epub")
    defer { try? FileManager.default.removeItem(at: sample.deletingLastPathComponent()) }
    let added = try store.add(fileAt: sample, metadata: NewBook(title: "The Fresh Start", authors: ["Ada Lovelace"]))

    #expect(added.sort == "Fresh Start, The")  // title_sort(), via books_insert_trg
    #expect(added.uuid.isEmpty == false)       // uuid4(), same trigger
    #expect(added.format("EPUB") != nil)
    #expect(try store.books().count == 1)

    // Creating over an existing library must not clobber it.
    #expect(throws: CalibreError.self) { try CalibreLibraryStore.create(at: library) }
    #expect(try store.books().count == 1)
}

/// The books/series triggers call title_sort(); without our registered implementation
/// every write fails with "no such function".
@Test func writesThroughCalibreTriggers() throws {
    let library = makeEmptyLibrary()
    defer { try? FileManager.default.removeItem(at: library) }
    let sample = try makeSampleFile("seed.epub")
    defer { try? FileManager.default.removeItem(at: sample.deletingLastPathComponent()) }

    let store = try CalibreLibraryStore.create(at: library)
    var book = try store.add(fileAt: sample, metadata: NewBook(title: "Seed", authors: ["Someone"]))

    book.title = "The Octavo Test Title"
    book.authors = ["Ada Lovelace"]
    book.tags = ["octavo-test", "sync"]
    book.series = "The Octavo Series"
    book.seriesIndex = 3
    book.comments = "written by Octavo"
    book.identifiers = ["isbn": "9780000000001"]
    try store.update(book)

    let reloaded = try #require(try store.books().first { $0.id == book.id })
    #expect(reloaded.title == "The Octavo Test Title")
    #expect(reloaded.sort == "Octavo Test Title, The")  // computed by calibre's trigger
    #expect(reloaded.authors == ["Ada Lovelace"])
    #expect(reloaded.authorSort == "Lovelace, Ada")
    #expect(reloaded.tags.sorted() == ["octavo-test", "sync"])
    #expect(reloaded.series == "The Octavo Series")
    #expect(reloaded.seriesIndex == 3)
    #expect(reloaded.comments == "written by Octavo")
    #expect(reloaded.identifiers["isbn"] == "9780000000001")
}

@Test func importsBookFromFile() throws {
    let library = makeEmptyLibrary()
    defer { try? FileManager.default.removeItem(at: library) }
    let sample = try makeSampleFile("source.epub")
    defer { try? FileManager.default.removeItem(at: sample.deletingLastPathComponent()) }

    let store = try CalibreLibraryStore.create(at: library)
    let before = try store.books().count

    let added = try store.add(fileAt: sample, metadata: NewBook(
        title: "Полёт над гнездом",
        authors: ["Кен Кизи"],
        publisher: "Тест",
        tags: ["импорт", "тест"],
        series: "Проверка",
        seriesIndex: 2,
        cover: Data("not-a-real-jpeg".utf8)
    ))

    #expect(try store.books().count == before + 1)
    #expect(added.title == "Полёт над гнездом")
    #expect(added.authors == ["Кен Кизи"])
    #expect(added.authorSort == "Кизи, Кен")
    #expect(added.series == "Проверка")
    #expect(added.tags.sorted() == ["импорт", "тест"])
    #expect(added.format("EPUB") != nil)
    #expect(added.uuid.isEmpty == false)  // set by calibre's insert trigger

    // Folder layout has to match calibre's: <Author>/<Title> (<id>)/<Title> - <Author>.epub
    #expect(added.path == "Ken Kizi/Polet nad gnezdom (\(added.id))")
    let file = try #require(added.format("EPUB")).filename
    let fileURL = library.appending(path: added.path).appending(path: file)
    #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    #expect(try #require(added.format("EPUB")).size > 0)

    let opf = library.appending(path: added.path).appending(path: "metadata.opf")
    let opfText = try String(contentsOf: opf, encoding: .utf8)
    #expect(opfText.contains("<dc:title>Полёт над гнездом</dc:title>"))
    #expect(opfText.contains("calibre:series"))
    #expect(opfText.contains(added.uuid))

    // A second import of the same book must be recognised as a duplicate.
    #expect(try store.duplicate(ofTitle: "Полёт над гнездом", authors: ["Кен Кизи"])?.id == added.id)
}

@Test func addsSecondFormatToExistingBook() throws {
    let library = makeEmptyLibrary()
    defer { try? FileManager.default.removeItem(at: library) }
    let sample = try makeSampleFile("source.epub")
    defer { try? FileManager.default.removeItem(at: sample.deletingLastPathComponent()) }

    let store = try CalibreLibraryStore.create(at: library)
    let book = try store.add(fileAt: sample, metadata: NewBook(title: "Формат-тест", authors: ["Автор"]))
    let updated = try store.addFormat(fileAt: sample, to: book)

    #expect(updated.formats.count == 1)  // same EPUB format, replaced rather than duplicated
    #expect(updated.format("EPUB")?.size == book.format("EPUB")?.size)
}
