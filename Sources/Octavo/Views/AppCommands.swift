import AppKit
import CalibreLibrary
import SwiftUI

/// Everything in the menu bar beyond what SwiftUI supplies for free (About, Quit, Window…).
/// Kept as a standalone `Commands` conformance, the same way `DeviceToolbar` is a standalone
/// `ToolbarContent` — `OctavoApp` just assembles the scene.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Library…") {
                if let url = LibraryPanels.chooseNewLibrary() { model.createLibrary(at: url) }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Open Library…") {
                if let url = LibraryPanels.chooseExistingLibrary() { model.openLibrary(at: url) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Menu("Open Recent") {
                let recents = LibraryLocation.recents.filter { $0 != model.libraryRoot }
                if recents.isEmpty {
                    Text("No Recent Libraries")
                } else {
                    ForEach(recents, id: \.self) { url in
                        Button(url.lastPathComponent) { model.openLibrary(at: url) }
                    }
                    Divider()
                    Button("Clear Menu") { LibraryLocation.forgetRecents() }
                }
            }

            Divider()

            // The daily action, so it claims the bare ⌘O; Open Library moved to ⇧⌘O for it.
            Button("Add Books…") { model.isImportingFiles = true }
                .keyboardShortcut("o")
                .disabled(model.store == nil)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find") { model.searchFocusRequests += 1 }
                .keyboardShortcut("f")
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("All Books") { model.filter = .all }
                .keyboardShortcut("1")
            Button("On Device") { model.filter = .onDevice }
                .keyboardShortcut("2")
            Button("Not on Device") { model.filter = .notOnDevice }
                .keyboardShortcut("3")
            Button("Converted") { model.filter = .needsConversion }
                .keyboardShortcut("4")
        }

        CommandMenu("Library") {
            Button("Edit Metadata…") {
                if let book = model.selectedBooks.first { model.editingBook = book }
            }
            .keyboardShortcut("i")
            .disabled(model.selectedBooks.count != 1)

            Button("Show in Finder") { model.revealInFinder(model.selectedBooks) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedBooks.isEmpty)

            Divider()

            Button("Refresh Library") { model.loadLibrary() }
                .keyboardShortcut("r")

            Button("Reveal Library in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.libraryRoot])
            }
        }

        CommandMenu("Device") {
            Button("Sync") { Task { await model.sync() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.isConnected || model.syncProgress != nil)

            Button("Cancel Sync") { model.cancelSync() }
                .keyboardShortcut(".")
                .disabled(model.syncProgress == nil)

            Divider()

            Button(model.isConnected ? "Disconnect" : "Connect") {
                Task {
                    if model.isConnected {
                        await model.disconnect()
                    } else {
                        await model.connect()
                    }
                }
            }

            Button("Back Up Device…") { Task { await model.backUpDevice() } }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!model.isConnected)

            Divider()

            Button("Remove from Device", role: .destructive) {
                model.requestRemoval(model.selectedBooks)
            }
            .disabled(!model.selectedBooks.contains { model.status(of: $0) == .synced })
        }

        CommandGroup(replacing: .help) {
            Link("Octavo on GitHub", destination: URL(string: "https://github.com/artemnovichkov/Octavo")!)
        }
    }
}
