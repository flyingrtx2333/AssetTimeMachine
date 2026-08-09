import SwiftUI
import SwiftData

extension ContentView {
    var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { selectTab($0) }
        )
    }

    @MainActor
    func scheduleWorkActivation(for tab: AppTab) {
        workActivationTask?.cancel()
        guard workActiveTab != tab else { return }

        // Stop the old tab's observers in the same state transaction as the
        // visual selection. Keeping the old page active makes it recompute its
        // SwiftData/chart tokens while the tab bar is trying to render.
        workActiveTab = nil

        // Start the destination's refresh work after the native tab transition.
        // Previously visited tabs can display their retained cache immediately.
        workActivationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, selectedTab == tab else { return }
            workActiveTab = tab
            workActivationTask = nil
        }
    }

    @MainActor
    func selectTab(_ tab: AppTab) {
        guard tab != selectedTab else { return }
        TabMountController.noteSelection(
            tab,
            mountedTabs: &mountedTabs,
            lastSelectedTab: &lastSelectedTab
        )
        selectedTab = tab
        scheduleWorkActivation(for: tab)
    }

    @ViewBuilder
    func deferredTabContent<Content: View>(for tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        if TabMountController.shouldMount(tab, selectedTab: selectedTab, mountedTabs: mountedTabs) {
            content()
        } else {
            Color.clear
        }
    }
}
