import Foundation
import Testing
@testable import KindleFormat

/// Everything the AZW3 writer produces sits behind this codec, so it is worth pinning down
/// on its own before anything else is built on top of it.
@Suite struct PalmDocTests {
    @Test func decodesTheFourCases() {
        // literal, literal run, back-reference, space-packed character
        #expect(PalmDoc.decompress(Data([0x41, 0x42])) == Data("AB".utf8))
        #expect(PalmDoc.decompress(Data([0x02, 0x00, 0x81])) == Data([0x00, 0x81]))
        #expect(PalmDoc.decompress(Data([0xC1])) == Data(" A".utf8))
        // "abcabc": three literals, then distance 3 length 3 → 0x8000 | 3<<3 | 0
        #expect(PalmDoc.decompress(Data([0x61, 0x62, 0x63, 0x80, 0x18])) == Data("abcabc".utf8))
    }

    @Test func roundTripsAwkwardInput() {
        let cases: [Data] = [
            Data(),
            Data([0x00]),
            Data(repeating: 0x00, count: 100),
            Data("        ".utf8),
            Data((0...255).map { UInt8($0) }),
            Data("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".utf8),
            Data("Привет, мир! Привет, мир! Привет, мир!".utf8),
            Data("<p class=\"calibre1\" aid=\"7\">The quick brown fox</p>".utf8),
        ]
        for original in cases {
            #expect(PalmDoc.decompress(PalmDoc.compress(original)) == original)
        }
    }

    @Test func roundTripsRealBookText() throws {
        let urls = corpusFiles(withExtension: "epub")
        guard !urls.isEmpty else { return }

        var compared = 0
        for url in urls.prefix(10) {
            guard let archive = try? ZipArchive(url: url) else { continue }
            for entry in archive.entries where entry.path.hasSuffix(".xhtml") || entry.path.hasSuffix(".html") {
                guard let data = try? archive.contents(of: entry), !data.isEmpty else { continue }
                // Records are compressed one at a time, so that is how they must be tested.
                for record in MOBIRecord0.textRecords(data, size: 4096, compress: false) {
                    #expect(PalmDoc.decompress(PalmDoc.compress(record)) == record, "\(entry.path)")
                    compared += 1
                }
                break
            }
        }
        #expect(compared > 0, "в корпусе не нашлось текста для проверки")
    }

    /// Compression is only worth having if it actually compresses. calibre's AZW3 of the same
    /// book is the yardstick; anything near 2:1 on markup means the matcher is working.
    @Test func compressesMarkup() {
        let markup = String(
            repeating: "<p class=\"calibre1\" aid=\"7\">The quick brown fox jumps over the lazy dog.</p>",
            count: 50
        )
        let original = Data(markup.utf8)
        let compressed = PalmDoc.compress(original)
        #expect(PalmDoc.decompress(compressed) == original)
        #expect(compressed.count < original.count / 2)
    }

    /// The decoder has to agree with calibre's encoder, not just with our own — otherwise a
    /// shared bug in `compress`/`decompress` would look like success.
    @Test func decodesCalibreRecords() throws {
        let urls = corpusFiles(withExtension: "azw3")
        guard let url = urls.first else { return }

        let file = try KF8File(url: url)
        #expect(file.compression == 2, "в корпусе ожидается PalmDoc-сжатие")

        let text = try file.rawText()
        #expect(text.count == file.uncompressedTextLength)
        // Whatever else it is, KF8 flow 0 is XHTML.
        let head = String(decoding: text.prefix(200), as: UTF8.self)
        #expect(head.contains("<html"), "распакованный поток не похож на разметку: \(head.prefix(60))")
    }
}
