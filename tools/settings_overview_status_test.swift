import Foundation

@main
enum SettingsOverviewStatusTest {
    static func main() {
        expect(
            SettingsOverviewStatus.notificationKey(
                assetBriefingEnabled: false,
                rebalanceReminderEnabled: false,
                authorizationDenied: false
            ) == "已关闭",
            "Both notification features off should report 已关闭"
        )
        expect(
            SettingsOverviewStatus.notificationKey(
                assetBriefingEnabled: true,
                rebalanceReminderEnabled: false,
                authorizationDenied: false
            ) == "已开启",
            "Either enabled notification feature should report 已开启"
        )
        expect(
            SettingsOverviewStatus.notificationKey(
                assetBriefingEnabled: true,
                rebalanceReminderEnabled: true,
                authorizationDenied: true
            ) == "需授权",
            "Denied system permission must override enabled feature toggles"
        )

        expect(
            SettingsOverviewStatus.cloudKey(
                hasAccount: false,
                isWorking: false,
                completedInitialSync: false,
                hasError: false
            ) == "未开启",
            "Signed-out cloud sync should report 未开启"
        )
        expect(
            SettingsOverviewStatus.cloudKey(
                hasAccount: true,
                isWorking: true,
                completedInitialSync: true,
                hasError: false
            ) == "同步中",
            "Active cloud work should report 同步中"
        )
        expect(
            SettingsOverviewStatus.cloudKey(
                hasAccount: true,
                isWorking: false,
                completedInitialSync: true,
                hasError: false
            ) == "正常",
            "A completed signed-in sync should report 正常"
        )
        expect(
            SettingsOverviewStatus.cloudKey(
                hasAccount: true,
                isWorking: false,
                completedInitialSync: false,
                hasError: false
            ) == "待同步",
            "A signed-in account before first sync should report 待同步"
        )
        expect(
            SettingsOverviewStatus.cloudKey(
                hasAccount: true,
                isWorking: false,
                completedInitialSync: true,
                hasError: true
            ) == "需处理",
            "Cloud errors must override otherwise healthy state"
        )

        print("settings overview status tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
