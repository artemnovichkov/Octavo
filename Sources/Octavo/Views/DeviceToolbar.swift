import SwiftUI

struct DeviceToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .status) {
            deviceStatus.labelStyle(.titleAndIcon)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await refreshOrConnect() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.syncProgress != nil)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.sync() }
            } label: {
                Label(syncTitle, systemImage: "arrow.up.arrow.down.circle.fill")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!canSync)
            .help(syncHelp)
        }
    }

    @ViewBuilder
    private var deviceStatus: some View {
        switch model.deviceState {
        case .disconnected:
            Label("Kindle not connected", systemImage: "cable.connector.slash")
                .foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
            }
        case .waitingForMTP:
            // Not an error: the cable is in, the Kindle just isn't offering MTP. Styled to
            // match .disconnected so the orange triangle keeps meaning "something is wrong".
            Label("Kindle connected, but not in MTP mode", systemImage: "bolt.badge.clock")
                .foregroundStyle(.secondary)
                .help("Unlock the Kindle screen or choose file transfer on the device")
        case .connected(let snapshot):
            Label(
                "\(snapshot.name) — \(snapshot.booksOnDevice) files, \(format(snapshot.freeSpace)) free",
                systemImage: "book.closed.fill"
            )
            .help(spaceDetail(snapshot))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
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

    private func spaceDetail(_ snapshot: DeviceController.Snapshot) -> String {
        let used = snapshot.capacity > snapshot.freeSpace ? snapshot.capacity - snapshot.freeSpace : 0
        return "\(format(used)) used of \(format(snapshot.capacity))"
    }

    private func refreshOrConnect() async {
        model.loadLibrary()
        if model.isConnected {
            await model.refreshPlan()
        } else {
            // A connect the user asked for, so a failure here is reported as a real error
            // rather than the watcher's quieter .waitingForMTP.
            await model.connect()
        }
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
