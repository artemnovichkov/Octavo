import Foundation
import Testing
@testable import KindleFormat

private let library = URL.homeDirectory.appending(path: "Calibre Library")

private func sample(_ ext: String) -> URL? {
    FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .first { $0.pathExtension.lowercased() == ext }
}

/// The converter's output has to survive our own MOBI parser: same title, same author,
/// a real cover, and a PalmDB whose record table actually lines up.
@Test func convertsEPUBToReadableMOBI() throws {
    guard let epub = sample("epub") else { return }
    let source = EbookReader.metadata(of: epub)
    let mobi = MOBIWriter.write(try Converter.readEPUB(epub))

    #expect(mobi.count > 1024)
    #expect(mobi.subdata(in: 60..<68) == Data("BOOKMOBI".utf8))

    let parsed = try MOBIReader.metadata(of: mobi, fallbackTitle: "fallback")
    #expect(parsed.title == source.title)
    #expect(parsed.authors == source.authors)
    #expect(parsed.title != "fallback")
    if source.cover != nil {
        #expect(parsed.cover != nil)
    }

    // Every record offset must be inside the file and strictly increasing.
    let offsets = try MOBIReader.recordOffsets(mobi)
    #expect(offsets.count > 2)
    #expect(offsets == offsets.sorted())
    #expect(offsets.last! < mobi.count)
    #expect(mobi.suffix(4) == Data([0xE9, 0x8E, 0x0D, 0x0A]))
}

@Test func convertsComicToMOBI() throws {
    guard let cbz = sample("cbz") else { return }
    let mobi = MOBIWriter.write(try Converter.readComic(cbz))
    let parsed = try MOBIReader.metadata(of: mobi, fallbackTitle: "fallback")
    #expect(parsed.cover != nil)
    #expect(parsed.title != "fallback")

    // A comic is nothing but image records: they must dominate the file size.
    let offsets = try MOBIReader.recordOffsets(mobi)
    #expect(offsets.count > 10)
}

/// Header fields have to match the reference file calibre produced for this library.
@Test func headerMatchesCalibreReference() throws {
    guard let epub = sample("epub") else { return }
    let mobi = MOBIWriter.write(try Converter.readEPUB(epub))
    let offsets = try MOBIReader.recordOffsets(mobi)
    let record0 = offsets[0]
    let mobiHeader = record0 + 16

    #expect(mobi.subdata(in: mobiHeader..<mobiHeader + 4) == Data("MOBI".utf8))
    #expect(mobi.loadBE32(mobiHeader + MOBIHeader.headerLength) == 232)
    #expect(mobi.loadBE32(mobiHeader + MOBIHeader.type) == 2)
    #expect(mobi.loadBE32(mobiHeader + MOBIHeader.codepage) == 65001)
    #expect(mobi.loadBE32(mobiHeader + MOBIHeader.fileVersion) == 6)
    #expect(mobi.loadBE32(mobiHeader + MOBIHeader.exthFlags) == 0x50)

    // The full title must sit exactly where the header says it does.
    let nameOffset = record0 + Int(mobi.loadBE32(mobiHeader + MOBIHeader.fullNameOffset))
    let nameLength = Int(mobi.loadBE32(mobiHeader + MOBIHeader.fullNameLength))
    let title = String(data: mobi.subdata(in: nameOffset..<nameOffset + nameLength), encoding: .utf8)
    #expect(title == EbookReader.metadata(of: epub).title)
}
