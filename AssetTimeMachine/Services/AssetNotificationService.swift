import Foundation
import UserNotifications

nonisolated struct AssetNotificationSnapshot: Sendable {
    let totalAssets: Double
    let totalLiabilities: Double
    let financialAssets: Double
    let physicalAssets: Double

    var netAssets: Double { totalAssets - totalLiabilities }
}

nonisolated enum NotificationAuthorizationResult: Sendable {
    case granted
    case denied
    case failed(String)
}

nonisolated enum StrategyTestNotificationResult: Sendable {
    case sent
    case denied
    case failed(String)
}

enum AssetNotificationService {
    static let notificationIdentifier = "assettimemachine.asset-report"
    static let strategyNotificationIdentifier = "assettimemachine.strategy-rebalance"
    static let strategyTestNotificationIdentifier = "assettimemachine.strategy-rebalance.test"
    static let intervalOptions: [Double] = [1, 2, 4, 6, 8, 12, 24]
    static let strategyHourOptions: [Int] = [8, 9, 12, 18, 21]

    static func refreshSchedule(isEnabled: Bool, intervalHours: Double, snapshot: AssetNotificationSnapshot?) async throws -> Bool {
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

        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
        guard snapshot != nil else { return true }

        let content = scheduledAssetContent()

        let interval = max(3600, intervalHours * 3600)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: true)
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)
        try await center.add(request)
        return true
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func preflightTestNotificationAuthorization() async -> NotificationAuthorizationResult {
        let center = UNUserNotificationCenter.current()
        do {
            return try await ensureAuthorization(for: center) ? .granted : .denied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func refreshStrategySchedule(
        isEnabled: Bool,
        hour: Int,
        strategyTitle: String
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

        let content = scheduledStrategyContent(strategyTitle: strategyTitle)

        var components = DateComponents()
        components.calendar = .autoupdatingCurrent
        components.timeZone = .autoupdatingCurrent
        components.hour = min(max(hour, 0), 23)
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: strategyNotificationIdentifier, content: content, trigger: trigger)
        try await center.add(request)
        return true
    }

    static func sendStrategyTestNotification(strategyTitle: String, body: String?) async -> StrategyTestNotificationResult {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await ensureAuthorization(for: center)
            guard granted else { return .denied }

            center.removePendingNotificationRequests(withIdentifiers: [strategyTestNotificationIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [strategyTestNotificationIdentifier])

            let content = UNMutableNotificationContent()
            content.title = AppLocalization.string("调仓建议")
            content.subtitle = strategyTitle
            content.body = body ?? AppLocalization.string("打开资产时光机，查看最新策略信号。")
            content.sound = .default
            content.threadIdentifier = strategyNotificationIdentifier

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: strategyTestNotificationIdentifier, content: content, trigger: trigger)
            try await center.add(request)
            return .sent
        } catch {
            return .failed(error.localizedDescription)
        }
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

    // Repeated local notifications cannot fetch a new price or recompute advice when
    // delivered. Only the explicitly requested, non-repeating test may contain advice.
    static func scheduledAssetContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.string("资产记录提醒")
        content.body = AppLocalization.string("打开资产时光机，查看最新资产记录。")
        content.sound = .default
        return content
    }

    static func scheduledStrategyContent(strategyTitle: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.string("策略更新提醒")
        content.subtitle = strategyTitle
        content.body = AppLocalization.string("打开资产时光机，获取最新调仓建议。")
        content.sound = .default
        content.threadIdentifier = strategyNotificationIdentifier
        return content
    }
}
