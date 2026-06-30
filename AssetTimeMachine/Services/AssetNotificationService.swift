import Foundation
import UserNotifications

enum AssetNotificationService {
    static let notificationIdentifier = "assettimemachine.asset-report"
    static let strategyNotificationIdentifier = "assettimemachine.strategy-rebalance"
    static let intervalOptions: [Double] = [1, 2, 4, 6, 8, 12, 24]
    static let strategyHourOptions: [Int] = [8, 9, 12, 18, 21]

    static func refreshSchedule(isEnabled: Bool, intervalHours: Double, snapshot: AssetSnapshot?) async throws -> Bool {
        let center = UNUserNotificationCenter.current()

        if !isEnabled {
            center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
            return true
        }

        let granted = try await ensureAuthorization(for: center)
        guard granted else {
            center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
            return false
        }

        guard let snapshot else { return true }

        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])

        let content = UNMutableNotificationContent()
        content.title = AppLocalization.string("资产播报")
        content.subtitle = subtitle(for: snapshot)
        content.body = body(for: snapshot)
        content.sound = .default

        let interval = max(3600, intervalHours * 3600)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: true)
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)
        try await center.add(request)
        return true
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func refreshStrategySchedule(
        isEnabled: Bool,
        hour: Int,
        strategyTitle: String,
        body: String?
    ) async throws -> Bool {
        let center = UNUserNotificationCenter.current()

        if !isEnabled {
            center.removePendingNotificationRequests(withIdentifiers: [strategyNotificationIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [strategyNotificationIdentifier])
            return true
        }

        let granted = try await ensureAuthorization(for: center)
        guard granted else {
            center.removePendingNotificationRequests(withIdentifiers: [strategyNotificationIdentifier])
            return false
        }

        center.removePendingNotificationRequests(withIdentifiers: [strategyNotificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [strategyNotificationIdentifier])

        let content = UNMutableNotificationContent()
        content.title = AppLocalization.string("今日调仓提醒")
        content.subtitle = strategyTitle
        content.body = body ?? AppLocalization.string("打开资产时光机，更新最新策略信号。")
        content.sound = .default
        content.threadIdentifier = strategyNotificationIdentifier

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        components.hour = min(max(hour, 0), 23)
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: strategyNotificationIdentifier, content: content, trigger: trigger)
        try await center.add(request)
        return true
    }

    private static func ensureAuthorization(for center: UNUserNotificationCenter) async throws -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func subtitle(for snapshot: AssetSnapshot) -> String {
        let totalAssets = PortfolioCalculator.totalAssets(for: snapshot)
        let netAssets = PortfolioCalculator.netAssets(for: snapshot)
        return AppLocalization.format("总资产 %@ · 净资产 %@", totalAssets.currencyString(), netAssets.currencyString())
    }

    private static func body(for snapshot: AssetSnapshot) -> String {
        let liabilities = PortfolioCalculator.totalLiabilities(for: snapshot)
        let breakdown = PortfolioCalculator.breakdown(for: snapshot)
        let financial = breakdown[.financial] ?? 0
        let physical = breakdown[.physical] ?? 0
        return AppLocalization.format(
            "负债 %@。金融 %@ · 实物 %@",
            liabilities.currencyString(),
            financial.currencyString(),
            physical.currencyString()
        )
    }
}
