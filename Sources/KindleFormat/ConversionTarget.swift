import Foundation

/// What EPUB, FB2 and CBZ are converted into before they are sent to the Kindle.
///
/// It lives in `KindleFormat` rather than `SyncEngine` because `octavo-convert` depends only on
/// this module — putting it a layer up would drag MTPKit and CalibreLibrary into a CLI that
/// never touches USB.
///
/// `rawValue` does four jobs at once: the file extension, the `--format` argument, the value in
/// the defaults suite, and the `Picker` tag. One string, no mapping table to keep in step.
public enum ConversionTarget: String, Sendable, Codable, CaseIterable, Hashable {
    case azw3
    case mobi

    /// AZW3, because it is the only one of the two that can carry stylesheets and a table of
    /// contents. MOBI 6 stays reachable because the only real test of "does this book open" is
    /// the Kindle's screen, and a known-good fallback is worth keeping until every book in the
    /// library has been through it.
    public static let `default`: ConversionTarget = .azw3

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .azw3: "AZW3"
        case .mobi: "MOBI 6"
        }
    }
}

public extension ConversionTarget {
    static let defaultsSuite = "org.octavo.Octavo"
    static let defaultsKey = "conversion.target"

    /// What the app is set to, so a CLI run and a sync from the app agree without either
    /// having to be told. Same suite trick as `LibraryLocation`: inside Octavo.app the suite
    /// *is* our own domain, and asking for it by name returns nil.
    static var preferred: ConversionTarget {
        let defaults = Bundle.main.bundleIdentifier == defaultsSuite
            ? UserDefaults.standard
            : UserDefaults(suiteName: defaultsSuite) ?? .standard
        return defaults.string(forKey: defaultsKey).flatMap(ConversionTarget.init(rawValue:)) ?? .default
    }
}
