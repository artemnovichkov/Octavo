import AppKit
import CalibreLibrary
import SwiftUI

struct CoverImage: View {
    let book: Book
    let library: URL
    var height: CGFloat = 220

    var body: some View {
        Group {
            if let image = CoverCache.shared.image(for: book, in: library) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) }
                    .aspectRatio(2 / 3, contentMode: .fit)
            }
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 4))
    }
}

/// Covers are read straight from the calibre folders, so a small cache keeps the
/// table from hitting the disk on every redraw.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private var images: [String: NSImage] = [:]

    func image(for book: Book, in library: URL) -> NSImage? {
        if let cached = images[book.uuid] { return cached }
        guard let url = book.coverURL(in: library),
              let image = NSImage(contentsOf: url)
        else { return nil }
        images[book.uuid] = image
        return image
    }

    func invalidate(_ book: Book) {
        images[book.uuid] = nil
    }

    /// Covers are keyed by uuid, which says nothing about which library they came from.
    func removeAll() {
        images.removeAll()
    }
}

struct BookDetailView: View {
    @Environment(AppModel.self) private var model
    let book: Book
    @State private var isEditing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    CoverImage(book: book, library: model.libraryRoot)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title).font(.title2).bold()
                        Text(book.authorDisplay).font(.title3).foregroundStyle(.secondary)
                        if let series = book.series {
                            Text("\(series) #\(book.seriesIndex.formatted(.number.precision(.fractionLength(0...1))))")
                                .foregroundStyle(.secondary)
                        }
                        statusBadge
                    }
                    Spacer()
                }

                if !book.tags.isEmpty {
                    FlowTags(tags: book.tags)
                }

                GroupBox("Files") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(book.formats, id: \.self) { format in
                            HStack {
                                Text(format.format).font(.callout.monospaced()).bold()
                                Text(format.filename).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: format.size, countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                if let publisher = book.publisher {
                    LabeledContent("Publisher", value: publisher)
                }
                if let pubdate = book.pubdate {
                    LabeledContent("Publication date", value: pubdate.formatted(date: .abbreviated, time: .omitted))
                }
                if let isbn = book.isbn {
                    LabeledContent("ISBN", value: isbn)
                }

                if let comments = book.comments, !comments.isEmpty {
                    GroupBox("Description") {
                        Text(stripHTML(comments))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
            }
            .padding()
        }
        .toolbar {
            Button("Metadata…", systemImage: "pencil") { isEditing = true }
        }
        .sheet(isPresented: $isEditing) {
            MetadataEditor(book: book)
        }
    }

    private var statusBadge: some View {
        let status = model.status(of: book)
        return Label(status.help, systemImage: status.symbol)
            .font(.callout)
            .padding(.top, 4)
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct FlowTags: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
            }
        }
    }
}

/// Wraps onto as many rows as it needs. The previous `ViewThatFits` between an HStack and a
/// VStack was not a flow at all — past a handful of tags it collapsed to one per line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(within: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(within: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(within maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
