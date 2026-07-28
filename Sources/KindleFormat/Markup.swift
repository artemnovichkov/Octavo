import Foundation

/// The markup handling shared by the readers and both writers.
///
/// There is no HTML tree parser here and there should not be one: nothing in Octavo needs a
/// DOM. Reading uses regexes for single-attribute lookups, and the KF8 writer uses `tags(in:)`,
/// a forward scanner that finds tag and attribute *byte ranges* and copies everything else
/// through untouched. Byte ranges are the point — every offset a KF8 index records is a byte
/// offset, so the writer can never afford to round-trip markup through a data structure.
enum Markup {
    // MARK: - Lookups

    static func attributeValues(in html: String, tag: String, attribute: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: attribute)
        let pattern = "<\(tag)\\b[^>]*?\\b\(escaped)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let source = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range(at: 1)) }
    }

    static func textOfFirst(tag: String, in html: String) -> String? {
        guard let range = html.range(
            of: "<\(tag)[^>]*>(.*?)</\(tag)>",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let matched = String(html[range])
        guard let open = matched.range(of: ">"), let close = matched.range(of: "<", options: .backwards)
        else { return nil }
        return String(matched[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The attribute text of an opening tag, leading space and all, ready to paste into a
    /// rebuilt tag: `<body class="calibre">` gives back ` class="calibre"`.
    static func openTagAttributes(of tag: String, in html: String) -> String? {
        guard let range = html.range(
            of: "<\(tag)(\\s[^>]*)?>",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let matched = html[range].dropFirst(tag.count + 1).dropLast()
        return matched.hasSuffix("/") ? String(matched.dropLast()) : String(matched)
    }

    // MARK: - Tokenizing

    struct Tag {
        enum Kind {
            case open
            case close
            /// Comments, processing instructions, doctypes and CDATA — copied through verbatim.
            case other
        }

        struct Attribute {
            /// Both ranges are relative to the start of the tag, not the document.
            var name: Range<Int>
            var value: Range<Int>
        }

        var range: Range<Int>
        var name: String
        var kind: Kind
        var isSelfClosing: Bool
        var attributes: [Attribute]
    }

    static func tags(in bytes: [UInt8]) -> [Tag] {
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
        let bang = UInt8(ascii: "!"), question = UInt8(ascii: "?")
        var result: [Tag] = []
        var index = 0

        while index < bytes.count {
            guard bytes[index] == lt else { index += 1; continue }

            if starts(bytes, at: index, with: "<!--") {
                let end = find(bytes, "-->", from: index + 4).map { $0 + 3 } ?? bytes.count
                result.append(Tag(range: index..<end, name: "", kind: .other, isSelfClosing: false, attributes: []))
                index = end
                continue
            }
            if index + 1 < bytes.count, bytes[index + 1] == bang || bytes[index + 1] == question {
                let end = bytes[(index + 2)...].firstIndex(of: gt).map { $0 + 1 } ?? bytes.count
                result.append(Tag(range: index..<end, name: "", kind: .other, isSelfClosing: false, attributes: []))
                index = end
                continue
            }

            // Attribute values may contain '>', so quoting has to be tracked.
            var cursor = index + 1
            var quote: UInt8?
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    quote = byte
                } else if byte == gt {
                    break
                }
                cursor += 1
            }
            guard cursor < bytes.count else { break }  // unterminated tag: leave the tail alone

            let range = index..<(cursor + 1)
            let isClosing = index + 1 < bytes.count && bytes[index + 1] == slash
            let selfClosing = cursor > index + 1 && bytes[cursor - 1] == slash
            var inner = (index + (isClosing ? 2 : 1))..<(selfClosing ? cursor - 1 : cursor)

            var name = ""
            var attributes: [Tag.Attribute] = []
            if inner.lowerBound < inner.upperBound {
                var scan = inner.lowerBound
                while scan < inner.upperBound, !isSpace(bytes[scan]) { scan += 1 }
                name = String(decoding: bytes[inner.lowerBound..<scan], as: UTF8.self).lowercased()
                inner = scan..<inner.upperBound
                if !isClosing {
                    attributes = parseAttributes(bytes, in: inner, base: index)
                }
            }

            result.append(Tag(
                range: range,
                name: name,
                kind: isClosing ? .close : .open,
                isSelfClosing: selfClosing,
                attributes: attributes
            ))
            index = cursor + 1
        }

        return result
    }

    private static func parseAttributes(_ bytes: [UInt8], in range: Range<Int>, base: Int) -> [Tag.Attribute] {
        var result: [Tag.Attribute] = []
        var index = range.lowerBound

        while index < range.upperBound {
            while index < range.upperBound, isSpace(bytes[index]) { index += 1 }
            guard index < range.upperBound else { break }

            let nameStart = index
            while index < range.upperBound, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: "=") {
                index += 1
            }
            let nameRange = nameStart..<index
            guard !nameRange.isEmpty else { index += 1; continue }

            while index < range.upperBound, isSpace(bytes[index]) { index += 1 }
            guard index < range.upperBound, bytes[index] == UInt8(ascii: "=") else {
                continue  // a valueless attribute; nothing here needs one
            }
            index += 1
            while index < range.upperBound, isSpace(bytes[index]) { index += 1 }
            guard index < range.upperBound else { break }

            let valueRange: Range<Int>
            if bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                let quote = bytes[index]
                index += 1
                let valueStart = index
                while index < range.upperBound, bytes[index] != quote { index += 1 }
                valueRange = valueStart..<index
                if index < range.upperBound { index += 1 }
            } else {
                let valueStart = index
                while index < range.upperBound, !isSpace(bytes[index]) { index += 1 }
                valueRange = valueStart..<index
            }

            result.append(Tag.Attribute(
                name: (nameRange.lowerBound - base)..<(nameRange.upperBound - base),
                value: (valueRange.lowerBound - base)..<(valueRange.upperBound - base)
            ))
        }

        return result
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func starts(_ bytes: [UInt8], at index: Int, with text: String) -> Bool {
        let pattern = Array(text.utf8)
        guard index + pattern.count <= bytes.count else { return false }
        return Array(bytes[index..<(index + pattern.count)]) == pattern
    }

    private static func find(_ bytes: [UInt8], _ text: String, from index: Int) -> Int? {
        let pattern = Array(text.utf8)
        guard pattern.count <= bytes.count else { return nil }
        var scan = index
        while scan + pattern.count <= bytes.count {
            if Array(bytes[scan..<(scan + pattern.count)]) == pattern { return scan }
            scan += 1
        }
        return nil
    }
}
