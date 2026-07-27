import SwiftUI

/// The library's left panel: four smart filters, then collapsible Authors/Series/Tags
/// sections with per-row counts. A pinned filter field narrows the facet rows (not the
/// book table — that has its own `.searchable` in `ContentView`) so a library with dozens
/// of authors stays reachable without scrolling past all of them.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var facetSearch = ""

    // Same `org.octavo.Octavo` defaults suite as everything else backed by `@AppStorage`/
    // `UserDefaults` in this app (see `LibraryLocation`) — it's the process's bundle id, not a
    // separate suite. Collapsed by default: a freshly launched sidebar should read as four
    // rows, not a wall of authors.
    @AppStorage("sidebar.authorsExpanded") private var authorsExpanded = false
    @AppStorage("sidebar.seriesExpanded") private var seriesExpanded = false
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = false

    var body: some View {
        @Bindable var model = model

        List(selection: $model.filter) {
            Section {
                label(.all, "books.vertical", model.books.count)
                deviceLabel(.onDevice, "checkmark.circle", model.planCounts?.onDevice)
                deviceLabel(.notOnDevice, "arrow.up.circle", model.planCounts?.notOnDevice)
                deviceLabel(.needsConversion, "wand.and.sparkles", model.planCounts?.needsConversion)
            }

            facetSection(
                "Authors", facets: model.authorFacets, kind: AppModel.Filter.author,
                expanded: expansion($authorsExpanded)
            )
            facetSection(
                "Series", facets: model.seriesFacets, kind: AppModel.Filter.series,
                expanded: expansion($seriesExpanded)
            )
            facetSection(
                "Tags", facets: model.tagFacets, kind: AppModel.Filter.tag,
                expanded: expansion($tagsExpanded)
            )

            if !facetSearch.isEmpty && hasNoMatches {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            SidebarFilterField(text: $facetSearch)
        }
    }

    private func label(_ filter: AppModel.Filter, _ symbol: String, _ count: Int?) -> some View {
        Label(filter.title, systemImage: symbol)
            .badge(count ?? 0)
            .tag(filter)
    }

    /// The three device-derived rows: no badge and a dimmed glyph while `count` is `nil`, i.e.
    /// no Kindle is connected — an honest "unknown" rather than a claimed zero.
    private func deviceLabel(_ filter: AppModel.Filter, _ symbol: String, _ count: Int?) -> some View {
        Label(filter.title, systemImage: symbol)
            .foregroundStyle(count == nil ? .secondary : .primary)
            .modifier(OptionalBadge(count: count))
            .tag(filter)
    }

    /// A section is hidden entirely once its facet list is empty, whether that's because the
    /// library has none or because the filter field matched nothing in it.
    ///
    /// Rows are gated by `if expanded.wrappedValue` rather than the built-in
    /// `Section(_:isExpanded:)` — that control's disclosure chevron only appears on hover and is
    /// a few points wide, which reads as "this text is disabled" rather than "click to expand".
    /// `FacetSectionHeader` below trades that native control for a header that is a plain
    /// `Button` filling the whole row, so the entire header is the hit target and the chevron is
    /// always visible.
    @ViewBuilder
    private func facetSection(
        _ title: String,
        facets: [AppModel.Facet],
        kind: @escaping (String) -> AppModel.Filter,
        expanded: Binding<Bool>
    ) -> some View {
        let matches = matching(facets)
        if !facets.isEmpty && !matches.isEmpty {
            Section {
                if expanded.wrappedValue {
                    ForEach(matches) { facet in
                        Text(facet.name)
                            .badge(facet.count)
                            .tag(kind(facet.name))
                    }
                }
            } header: {
                FacetSectionHeader(title: title, expanded: expanded)
            }
        }
    }

    private func matching(_ facets: [AppModel.Facet]) -> [AppModel.Facet] {
        guard !facetSearch.isEmpty else { return facets }
        return facets.filter { $0.name.localizedStandardContains(facetSearch) }
    }

    /// True once the filter field has narrowed all three facet lists down to nothing —
    /// distinct from an empty *library*, where the sections are simply absent.
    private var hasNoMatches: Bool {
        matching(model.authorFacets).isEmpty
            && matching(model.seriesFacets).isEmpty
            && matching(model.tagFacets).isEmpty
    }

    /// While filtering, every section is forced open so the matches are visible; clearing the
    /// field reverts to whatever the user actually chose, rather than leaving everything open.
    private func expansion(_ stored: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { !facetSearch.isEmpty || stored.wrappedValue },
            set: { if facetSearch.isEmpty { stored.wrappedValue = $0 } }
        )
    }
}

/// A collapsible section header: chevron + title, the whole row clickable. Unlike the built-in
/// `Section(_:isExpanded:)` disclosure — whose triangle only shows on hover and is a few points
/// wide — the chevron here is always on screen and rotates in place, and `.contentShape` makes
/// the full width (not just the glyph) register the tap.
private struct FacetSectionHeader: View {
    let title: String
    @Binding var expanded: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                Text(title)
                    .font(.body)
                Spacer()
            }
            // Section headers otherwise inherit the sidebar's automatic small, dimmed
            // caption style, which is what made this read as a disabled label rather than
            // a button — overriding both color and case here escapes that.
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(isHovering ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// `.badge` has no overload that hides itself for `nil` — this applies it only when there is a
/// count to show, so the device rows carry no badge at all (not a `0`) while disconnected.
private struct OptionalBadge: ViewModifier {
    let count: Int?

    func body(content: Content) -> some View {
        if let count {
            content.badge(count)
        } else {
            content
        }
    }
}

/// Pinned above the facet list. Narrows Authors/Series/Tags rows as you type; deliberately not
/// persisted (`@State`, not `@AppStorage`) — a filter left typed from a prior session would read
/// as a bug, not a preference.
private struct SidebarFilterField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter authors, series, tags", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: .capsule)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }
}
