import SwiftUI

@main
struct OctavoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Library…") {
                    if let url = LibraryPanels.chooseNewLibrary() { model.createLibrary(at: url) }
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Open Library…") {
                    if let url = LibraryPanels.chooseExistingLibrary() { model.openLibrary(at: url) }
                }
                .keyboardShortcut("o")
                Divider()
                Button("Refresh library") { model.loadLibrary() }
                    .keyboardShortcut("r")
                Button("Sync") { Task { await model.sync() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}
