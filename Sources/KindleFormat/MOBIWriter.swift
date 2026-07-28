import Foundation

/// Builds a MOBI 6 file — the format the stock Kindle firmware still indexes and opens
/// from a sideloaded file. MOBI 6 needs no INDX/TAGX index structures at all: one
/// flattened HTML stream plus image records is a complete book.
///
/// Layout and header values were taken from a reference file produced by calibre for
/// this library, not from memory. Record 0, the EXTH block and the trailing FLIS/FCIS/EOF
/// records are shared with `KF8Writer` and live in `MOBIRecord0`.
public struct MOBIWriter {
    public struct Input {
        /// Flattened book markup, without the <html>/<body> wrapper.
        public var html: String
        /// Images in the order they are referenced; `recindex` is the 1-based position.
        public var images: [Data]
        public var metadata: EbookMetadata
        /// Index into `images`, if one of them is the cover.
        public var coverIndex: Int?

        public init(html: String, images: [Data], metadata: EbookMetadata, coverIndex: Int? = nil) {
            self.html = html
            self.images = images
            self.metadata = metadata
            self.coverIndex = coverIndex
        }
    }

    static let textRecordSize = 4096

    /// Flattens a `BookDocument` into the one HTML stream MOBI 6 can hold: section bodies
    /// separated by page breaks, images by `recindex`. Stylesheets and the table of contents
    /// have nowhere to go in this format and are dropped — that is what AZW3 is for.
    public static func write(_ document: BookDocument) -> Data {
        var html = ""
        for section in document.sections {
            let body = HTMLFlattener.body(of: section.xhtml)
            let rewritten = HTMLFlattener.rewriteImages(in: body) { src in
                section.resources[src].map { $0 + 1 }  // recindex is 1-based
            }
            guard !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if !html.isEmpty { html += "<mbp:pagebreak/>" }
            html += rewritten
        }

        return write(Input(
            html: html,
            images: document.resources,
            metadata: document.metadata,
            coverIndex: document.coverResourceIndex
        ))
    }

    public static func write(_ input: Input) -> Data {
        let text = Data("<html><head></head><body>\(input.html)</body></html>".utf8)
        let textRecords = MOBIRecord0.textRecords(text, size: textRecordSize, compress: true)

        // Record 0 is the header; text records follow, then images, then the trailing
        // bookkeeping records.
        let firstImageIndex = 1 + textRecords.count
        let flisIndex = firstImageIndex + input.images.count
        let fcisIndex = flisIndex + 1

        let header = MOBIRecord0.build(
            layout: .mobi6,
            text: MOBIRecord0.Text(
                uncompressedLength: text.count,
                recordCount: textRecords.count,
                recordSize: textRecordSize,
                compression: 2  // PalmDoc
            ),
            metadata: input.metadata,
            exth: MOBIRecord0.exth(metadata: input.metadata, coverIndex: input.coverIndex),
            fields: [
                0x40: UInt32(firstImageIndex),  // first non-book index
                0x5C: UInt32(firstImageIndex),
                0xB4: 1,
                0xB8: UInt32(fcisIndex),
                0xBC: 1,  // FCIS count
                0xC0: UInt32(flisIndex),
                0xC4: 1,  // FLIS count
            ],
            halfFields: [
                0xB0: 1,  // first content record
                0xB2: UInt16(flisIndex - 1),  // last content record
            ]
        )

        var database = PalmDatabase(name: input.metadata.title)
        database.records = [header] + textRecords + input.images + [
            MOBIRecord0.flisRecord(),
            MOBIRecord0.fcisRecord(textLength: text.count),
            MOBIRecord0.eofRecord(),
        ]
        return database.serialized()
    }
}
