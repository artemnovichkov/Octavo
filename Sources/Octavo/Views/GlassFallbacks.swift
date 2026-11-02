import SwiftUI

/// `ToolbarSpacer` is macOS 26 only. Before Tahoe the toolbar does not group items into glass
/// capsules, so there is nothing for the spacer to separate and it is simply left out.
struct FixedToolbarSpacer: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }
}

extension View {
    /// Liquid Glass button styles on macOS 26, the bordered pair they replaced before it.
    /// `.glass`/`.glassProminent` are distinct concrete PrimitiveButtonStyle types, so picking
    /// between them can't be a ternary on one `.buttonStyle(_:)` call — hence the branches.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}
