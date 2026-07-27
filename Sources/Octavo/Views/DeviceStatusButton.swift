import SwiftUI

/// The device's whole state, condensed into one fixed-width toolbar button. Text used to live
/// inline in the toolbar (`ToolbarItem(placement: .status)`), which made the bar's width — and,
/// for `.failed`, its color — swing with an error message. The detail now lives in a popover
/// instead, so the toolbar itself never changes width across device states.
struct DeviceStatusButton: View {
    @Environment(AppModel.self) private var model
    @State private var showingDetail = false

    private struct Presentation {
        /// `nil` while `.connecting` — the button shows a spinner instead of a glyph.
        var symbol: String?
        var tint: Color?
        var title: String
        var detail: String?
        var actionTitle: String?
    }

    private var presentation: Presentation {
        switch model.deviceState {
        case .disconnected:
            Presentation(
                symbol: "cable.connector.slash",
                tint: .secondary,
                title: "Kindle not connected",
                detail: "Plug the Kindle in over USB.",
                actionTitle: "Connect"
            )
        case .connecting:
            Presentation(symbol: nil, tint: .secondary, title: "Connecting…", detail: nil, actionTitle: nil)
        case .waitingForMTP:
            // Not an error: the cable is in, the Kindle just isn't offering MTP. Same tint as
            // .disconnected so orange keeps meaning "something is wrong" and nothing else does.
            Presentation(
                symbol: "bolt.badge.clock",
                tint: .secondary,
                title: "Kindle connected, not in MTP mode",
                detail: "Unlock the Kindle screen or choose file transfer on the device.",
                actionTitle: "Try again"
            )
        case .connected(let snapshot):
            Presentation(
                symbol: "book.closed.fill",
                tint: nil,
                title: snapshot.name,
                detail: "\(snapshot.booksOnDevice) files, \(format(snapshot.freeSpace)) free",
                actionTitle: nil
            )
        case .failed(let message):
            Presentation(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Kindle problem",
                detail: message,
                actionTitle: "Try again"
            )
        }
    }

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            if let symbol = presentation.symbol {
                Label(presentation.title, systemImage: symbol)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(presentation.tint ?? .primary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .help(presentation.title)
        .accessibilityLabel(presentation.title)
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.title).font(.headline)
            if let detail = presentation.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            if case .connected(let snapshot) = model.deviceState {
                capacityBar(snapshot)
            }
            if let actionTitle = presentation.actionTitle {
                Button(actionTitle) {
                    showingDetail = false
                    Task { await model.refreshOrConnect() }
                }
            }
        }
        .padding()
        .frame(width: 260, alignment: .leading)
    }

    private func capacityBar(_ snapshot: DeviceController.Snapshot) -> some View {
        let used = snapshot.capacity > snapshot.freeSpace ? snapshot.capacity - snapshot.freeSpace : 0
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(used), total: Double(max(snapshot.capacity, 1)))
            Text("\(format(used)) used of \(format(snapshot.capacity))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
