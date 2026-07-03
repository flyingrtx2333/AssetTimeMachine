import SwiftUI
import SwiftData

extension ContentView {
    var notificationSnapshot: AssetSnapshot? {
        snapshots.first(where: { Calendar.current.isDateInToday($0.date) }) ?? snapshots.first
    }

    var notificationRefreshToken: String {
        guard let notificationSnapshot else { return "empty" }
        return "\(notificationSnapshot.id.uuidString)-\(notificationSnapshot.updatedAt.timeIntervalSinceReferenceDate)"
    }

    @MainActor
    func scheduleSnapshotNotificationRefresh() {
        pendingSnapshotNotificationRefreshTask?.cancel()
        pendingSnapshotNotificationRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await refreshAssetNotifications()
            if strategyNotificationEnabled {
                await refreshStrategyNotifications()
            }
            await MainActor.run {
                pendingSnapshotNotificationRefreshTask = nil
            }
        }
    }

    @MainActor
    func refreshAssetNotifications() async {
        do {
            let granted = try await AssetNotificationService.refreshSchedule(
                isEnabled: notificationEnabled,
                intervalHours: notificationIntervalHours,
                snapshot: notificationSnapshot
            )
            if notificationEnabled && !granted {
                notificationEnabled = false
            }
        } catch {
            print("[AssetTimeMachine] refresh notifications failed: \(error)")
        }
    }

    @MainActor
    func refreshStrategyNotifications() async {
        do {
            guard !StrategyNotificationDefaults.eligibleTemplates.isEmpty else {
                if strategyNotificationEnabled {
                    strategyNotificationEnabled = false
                }
                _ = try await AssetNotificationService.refreshStrategySchedule(
                    isEnabled: false,
                    hour: strategyNotificationHour,
                    strategyTitle: AppLocalization.string("策略提醒"),
                    body: nil
                )
                return
            }

            let content = await currentStrategyNotificationContent()
            let granted = try await AssetNotificationService.refreshStrategySchedule(
                isEnabled: strategyNotificationEnabled,
                hour: strategyNotificationHour,
                strategyTitle: content.title,
                body: content.body
            )
            if strategyNotificationEnabled && !granted {
                strategyNotificationEnabled = false
            }
        } catch {
            print("[AssetTimeMachine] refresh strategy notifications failed: \(error)")
        }
    }

    @MainActor
    func currentStrategyNotificationContent(includeAdviceWhenDisabled: Bool = false) async -> (title: String, body: String?) {
        guard let template = StrategyNotificationDefaults.template(for: strategyNotificationTemplateID) else {
            return (AppLocalization.string("策略提醒"), AppLocalization.string("打开资产时光机，选择一个策略作为每日提醒。"))
        }

        guard strategyNotificationEnabled || includeAdviceWhenDisabled else {
            return (template.title, nil)
        }

        await marketStore.refreshHistoryIfNeeded(force: false)

        let assetOptions = StrategyNotificationDefaults.assetOptions(for: template)
        let assetInputs = assetOptions.map { option in
            (
                assetSeries: marketStore.history(for: option.symbol),
                assetOption: option,
                fxSeries: option.historicalFXSymbol.flatMap { marketStore.history(for: $0) }
            )
        }
        guard let advice = BacktestEngine.advancedRotationRebalanceAdvice(assetInputs: assetInputs, mode: template.mode) else {
            return (template.title, AppLocalization.string("历史行情暂时不足，今日调仓将在数据补齐后更新。"))
        }

        let actions = StrategyRebalanceActionBuilder.actions(
            for: advice,
            snapshot: notificationSnapshot,
            selectedAssetOptions: assetOptions,
            allAssetOptions: BacktestDefaults.dcaAssetOptions
        )
        return (template.title, StrategyNotificationContentBuilder.body(advice: advice, actions: actions))
    }

    @MainActor
    func sendStrategyTestNotification() async -> Bool {
        do {
            let content = await currentStrategyNotificationContent(includeAdviceWhenDisabled: true)
            return try await AssetNotificationService.sendStrategyTestNotification(
                strategyTitle: content.title,
                body: content.body
            )
        } catch {
            print("[AssetTimeMachine] send strategy test notification failed: \(error)")
            return false
        }
    }
}
