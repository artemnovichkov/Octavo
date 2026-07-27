import Foundation
import Observation
import SyncEngine

/// Convenience settings, all backed by `UserDefaults.standard` — the same domain
/// `LibraryLocation` and `SidebarView`'s `@AppStorage` already write to (see the comment on
/// `LibraryLocation.defaults`), so the CLIs and a future settings sync see the same values.
///
/// A plain `@Observable` class rather than `@AppStorage` throughout: several of these are read
/// from non-view code (`AppModel`, `DeviceController`, `MetadataFetcher`), where `@AppStorage`
/// isn't available.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let autoOnConnect = "sync.autoOnConnect"
        static let backupBeforeFirst = "sync.backupBeforeFirst"
        static let backupDirectory = "sync.backupDirectory"
        static let pruneAfterSync = "conversion.pruneAfterSync"
        static let rememberFilter = "library.rememberFilter"
        static let lastFilter = "library.lastFilter"
        static let confirmRemoval = "device.confirmRemoval"
        static let googleBooksAPIKey = "GoogleBooksAPIKey"
        static let useOpenLibrary = "metadata.useOpenLibrary"
        static let useFantLab = "metadata.useFantLab"
        static let useGoogleBooks = "metadata.useGoogleBooks"
    }

    private let defaults = UserDefaults.standard

    var autoSyncOnConnect: Bool { didSet { defaults.set(autoSyncOnConnect, forKey: Key.autoOnConnect) } }
    var backupBeforeFirstSync: Bool { didSet { defaults.set(backupBeforeFirstSync, forKey: Key.backupBeforeFirst) } }
    var backupDirectory: URL {
        didSet { defaults.set(backupDirectory.path(percentEncoded: false), forKey: Key.backupDirectory) }
    }
    var pruneCacheAfterSync: Bool { didSet { defaults.set(pruneCacheAfterSync, forKey: Key.pruneAfterSync) } }
    var rememberLastFilter: Bool { didSet { defaults.set(rememberLastFilter, forKey: Key.rememberFilter) } }
    var lastFilter: String { didSet { defaults.set(lastFilter, forKey: Key.lastFilter) } }
    var confirmDeviceRemoval: Bool { didSet { defaults.set(confirmDeviceRemoval, forKey: Key.confirmRemoval) } }

    /// Legacy key, kept exactly as `MetadataFetcher` already reads it — this is the only
    /// writer, giving the field in Settings ▸ Metadata somewhere to save to.
    var googleBooksAPIKey: String { didSet { defaults.set(googleBooksAPIKey, forKey: Key.googleBooksAPIKey) } }
    var useOpenLibrary: Bool { didSet { defaults.set(useOpenLibrary, forKey: Key.useOpenLibrary) } }
    var useFantLab: Bool { didSet { defaults.set(useFantLab, forKey: Key.useFantLab) } }
    var useGoogleBooks: Bool { didSet { defaults.set(useGoogleBooks, forKey: Key.useGoogleBooks) } }

    private init() {
        let defaults = UserDefaults.standard
        autoSyncOnConnect = defaults.bool(forKey: Key.autoOnConnect)
        backupBeforeFirstSync = defaults.bool(forKey: Key.backupBeforeFirst)
        backupDirectory = defaults.string(forKey: Key.backupDirectory).map { URL(filePath: $0) }
            ?? SyncEngine.defaultBackupDirectory
        // Bools default to false from an absent key, but these three read "on" until the user
        // says otherwise — an object() check is what tells "never set" apart from "set to false".
        pruneCacheAfterSync = defaults.object(forKey: Key.pruneAfterSync) as? Bool ?? true
        rememberLastFilter = defaults.object(forKey: Key.rememberFilter) as? Bool ?? true
        confirmDeviceRemoval = defaults.object(forKey: Key.confirmRemoval) as? Bool ?? true
        lastFilter = defaults.string(forKey: Key.lastFilter) ?? "all"
        googleBooksAPIKey = defaults.string(forKey: Key.googleBooksAPIKey) ?? ""
        useOpenLibrary = defaults.object(forKey: Key.useOpenLibrary) as? Bool ?? true
        useFantLab = defaults.object(forKey: Key.useFantLab) as? Bool ?? true
        useGoogleBooks = defaults.object(forKey: Key.useGoogleBooks) as? Bool ?? true
    }
}
