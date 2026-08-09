import SwiftUI

enum TabMountController {
    static func noteSelection(
        _ tab: AppTab,
        mountedTabs: inout Set<AppTab>,
        lastSelectedTab: inout AppTab
    ) {
        // Keep only the destination and the immediately previous page. Retaining all
        // five trees lets off-screen @Query/@ObservedObject updates compete with the
        // selected tab and recreates the multi-second switch stalls on larger stores.
        mountedTabs = [tab, lastSelectedTab]
        lastSelectedTab = tab
    }

    static func shouldMount(_ tab: AppTab, selectedTab: AppTab, mountedTabs: Set<AppTab>) -> Bool {
        mountedTabs.contains(tab) || tab == selectedTab
    }
}
