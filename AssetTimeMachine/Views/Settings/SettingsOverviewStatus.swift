import Foundation

enum SettingsOverviewStatus {
    static func notificationKey(
        assetBriefingEnabled: Bool,
        rebalanceReminderEnabled: Bool,
        authorizationDenied: Bool
    ) -> String {
        if authorizationDenied {
            return "需授权"
        }

        return assetBriefingEnabled || rebalanceReminderEnabled ? "已开启" : "已关闭"
    }

    static func cloudKey(
        hasAccount: Bool,
        isWorking: Bool,
        completedInitialSync: Bool,
        hasError: Bool
    ) -> String {
        if hasError {
            return "需处理"
        }
        if isWorking {
            return "同步中"
        }
        guard hasAccount else {
            return "未开启"
        }
        return completedInitialSync ? "正常" : "待同步"
    }
}
