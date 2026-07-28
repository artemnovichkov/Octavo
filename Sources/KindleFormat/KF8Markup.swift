import Foundation

/// Rewrites a `BookDocument`'s sections into the markup KF8 stores.
///
/// Three things change. Every element gets an `aid` — a base-32 counter — because that is what
/// the chunk index selects elements by. Stylesheets become `kindle:flow:` links and images
/// `kindle:embed:` references, since a KF8 file has no filenames to point at. And internal
/// links become `kindle:pos:fid:XXXX:off:YYYYYYYYYY`, where the chunk number and offset are not
/// known until the text has been chunked — so they go in as a **fixed-width placeholder** and
/// are patched in place afterwards. Fixed width is the whole trick: patching must not move a
/// single byte, or every offset already recorded would be wrong.
///
/// Sections are rebuilt from their parts rather than edited in place. EPUBs in the wild are
/// inconsistent about what they wrap content in, and a KF8 skeleton has to be predictable.
enum KF8Markup {
    /// `kindle:pos:fid:0000:off:0000000000` — 33 bytes, and never any other length.
    static let linkPlaceholder = "kindle:pos:fid:0000:off:0000000000"
    static let fidWidth = 4
    static let offsetWidth = 10

    struct Link {
        /// Byte offset of the placeholder's first character within the section.
        var offset: Int
        var target: BookDocument.LinkTarget
    }

    struct Section {
        var bytes: [UInt8]
        /// Element `id`/`name` → byte offset of that element's opening `<`, within `bytes`.
        var anchors: [String: Int]
        var links: [Link]
        /// The body's content: everything outside it is skeleton, everything inside is chunks.
        var bodyContent: Range<Int>
    }

    static func prepare(_ document: BookDocument) -> [Section] {
        var nextAID = 0
        return document.sections.map { section in
            prepare(section, stylesheets: document.stylesheets.count, nextAID: &nextAID)
        }
    }

    private static func prepare(
        _ section: BookDocument.Section,
        stylesheets: Int,
        nextAID: inout Int
    ) -> Section {
        var output = [UInt8]()
        var anchors: [String: Int] = [:]
        var links: [Link] = []

        func emit(_ text: String) { output.append(contentsOf: Array(text.utf8)) }

        emit("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        emit("<html xmlns=\"http://www.w3.org/1999/xhtml\">\n<head>\n")
        emit("<title>\(escape(Markup.textOfFirst(tag: "title", in: section.xhtml) ?? ""))</title>\n")
        emit("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"/>\n")
        // Flows are numbered from 1 — flow 0 is the markup itself. A section links every
        // stylesheet in the book rather than only its own: KF8 has one flow list per file, and
        // dropping a sheet a later section needs is worse than loading one this section does not.
        for flow in 1...max(1, stylesheets) where stylesheets > 0 {
            emit("<link rel=\"stylesheet\" type=\"text/css\" href=\"kindle:flow:\(String(format: "%04d", flow))?mime=text/css\"/>\n")
        }
        emit("</head>\n")

        let bodyAttributes = Markup.openTagAttributes(of: "body", in: section.xhtml) ?? ""
        emit("<body\(bodyAttributes) aid=\"\(Base32.encode(nextAID))\">")
        nextAID += 1

        let bodyContentOffset = output.count
        let content = Array(HTMLFlattener.body(of: section.xhtml).utf8)
        transform(
            content,
            into: &output,
            section: section,
            nextAID: &nextAID,
            anchors: &anchors,
            links: &links
        )

        let bodyContentEnd = output.count
        emit("</body>\n</html>")
        return Section(
            bytes: output,
            anchors: anchors,
            links: links,
            bodyContent: bodyContentOffset..<bodyContentEnd
        )
    }

    /// Walks the body's tags once, copying everything through and editing the tags in place:
    /// an `aid` appended, `src`/`href` values swapped. Text between tags is never touched.
    private static func transform(
        _ content: [UInt8],
        into output: inout [UInt8],
        section: BookDocument.Section,
        nextAID: inout Int,
        anchors: inout [String: Int],
        links: inout [Link]
    ) {
        var cursor = 0
        for tag in Markup.tags(in: content) {
            output.append(contentsOf: content[cursor..<tag.range.lowerBound])
            cursor = tag.range.upperBound

            guard tag.kind == .open else {
                // Comments, declarations and closing tags go through as they are.
                output.append(contentsOf: content[tag.range])
                continue
            }

            let tagStart = output.count
            let raw = Array(content[tag.range])

            var edits: [(range: Range<Int>, replacement: String, target: BookDocument.LinkTarget?)] = []
            for attribute in tag.attributes {
                let name = String(decoding: raw[attribute.name], as: UTF8.self).lowercased()
                let value = String(decoding: raw[attribute.value], as: UTF8.self)
                switch name {
                case "id", "name":
                    anchors[value] = tagStart
                case "src", "xlink:href":
                    if let resource = section.resources[value] {
                        edits.append((attribute.value, embedURI(resource), nil))
                    }
                case "href" where tag.name == "a":
                    if let target = section.links[value] {
                        edits.append((attribute.value, linkPlaceholder, target))
                    }
                default:
                    break
                }
            }

            // `aid` goes right before the tag closes, so `<br/>` stays `<br aid="X"/>`.
            let insertAt = tag.isSelfClosing ? raw.count - 2 : raw.count - 1
            edits.append((insertAt..<insertAt, " aid=\"\(Base32.encode(nextAID))\"", nil))
            nextAID += 1

            // Applied front to back so each placeholder's offset in the *output* is known as
            // it is written. Anything computed against the source would be off by the edits
            // before it, and a link offset that is off by even one byte points at nothing.
            var last = 0
            for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                output.append(contentsOf: raw[last..<edit.range.lowerBound])
                if let target = edit.target {
                    links.append(Link(offset: output.count, target: target))
                }
                output.append(contentsOf: Array(edit.replacement.utf8))
                last = edit.range.upperBound
            }
            output.append(contentsOf: raw[last...])
        }
        output.append(contentsOf: content[cursor...])
    }

    /// `kindle:embed:` numbers resources from 1, in hex, and the Kindle sniffs the type itself
    /// — the `mime` parameter is advisory, so JPEG is a safe thing to claim for anything.
    private static func embedURI(_ resource: Int) -> String {
        "kindle:embed:\(String(format: "%04X", resource + 1))"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Patching

    /// Fills in a placeholder once the chunk it points into is known. Both halves are written
    /// at their fixed widths, so the byte count is unchanged and every recorded offset holds.
    static func patch(_ bytes: inout [UInt8], at offset: Int, chunk: Int, within: Int) {
        let filled = "kindle:pos:fid:\(Base32.encode(chunk, width: fidWidth))"
            + ":off:\(Base32.encode(within, width: offsetWidth))"
        let replacement = Array(filled.utf8)
        guard replacement.count == linkPlaceholder.utf8.count,
              offset + replacement.count <= bytes.count
        else { return }
        bytes.replaceSubrange(offset..<(offset + replacement.count), with: replacement)
    }
}
