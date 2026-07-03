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
        workActiveTab = nil
        workActivationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
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
