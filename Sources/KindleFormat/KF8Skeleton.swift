import Foundation

/// Splits prepared sections into the skeleton/chunk arrangement KF8 stores text in, and lays
/// the pieces out into flow 0.
///
/// The arrangement is not obvious from the field names, and was worked out by decoding
/// calibre's own AZW3 files (see `KF8CorpusTests`):
///
/// - Flow 0 is, per section, the **skeleton** — the document with its body emptied — followed
///   immediately by that section's **chunks**, the body content in pieces.
/// - The reader rebuilds a section by inserting each chunk into the skeleton at a recorded
///   position, working on the document *as it grows*. So chunk 2's position accounts for
///   chunk 1 already being there.
/// - That position is stored biased by the skeleton's own offset in the flow, as the chunk
///   index entry's *name*.
enum KF8Skeleton {
    /// Chunks are cut at top-level element boundaries once they pass this. calibre uses a
    /// similar figure; the point is only that one chunk should not be a whole book.
    static let targetChunkSize = 4096

    struct Skeleton {
        var flowStart: Int
        var length: Int
        var chunkCount: Int

        var name: String { "SKEL" + String(format: "%010d", index) }
        fileprivate var index: Int = 0
    }

    struct Chunk {
        /// Where the chunk's bytes sit in flow 0.
        var flowStart: Int
        var length: Int
        /// The insert position the index records, biased by the skeleton's flow offset.
        var insertPosition: Int
        /// Which section — the chunk index calls this the file number.
        var fileNumber: Int
        /// Position among its skeleton's chunks.
        var sequence: Int
        /// CNCX selector: which element the chunk's content belongs inside.
        var selector: String

        var name: String { String(format: "%010d", insertPosition) }
    }

    /// Where an anchor ended up, in the coordinates a `kindle:pos:` link needs.
    struct Position {
        var chunk: Int
        var offset: Int
    }

    struct Layout {
        var flow: [UInt8]
        var skeletons: [Skeleton]
        var chunks: [Chunk]
        /// Section index → anchor id → position. Anchors that landed in a skeleton rather than
        /// a chunk resolve to the head of the section's first chunk, which is the nearest
        /// addressable thing to them.
        var anchors: [[String: Position]]
        /// Section index → the head of its first chunk, for links that name no anchor.
        var sectionStarts: [Position]
    }

    static func layout(_ sections: [KF8Markup.Section]) -> Layout {
        var flow = [UInt8]()
        var skeletons: [Skeleton] = []
        var chunks: [Chunk] = []
        var anchors = [[String: Position]](repeating: [:], count: sections.count)
        var sectionStarts = [Position](repeating: Position(chunk: 0, offset: 0), count: sections.count)

        for (index, section) in sections.enumerated() {
            let content = section.bodyContent
            let bodyAID = Self.bodyAID(of: section)

            var skeleton = [UInt8]()
            skeleton.append(contentsOf: section.bytes[..<content.lowerBound])
            skeleton.append(contentsOf: section.bytes[content.upperBound...])

            let flowStart = flow.count
            flow.append(contentsOf: skeleton)

            let firstChunk = chunks.count
            // The first chunk is inserted where the body's content used to start; each one
            // after it lands directly behind its predecessor, because everything in this
            // arrangement is a child of `<body>` in document order.
            var insertPosition = flowStart + content.lowerBound
            var chunkRanges = split(Array(section.bytes[content]))
            if chunkRanges.isEmpty { chunkRanges = [0..<0] }

            for (sequence, range) in chunkRanges.enumerated() {
                let start = content.lowerBound + range.lowerBound
                let end = content.lowerBound + range.upperBound
                let chunkFlowStart = flow.count
                flow.append(contentsOf: section.bytes[start..<end])

                chunks.append(Chunk(
                    flowStart: chunkFlowStart,
                    length: end - start,
                    insertPosition: insertPosition,
                    fileNumber: index,
                    sequence: sequence,
                    selector: "P-//*[@aid='\(bodyAID)']"
                ))
                insertPosition += end - start

                // Anchors inside this chunk become addressable; the rest fall back below.
                for (anchor, offset) in section.anchors where offset >= start && offset < end {
                    anchors[index][anchor] = Position(chunk: chunks.count - 1, offset: offset - start)
                }
            }

            sectionStarts[index] = Position(chunk: firstChunk, offset: 0)
            for (anchor, _) in section.anchors where anchors[index][anchor] == nil {
                anchors[index][anchor] = sectionStarts[index]
            }

            skeletons.append(Skeleton(
                flowStart: flowStart,
                length: skeleton.count,
                chunkCount: chunkRanges.count,
                index: index
            ))
        }

        return Layout(
            flow: flow,
            skeletons: skeletons,
            chunks: chunks,
            anchors: anchors,
            sectionStarts: sectionStarts
        )
    }

    /// Cuts the body content into runs of roughly `targetChunkSize`, never inside an element.
    /// A chunk that split an element in half would be reassembled into broken markup.
    static func split(_ content: [UInt8]) -> [Range<Int>] {
        guard !content.isEmpty else { return [] }

        var boundaries: [Int] = []
        var depth = 0
        for tag in Markup.tags(in: content) {
            switch tag.kind {
            case .open:
                if tag.isSelfClosing || voidElements.contains(tag.name) {
                    if depth == 0 { boundaries.append(tag.range.upperBound) }
                } else {
                    depth += 1
                }
            case .close:
                depth = max(0, depth - 1)
                if depth == 0 { boundaries.append(tag.range.upperBound) }
            case .other:
                break
            }
        }
        if boundaries.last != content.count { boundaries.append(content.count) }

        var ranges: [Range<Int>] = []
        var start = 0
        for boundary in boundaries where boundary - start >= targetChunkSize {
            ranges.append(start..<boundary)
            start = boundary
        }
        if start < content.count { ranges.append(start..<content.count) }
        return ranges
    }

    /// The `aid` `KF8Markup` gave the body tag — always the first one it assigned for the
    /// section, and what every chunk of that section is a child of.
    private static func bodyAID(of section: KF8Markup.Section) -> String {
        let head = section.bytes[..<section.bodyContent.lowerBound]
        let text = String(decoding: head, as: UTF8.self)
        guard let range = text.range(of: "aid=\"[^\"]*\"", options: [.regularExpression, .backwards])
        else { return "0" }
        return String(text[range].dropFirst(5).dropLast())
    }

    /// HTML elements that never have a closing tag, so depth tracking must not wait for one.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]
}
