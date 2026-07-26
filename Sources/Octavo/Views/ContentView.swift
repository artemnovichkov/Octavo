import AppKit
import CalibreLibrary
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isImporting = false
    @State private var pendingRemoval: [Book] = []

    /// azw3/mobi/cbz/fb2 have no system-declared UTType, so they are derived from the
    /// filename extension.
    private var importableTypes: [UTType] {
        AppModel.importableExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } content: {
            BookTable(pendingRemoval: $pendingRemoval)
                .navigationSplitViewColumnWidth(min: 420, ideal: 640)
        } detail: {
            DetailPane()
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search by title, author, series")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isImporting = true
                } label: {
                    Label("Add books", systemImage: "plus")
                }
                .help("Add books to the library (or drop files onto the list)")
                // Importing needs somewhere to import to; without a library it would no-op.
                .disabled(model.store == nil)
            }
        }
        .toolbar { DeviceToolbar() }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: importableTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .alert(
            "Import finished",
            isPresented: Binding(
                get: { model.importSummary != nil },
                set: { if !$0 { model.importSummary = nil } }
            )
        ) {
            Button("OK") { model.importSummary = nil }
        } message: {
            Text(model.importSummary?.message ?? "")
        }
        .alert(
            "Could not open that folder",
            isPresented: Binding(
                get: { model.libraryAlert != nil },
                set: { if !$0 { model.libraryAlert = nil } }
            )
        ) {
            Button("OK") { model.libraryAlert = nil }
        } message: {
            Text(model.libraryAlert ?? "")
        }
        .confirmationDialog(
            removalPrompt,
            isPresented: Binding(
                get: { !pendingRemoval.isEmpty },
                set: { if !$0 { pendingRemoval = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                let books = pendingRemoval
                pendingRemoval = []
                Task { await model.removeFromDevice(books) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = [] }
        } message: {
            Text("The files will be deleted from the Kindle. Reading progress and notes stay, and so do the books in the library.")
        }
        // The watcher's first drain reports an already-connected Kindle, so this covers
        // both launching with the cable in and plugging it in later.
        .task { await model.watchDevice() }
        .overlay(alignment: .bottom) { SyncStatusBar() }
    }

    private var removalPrompt: String {
        pendingRemoval.count == 1
            ? "Remove “\(pendingRemoval[0].title)” from the device?"
            : "Remove \(Plural.books(pendingRemoval.count)) from the device?"
    }
}

extension Book {
    /// Sort key that keeps a series together and orders it by volume. Books with no series
    /// collapse to the empty string and sort first.
    var seriesSortKey: String {
        guard let series else { return "" }
        return "\(series) \(String(format: "%08.2f", seriesIndex))"
    }

    var formatsLabel: String {
        formats.map(\.format).sorted().joined(separator: ", ")
    }
}

enum Plural {
    static func books(_ count: Int) -> String {
        "\(count) \(count == 1 ? "book" : "books")"
    }
}

struct DetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selection.count > 1 {
            ContentUnavailableView(
                "\(Plural.books(model.selection.count)) selected",
                systemImage: "books.vertical",
                description: Text("Right-click the list for actions on everything selected.")
            )
        } else if let id = model.selection.first, let book = model.books.first(where: { $0.id == id }) {
            BookDetailView(book: book)
        } else {
            ContentUnavailableView("No book selected", systemImage: "book.closed")
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.filter) {
            Section {
                label(.all, "books.vertical", model.books.count)
                label(.onDevice, "checkmark.circle", model.plan?.upToDate.count)
                label(.notOnDevice, "arrow.up.circle", model.plan?.send.count)
                label(.needsConversion, "wand.and.sparkles", model.plan?.send.filter(\.needsConversion).count)
            }

            Section("Authors") {
                ForEach(model.authors, id: \.self) { author in
                    Label(author, systemImage: "person").tag(AppModel.Filter.author(author))
                }
            }

            if !model.series.isEmpty {
                Section("Series") {
                    ForEach(model.series, id: \.self) { series in
                        Label(series, systemImage: "square.stack").tag(AppModel.Filter.series(series))
                    }
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags, id: \.self) { tag in
                        Label(tag, systemImage: "tag").tag(AppModel.Filter.tag(tag))
                    }
                }
            }
        }
    }

    private func label(_ filter: AppModel.Filter, _ symbol: String, _ count: Int?) -> some View {
        Label(filter.title, systemImage: symbol)
            .badge(count ?? 0)
            .tag(filter)
    }
}

struct BookTable: View {
    @Environment(AppModel.self) private var model
    @Binding var pendingRemoval: [Book]
    @State private var editing: Book?

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.libraryState {
            case .needsSetup:
                WelcomeView()
            case .failed(let error):
                ContentUnavailableView {
                    Label("Could not open the library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { model.loadLibrary() }
                    Button("Open Library…") {
                        if let url = LibraryPanels.chooseExistingLibrary() { model.openLibrary(at: url) }
                    }
                    Button("Create Library…") {
                        if let url = LibraryPanels.chooseNewLibrary() { model.createLibrary(at: url) }
                    }
                }
            case .loaded:
                table
            }
        }
        .navigationTitle(model.filter.title)
        .navigationSubtitle(Plural.books(model.filteredBooks.count))
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls)
            return true
        }
        .sheet(item: $editing) { MetadataEditor(book: $0) }
    }

    private var table: some View {
        @Bindable var model = model

        return Table(model.filteredBooks, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("") { book in
                Image(systemName: model.status(of: book).symbol)
                    .foregroundStyle(color(for: model.status(of: book)))
                    .help(model.status(of: book).help)
            }
            .width(20)

            // Sorted by calibre's title_sort rather than the raw title, so articles are
            // ignored the same way calibre ignores them.
            TableColumn("Title", value: \.sort) { book in
                HStack(spacing: 8) {
                    CoverImage(book: book, library: model.libraryRoot, height: 34)
                    Text(book.title).lineLimit(2)
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Author", value: \.authorSort) { book in
                Text(book.authorDisplay).lineLimit(1)
            }

            TableColumn("Series", value: \.seriesSortKey) { book in
                if let series = book.series {
                    Text("\(series) #\(book.seriesIndex.formatted(.number.precision(.fractionLength(0...1))))")
                        .lineLimit(1)
                }
            }

            TableColumn("Formats", value: \.formatsLabel) { book in
                Text(book.formatsLabel)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(110)
        }
        .contextMenu(forSelectionType: Book.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if let book = books(for: ids).first { editing = book }
        }
        .overlay {
            if model.filteredBooks.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<Book.ID>) -> some View {
        let chosen = books(for: ids)
        if !chosen.isEmpty {
            if chosen.count == 1 {
                Button("Metadata…", systemImage: "pencil") { editing = chosen[0] }
            }
            Button("Show in Finder", systemImage: "folder") { revealInFinder(chosen) }
            Divider()
            Button("Remove from device", systemImage: "eject", role: .destructive) {
                pendingRemoval = chosen
            }
            .disabled(!chosen.contains { model.status(of: $0) == .synced })
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.search.isEmpty {
            ContentUnavailableView.search(text: model.search)
        } else if model.books.isEmpty {
            ContentUnavailableView {
                Label("The library is empty", systemImage: "books.vertical")
            } description: {
                Text("Drop books here or press + in the toolbar.")
            }
        } else {
            ContentUnavailableView(
                "Nothing here",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("“\(model.filter.title)” has no books yet.")
            )
        }
    }

    private func books(for ids: Set<Book.ID>) -> [Book] {
        model.filteredBooks.filter { ids.contains($0.id) }
    }

    private func revealInFinder(_ books: [Book]) {
        let urls = books.map { model.libraryRoot.appending(path: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func color(for status: BookStatus) -> Color {
        switch status {
        case .synced: return .green
        case .pending: return .accentColor
        case .willConvert: return .purple
        case .unsupported: return .orange
        case .unknown: return .secondary
        }
    }
}

/// One bottom overlay for both halves of a sync's lifecycle: progress while it runs, then a
/// short confirmation. Previously `lastSyncSummary` was written but never shown anywhere.
struct SyncStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let progress = model.syncProgress {
                progressCard(progress)
            } else if let summary = model.lastSyncSummary {
                summaryCard(summary)
            }
        }
        .animation(.default, value: model.syncProgress == nil)
        .animation(.default, value: model.lastSyncSummary)
    }

    private func progressCard(_ progress: AppModel.SyncProgress) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.current).lineLimit(1).font(.callout)
                ProgressView(value: Double(progress.index), total: Double(max(progress.total, 1)))
                Text("\(progress.index) of \(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(model.isCancellingSync ? "Cancelling…" : "Cancel") { model.cancelSync() }
                .disabled(model.isCancellingSync)
        }
        .padding()
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .padding()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func summaryCard(_ summary: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(summary).font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .padding()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: summary) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            model.lastSyncSummary = nil
        }
    }
}
