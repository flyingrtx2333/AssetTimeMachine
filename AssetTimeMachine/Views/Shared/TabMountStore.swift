import Combine
import SwiftUI

@MainActor
final class TabMountStore: ObservableObject {
    @Published private(set) var mountedTabs: Set<AppTab> = [.dashboard]
    private var lastSelectedTab: AppTab = .dashboard

    func noteSelection(_ tab: AppTab) {
        let previous = lastSelectedTab
        lastSelectedTab = tab
        mountedTabs.insert(tab)
        mountedTabs.insert(previous)
        pruneMountedTabs(current: tab, previous: previous)
    }

    func shouldMount(_ tab: AppTab, selectedTab: AppTab) -> Bool {
        mountedTabs.contains(tab) || tab == selectedTab
    }

    func markMounted(_ tab: AppTab) {
        mountedTabs.insert(tab)
    }

    private func pruneMountedTabs(current: AppTab, previous: AppTab) {
        guard mountedTabs.count > 3 else { return }

        var kept: Set<AppTab> = [current, previous]
        if current != .dashboard, previous != .dashboard {
            kept.insert(.dashboard)
        }
        mountedTabs = kept
    }
}
