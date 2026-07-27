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
    static let recentsKey = "RecentLibraries"
    static let recentsCap = 8

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

        var paths = defaults.stringArray(forKey: recentsKey) ?? []
        let path = url.path(percentEncoded: false)
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(recentsCap)), forKey: recentsKey)
    }

    public static func forget() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: recentsKey)
    }

    /// Remembered libraries, most recent first, silently dropping any that moved or were
    /// deleted since — a stale row would otherwise error out `openLibrary(at:)` on click.
    public static var recents: [URL] {
        let paths = defaults.stringArray(forKey: recentsKey) ?? []
        return paths.map { URL(filePath: $0) }.filter { CalibreLibraryStore.isLibrary(at: $0) }
    }

    /// Drops everything remembered without touching the current `LibraryRoot` — the "Clear
    /// Menu" action in File ▸ Open Recent.
    public static func forgetRecents() {
        defaults.removeObject(forKey: recentsKey)
    }
}
