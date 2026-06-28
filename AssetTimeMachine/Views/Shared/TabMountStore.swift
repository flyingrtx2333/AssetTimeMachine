import SwiftUI

enum TabMountController {
    static func noteSelection(
        _ tab: AppTab,
        mountedTabs: inout Set<AppTab>,
        lastSelectedTab: inout AppTab
    ) {
        mountedTabs.insert(tab)
        mountedTabs.insert(lastSelectedTab)
        lastSelectedTab = tab
    }

    static func shouldMount(_ tab: AppTab, selectedTab: AppTab, mountedTabs: Set<AppTab>) -> Bool {
        mountedTabs.contains(tab) || tab == selectedTab
    }
}
