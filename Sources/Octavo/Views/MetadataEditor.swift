import CalibreLibrary
import MetadataFetch
import SwiftUI

struct MetadataEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Book
    @State private var authorsText: String
    @State private var tagsText: String
    @State private var candidates: [MetadataCandidate] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var applying: MetadataCandidate.ID?

    /// Rebuilt per search rather than stored, so a source toggled off in Settings ▸ Metadata
    /// while this sheet is already open takes effect on the next search.
    private var fetcher: MetadataFetcher {
        let preferences = Preferences.shared
        var sources: MetadataFetcher.Sources = []
        if preferences.useOpenLibrary { sources.insert(.openLibrary) }
        if preferences.useFantLab { sources.insert(.fantLab) }
        if preferences.useGoogleBooks { sources.insert(.googleBooks) }
        return MetadataFetcher(sources: sources)
    }

    init(book: Book) {
        _draft = State(initialValue: book)
        _authorsText = State(initialValue: book.authors.joined(separator: ", "))
        _tagsText = State(initialValue: book.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                form
                Divider()
                onlineResults
            }
            .padding()

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 860, height: 560)
    }

    private var form: some View {
        Form {
            Section("Metadata") {
                TextField("Title", text: $draft.title)
                TextField("Authors", text: $authorsText, prompt: Text("comma-separated"))
                TextField("Series", text: Binding(
                    get: { draft.series ?? "" },
                    set: { draft.series = $0.isEmpty ? nil : $0 }
                ))
                TextField("Number in series", value: $draft.seriesIndex, format: .number)
                TextField("Publisher", text: Binding(
                    get: { draft.publisher ?? "" },
                    set: { draft.publisher = $0.isEmpty ? nil : $0 }
                ))
                TextField("Tags", text: $tagsText, prompt: Text("comma-separated"))
                TextField("ISBN", text: Binding(
                    get: { draft.identifiers["isbn"] ?? "" },
                    set: { draft.identifiers["isbn"] = $0.isEmpty ? nil : $0 }
                ))
                // A plain `draft.pubdate ?? Date()` binding stamped today onto every book
                // that had no date, just for opening the editor and pressing Save.
                // The toggle keeps nil reachable and makes "no date" an explicit choice.
                Toggle("Publication date known", isOn: Binding(
                    get: { draft.pubdate != nil },
                    set: { draft.pubdate = $0 ? (draft.pubdate ?? Date()) : nil }
                ))
                if draft.pubdate != nil {
                    DatePicker("Publication date", selection: Binding(
                        get: { draft.pubdate ?? Date() },
                        set: { draft.pubdate = $0 }
                    ), displayedComponents: .date)
                }
            }

            Section("Description") {
                TextEditor(text: Binding(
                    get: { draft.comments ?? "" },
                    set: { draft.comments = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 120)
                .font(.body)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private var onlineResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Open catalogues").font(.headline)
                Spacer()
                Button {
                    Task { await search() }
                } label: {
                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                .disabled(isSearching)
            }

            if let searchError {
                Text(searchError).font(.callout).foregroundStyle(.orange)
            }

            if candidates.isEmpty && !isSearching {
                ContentUnavailableView(
                    "Nothing found",
                    systemImage: "globe",
                    description: Text("Open Library, FantLab and Google Books search by title, author and ISBN")
                )
            } else {
                List(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.title).bold().lineLimit(2)
                        Text(candidate.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        HStack {
                            Text(candidate.source).font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            if applying == candidate.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Apply") { Task { await apply(candidate) } }
                                    .buttonStyle(.link)
                                    .disabled(applying != nil)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 340)
    }

    private func search() async {
        isSearching = true
        searchError = nil
        defer { isSearching = false }

        let results = await fetcher.search(
            title: draft.title,
            author: draft.authors.first,
            isbn: draft.identifiers["isbn"]
        )
        candidates = results.candidates
        searchError = results.notes.isEmpty
            ? (results.candidates.isEmpty ? "The catalogues returned nothing" : nil)
            : results.notes.joined(separator: "\n")
    }

    /// Fills only the fields the candidate actually carries — an online result never
    /// wipes data that is already in the library.
    ///
    /// The candidate is enriched first: search endpoints omit the annotation and often the
    /// cover, so applying a raw search hit used to leave the description and the cover untouched
    /// with no indication why.
    private func apply(_ candidate: MetadataCandidate) async {
        applying = candidate.id
        defer { applying = nil }

        let full = await fetcher.enrich(candidate)

        if !full.title.isEmpty { draft.title = full.title }
        if !full.authors.isEmpty {
            draft.authors = full.authors
            authorsText = full.authors.joined(separator: ", ")
        }
        if let publisher = full.publisher { draft.publisher = publisher }
        if let published = full.published { draft.pubdate = published }
        if let comments = full.comments, !comments.isEmpty { draft.comments = comments }
        if let isbn = full.isbn { draft.identifiers["isbn"] = isbn }
        if !full.tags.isEmpty {
            let merged = Set(draft.tags).union(full.tags).sorted()
            draft.tags = merged
            tagsText = merged.joined(separator: ", ")
        }

        if full.coverURL != nil { await downloadCover(from: full) }
    }

    private func downloadCover(from candidate: MetadataCandidate) async {
        guard let data = try? await fetcher.coverData(for: candidate), !data.isEmpty else {
            searchError = "Could not download the cover"
            return
        }
        let destination = model.libraryRoot.appending(path: draft.path).appending(path: "cover.jpg")
        do {
            try data.write(to: destination)
        } catch {
            // Was `try?` before, so a failure here looked exactly like "no cover offered".
            searchError = "Could not save the cover: \(error.localizedDescription)"
            return
        }
        draft.hasCover = true
        CoverCache.shared.invalidate(draft)
    }

    private func save() {
        draft.authors = split(authorsText)
        draft.tags = split(tagsText)
        model.save(draft)
        dismiss()
    }

    private func split(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
