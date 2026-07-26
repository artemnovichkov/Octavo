import Foundation
import Testing
@testable import KindleFormat

/// Runs against the real calibre library when it is present: 28 EPUB, 30 AZW3, 13 CBZ,
/// one FB2 and one PDF are a better corpus than any fixture we could invent.
private let library = URL.homeDirectory.appending(path: "Calibre Library")

private func files(withExtension ext: String) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == ext }
}

@Test func readsEPUBCorpus() {
    let urls = files(withExtension: "epub")
    guard !urls.isEmpty else { return }
    for url in urls {
        let meta = EbookReader.metadata(of: url)
        #expect(!meta.title.isEmpty)
        #expect(meta.title != url.deletingPathExtension().lastPathComponent, "название не разобралось: \(url.lastPathComponent)")
        #expect(!meta.authors.isEmpty, "автор не разобрался: \(url.lastPathComponent)")
    }
    let covers = urls.compactMap { EbookReader.metadata(of: $0).cover }
    #expect(covers.count >= urls.count * 3 / 4)
    for cover in covers { #expect(isImage(cover)) }
}

@Test func readsMOBICorpus() {
    let urls = files(withExtension: "azw3")
    guard !urls.isEmpty else { return }
    for url in urls {
        let meta = EbookReader.metadata(of: url)
        #expect(!meta.title.isEmpty)
        #expect(meta.title != url.deletingPathExtension().lastPathComponent, "название не разобралось: \(url.lastPathComponent)")
    }
    // Covers live in image records addressed via EXTH 201 + firstImageIndex. Checking
    // for image magic matters: a wrong firstImageIndex still yields non-nil bytes.
    let covers = urls.compactMap { EbookReader.metadata(of: $0).cover }
    #expect(covers.count >= urls.count * 3 / 4)
    for cover in covers {
        #expect(isImage(cover), "обложка не похожа на картинку")
    }
}

/// A wrong codepage offset turns Cyrillic titles into mojibake without failing anything
/// else, so the corpus check looks at the decoded characters.
@Test func decodesCyrillicTitles() {
    // Same bail-out as the other corpus tests: no library on this machine (CI), nothing to check.
    // With a corpus present the emptiness check below stays, so the test cannot go vacuous.
    let urls = files(withExtension: "azw3")
    guard !urls.isEmpty else { return }
    let cyrillic = urls
        .map { EbookReader.metadata(of: $0) }
        .filter { $0.title.unicodeScalars.contains { scalar in (0x0400...0x04FF).contains(scalar.value) } }
    #expect(!cyrillic.isEmpty, "в корпусе нет книг с кириллицей в названии")
    for meta in cyrillic {
        #expect(!meta.title.contains("Ð"), "mojibake в названии: \(meta.title)")
        #expect(!meta.title.contains("Ñ"), "mojibake в названии: \(meta.title)")
    }
}

private func isImage(_ data: Data) -> Bool {
    let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
    let head = Array(data.prefix(4))
    return head.starts(with: jpeg) || head.starts(with: png)
}

@Test func readsComicAndFB2() {
    for url in files(withExtension: "cbz") {
        // CBZ has no metadata at all — the first page is the only thing worth taking.
        #expect(EbookReader.metadata(of: url).cover != nil)
    }
    for url in files(withExtension: "fb2") {
        let meta = EbookReader.metadata(of: url)
        #expect(!meta.authors.isEmpty)
    }
}
