import Foundation

/// Builds an AZW3 (KF8) file.
///
/// Where MOBI 6 is one flat HTML stream, KF8 keeps the book's structure: stylesheets survive as
/// separate flows, the spine stays split into documents, and four INDX structures describe how
/// to put it back together and how to navigate it. That is the whole reason to prefer it — a
/// converted EPUB arrives styled, with a table of contents the Kindle's own button can use.
///
/// The record order follows what calibre emits, which is not arbitrary: `firstNonBookIndex`
/// points at the first index record, so the indices must sit between the text and the images.
public enum KF8Writer {
    static let textRecordSize = 4096

    public static func write(_ document: BookDocument) -> Data {
        var document = document
        // A generated contents page gives the guide index something true to point at, and gives
        // the book a visible TOC as well as the one behind the hardware button.
        let tocSection = document.toc.isEmpty ? nil : appendTOCPage(to: &document)

        let prepared = KF8Markup.prepare(document)
        var layout = KF8Skeleton.layout(prepared)

        resolveLinks(in: &layout, prepared: prepared)

        // Flow 0 is the markup; 1…n are the stylesheets, in the order the sections link them.
        var flows: [[UInt8]] = [layout.flow]
        flows.append(contentsOf: document.stylesheets.map { Array($0.utf8) })

        var text = Data()
        var ranges: [(Int, Int)] = []
        for flow in flows {
            ranges.append((text.count, text.count + flow.count))
            text.append(contentsOf: flow)
        }

        let textRecords = MOBIRecord0.textRecords(text, size: textRecordSize, compress: true)

        // Record layout: header, text, a one-byte spacer, the four indices, the images, then
        // the trailing bookkeeping records.
        var cursor = 1 + textRecords.count + 1
        let chunkRecords = KF8Indices.chunk(layout)
        let chunkIndex = cursor
        cursor += chunkRecords.count
        let skeletonRecords = KF8Indices.skeleton(layout)
        let skeletonIndex = cursor
        cursor += skeletonRecords.count

        var guideRecords: [Data] = []
        var ncxRecords: [Data] = []
        var guideIndex = 0xFFFF_FFFF
        var ncxIndex = 0xFFFF_FFFF

        let targets = tocTargets(document: document, layout: layout)
        if let tocSection, let start = layout.sectionStarts[safe: tocSection] {
            guideRecords = KF8Indices.guide(tocPosition: position(of: start, in: layout))
            guideIndex = cursor
            cursor += guideRecords.count
        }
        if !targets.isEmpty {
            ncxRecords = KF8Indices.ncx(targets, textLength: layout.flow.count)
            ncxIndex = cursor
            cursor += ncxRecords.count
        }

        let firstResourceIndex = cursor
        cursor += document.resources.count
        let fdstIndex = cursor
        let flisIndex = fdstIndex + 1
        let fcisIndex = flisIndex + 1

        let header = MOBIRecord0.build(
            layout: .kf8,
            text: MOBIRecord0.Text(
                uncompressedLength: text.count,
                recordCount: textRecords.count,
                recordSize: textRecordSize,
                compression: 2  // PalmDoc
            ),
            metadata: document.metadata,
            exth: MOBIRecord0.exth(
                metadata: document.metadata,
                coverIndex: document.coverResourceIndex,
                extra: [MOBIRecord0.uintEntry(125, UInt32(document.resources.count))]
            ),
            fields: [
                0x40: UInt32(1 + textRecords.count + 1),  // first non-book index
                0x5C: UInt32(firstResourceIndex),
                0xB0: UInt32(fdstIndex),
                0xB4: UInt32(flows.count),
                0xB8: UInt32(fcisIndex),
                0xBC: 1,
                0xC0: UInt32(flisIndex),
                0xC4: 1,
                0xE4: UInt32(ncxIndex),
                0xE8: UInt32(chunkIndex),
                0xEC: UInt32(skeletonIndex),
                0xF4: UInt32(guideIndex),
            ]
        )

        var database = PalmDatabase(name: document.metadata.title)
        database.records =
            [header]
            + textRecords
            + [Data([0])]  // the spacer calibre leaves between the text and the indices
            + chunkRecords
            + skeletonRecords
            + guideRecords
            + ncxRecords
            + document.resources
            + [
                fdstRecord(ranges),
                MOBIRecord0.flisRecord(),
                MOBIRecord0.fcisRecord(textLength: text.count),
                MOBIRecord0.eofRecord(),
            ]
        return database.serialized()
    }

    // MARK: - Links

    /// Fills in the `kindle:pos:` placeholders now that every chunk has a number and an offset.
    /// Nothing moves: the placeholder was written at the exact width its filled-in form takes.
    private static func resolveLinks(in layout: inout KF8Skeleton.Layout, prepared: [KF8Markup.Section]) {
        for (index, section) in prepared.enumerated() {
            // A link's offset was recorded inside its section; find where that section's bytes
            // ended up in the flow before patching.
            for link in section.links {
                guard let flowOffset = flowOffset(of: link.offset, section: index, layout: layout)
                else { continue }
                let target = link.target
                let position = target.anchor.flatMap { layout.anchors[safe: target.section]?[$0] }
                    ?? layout.sectionStarts[safe: target.section]
                guard let position else { continue }
                KF8Markup.patch(
                    &layout.flow,
                    at: flowOffset,
                    chunk: position.chunk,
                    within: position.offset
                )
            }
        }
    }

    /// Maps an offset inside a prepared section to its offset in flow 0. The section was taken
    /// apart into a skeleton and chunks, so where a byte landed depends on which piece it is in.
    private static func flowOffset(of offset: Int, section: Int, layout: KF8Skeleton.Layout) -> Int? {
        guard let skeleton = layout.skeletons[safe: section] else { return nil }
        for chunk in layout.chunks where chunk.fileNumber == section {
            let start = chunk.insertPosition - skeleton.flowStart
            // `insertPosition` is biased by the skeleton's flow offset, and chunks are laid out
            // in order, so this window is exactly the chunk's slice of the original section.
            if offset >= start, offset < start + chunk.length {
                return chunk.flowStart + (offset - start)
            }
        }
        return nil
    }

    private static func position(of position: KF8Skeleton.Position, in layout: KF8Skeleton.Layout) -> Int {
        guard let chunk = layout.chunks[safe: position.chunk] else { return 0 }
        return chunk.insertPosition + position.offset
    }

    private static func tocTargets(
        document: BookDocument,
        layout: KF8Skeleton.Layout
    ) -> [KF8Indices.TOCTarget] {
        document.toc.compactMap { entry in
            let anchored = entry.anchor.flatMap { layout.anchors[safe: entry.sectionIndex]?[$0] }
            guard let found = anchored ?? layout.sectionStarts[safe: entry.sectionIndex] else { return nil }
            return KF8Indices.TOCTarget(
                title: entry.title,
                position: position(of: found, in: layout),
                chunk: found.chunk,
                offset: found.offset
            )
        }
        .sorted { $0.position < $1.position }
    }

    // MARK: - Generated contents page

    /// Appends a contents page built from the document's own TOC and returns its section index.
    /// Its links go through the same `href` → target map the rest of the book uses, so they get
    /// resolved by the same machinery.
    private static func appendTOCPage(to document: inout BookDocument) -> Int {
        var links: [String: BookDocument.LinkTarget] = [:]
        var items = ""

        for (index, entry) in document.toc.enumerated() {
            let href = "octavo-toc-\(index)"
            links[href] = BookDocument.LinkTarget(section: entry.sectionIndex, anchor: entry.anchor)
            items += "<li><a href=\"\(href)\">\(escape(entry.title))</a></li>"
        }

        document.sections.append(BookDocument.Section(
            path: "octavo-toc.xhtml",
            xhtml: "<html><head><title>Table of Contents</title></head>"
                + "<body><h1>Table of Contents</h1><ul>\(items)</ul></body></html>",
            links: links
        ))
        return document.sections.count - 1
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - FDST

    private static func fdstRecord(_ ranges: [(Int, Int)]) -> Data {
        var record = Data()
        record.append(contentsOf: Array("FDST".utf8))
        record.appendBE32(12)  // offset of the first entry
        record.appendBE32(UInt32(ranges.count))
        for (start, end) in ranges {
            record.appendBE32(UInt32(start))
            record.appendBE32(UInt32(end))
        }
        return record
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
