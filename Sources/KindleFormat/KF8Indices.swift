import Foundation

/// The four indices a KF8 file carries, each a thin caller of `INDXWriter`. The tag numbers and
/// bitmasks are not documented anywhere reliable — they were read off calibre's AZW3 files for
/// this library, and `KF8CorpusTests` re-reads those same files to keep the reading of them
/// honest.
enum KF8Indices {
    /// Per skeleton: how many chunks belong to it, and where it sits in flow 0.
    static func skeleton(_ layout: KF8Skeleton.Layout) -> [Data] {
        let tagx = [
            INDXWriter.TagDefinition(tag: 1, valuesPerEntry: 1, mask: 0x03),  // chunk count
            INDXWriter.TagDefinition(tag: 6, valuesPerEntry: 2, mask: 0x0C),  // start, length
        ]
        let entries = layout.skeletons.map { skeleton in
            INDXWriter.Entry(
                name: skeleton.name,
                values: [1: [skeleton.chunkCount], 6: [skeleton.flowStart, skeleton.length]]
            )
        }
        return INDXWriter.records(entries: entries, tagx: tagx)
    }

    /// Per chunk: which element it belongs inside, which section, and where it goes.
    ///
    /// Tag 6's first value is the running total of chunk bytes **within the current section**,
    /// not an offset into the flow, and it resets at every section boundary.
    static func chunk(_ layout: KF8Skeleton.Layout) -> [Data] {
        let tagx = [
            INDXWriter.TagDefinition(tag: 2, valuesPerEntry: 1, mask: 0x01),  // CNCX selector
            INDXWriter.TagDefinition(tag: 3, valuesPerEntry: 1, mask: 0x02),  // section
            INDXWriter.TagDefinition(tag: 4, valuesPerEntry: 1, mask: 0x04),  // sequence
            INDXWriter.TagDefinition(tag: 6, valuesPerEntry: 2, mask: 0x08),  // offset, length
        ]

        var strings: [String] = []
        var offsetByString: [String: Int] = [:]
        for chunk in layout.chunks where offsetByString[chunk.selector] == nil {
            offsetByString[chunk.selector] = strings.count
            strings.append(chunk.selector)
        }
        let offsets = INDXWriter.stringOffsets(strings)

        var entries: [INDXWriter.Entry] = []
        var withinSection = 0
        var section = -1
        for chunk in layout.chunks {
            if chunk.fileNumber != section {
                section = chunk.fileNumber
                withinSection = 0
            }
            entries.append(INDXWriter.Entry(
                name: chunk.name,
                values: [
                    2: [offsets[offsetByString[chunk.selector] ?? 0]],
                    3: [chunk.fileNumber],
                    4: [chunk.sequence],
                    6: [withinSection, chunk.length],
                ]
            ))
            withinSection += chunk.length
        }

        return INDXWriter.records(entries: entries, tagx: tagx, strings: strings)
    }

    struct TOCTarget {
        var title: String
        /// Position in the reading coordinate the Kindle uses: the containing chunk's insert
        /// position plus the offset within it.
        var position: Int
        var chunk: Int
        var offset: Int
        /// 0 for a top-level entry, 1 for its children, and so on.
        var depth: Int
    }

    /// The index behind the Kindle's own table-of-contents button, nesting included — the
    /// Kindle renders a nested one under collapsible headings.
    ///
    /// Three conventions here were read off calibre's files and none is guessable:
    ///
    /// - Entries are stored **breadth-first**: every depth-0 entry, then every depth-1 entry,
    ///   with one parent's children contiguous. Reading order is carried by the positions.
    /// - Entry names are **hex**, two digits and up (`0A`, `13`, `66`), not decimal.
    /// - A parent's length spans its **whole subtree**, reaching to the next entry at the same
    ///   or a shallower depth — not to its first child.
    static func ncx(_ targets: [TOCTarget], textLength: Int) -> [Data] {
        let tagx = [
            INDXWriter.TagDefinition(tag: 1, valuesPerEntry: 1, mask: 0x01),  // position
            INDXWriter.TagDefinition(tag: 2, valuesPerEntry: 1, mask: 0x02),  // length
            INDXWriter.TagDefinition(tag: 3, valuesPerEntry: 1, mask: 0x04),  // CNCX label
            INDXWriter.TagDefinition(tag: 4, valuesPerEntry: 1, mask: 0x08),  // depth
            INDXWriter.TagDefinition(tag: 21, valuesPerEntry: 1, mask: 0x10),  // parent
            INDXWriter.TagDefinition(tag: 22, valuesPerEntry: 1, mask: 0x20),  // first child
            INDXWriter.TagDefinition(tag: 23, valuesPerEntry: 1, mask: 0x40),  // last child
            INDXWriter.TagDefinition(tag: 6, valuesPerEntry: 2, mask: 0x80),  // chunk, offset
        ]

        // Reading order first: lengths and parentage are both defined in terms of it.
        let reading = targets

        // An entry ends where the next entry at the same or a shallower depth begins, so a
        // section covers its chapters and the last chapter covers the rest of the section.
        func end(of index: Int) -> Int {
            for next in (index + 1)..<reading.count where reading[next].depth <= reading[index].depth {
                return reading[next].position
            }
            return textLength
        }

        // Parent is the nearest preceding entry one level up.
        var parentOf = [Int?](repeating: nil, count: reading.count)
        for index in reading.indices where reading[index].depth > 0 {
            for previous in stride(from: index - 1, through: 0, by: -1)
            where reading[previous].depth == reading[index].depth - 1 {
                parentOf[index] = previous
                break
            }
        }

        // Breadth-first storage order, and the map from reading order to stored ordinal.
        let stored = reading.indices.sorted {
            reading[$0].depth != reading[$1].depth ? reading[$0].depth < reading[$1].depth : $0 < $1
        }
        var ordinalOf = [Int](repeating: 0, count: reading.count)
        for (ordinal, index) in stored.enumerated() { ordinalOf[index] = ordinal }

        var children = [[Int]](repeating: [], count: reading.count)
        for index in reading.indices {
            if let parent = parentOf[index] { children[parent].append(ordinalOf[index]) }
        }

        let labels = stored.map { reading[$0].title }
        let offsets = INDXWriter.stringOffsets(labels)

        let entries = stored.enumerated().map { ordinal, index in
            let target = reading[index]
            var values: [UInt8: [Int]] = [
                1: [target.position],
                2: [max(0, end(of: index) - target.position)],
                3: [offsets[ordinal]],
                4: [target.depth],
                6: [target.chunk, target.offset],
            ]
            if let parent = parentOf[index] { values[21] = [ordinalOf[parent]] }
            if let first = children[index].min(), let last = children[index].max() {
                values[22] = [first]
                values[23] = [last]
            }
            return INDXWriter.Entry(name: String(format: "%02X", ordinal), values: values)
        }

        return INDXWriter.records(entries: entries, tagx: tagx, strings: labels)
    }

    /// One landmark: where the book's own table-of-contents page is.
    static func guide(tocPosition: Int) -> [Data] {
        let tagx = [
            INDXWriter.TagDefinition(tag: 1, valuesPerEntry: 1, mask: 0x01),  // CNCX title
            INDXWriter.TagDefinition(tag: 6, valuesPerEntry: 2, mask: 0x02),  // position
        ]
        let entries = [INDXWriter.Entry(name: "toc", values: [1: [0], 6: [tocPosition, 0]])]
        return INDXWriter.records(entries: entries, tagx: tagx, strings: ["Table of Contents"])
    }
}
