import SwiftUI

/// Keeps tab content mounted after first activation so revisiting a tab does not
/// rebuild a heavy subtree during the tab-bar transition.
struct TabSurface<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder var content: () -> Content

    @State private var keepsContentMounted = false

    var body: some View {
        ZStack {
            if keepsContentMounted {
                content()
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
            }
        }
        .onChange(of: isSelected) { _, selected in
            if selected {
                mountContentIfNeeded(deferFirstMount: !keepsContentMounted)
            }
        }
        .onAppear {
            if isSelected {
                mountContentIfNeeded(deferFirstMount: !keepsContentMounted)
            }
        }
    }

    @MainActor
    private func mountContentIfNeeded(deferFirstMount: Bool) {
        guard !keepsContentMounted else { return }

        if deferFirstMount {
            Task { @MainActor in
                await Task.yield()
                guard isSelected else { return }
                keepsContentMounted = true
            }
        } else {
            keepsContentMounted = true
        }
    }
}
