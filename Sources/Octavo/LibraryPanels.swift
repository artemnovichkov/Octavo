import AppKit
import CalibreLibrary
import Foundation

/// The two folder pickers the library needs. AppKit rather than SwiftUI's `.fileImporter`
/// because only NSSavePanel offers "pick a parent and name the new folder", which is what
/// creating a library is. The app is unsandboxed, so the chosen path is usable as-is.
enum LibraryPanels {
    /// Where to put a new library. Defaults to ~/Octavo Library, one level up from the name field.
    static func chooseNewLibrary() -> URL? {
        let panel = NSSavePanel()
        panel.title = "New Library"
        panel.message = "Choose where to keep your books. Octavo creates a folder there."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Library name:"
        panel.nameFieldStringValue = LibraryLocation.suggested.lastPathComponent
        panel.directoryURL = LibraryLocation.suggested.deletingLastPathComponent()
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExistingLibrary() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Library"
        panel.message = "Choose a library folder — the one holding metadata.db."
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL.homeDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }
}
