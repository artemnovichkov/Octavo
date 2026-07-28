import Foundation
import Testing
@testable import KindleFormat

/// Proves `KF8File` against the 30 AZW3 files calibre produced for this library. Every
/// assertion here is about *calibre's* output, so passing means the reader understands the
/// real format — which is the only thing that makes it useful for checking our own writer.
@Suite struct KF8CorpusTests {
    @Test func readsEveryCorpusFile() throws {
        let urls = corpusFiles(withExtension: "azw3")
        guard !urls.isEmpty else { return }

        for url in urls {
            let file = try KF8File(url: url)
            let name = url.lastPathComponent

            #expect(file.headerLength == MOBIHeader.kf8Length, "\(name): не KF8-заголовок")
            #expect(file.fileVersion == 8, "\(name)")
            #expect(file.codepage == 65001, "\(name)")
            #expect(!file.title.isEmpty, "\(name)")

            let text = try file.rawText()
            #expect(text.count == file.uncompressedTextLength, "\(name): длина потока не сошлась")

            let flows = try file.flows()
            #expect(!flows.isEmpty, "\(name): нет FDST")
            #expect(flows.count == file.fdstCount, "\(name)")
            let markup = String(decoding: flows[0], as: UTF8.self)
            #expect(markup.contains("<html"), "\(name): нулевой поток не разметка")

            let skeletons = try file.index(at: file.skeletonIndex)
            let chunks = try file.index(at: file.chunkIndex)
            #expect(!skeletons.entries.isEmpty, "\(name)")
            #expect(!chunks.entries.isEmpty, "\(name)")
            #expect(skeletons.entries.allSatisfy { $0.name.hasPrefix("SKEL") }, "\(name)")
            #expect(chunks.strings.values.allSatisfy { $0.contains("@aid=") }, "\(name): CNCX не селекторы")
        }
    }

    /// The one check that exercises the whole chain at once: each skeleton's bytes are followed
    /// in the flow by exactly its own chunks' bytes, and inserting those chunks back into the
    /// skeleton at the recorded positions rebuilds a document.
    ///
    /// Three things here are not what the field names suggest, and each cost time to work out:
    ///
    /// - A chunk entry's **name is an insert position biased by its skeleton's flow offset**.
    ///   Subtract the skeleton's start and it indexes into the skeleton *as it grows*.
    /// - **Tag 6's first value is not where the chunk lives.** The chunk's bytes are simply the
    ///   next ones after the previous chunk's, starting right behind the skeleton.
    /// - calibre writes every skeleton tag **twice** — `chunk_count` as `[n, n]` and the
    ///   geometry as `[start, length, start, length]`. The control byte says so, so it decodes
    ///   correctly; only the first copy carries meaning.
    @Test func skeletonsAndChunksRebuildTheDocument() throws {
        let urls = corpusFiles(withExtension: "azw3")
        guard !urls.isEmpty else { return }

        for url in urls.prefix(10) {
            let file = try KF8File(url: url)
            let name = url.lastPathComponent
            let flow = try file.flows()[0]

            let skeletons = try file.index(at: file.skeletonIndex)
            let chunks = try file.index(at: file.chunkIndex)

            var chunkCursor = 0
            for (position, skeleton) in skeletons.entries.enumerated() {
                guard let geometry = skeleton.tags[6], geometry.count >= 2,
                      let chunkCount = skeleton.tags[1]?.first
                else { Issue.record("\(name): у скелета \(skeleton.name) нет геометрии"); continue }

                let start = geometry[0], length = geometry[1]
                #expect(start + length <= flow.count, "\(name): скелет за границей потока")

                var document = [UInt8](flow[flow.startIndex + start..<flow.startIndex + start + length])
                var cursor = start + length

                for _ in 0..<chunkCount {
                    guard chunkCursor < chunks.entries.count else { break }
                    let chunk = chunks.entries[chunkCursor]
                    chunkCursor += 1
                    guard let geometry = chunk.tags[6], geometry.count >= 2,
                          let position = Int(chunk.name)
                    else { Issue.record("\(name): кусок \(chunk.name) не разобрался"); continue }

                    let insertAt = position - start
                    let chunkLength = geometry[1]
                    guard cursor + chunkLength <= flow.count, insertAt <= document.count else {
                        Issue.record("\(name): кусок \(chunk.name) не помещается")
                        continue
                    }
                    document.insert(
                        contentsOf: flow[flow.startIndex + cursor..<flow.startIndex + cursor + chunkLength],
                        at: insertAt
                    )
                    cursor += chunkLength
                }

                // The chunks of one skeleton run up to exactly where the next skeleton begins.
                let next = position + 1 < skeletons.entries.count
                    ? skeletons.entries[position + 1].tags[6]?.first ?? flow.count
                    : flow.count
                #expect(cursor == next, "\(name): \(skeleton.name) не стыкуется со следующим")

                let rebuilt = String(decoding: document, as: UTF8.self)
                #expect(rebuilt.contains("<html"), "\(name): \(skeleton.name) собрался не в документ")
                #expect(rebuilt.hasSuffix("</html>\n") || rebuilt.hasSuffix("</html>"), "\(name): \(skeleton.name) обрывается")
            }

            #expect(chunkCursor == chunks.entries.count, "\(name): куски не разошлись по скелетам")
        }
    }
}

/// The invariant that a self-consistent reader cannot check on its own.
///
/// Text records must be **exactly** `textRecordSize` uncompressed bytes, because the reader
/// locates flow offset N by dividing it by that size. Octavo shipped records shortened to UTF-8
/// character boundaries once; every index in the file drifted after the first split character,
/// and a Cyrillic book rendered from the middle of a tag and could not be paged. Nothing in the
/// suite caught it, because the writer and the reader shared the assumption.
///
/// So this is checked the only way that means anything: the same assertions over calibre's files
/// and over ours, in one place.
@Suite struct RecordSizeInvariantTests {
    private func check(_ file: KF8File, _ name: String) throws {
        let contents = try file.textRecordContents()
        guard !contents.isEmpty else { return }

        #expect(file.extraDataFlags & 1 == 1, "\(name): нет флага multibyte-overlap")
        for (index, record) in contents.dropLast().enumerated() {
            #expect(
                record.count == file.textRecordSize,
                "\(name): запись \(index + 1) — \(record.count) байт вместо \(file.textRecordSize)"
            )
        }
        #expect(contents.last!.count <= file.textRecordSize, "\(name): последняя запись слишком велика")
        #expect(contents.reduce(0) { $0 + $1.count } == file.uncompressedTextLength, "\(name)")

        // The trailer duplicates the next record's leading continuation bytes, so a reader that
        // jumped straight here can finish the straddling character without fetching its
        // neighbour. A trailer that says anything else is worse than none.
        for index in 0..<(contents.count - 1) {
            let trailer = try file.overlapTrailer(of: index + 1)
            guard !trailer.isEmpty else { continue }
            #expect(trailer.count <= 3, "\(name): хвост длиннее трёх байт не влезает в счётчик")
            #expect(
                trailer == contents[index + 1].prefix(trailer.count),
                "\(name): хвост записи \(index + 1) не совпадает с началом следующей"
            )
        }
    }

    @Test func calibreFilesHoldTheInvariant() throws {
        let urls = corpusFiles(withExtension: "azw3")
        guard !urls.isEmpty else { return }
        for url in urls { try check(try KF8File(url: url), url.lastPathComponent) }
    }

    @Test func ourFilesHoldTheInvariant() throws {
        let urls = corpusFiles(withExtension: "epub")
        guard !urls.isEmpty else { return }
        for url in urls.prefix(8) {
            let document = try Converter.readEPUB(url)
            try check(try KF8File(data: KF8Writer.write(document)), url.lastPathComponent)
        }
    }
}

/// The NCX tree, checked the same way the record-size invariant is: one set of rules applied to
/// calibre's files and to ours, so neither can drift into a private convention.
///
/// The conventions are not guessable and were read off calibre's output — entries stored
/// breadth-first by depth, hex names, and a parent's length spanning its whole subtree rather
/// than stopping at its first child.
@Suite struct NCXStructureTests {
    private func check(_ file: KF8File, _ name: String) throws {
        guard file.ncxIndex < file.recordCount else { return }
        let ncx = try file.index(at: file.ncxIndex)
        guard !ncx.entries.isEmpty else { return }

        let depths = ncx.entries.map { $0.tags[4]?.first ?? 0 }
        let positions = ncx.entries.map { $0.tags[1]?.first ?? 0 }
        let lengths = ncx.entries.map { $0.tags[2]?.first ?? 0 }

        // Stored breadth-first: depths never decrease as you walk the entries.
        #expect(zip(depths, depths.dropFirst()).allSatisfy { $0 <= $1 }, "\(name): записи не по уровням")

        // Names are hex ordinals.
        for (ordinal, entry) in ncx.entries.enumerated() {
            #expect(Int(entry.name, radix: 16) == ordinal, "\(name): имя \(entry.name) не hex-порядковый")
        }

        // Within one depth, reading order is preserved.
        for depth in Set(depths) {
            let atDepth = ncx.entries.indices.filter { depths[$0] == depth }.map { positions[$0] }
            #expect(zip(atDepth, atDepth.dropFirst()).allSatisfy { $0 < $1 }, "\(name): позиции уровня \(depth) не растут")
        }

        for (ordinal, entry) in ncx.entries.enumerated() {
            // A child names its parent, and sits inside the parent's span.
            if depths[ordinal] > 0 {
                guard let parent = entry.tags[21]?.first else {
                    Issue.record("\(name): у вложенной записи \(entry.name) нет родителя")
                    continue
                }
                #expect(parent < ncx.entries.count, "\(name)")
                #expect(depths[parent] == depths[ordinal] - 1, "\(name): родитель не на уровень выше")
                #expect(
                    positions[ordinal] >= positions[parent]
                        && positions[ordinal] < positions[parent] + lengths[parent],
                    "\(name): запись \(entry.name) вне диапазона родителя"
                )
            } else {
                #expect(entry.tags[21] == nil, "\(name): у записи верхнего уровня есть родитель")
            }

            // A parent's declared child range has to be exactly the entries claiming it.
            if let first = entry.tags[22]?.first, let last = entry.tags[23]?.first {
                #expect(first <= last, "\(name)")
                let claimed = ncx.entries.indices.filter { ncx.entries[$0].tags[21]?.first == ordinal }
                #expect(claimed.min() == first && claimed.max() == last, "\(name): диапазон детей не сходится")
            }
        }
    }

    @Test func calibreNCXTreesHoldTheRules() throws {
        let urls = corpusFiles(withExtension: "azw3")
        guard !urls.isEmpty else { return }
        var nested = 0
        for url in urls {
            let file = try KF8File(url: url)
            try check(file, url.lastPathComponent)
            if file.ncxIndex < file.recordCount,
               try file.index(at: file.ncxIndex).entries.contains(where: { ($0.tags[4]?.first ?? 0) > 0 }) {
                nested += 1
            }
        }
        #expect(nested > 0, "в корпусе не нашлось вложенных оглавлений — правила не проверены")
    }

    @Test func ourNCXTreesHoldTheRules() throws {
        let urls = corpusFiles(withExtension: "epub")
        guard !urls.isEmpty else { return }
        var nested = 0
        for url in urls {
            let document = try Converter.readEPUB(url)
            guard document.toc.contains(where: { $0.depth > 0 }) else { continue }
            nested += 1
            try check(try KF8File(data: KF8Writer.write(document)), url.lastPathComponent)
        }
        #expect(nested > 0, "в корпусе не нашлось EPUB с вложенным оглавлением")
    }
}
