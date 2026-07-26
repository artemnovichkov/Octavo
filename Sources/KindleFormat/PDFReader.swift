import Foundation
import PDFKit

enum PDFReader {
    /// PDFKit exposes the document info dictionary; most sideloaded PDFs have at least a title.
    static func metadata(of url: URL) -> EbookMetadata? {
        guard let document = PDFDocument(url: url) else { return nil }
        var result = EbookMetadata(title: url.deletingPathExtension().lastPathComponent)

        let attributes = document.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String,
           !title.trimmingCharacters(in: .whitespaces).isEmpty {
            result.title = title
        }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String,
           !author.trimmingCharacters(in: .whitespaces).isEmpty {
            result.authors = [author]
        }
        if let subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String, !subject.isEmpty {
            result.comments = subject
        }
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            result.tags = keywords
        }

        if let page = document.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: bounds.width, height: bounds.height), for: .mediaBox)
            result.cover = image.tiffRepresentation
                .flatMap { NSBitmapImageRep(data: $0) }
                .flatMap { $0.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) }
        }
        return result
    }
}
