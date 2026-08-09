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
            }
        }
        .task(id: isSelected) {
            guard isSelected, !keepsContentMounted else { return }
            await Task.yield()
            guard !Task.isCancelled, isSelected else { return }
            keepsContentMounted = true
        }
    }
}
