import AppKit
import Foundation
import SwiftUI
import SyncEngine

/// The `⌘,` window: four `Form`s, one per group of convenience settings, all backed by
/// `Preferences.shared` (General also reads `AppModel` for the current library path).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            SyncSettingsTab()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            ConversionSettingsTab()
                .tabItem { Label("Conversion", systemImage: "wand.and.sparkles") }
            MetadataSettingsTab()
                .tabItem { Label("Metadata", systemImage: "text.book.closed") }
        }
        .frame(width: 480)
        .scenePadding()
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model
    private var preferences = Preferences.shared

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            LabeledContent("Library") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(model.libraryRoot.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Change…") {
                            if let url = LibraryPanels.chooseExistingLibrary() { model.openLibrary(at: url) }
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.libraryRoot])
                        }
                    }
                }
            }

            Toggle("Remember the last filter across launches", isOn: $preferences.rememberLastFilter)
            Toggle("Ask before removing books from the device", isOn: $preferences.confirmDeviceRemoval)
        }
        .formStyle(.grouped)
    }
}

private struct SyncSettingsTab: View {
    private var preferences = Preferences.shared

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Toggle("Sync automatically when a Kindle connects", isOn: $preferences.autoSyncOnConnect)

            Section {
                Toggle("Back up the device before the first sync", isOn: $preferences.backupBeforeFirstSync)

                LabeledContent("Backup folder") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(preferences.backupDirectory.path(percentEncoded: false))
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Choose…") { chooseBackupFolder() }
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([preferences.backupDirectory])
                            }
                        }
                    }
                }
                .disabled(!preferences.backupBeforeFirstSync)
            } footer: {
                Text("Reading progress and highlights (.sdr) are never touched, backed up or not.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.backupDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.backupDirectory = url
    }
}

private struct ConversionSettingsTab: View {
    private var preferences = Preferences.shared
    @State private var cacheSize: Int64?
    @State private var isClearing = false

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            LabeledContent("Cache location") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(ConversionCache.default.directory.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([ConversionCache.default.directory])
                        }
                        Button("Clear Cache…", role: .destructive) { isClearing = true }
                    }
                }
            }

            if let cacheSize {
                LabeledContent("Size on disk", value: cacheSize.formatted(.byteCount(style: .file)))
            }

            Toggle("Remove stale converted files after each sync", isOn: $preferences.pruneCacheAfterSync)
        }
        .formStyle(.grouped)
        .task { cacheSize = Self.directorySize(ConversionCache.default.directory) }
        .confirmationDialog(
            "Delete every converted file?",
            isPresented: $isClearing,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) { clearCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next sync re-converts whatever it needs. The library and the device are unaffected.")
        }
    }

    private func clearCache() {
        let directory = ConversionCache.default.directory
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        cacheSize = Self.directorySize(directory)
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

private struct MetadataSettingsTab: View {
    private var preferences = Preferences.shared

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                SecureField("Google Books API key", text: $preferences.googleBooksAPIKey)
            } footer: {
                Text("Google Books throttles anonymous requests; a free API key gets a private quota. Open Library and FantLab need no key.")
            }

            Section("Sources") {
                Toggle("Open Library", isOn: $preferences.useOpenLibrary)
                    .disabled(isOnlyEnabledSource(current: preferences.useOpenLibrary))
                Toggle("FantLab", isOn: $preferences.useFantLab)
                    .disabled(isOnlyEnabledSource(current: preferences.useFantLab))
                Toggle("Google Books", isOn: $preferences.useGoogleBooks)
                    .disabled(isOnlyEnabledSource(current: preferences.useGoogleBooks))
            }
        }
        .formStyle(.grouped)
    }

    /// Keeps at least one catalogue enabled — flipping the last one off would leave the
    /// metadata editor with nowhere to search.
    private func isOnlyEnabledSource(current: Bool) -> Bool {
        guard current else { return false }
        let enabledCount = [preferences.useOpenLibrary, preferences.useFantLab, preferences.useGoogleBooks]
            .filter { $0 }.count
        return enabledCount == 1
    }
}
