import Foundation

/// Field offsets inside the MOBI header, counted from the "MOBI" magic. Recovered by
/// scanning calibre-produced AZW3 files rather than from memory: several of these are
/// documented inconsistently in the wild.
enum MOBIHeader {
    static let headerLength = 0x04
    static let type = 0x08
    static let codepage = 0x0C
    static let uniqueID = 0x10
    static let fileVersion = 0x14
    static let firstNonBookIndex = 0x40
    static let fullNameOffset = 0x44
    static let fullNameLength = 0x48
    static let locale = 0x4C
    static let firstImageIndex = 0x5C
    static let exthFlags = 0x70
    static let fdstIndex = 0xB0
    static let fdstCount = 0xB4
    static let fcisIndex = 0xB8
    static let flisIndex = 0xC0
    static let ncxIndex = 0xE4
    static let chunkIndex = 0xE8
    static let skeletonIndex = 0xEC
    static let guideIndex = 0xF4
    /// KF8 header length calibre writes.
    static let kf8Length = 264
}

/// Reads the PalmDB / MOBI header pair that AZW3, AZW, MOBI and PRC files share.
/// The same structures are what the AZW3 writer will have to emit, so this doubles
/// as the reference implementation for it.
public enum MOBIReader {
    public enum MOBIError: Error {
        case notAPalmDatabase
        case noMOBIHeader
    }

    /// EXTH record types (MobileRead's MOBI documentation).
    enum EXTH: UInt32 {
        case author = 100
        case publisher = 101
        case description = 103
        case isbn = 104
        case subject = 105
        case publishingDate = 106
        case coverOffset = 201
        case thumbOffset = 202
        case updatedTitle = 503
    }

    public static func metadata(of url: URL) throws -> EbookMetadata {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try metadata(of: data, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    public static func metadata(of data: Data, fallbackTitle: String) throws -> EbookMetadata {
        let records = try recordOffsets(data)
        guard let record0Start = records.first else { throw MOBIError.notAPalmDatabase }
        let record0End = records.count > 1 ? records[1] : data.count

        guard record0Start + 20 < data.count,
              data.subdata(in: record0Start + 16..<record0Start + 20) == Data("MOBI".utf8)
        else { throw MOBIError.noMOBIHeader }

        // Offsets verified against the AZW3 files calibre produced for this library —
        // see MOBIHeader for the full map.
        let mobiHeaderStart = record0Start + 16
        let mobiHeaderLength = Int(data.loadBE32(mobiHeaderStart + MOBIHeader.headerLength))
        let textEncoding = data.loadBE32(mobiHeaderStart + MOBIHeader.codepage)
        let firstImageIndex = Int(data.loadBE32(mobiHeaderStart + MOBIHeader.firstImageIndex))
        let fullNameOffset = Int(data.loadBE32(mobiHeaderStart + MOBIHeader.fullNameOffset))
        let fullNameLength = Int(data.loadBE32(mobiHeaderStart + MOBIHeader.fullNameLength))
        let encoding: String.Encoding = textEncoding == 65001 ? .utf8 : .windowsCP1252

        var metadata = EbookMetadata(title: fallbackTitle)

        let nameStart = record0Start + fullNameOffset
        if fullNameLength > 0, nameStart + fullNameLength <= record0End {
            let raw = data.subdata(in: nameStart..<nameStart + fullNameLength)
            if let name = String(data: raw, encoding: encoding), !name.isEmpty { metadata.title = name }
        }

        // EXTH sits right after the MOBI header when bit 0x40 of the flags is set.
        let exthFlags = data.loadBE32(mobiHeaderStart + MOBIHeader.exthFlags)
        guard exthFlags & 0x40 != 0 else { return metadata }

        let exthStart = mobiHeaderStart + mobiHeaderLength
        guard exthStart + 12 <= data.count,
              data.subdata(in: exthStart..<exthStart + 4) == Data("EXTH".utf8)
        else { return metadata }

        let recordCount = Int(data.loadBE32(exthStart + 8))
        var cursor = exthStart + 12
        var coverIndex: Int?

        for _ in 0..<recordCount {
            guard cursor + 8 <= data.count else { break }
            let type = data.loadBE32(cursor)
            let length = Int(data.loadBE32(cursor + 4))
            guard length >= 8, cursor + length <= data.count else { break }
            let payload = data.subdata(in: cursor + 8..<cursor + length)
            cursor += length

            func text() -> String? {
                String(data: payload, encoding: encoding)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            switch EXTH(rawValue: type) {
            case .author:
                if let value = text(), !value.isEmpty { metadata.authors.append(value) }
            case .publisher:
                metadata.publisher = text()
            case .description:
                metadata.comments = text()
            case .isbn:
                metadata.isbn = text()
            case .subject:
                if let value = text(), !value.isEmpty { metadata.tags.append(value) }
            case .publishingDate:
                metadata.published = text().flatMap(OPFParser.parseDate)
            case .coverOffset:
                if payload.count == 4 { coverIndex = Int(payload.loadBE32(0)) }
            case .updatedTitle:
                if let value = text(), !value.isEmpty { metadata.title = value }
            default:
                break
            }
        }

        // The cover record index is relative to the first image record.
        if let coverIndex, firstImageIndex != Int(UInt32.max) {
            let record = firstImageIndex + coverIndex
            if record > 0, record < records.count {
                let start = records[record]
                let end = record + 1 < records.count ? records[record + 1] : data.count
                if start < end { metadata.cover = data.subdata(in: start..<end) }
            }
        }

        return metadata
    }

    /// PalmDB: 78-byte header, then one 8-byte entry per record holding its file offset.
    static func recordOffsets(_ data: Data) throws -> [Int] {
        guard data.count > 78 else { throw MOBIError.notAPalmDatabase }
        let recordCount = Int(data.loadBE16(76))
        guard recordCount > 0, 78 + recordCount * 8 <= data.count else { throw MOBIError.notAPalmDatabase }

        return (0..<recordCount).map { index in
            Int(data.loadBE32(78 + index * 8))
        }
    }
}

enum FB2Reader {
    /// FB2 is a single XML file; `<description><title-info>` holds everything we need.
    static func metadata(of url: URL) throws -> EbookMetadata {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let parser = FB2Parser(fallbackTitle: url.deletingPathExtension().lastPathComponent)
        return parser.parse(data)
    }
}

private final class FB2Parser: NSObject, XMLParserDelegate {
    private let fallbackTitle: String
    private var metadata: EbookMetadata
    private var path: [String] = []
    private var text = ""
    private var firstName = ""
    private var lastName = ""

    init(fallbackTitle: String) {
        self.fallbackTitle = fallbackTitle
        self.metadata = EbookMetadata(title: fallbackTitle)
    }

    func parse(_ data: Data) -> EbookMetadata {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return metadata
    }

    private var inTitleInfo: Bool { path.contains("title-info") }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        path.append(elementName.lowercased())
        text = ""
        if elementName.lowercased() == "sequence", inTitleInfo {
            metadata.series = attributes["name"]
            metadata.seriesIndex = attributes["number"].flatMap(Double.init)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let element = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if inTitleInfo {
            switch element {
            case "book-title" where !value.isEmpty:
                metadata.title = value
            case "first-name":
                firstName = value
            case "last-name":
                lastName = value
            case "author":
                let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
                if !name.isEmpty { metadata.authors.append(name) }
                firstName = ""
                lastName = ""
            case "genre" where !value.isEmpty:
                metadata.tags.append(value)
            case "lang":
                metadata.language = value
            case "annotation", "p" where path.contains("annotation"):
                if metadata.comments == nil, !value.isEmpty { metadata.comments = value }
            default:
                break
            }
        }
        path.removeLast()
    }
}
