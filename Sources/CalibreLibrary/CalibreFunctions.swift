import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// calibre defines `title_sort()` and `uuid4()` in Python and its schema triggers call
/// them — `books_insert_trg`, `books_update_trg`, `series_insert_trg`, `series_update_trg`.
/// Any process that writes to metadata.db has to supply its own implementations or every
/// INSERT/UPDATE fails with "no such function".
public enum CalibreFunctions {
    public static func register(on database: SQLiteDatabase) {
        sqlite3_create_function_v2(
            database.handle, "title_sort", 1,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            { context, argumentCount, arguments in
                guard argumentCount >= 1, let arguments,
                      let text = sqlite3_value_text(arguments[0])
                else {
                    sqlite3_result_null(context)
                    return
                }
                let result = CalibreFunctions.titleSort(String(cString: text))
                sqlite3_result_text(context, result, -1, SQLITE_TRANSIENT)
            },
            nil, nil, nil
        )

        sqlite3_create_function_v2(
            database.handle, "uuid4", 0,
            SQLITE_UTF8, nil,
            { context, _, _ in
                sqlite3_result_text(context, UUID().uuidString.lowercased(), -1, SQLITE_TRANSIENT)
            },
            nil, nil, nil
        )
    }

    /// Matches calibre's default `title_sort`: a leading article moves to the end.
    /// "The Hobbit" -> "Hobbit, The".
    public static func titleSort(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["A", "The", "An"] {
            let prefix = article + " "
            if trimmed.count > prefix.count,
               trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                let rest = trimmed.dropFirst(article.count).trimmingCharacters(in: .whitespaces)
                return "\(rest), \(trimmed.prefix(article.count))"
            }
        }
        return trimmed
    }

    /// calibre's default `author_sort_copy_method` ("invert"): "Gergely Orosz" -> "Orosz, Gergely".
    public static func authorSort(_ author: String) -> String {
        let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "i", "ii", "iii", "iv", "md", "phd"]
        var tokens = author.split(separator: " ").map(String.init)
        guard tokens.count > 1 else { return author }

        var suffix = ""
        if let last = tokens.last, suffixes.contains(last.lowercased()) {
            suffix = " " + last
            tokens.removeLast()
        }
        guard tokens.count > 1, let family = tokens.last else { return author }
        let given = tokens.dropLast().joined(separator: " ")
        return "\(family)\(suffix), \(given)"
    }

    public static func authorSort(of authors: [String]) -> String {
        authors.map(authorSort).joined(separator: " & ")
    }

    /// Folder and file names for the library and the device: plain ASCII, no characters
    /// that any filesystem could object to.
    public static func filenameSafe(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        var stripped = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin

        // toLatin leaves modifier letters behind ("Путь" -> "Putʹ"); fold them to a quote
        // and drop whatever else is still outside ASCII.
        for quote in ["ʹ", "ʺ", "’", "‘", "“", "”"] {
            stripped = stripped.replacingOccurrences(of: quote, with: "'")
        }
        stripped = String(stripped.unicodeScalars.filter { $0.isASCII })

        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = stripped
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
