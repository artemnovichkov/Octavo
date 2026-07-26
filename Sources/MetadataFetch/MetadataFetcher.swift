import Foundation

public struct MetadataCandidate: Sendable, Identifiable, Hashable {
    public let id: String
    public let source: String
    public var title: String
    public var authors: [String]
    public var publisher: String?
    public var published: Date?
    public var comments: String?
    public var isbn: String?
    public var tags: [String]
    public var coverURL: URL?

    public var authorDisplay: String { authors.joined(separator: ", ") }

    /// Ids are namespaced by source where they are built: "fl:305966", "ol:/works/OL27448W",
    /// "gb:zyTCAlFPjgYC". Splitting that back out is what lets `enrich` pick an endpoint.
    var reference: (source: String, value: String)? {
        guard let separator = id.firstIndex(of: ":") else { return nil }
        return (String(id[..<separator]), String(id[id.index(after: separator)...]))
    }

    public var subtitle: String {
        var parts: [String] = []
        if !authors.isEmpty { parts.append(authorDisplay) }
        if let published { parts.append(published.formatted(.dateTime.year())) }
        if let publisher { parts.append(publisher) }
        return parts.joined(separator: " · ")
    }
}

public struct SearchResults: Sendable {
    public var candidates: [MetadataCandidate] = []
    /// Per-source problems worth showing: an exhausted quota looks exactly like
    /// "nothing found" otherwise.
    public var notes: [String] = []
}

/// Looks up book metadata in Open Library, FantLab and Google Books.
///
/// Coverage differs a lot by language: Open Library indexes almost no Russian titles,
/// FantLab covers Russian fiction well, and Google Books covers both but throttles
/// anonymous callers — set `GoogleBooksAPIKey` in defaults to get a private quota.
public struct MetadataFetcher: Sendable {
    private let session: URLSession
    private let googleAPIKey: String?

    public init(session: URLSession = .shared, googleAPIKey: String? = UserDefaults.standard.string(forKey: "GoogleBooksAPIKey")) {
        self.session = session
        self.googleAPIKey = googleAPIKey?.isEmpty == true ? nil : googleAPIKey
    }

    /// Searches every source at once. An ISBN match wins, so it goes first when known.
    public func search(title: String, author: String? = nil, isbn: String? = nil) async -> SearchResults {
        async let openLibrary = searchOpenLibrary(title: title, author: author, isbn: isbn)
        async let fantLab = searchFantLab(title: title, author: author)
        async let google = searchGoogleBooks(title: title, author: author, isbn: isbn)

        var results = SearchResults()
        for source in await [openLibrary, fantLab, google] {
            switch source {
            case .success(let candidates): results.candidates += candidates
            case .failure(let note): results.notes.append(note)
            }
        }
        return results
    }

    enum SourceOutcome {
        case success([MetadataCandidate])
        case failure(String)
    }

    /// Fills in what the search endpoints leave out.
    ///
    /// Neither FantLab's `search-works` nor Open Library's `search.json` returns an
    /// annotation, and FantLab's list-level `pic_edition_id` is 0 for most works — so a
    /// candidate straight out of `search` usually has no description and no cover, and
    /// applying it silently changed neither. The per-work endpoints carry both, so they are
    /// fetched on demand, when the user actually picks a result rather than for all of them.
    ///
    /// Returns the candidate unchanged if the source has no detail endpoint or the request
    /// fails; enrichment is a bonus, never a reason to block applying what we already have.
    public func enrich(_ candidate: MetadataCandidate) async -> MetadataCandidate {
        guard let reference = candidate.reference else { return candidate }
        switch reference.source {
        case "fl": return await enrichFantLab(candidate, workID: reference.value)
        case "ol": return await enrichOpenLibrary(candidate, key: reference.value)
        default: return candidate   // Google Books already returns both in the search payload.
        }
    }

    private func enrichFantLab(_ candidate: MetadataCandidate, workID: String) async -> MetadataCandidate {
        guard let url = URL(string: "https://api.fantlab.ru/work/\(workID)"),
              let payload: FantLabWork = try? await decode(url)
        else { return candidate }

        var enriched = candidate
        if enriched.comments?.isEmpty != false {
            enriched.comments = payload.work_description?.trimmed.nilWhenEmpty
        }
        if enriched.coverURL == nil, let image = payload.image?.trimmed.nilWhenEmpty {
            // Site-relative, e.g. "/images/editions/big/333731?r=1635955349".
            enriched.coverURL = URL(string: "https://data.fantlab.ru\(image)")
        }
        return enriched
    }

    private func enrichOpenLibrary(_ candidate: MetadataCandidate, key: String) async -> MetadataCandidate {
        // `key` is already a path like "/works/OL27448W".
        guard key.hasPrefix("/"),
              let url = URL(string: "https://openlibrary.org\(key).json"),
              let payload: OpenLibraryWork = try? await decode(url)
        else { return candidate }

        var enriched = candidate
        if enriched.comments?.isEmpty != false {
            enriched.comments = payload.description?.trimmed.nilWhenEmpty
        }
        return enriched
    }

    public func coverData(for candidate: MetadataCandidate) async throws -> Data? {
        guard let url = candidate.coverURL else { return nil }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    // MARK: - Open Library

    private func searchOpenLibrary(title: String, author: String?, isbn: String?) async -> SourceOutcome {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        var query: [URLQueryItem] = [
            .init(name: "limit", value: "5"),
            .init(name: "fields", value: "key,title,author_name,first_publish_year,isbn,cover_i,publisher,subject"),
        ]
        if let isbn, !isbn.isEmpty {
            query.append(.init(name: "isbn", value: isbn))
        } else {
            query.append(.init(name: "title", value: title))
            if let author, !author.isEmpty { query.append(.init(name: "author", value: author)) }
        }
        components.queryItems = query

        guard let url = components.url else { return .failure("Open Library: malformed request") }
        let payload: OpenLibraryResponse
        do {
            payload = try await decode(url)
        } catch {
            return .failure("Open Library: \(error.localizedDescription)")
        }

        return .success(payload.docs.map { doc in
            MetadataCandidate(
                id: "ol:\(doc.key ?? UUID().uuidString)",
                source: "Open Library",
                title: doc.title ?? title,
                authors: doc.author_name ?? [],
                publisher: doc.publisher?.first,
                published: doc.first_publish_year.flatMap(Self.date(fromYear:)),
                comments: nil,
                isbn: doc.isbn?.first,
                tags: Array((doc.subject ?? []).prefix(8)),
                coverURL: doc.cover_i.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") }
            )
        })
    }

    // MARK: - FantLab

    /// Russian catalogue, keyless. Indexes fiction by title and author in Cyrillic,
    /// which is exactly what Open Library misses.
    private func searchFantLab(title: String, author: String?) async -> SourceOutcome {
        var components = URLComponents(string: "https://api.fantlab.ru/search-works")!
        let query = [title, author].compactMap { $0 }.joined(separator: " ")
        components.queryItems = [.init(name: "q", value: query), .init(name: "page", value: "1")]

        guard let url = components.url else { return .failure("FantLab: malformed request") }
        let payload: FantLabResponse
        do {
            payload = try await decode(url)
        } catch {
            return .failure("FantLab: \(error.localizedDescription)")
        }

        return .success(payload.matches.prefix(5).map { match in
            let authors = [match.autor1_rusname, match.autor2_rusname, match.autor3_rusname]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            let keywords = (match.keywords ?? "")
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            return MetadataCandidate(
                id: "fl:\(match.work_id ?? 0)",
                source: "FantLab",
                title: match.rusname ?? match.name ?? title,
                authors: authors,
                publisher: nil,
                published: match.year.flatMap(Self.date(fromYear:)),
                comments: nil,
                isbn: nil,
                tags: Array(keywords.prefix(8)),
                // pic_edition_id is 0 when no edition cover exists.
                coverURL: (match.pic_edition_id ?? 0) > 0
                    ? URL(string: "https://data.fantlab.ru/images/editions/big/\(match.pic_edition_id!)")
                    : nil
            )
        })
    }

    // MARK: - Google Books

    private func searchGoogleBooks(title: String, author: String?, isbn: String?) async -> SourceOutcome {
        var terms: [String] = []
        if let isbn, !isbn.isEmpty {
            terms.append("isbn:\(isbn)")
        } else {
            terms.append("intitle:\(title)")
            if let author, !author.isEmpty { terms.append("inauthor:\(author)") }
        }

        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            .init(name: "q", value: terms.joined(separator: "+")),
            .init(name: "maxResults", value: "5"),
        ]
        if let googleAPIKey { components.queryItems?.append(.init(name: "key", value: googleAPIKey)) }

        guard let url = components.url else { return .failure("Google Books: malformed request") }
        let payload: GoogleBooksResponse
        do {
            payload = try await decode(url)
        } catch MetadataFetchError.quotaExceeded {
            return .failure(googleAPIKey == nil
                ? "Google Books: the shared anonymous quota is exhausted. Your own key: settings → GoogleBooksAPIKey"
                : "Google Books: your key's quota is exhausted")
        } catch {
            return .failure("Google Books: \(error.localizedDescription)")
        }

        return .success((payload.items ?? []).map { item in
            let info = item.volumeInfo
            var cover = info.imageLinks?.thumbnail ?? info.imageLinks?.smallThumbnail
            cover = cover?.replacingOccurrences(of: "http://", with: "https://")
            return MetadataCandidate(
                id: "gb:\(item.id)",
                source: "Google Books",
                title: info.title ?? title,
                authors: info.authors ?? [],
                publisher: info.publisher,
                published: info.publishedDate.flatMap(Self.date(fromGoogleDate:)),
                comments: info.description,
                isbn: info.industryIdentifiers?.first(where: { $0.type?.hasPrefix("ISBN") == true })?.identifier,
                tags: Array((info.categories ?? []).prefix(8)),
                coverURL: cover.flatMap { URL(string: $0) }
            )
        })
    }

    private func decode<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Octavo/1.0 (personal Kindle library manager)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)

        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw status == 429 ? MetadataFetchError.quotaExceeded : MetadataFetchError.badStatus(status)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func date(fromYear year: Int) -> Date? {
        DateComponents(calendar: .current, timeZone: .gmt, year: year, month: 1, day: 1).date
    }

    /// Google returns "2015", "2015-03" or "2015-03-17".
    static func date(fromGoogleDate raw: String) -> Date? {
        let formats = ["yyyy-MM-dd", "yyyy-MM", "yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

public enum MetadataFetchError: Error, LocalizedError {
    case quotaExceeded
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .quotaExceeded: return "quota exhausted"
        case .badStatus(let code): return "the server answered \(code)"
        }
    }
}

// MARK: - Wire formats

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

private struct FantLabWork: Decodable {
    let work_description: String?
    let image: String?
}

/// Open Library returns `description` as either a bare string or `{"type": …, "value": …}`,
/// depending on the record's age.
private struct OpenLibraryWork: Decodable {
    let description: String?

    private enum CodingKeys: String, CodingKey { case description }
    private struct Wrapped: Decodable { let value: String? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .description) {
            description = text
        } else {
            description = try? container.decode(Wrapped.self, forKey: .description).value
        }
    }
}

private struct FantLabResponse: Decodable {
    struct Match: Decodable {
        let work_id: Int?
        let name: String?
        let rusname: String?
        let year: Int?
        let keywords: String?
        let pic_edition_id: Int?
        let autor1_rusname: String?
        let autor2_rusname: String?
        let autor3_rusname: String?
    }
    let matches: [Match]
}

private struct OpenLibraryResponse: Decodable {
    struct Doc: Decodable {
        let key: String?
        let title: String?
        let author_name: [String]?
        let first_publish_year: Int?
        let isbn: [String]?
        let cover_i: Int?
        let publisher: [String]?
        let subject: [String]?
    }
    let docs: [Doc]
}

private struct GoogleBooksResponse: Decodable {
    struct Item: Decodable {
        struct VolumeInfo: Decodable {
            struct ImageLinks: Decodable {
                let smallThumbnail: String?
                let thumbnail: String?
            }
            struct Identifier: Decodable {
                let type: String?
                let identifier: String?
            }
            let title: String?
            let authors: [String]?
            let publisher: String?
            let publishedDate: String?
            let description: String?
            let categories: [String]?
            let industryIdentifiers: [Identifier]?
            let imageLinks: ImageLinks?
        }
        let id: String
        let volumeInfo: VolumeInfo
    }
    let items: [Item]?
}
