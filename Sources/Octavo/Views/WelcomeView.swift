import SwiftUI

/// First launch with nothing to open. calibre is not required — "Create" lays down a library in
/// calibre's own format, so the user can still move to calibre later if they want to.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Octavo", systemImage: "books.vertical")
        } description: {
            Text("Choose where your books live. A library is a folder Octavo keeps your books and their metadata in.")
        } actions: {
            VStack(spacing: 8) {
                Button("Create Library…") {
                    if let url = LibraryPanels.chooseNewLibrary() { model.createLibrary(at: url) }
                }
                .buttonStyle(.borderedProminent)

                Button("Open Existing Library…") {
                    if let url = LibraryPanels.chooseExistingLibrary() { model.openLibrary(at: url) }
                }
            }
        }
    }
}
