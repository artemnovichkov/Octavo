import SwiftUI

struct DeviceToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            DeviceStatusButton()
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        // Refresh stays icon-only like every other secondary action; Sync is the only titled,
        // tinted button in the bar, and only while there's something to send — so the eye lands
        // on it exactly when it matters instead of every button competing for attention.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.refreshOrConnect() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.syncProgress != nil)

            syncButton
        }
    }

    // `.glass`/`.glassProminent` are distinct concrete PrimitiveButtonStyle types, so picking
    // between them can't be a ternary on one `.buttonStyle(_:)` call — split into two branches.
    @ViewBuilder
    private var syncButton: some View {
        let label = Button {
            Task { await model.sync() }
        } label: {
            Label(syncTitle, systemImage: "arrow.up.arrow.down")
        }
        .labelStyle(.titleAndIcon)
        .disabled(!canSync)
        .help(syncHelp)

        if canSync {
            label.buttonStyle(.glassProminent)
        } else {
            label.buttonStyle(.glass)
        }
    }

    private var canSync: Bool {
        guard model.syncProgress == nil, model.isConnected else { return false }
        return !(model.plan?.send.isEmpty ?? true)
    }

    private var syncTitle: String {
        guard let plan = model.plan, !plan.send.isEmpty else { return "Sync" }
        return "Send \(plan.send.count)"
    }

    private var syncHelp: String {
        guard let plan = model.plan else { return "Connect a Kindle" }
        guard !plan.send.isEmpty else { return "Everything is already on the device" }
        return "To send: \(Plural.books(plan.send.count)), \(format(UInt64(max(plan.totalBytes, 0))))"
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
