import Foundation

/// Where the library lives, remembered across launches.
///
/// Lives here rather than in the app so the CLIs resolve exactly what the app is showing. The
/// suite name is the app's bundle identifier, which is what makes that work: for Octavo.app it is
/// the same store as `UserDefaults.standard`, for a CLI it is the app's plist rather than the
/// CLI's own domain. A plain path, not a security-scoped bookmark — the app is unsandboxed.
public enum LibraryLocation {
    static let suiteName = "org.octavo.Octavo"
    static let key = "LibraryRoot"

    /// Inside Octavo.app the suite *is* our own domain, and asking for it by name returns nil with
    /// "using your own bundle identifier as a suite name does not make sense" — so ask for it only
    /// from the CLIs, where the domain really is someone else's.
    private static var defaults: UserDefaults {
        guard Bundle.main.bundleIdentifier != suiteName else { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Offered when there is nothing to resolve; named after the app, not calibre, because the
    /// user creating one here is precisely the user without calibre.
    public static let suggested = URL.homeDirectory.appending(path: "Octavo Library")

    /// The remembered library, else calibre's own if it happens to be there. `nil` means the user
    /// has not chosen yet — the caller offers to create one, and nothing is written until then.
    public static func resolve() -> URL? {
        if let saved = defaults.string(forKey: key), !saved.isEmpty {
            return URL(filePath: saved)
        }
        if CalibreLibraryStore.isLibrary(at: CalibreLibraryStore.defaultLocation) {
            return CalibreLibraryStore.defaultLocation
        }
        return nil
    }

    public static func remember(_ url: URL) {
        defaults.set(url.path(percentEncoded: false), forKey: key)
    }

    public static func forget() {
        defaults.removeObject(forKey: key)
    }
}
