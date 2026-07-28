import Foundation
import Testing
@testable import KindleFormat

/// Runs the writer's output back through `KF8File` — the same reader that parses all 30 of
/// calibre's AZW3 files in `KF8CorpusTests`. That ordering is the point: the reader was proved
/// against files we did not make before it was ever pointed at one we did.
@Suite struct KF8WriterTests {
    private func convert(_ url: URL) throws -> (KF8File, BookDocument) {
        let document = try Converter.readEPUB(url)
        return (try KF8File(data: KF8Writer.write(document)), document)
    }

    @Test func producesAReadableKF8Container() throws {
        guard let epub = corpusFiles(withExtension: "epub").first else { return }
        let (file, document) = try convert(epub)

        #expect(file.headerLength == MOBIHeader.kf8Length)
        #expect(file.fileVersion == 8)
        #expect(file.codepage == 65001)
        #expect(file.compression == 2)
        #expect(file.title == document.metadata.title)
        // The flags and the trailers must agree: bit 0 set, one overlap block per record.
        #expect(file.extraDataFlags == 1)

        let text = try file.rawText()
        #expect(text.count == file.uncompressedTextLength)

        // Every index the header names must actually be an index.
        #expect(file.chunkIndex < file.recordCount)
        #expect(file.skeletonIndex < file.recordCount)
        #expect(file.firstResourceIndex < file.recordCount)
        _ = try file.index(at: file.chunkIndex)
        _ = try file.index(at: file.skeletonIndex)

        // Trailing records, in the order the format expects them.
        let flis = try file.record(file.recordCount - 3)
        let fcis = try file.record(file.recordCount - 2)
        #expect(flis.prefix(4) == Data("FLIS".utf8))
        #expect(fcis.prefix(4) == Data("FCIS".utf8))
        #expect(try file.record(file.recordCount - 1) == Data([0xE9, 0x8E, 0x0D, 0x0A]))
    }

    @Test func carriesStylesheetsAsFlows() throws {
        let urls = corpusFiles(withExtension: "epub")
        guard !urls.isEmpty else { return }

        var checked = 0
        for url in urls.prefix(8) {
            let (file, document) = try convert(url)
            guard !document.stylesheets.isEmpty else { continue }
            checked += 1

            let flows = try file.flows()
            #expect(flows.count == 1 + document.stylesheets.count, "\(url.lastPathComponent)")
            #expect(flows.count == file.fdstCount)
            for (index, sheet) in document.stylesheets.enumerated() {
                #expect(flows[index + 1] == Data(sheet.utf8), "\(url.lastPathComponent): поток \(index + 1)")
            }
            // …and the markup has to actually reference them, or the Kindle renders unstyled.
            let markup = String(decoding: flows[0], as: UTF8.self)
            #expect(markup.contains("kindle:flow:0001?mime=text/css"), "\(url.lastPathComponent)")
        }
        #expect(checked > 0, "в корпусе не нашлось EPUB со стилями")
    }

    /// The same reassembly `KF8CorpusTests` applies to calibre's files, applied to ours: the
    /// skeletons and chunks have to tile flow 0 and rebuild well-formed documents.
    @Test func skeletonsAndChunksRebuildTheDocuments() throws {
        let urls = corpusFiles(withExtension: "epub")
        guard !urls.isEmpty else { return }

        for url in urls.prefix(8) {
            let (file, document) = try convert(url)
            let name = url.lastPathComponent
            let flow = try file.flows()[0]

            let skeletons = try file.index(at: file.skeletonIndex)
            let chunks = try file.index(at: file.chunkIndex)
            #expect(skeletons.entries.count == document.sections.count + (document.toc.isEmpty ? 0 : 1), "\(name)")

            var chunkCursor = 0
            var covered = 0
            for (position, skeleton) in skeletons.entries.enumerated() {
                guard let geometry = skeleton.tags[6], geometry.count >= 2,
                      let chunkCount = skeleton.tags[1]?.first
                else { Issue.record("\(name): скелет \(skeleton.name) без геометрии"); continue }

                let start = geometry[0], length = geometry[1]
                var rebuilt = [UInt8](flow[flow.startIndex + start..<flow.startIndex + start + length])
                var cursor = start + length
                covered += length

                for _ in 0..<chunkCount {
                    guard chunkCursor < chunks.entries.count else { break }
                    let chunk = chunks.entries[chunkCursor]
                    chunkCursor += 1
                    guard let geometry = chunk.tags[6], geometry.count >= 2,
                          let insert = Int(chunk.name)
                    else { Issue.record("\(name): кусок \(chunk.name)"); continue }

                    let chunkLength = geometry[1]
                    #expect(insert - start <= rebuilt.count, "\(name): кусок вставляется за концом документа")
                    rebuilt.insert(
                        contentsOf: flow[flow.startIndex + cursor..<flow.startIndex + cursor + chunkLength],
                        at: min(insert - start, rebuilt.count)
                    )
                    cursor += chunkLength
                    covered += chunkLength
                }

                let next = position + 1 < skeletons.entries.count
                    ? skeletons.entries[position + 1].tags[6]?.first ?? flow.count
                    : flow.count
                #expect(cursor == next, "\(name): \(skeleton.name) не стыкуется со следующим")

                let text = String(decoding: rebuilt, as: UTF8.self)
                #expect(text.hasPrefix("<?xml"), "\(name): \(skeleton.name)")
                #expect(text.hasSuffix("</html>"), "\(name): \(skeleton.name) обрывается")
                #expect(text.contains("<body"), "\(name): \(skeleton.name)")
            }

            #expect(chunkCursor == chunks.entries.count, "\(name): куски не разошлись по скелетам")
            #expect(covered == flow.count, "\(name): скелеты и куски не покрывают поток")
        }
    }

    /// A `kindle:pos:` link left at its placeholder value points at the start of the book, which
    /// looks like a working link and is not one. The whole fixed-width patching scheme exists to
    /// make sure that never happens.
    @Test func internalLinksAreResolved() throws {
        let urls = corpusFiles(withExtension: "epub")
        guard !urls.isEmpty else { return }

        var withLinks = 0
        for url in urls.prefix(8) {
            let (file, document) = try convert(url)
            guard document.sections.contains(where: { !$0.links.isEmpty }) else { continue }
            withLinks += 1

            let markup = String(decoding: try file.flows()[0], as: UTF8.self)
            #expect(markup.contains("kindle:pos:fid:"), "\(url.lastPathComponent): ссылки не переписаны")
            // Every placeholder is 0000/0000000000 until patched. A book whose links all
            // genuinely point at chunk 0 offset 0 is not a thing.
            let unpatched = markup.components(separatedBy: KF8Markup.linkPlaceholder).count - 1
            let total = markup.components(separatedBy: "kindle:pos:fid:").count - 1
            #expect(unpatched < total, "\(url.lastPathComponent): \(unpatched) из \(total) ссылок не заполнены")
        }
        #expect(withLinks > 0, "в корпусе не нашлось EPUB с внутренними ссылками")
    }

    @Test func tableOfContentsReachesRealPositions() throws {
        let urls = corpusFiles(withExtension: "epub")
        guard !urls.isEmpty else { return }

        var checked = 0
        for url in urls.prefix(8) {
            let (file, document) = try convert(url)
            guard !document.toc.isEmpty else { continue }
            checked += 1
            let name = url.lastPathComponent

            #expect(file.ncxIndex < file.recordCount, "\(name): нет NCX")
            #expect(file.guideIndex < file.recordCount, "\(name): нет guide")

            let ncx = try file.index(at: file.ncxIndex)
            #expect(!ncx.entries.isEmpty, "\(name)")
            #expect(ncx.strings.count == ncx.entries.count, "\(name): подписи не сошлись с записями")

            let chunks = try file.index(at: file.chunkIndex)
            for entry in ncx.entries {
                guard let position = entry.tags[1]?.first,
                      let geometry = entry.tags[6], geometry.count >= 2
                else { Issue.record("\(name): запись NCX без позиции"); continue }
                #expect(geometry[0] < chunks.entries.count, "\(name): NCX ссылается на несуществующий кусок")
                // Tag 1 must agree with tag 6: the reading position is the chunk's insert
                // position plus the offset inside it.
                let chunk = chunks.entries[geometry[0]]
                #expect(Int(chunk.name)! + geometry[1] == position, "\(name): позиция NCX не сходится с куском")
            }

            let guide = try file.index(at: file.guideIndex)
            #expect(guide.entries.first?.name == "toc", "\(name)")
            #expect(guide.strings[0] == "Table of Contents", "\(name)")
        }
        #expect(checked > 0, "в корпусе не нашлось EPUB с оглавлением")
    }

    @Test func coverAndResourcesSurvive() throws {
        guard let epub = corpusFiles(withExtension: "epub").first(where: {
            (try? Converter.readEPUB($0))?.coverResourceIndex != nil
        }) else { return }

        let (file, document) = try convert(epub)
        #expect(file.firstResourceIndex + document.resources.count < file.recordCount)
        for (index, resource) in document.resources.enumerated() {
            #expect(try file.record(file.firstResourceIndex + index) == resource, "ресурс \(index)")
        }

        // Read back through the shipping metadata parser, the way the sync engine would.
        let parsed = try MOBIReader.metadata(of: KF8Writer.write(document), fallbackTitle: "fallback")
        #expect(parsed.title == document.metadata.title)
        #expect(parsed.authors == document.metadata.authors)
        #expect(parsed.cover != nil)
    }
}

extension KF8WriterTests {
    /// The decisive check, and the one the earlier structural tests could not make: reassembling
    /// the skeletons and chunks must reproduce the prepared markup **byte for byte**.
    ///
    /// Tiling and well-formedness both pass even when bytes have been overwritten in place,
    /// which is exactly what a mis-aimed link patch does — it swaps 33 bytes of real markup for
    /// a `kindle:pos:` URI and leaves the tag around it in pieces.
    @Test func reassemblyReproducesThePreparedMarkupExactly() throws {
        let urls = corpusFiles(withExtension: "epub")
        guard !urls.isEmpty else { return }

        for url in urls.prefix(6) {
            let name = url.lastPathComponent
            let document = try Converter.readEPUB(url)
            let file = try KF8File(data: KF8Writer.write(document))
            let flow = try file.flows()[0]

            let skeletons = try file.index(at: file.skeletonIndex)
            let chunks = try file.index(at: file.chunkIndex)

            var chunkCursor = 0
            for (index, skeleton) in skeletons.entries.enumerated() {
                guard let geometry = skeleton.tags[6], geometry.count >= 2,
                      let chunkCount = skeleton.tags[1]?.first else { continue }

                let start = geometry[0]
                var rebuilt = [UInt8](flow[flow.startIndex + start..<flow.startIndex + start + geometry[1]])
                var cursor = start + geometry[1]

                for _ in 0..<chunkCount {
                    guard chunkCursor < chunks.entries.count else { break }
                    let chunk = chunks.entries[chunkCursor]
                    chunkCursor += 1
                    guard let g = chunk.tags[6], g.count >= 2, let insert = Int(chunk.name) else { continue }
                    rebuilt.insert(
                        contentsOf: flow[flow.startIndex + cursor..<flow.startIndex + cursor + g[1]],
                        at: insert - start
                    )
                    cursor += g[1]
                }

                // Every tag in the rebuilt document has to be a tag. A clobbered one shows up
                // as stray text like "div>" — which is what the Kindle displayed.
                let text = String(decoding: rebuilt, as: UTF8.self)
                let opens = text.filter { $0 == "<" }.count
                let closes = text.filter { $0 == ">" }.count
                // A link that genuinely points at the head of the book encodes as
                // fid:0000:off:0000000000, so unpatched placeholders are counted in
                // `internalLinksAreResolved` rather than looked for here.
                #expect(opens == closes, "\(name): скелет \(index) — разорванные теги (\(opens) '<' против \(closes) '>')")
            }
        }
    }
}

/// EPUB is not the only thing that reaches `KF8Writer`, and the other two shapes are the awkward
/// ones: a comic is dozens of sections with one image and no text each, and an FB2 is a single
/// section that can run to megabytes. Both were converted only through the MOBI path before, so
/// neither had any AZW3 coverage at all.
@Suite struct KF8WriterShapeTests {
    /// The corpus comics are 200 MB apiece, which is no way to run a test — so the shape is
    /// built directly. What matters is the shape, not the pixels.
    @Test func writesComicShapedDocuments() throws {
        var document = BookDocument(metadata: EbookMetadata(title: "Комикс"))
        let page = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x41, count: 512))
        for index in 0..<40 {
            document.resources.append(page)
            let name = "page-\(index).jpg"
            document.sections.append(BookDocument.Section(
                path: name,
                xhtml: "<html><body><div align=\"center\"><img src=\"\(name)\"/></div></body></html>",
                resources: [name: index]
            ))
        }
        document.coverResourceIndex = 0

        let file = try KF8File(data: KF8Writer.write(document))
        #expect(file.fileVersion == 8)
        #expect(try file.index(at: file.skeletonIndex).entries.count == document.sections.count)
        #expect(file.firstResourceIndex + document.resources.count <= file.recordCount)
        for (index, resource) in document.resources.enumerated() {
            #expect(try file.record(file.firstResourceIndex + index) == resource, "страница \(index)")
        }

        // Images must be addressed as kindle:embed, not left pointing at a filename that no
        // longer exists inside the container.
        let markup = String(decoding: try file.flows()[0], as: UTF8.self)
        #expect(!markup.contains("page-0.jpg"), "имя файла осталось в разметке")
        #expect(markup.contains("kindle:embed:0001"))
        #expect(markup.components(separatedBy: "kindle:embed:").count - 1 == document.resources.count)

        // A comic has no stylesheets and no TOC, so it must not claim either.
        #expect(try file.flowRanges().count == 1)
        #expect(file.ncxIndex == 0xFFFF_FFFF)
        #expect(file.guideIndex == 0xFFFF_FFFF)
    }

    @Test func writesFB2() throws {
        guard let fb2 = corpusFiles(withExtension: "fb2").first else { return }
        let document = try Converter.readFB2(fb2)
        let file = try KF8File(data: KF8Writer.write(document))

        #expect(document.sections.count == 1, "FB2 читается в одну секцию")
        #expect(file.fileVersion == 8)
        #expect(!file.title.isEmpty)

        let flow = try file.flows()[0]
        #expect(String(decoding: flow.prefix(64), as: UTF8.self).hasPrefix("<?xml"))

        // One section, but a long one: it has to be split into several chunks, or the whole
        // book would be a single chunk.
        let chunks = try file.index(at: file.chunkIndex)
        #expect(chunks.entries.count > 1, "длинная секция должна разбиться на куски")
        #expect(chunks.entries.allSatisfy { $0.tags[3]?.first == 0 }, "все куски одной секции")

        let contents = try file.textRecordContents()
        for record in contents.dropLast() {
            #expect(record.count == file.textRecordSize)
        }
    }
}
