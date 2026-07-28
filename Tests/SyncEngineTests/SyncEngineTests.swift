import CalibreLibrary
import Foundation
import KindleFormat
import Testing
@testable import MTPKit
@testable import SyncEngine

private let sent = Date(timeIntervalSince1970: 1_700_000_000)

private func makeBook(lastModified: Date = sent, formats: [BookFormat]) -> Book {
    Book(
        id: 1, uuid: "u-1", title: "Ремесло", sort: "Ремесло",
        authors: ["Сергей Довлатов"], authorSort: "Довлатов, Сергей",
        lastModified: lastModified, path: "Dovlatov/Riemieslo (18)", formats: formats
    )
}

private func makeObject(size: UInt64, name: String) -> MTPObject {
    MTPObject(id: 42, storageID: 1, parentID: 2, format: 0x3000, size: size, filename: name, modified: nil)
}

@Test func adoptsCalibreManifest() throws {
    let json = """
    [{"uuid": "u-1", "lpath": "documents/riemieslo - sierghiei dovaltov.azw3", "size": 591233,
      "last_modified": "2025-12-04T18:11:43.847151+00:00"},
     {"uuid": null, "lpath": "readme.md", "size": 10},
     {"uuid": "u-2", "lpath": "documents/sub/deep.azw3", "size": 5}]
    """
    let manifest = DeviceManifest.adoptingCalibreManifest(Array(json.utf8))
    #expect(manifest.adoptedFromCalibre)
    #expect(manifest.entries.count == 1)  // no uuid, or not a flat documents/ file
    let entry = try #require(manifest.entries["u-1"])
    #expect(entry.filename == "riemieslo - sierghiei dovaltov.azw3")
    #expect(entry.deviceSize == 591233)
    #expect(entry.sourceSize == nil)
    #expect(entry.sourceModified != nil)
}

/// calibre rewrites metadata during transfer, so its device copies differ from the
/// library file by a few bytes. Adopted entries must not be re-sent because of that.
@Test func adoptedEntryIsNotStaleDespiteSizeDrift() {
    let book = makeBook(formats: [BookFormat(format: "AZW3", name: "Riemieslo", size: 591_231)])
    let entry = DeviceManifest.Entry(
        filename: "riemieslo.azw3", deviceSize: 591_233,
        sourceModified: book.lastModified, format: "AZW3", sentAt: .distantPast
    )
    #expect(!SyncEngine.isStale(
        entry: entry, deviceObject: makeObject(size: 591_233, name: "riemieslo.azw3"),
        book: book, format: book.formats[0]
    ))
}

@Test func detectsReplacedFileOnDevice() {
    let book = makeBook(formats: [BookFormat(format: "AZW3", name: "R", size: 100)])
    let entry = DeviceManifest.Entry(
        filename: "r.azw3", deviceSize: 100, sourceSize: 100,
        sourceModified: book.lastModified, format: "AZW3", sentAt: sent
    )
    #expect(SyncEngine.isStale(
        entry: entry, deviceObject: makeObject(size: 250, name: "r.azw3"),
        book: book, format: book.formats[0]
    ))
}

@Test func detectsEditedMetadataAndChangedFile() {
    let format = BookFormat(format: "AZW3", name: "R", size: 100)
    let entry = DeviceManifest.Entry(
        filename: "r.azw3", deviceSize: 100, sourceSize: 100,
        sourceModified: sent, format: "AZW3", sentAt: sent
    )
    let edited = makeBook(lastModified: sent.addingTimeInterval(3600), formats: [format])
    #expect(SyncEngine.isStale(
        entry: entry, deviceObject: makeObject(size: 100, name: "r.azw3"), book: edited, format: format
    ))

    let grown = BookFormat(format: "AZW3", name: "R", size: 900)
    #expect(SyncEngine.isStale(
        entry: entry, deviceObject: makeObject(size: 100, name: "r.azw3"),
        book: makeBook(formats: [grown]), format: grown
    ))
}

@Test func transliteratesFilenamesToASCII() {
    // ICU's transliteration, not calibre's table — names differ from calibre's for new
    // files, which is fine: books already on the device are matched via the manifest.
    #expect(SyncEngine.asciiSanitized("Путь джедая") == "Put' dzedaa")
    #expect(SyncEngine.asciiSanitized("Сергей Довлатов") == "Sergej Dovlatov")
    #expect(SyncEngine.asciiSanitized("A/B: C?") == "A B C")
    // Whatever the script, the result must be plain ASCII and non-empty.
    let japanese = SyncEngine.asciiSanitized("日本語")
    #expect(!japanese.isEmpty)
    #expect(japanese.unicodeScalars.allSatisfy { $0.isASCII })
}

/// Switching the conversion target is the one change none of the staleness signals notice: the
/// device file is byte-for-byte what we recorded, the library file has not moved, and nothing
/// was edited. Without this check a book synced as MOBI would stay MOBI forever.
@Test func retargetIsDetectedFromTheDeviceExtension() {
    let entry = DeviceManifest.Entry(
        filename: "riemieslo - sierghiei dovlatov.mobi", deviceSize: 1000,
        sourceSize: 900, sourceModified: sent, format: "EPUB", sentAt: sent
    )

    #expect(SyncEngine.needsRetarget(entry: entry, target: .azw3))
    #expect(!SyncEngine.needsRetarget(entry: entry, target: .mobi))
    // A book sent as-is is never retargeted, whatever the setting says.
    #expect(!SyncEngine.needsRetarget(entry: entry, target: nil))
}

@Test func convertedFilenameCarriesTheTargetExtension() throws {
    let book = makeBook(formats: [BookFormat(format: "EPUB", name: "Riemieslo", size: 900)])
    let epub = try #require(book.format("EPUB"))

    #expect(SyncEngine.targetFilename(for: book, format: epub, convertedTo: .azw3).hasSuffix(".azw3"))
    #expect(SyncEngine.targetFilename(for: book, format: epub, convertedTo: .mobi).hasSuffix(".mobi"))
    // Not converted: the library format's own extension, unchanged by the setting.
    #expect(SyncEngine.targetFilename(for: book, format: epub).hasSuffix(".epub"))
}

/// A retarget must swap the extension and nothing else. calibre transliterates names differently
/// than Octavo does, and the .sdr sidecar holding reading progress is named after the stem — so
/// re-deriving the name here would silently strand the user's place in the book.
@Test func retargetKeepsTheStemSoSidecarsStayMatched() {
    let calibreName = "Zapovednik - Sergej Dovlatov.mobi"
    #expect(SyncEngine.retargeted(calibreName, to: .azw3) == "Zapovednik - Sergej Dovlatov.azw3")
    #expect(SyncEngine.retargeted("Nasi - Sergej Dovlatov.azw3", to: .mobi) == "Nasi - Sergej Dovlatov.mobi")

    // Our own naming for the same book differs, which is exactly why the stem is preserved.
    let book = makeBook(formats: [BookFormat(format: "EPUB", name: "Zapovednik", size: 900)])
    let epub = try! #require(book.format("EPUB"))
    #expect(SyncEngine.targetFilename(for: book, format: epub, convertedTo: .azw3) != calibreName)
}
