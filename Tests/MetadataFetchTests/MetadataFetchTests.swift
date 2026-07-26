import Foundation
import Testing
@testable import MetadataFetch

@Test func parsesGoogleDates() {
    #expect(MetadataFetcher.date(fromGoogleDate: "2015-03-17") != nil)
    #expect(MetadataFetcher.date(fromGoogleDate: "2015-03") != nil)
    #expect(MetadataFetcher.date(fromGoogleDate: "2015") != nil)
    #expect(MetadataFetcher.date(fromGoogleDate: "весна") == nil)
}

/// Hits the real catalogues; skipped unless OCTAVO_NETWORK_TESTS=1 so the suite stays offline.
@Test(.requiresNetwork, .tags(.network)) func searchesLatinTitle() async {
    let results = await MetadataFetcher(googleAPIKey: nil).search(title: "Dune", author: "Frank Herbert")
    #expect(results.candidates.contains { $0.source == "Open Library" })
    #expect(results.candidates.contains { $0.coverURL != nil })
}

/// Open Library indexes almost nothing in Cyrillic — FantLab is what makes the
/// Russian half of the library searchable.
@Test(.requiresNetwork, .tags(.network)) func searchesRussianTitle() async {
    let results = await MetadataFetcher(googleAPIKey: nil).search(title: "Заповедник", author: "Сергей Довлатов")
    let fantLab = results.candidates.filter { $0.source == "FantLab" }
    #expect(!fantLab.isEmpty)
    #expect(fantLab.contains { $0.authors.contains("Сергей Довлатов") })
}

extension Tag {
    @Tag static var network: Self
}

extension Trait where Self == ConditionTrait {
    /// The gate lives in the source rather than in a `--skip` regex on the CI command line,
    /// so renaming a test cannot silently put it back on the network.
    static var requiresNetwork: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["OCTAVO_NETWORK_TESTS"] == "1",
            "set OCTAVO_NETWORK_TESTS=1 to run the tests that hit the live catalogues"
        )
    }
}

/// Search endpoints carry neither an annotation nor (usually) a cover, which is why applying
/// a result used to leave Описание and the cover untouched. Enrichment is what fills them.
@Test(.requiresNetwork, .tags(.network)) func enrichesFantLabCandidateWithDescriptionAndCover() async throws {
    let fetcher = MetadataFetcher()
    let results = await fetcher.search(title: "Наши", author: "Сергей Довлатов")

    guard let bare = results.candidates.first(where: { $0.source == "FantLab" && $0.title == "Наши" }) else {
        return  // FantLab unreachable or changed its ranking; the network tests bail quietly.
    }
    #expect(bare.comments == nil)

    let full = await fetcher.enrich(bare)
    let comments = try #require(full.comments)
    #expect(comments.count > 20)
    #expect(comments.lowercased().contains("повесть"))

    let cover = try #require(full.coverURL)
    #expect(cover.absoluteString.hasPrefix("https://data.fantlab.ru/images/"))

    let data = try #require(try await fetcher.coverData(for: full))
    #expect(data.count > 1000)
    #expect(Array(data.prefix(2)) == [0xFF, 0xD8])  // JPEG magic
}
