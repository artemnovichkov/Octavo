import Foundation
import Testing
@testable import KindleFormat

/// The reading half of conversion. These are the inputs the AZW3 writer is built on, so it is
/// worth knowing they are actually populated — an EPUB whose stylesheets came back empty would
/// silently produce an AZW3 that renders no better than the MOBI it replaced.
@Suite struct BookDocumentTests {
    @Test func readsSpineStylesheetsAndTOCFromTheCorpus() throws {
        let urls = corpusFiles(withExtension: "epub")
        guard !urls.isEmpty else { return }

        var withStylesheets = 0
        var withTOC = 0

        for url in urls {
            let document = try Converter.readEPUB(url)
            let name = url.lastPathComponent

            #expect(!document.sections.isEmpty, "\(name): пустой spine")
            #expect(document.sections.allSatisfy { !$0.xhtml.isEmpty }, "\(name)")
            #expect(!document.metadata.title.isEmpty, "\(name)")

            if !document.stylesheets.isEmpty {
                withStylesheets += 1
                #expect(
                    document.sections.contains { !$0.stylesheets.isEmpty },
                    "\(name): стили есть, но ни одна секция на них не ссылается"
                )
                #expect(
                    document.sections.allSatisfy { $0.stylesheets.allSatisfy { $0 < document.stylesheets.count } },
                    "\(name): ссылка на несуществующий стиль"
                )
            }
            if !document.toc.isEmpty {
                withTOC += 1
                #expect(
                    document.toc.allSatisfy { $0.sectionIndex < document.sections.count },
                    "\(name): оглавление ссылается за пределы spine"
                )
            }

            // Resource maps are what both writers rewrite `src` through; a dangling index
            // would put the wrong picture on the page rather than fail.
            for section in document.sections {
                #expect(
                    section.resources.values.allSatisfy { $0 < document.resources.count },
                    "\(name): ссылка на несуществующий ресурс"
                )
            }
            if let cover = document.coverResourceIndex {
                #expect(cover < document.resources.count, "\(name)")
            }
        }

        // Nearly every EPUB in the wild ships both. If these collapse, the readers regressed.
        #expect(withStylesheets >= urls.count * 3 / 4, "стили нашлись только в \(withStylesheets) из \(urls.count)")
        #expect(withTOC >= urls.count / 2, "оглавление нашлось только в \(withTOC) из \(urls.count)")
    }

    @Test func comicBecomesOneSectionPerPage() throws {
        guard let cbz = corpusFiles(withExtension: "cbz").first else { return }
        let document = try Converter.readComic(cbz)

        #expect(document.sections.count == document.resources.count)
        #expect(document.coverResourceIndex == 0)
        for (index, section) in document.sections.enumerated() {
            #expect(section.resources.count == 1, "у страницы должна быть ровно одна картинка")
            #expect(section.resources.values.first == index, "страницы должны идти по порядку")
        }
    }
}
