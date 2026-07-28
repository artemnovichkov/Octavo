import Foundation

/// What a source format is read into before a Kindle format is written out of it.
///
/// MOBI 6 wants one flat HTML stream and AZW3 wants the spine kept apart — a document per
/// skeleton, stylesheets as separate flows — so the reading side stops here, at the last shape
/// both writers can be built from. Sections keep the markup exactly as it came out of the
/// EPUB; each writer does its own rewriting.
public struct BookDocument {
    public struct Section {
        /// Where it came from inside the container. Only used in diagnostics.
        public var path: String
        /// The document as the source had it, `<html>` wrapper and all.
        public var xhtml: String
        /// Every `src` this section's markup mentions, mapped to its index in `resources`.
        /// Keyed by the attribute value verbatim, so a writer never has to redo path resolution.
        public var resources: [String: Int]
        /// Indices into `stylesheets` that apply to this section, in link order.
        public var stylesheets: [Int]
        /// Every `href` in this section that lands somewhere else in the same book, keyed by
        /// the attribute value verbatim. Links to anywhere else are absent and stay untouched.
        public var links: [String: LinkTarget]

        public init(
            path: String,
            xhtml: String,
            resources: [String: Int] = [:],
            stylesheets: [Int] = [],
            links: [String: LinkTarget] = [:]
        ) {
            self.path = path
            self.xhtml = xhtml
            self.resources = resources
            self.stylesheets = stylesheets
            self.links = links
        }
    }

    public struct LinkTarget {
        public var section: Int
        /// The `id` the link points at, or nil for the top of the section.
        public var anchor: String?

        public init(section: Int, anchor: String?) {
            self.section = section
            self.anchor = anchor
        }
    }

    public struct TOCEntry {
        public var title: String
        public var sectionIndex: Int
        /// The `id` the entry points at inside its section, if it points at one.
        public var anchor: String?
        /// 0 for a top-level entry, 1 for its children. Entries stay in reading order; the
        /// depths are what describe the tree.
        public var depth: Int

        public init(title: String, sectionIndex: Int, anchor: String? = nil, depth: Int = 0) {
            self.title = title
            self.sectionIndex = sectionIndex
            self.anchor = anchor
            self.depth = depth
        }
    }

    public var sections: [Section] = []
    /// CSS source text. MOBI 6 has nowhere to put these and drops them; KF8 carries them as
    /// flows 1…n.
    public var stylesheets: [String] = []
    /// Images, in the order they are first referenced. The cover, when there is one, is put
    /// first so it can be addressed as resource 0.
    public var resources: [Data] = []
    public var metadata: EbookMetadata
    public var coverResourceIndex: Int?
    public var toc: [TOCEntry] = []

    public init(metadata: EbookMetadata) {
        self.metadata = metadata
    }

    var isEmpty: Bool {
        sections.allSatisfy { $0.xhtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
