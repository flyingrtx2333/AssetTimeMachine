import SwiftUI
import SwiftData

extension ContentView {
    var notificationSnapshot: AssetSnapshot? {
        var descriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    @MainActor
    func scheduleSnapshotNotificationRefresh(delayNanoseconds: UInt64 = 500_000_000) {
        notificationRefreshGeneration &+= 1
        notificationRefreshRequestedDelayNanoseconds = delayNanoseconds
        guard pendingSnapshotNotificationRefreshTask == nil else { return }

        let taskID = UUID()
        notificationRefreshTaskID = taskID
        pendingSnapshotNotificationRefreshTask = Task {
            var waitingGeneration = notificationRefreshGeneration
            var nextDelayNanoseconds = delayNanoseconds
            while !Task.isCancelled {
                if nextDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: nextDelayNanoseconds)
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled else { break }

                // True trailing-edge debounce: if another save/setting change arrived
                // during the quiet window, restart using that intent's requested delay.
                if waitingGeneration != notificationRefreshGeneration {
                    waitingGeneration = notificationRefreshGeneration
                    nextDelayNanoseconds = notificationRefreshRequestedDelayNanoseconds
                    continue
                }

                let processingGeneration = notificationRefreshGeneration
                await refreshAssetNotifications()
                await refreshStrategyNotifications()
                guard !Task.isCancelled else { break }

                if processingGeneration == notificationRefreshGeneration {
                    if notificationRefreshTaskID == taskID {
                        pendingSnapshotNotificationRefreshTask = nil
                        notificationRefreshTaskID = nil
                    }
                    return
                }
                // A setting changed while an uncancellable system notification call
                // was in flight. Reapply the newest state serially so stale work can
                // never be the final schedule installed on the device.
                waitingGeneration = notificationRefreshGeneration
                nextDelayNanoseconds = 0
            }

            if notificationRefreshTaskID == taskID {
                pendingSnapshotNotificationRefreshTask = nil
                notificationRefreshTaskID = nil
            }
        }
    }

    @MainActor
    func refreshAssetNotifications() async {
        guard !isApplyingCloudData else { return }
        do {
            let snapshot = notificationEnabled
                ? notificationSnapshot.map { notificationValue(from: $0) }
                : nil
            let granted = try await AssetNotificationService.refreshSchedule(
                isEnabled: notificationEnabled,
                intervalHours: notificationIntervalHours,
                snapshot: snapshot
            )
            if notificationEnabled && !granted {
                notificationEnabled = false
            }
        } catch {
            print("[AssetTimeMachine] refresh notifications failed: \(error)")
        }
    }

    @MainActor
    private func notificationValue(from snapshot: AssetSnapshot) -> AssetNotificationSnapshot {
        var totalAssets = 0.0
        var totalLiabilities = 0.0
        var financialAssets = 0.0
        var physicalAssets = 0.0

        for entry in snapshot.entries {
            let amount = entry.resolvedAmount
            switch entry.item?.category?.group ?? .financial {
            case .financial:
                totalAssets += amount
                financialAssets += amount
            case .physical:
                totalAssets += amount
                physicalAssets += amount
            case .liability:
                totalLiabilities += amount
            }
        }

        return AssetNotificationSnapshot(
            totalAssets: totalAssets,
            totalLiabilities: totalLiabilities,
            financialAssets: financialAssets,
            physicalAssets: physicalAssets
        )
    }

    @MainActor
    func refreshStrategyNotifications() async {
        guard !isApplyingCloudData else { return }
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
        let historySymbols = StrategyAdviceProjectionStore.historySymbols(for: assetOptions)
        let historyBySymbol = Dictionary(uniqueKeysWithValues: historySymbols.compactMap { symbol in
            marketStore.history(for: symbol).map { (symbol, $0) }
        })
        let historyToken = marketStore.historyRelevanceToken(for: historySymbols)
        let advice = await strategyAdviceService.advice(
            calculationToken: "\(template.id)|\(historyToken)",
            mode: template.mode,
            assetOptions: assetOptions,
            historyBySymbol: historyBySymbol,
            force: false
        )
        guard !Task.isCancelled else { return (template.title, nil) }

        guard let advice else {
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
    func sendStrategyTestNotification() async -> StrategyTestNotificationResult {
        switch await AssetNotificationService.preflightTestNotificationAuthorization() {
        case .granted:
            break
        case .denied:
            return .denied
        case .failed(let message):
            return .failed(message)
        }

        let content = await currentStrategyNotificationContent(includeAdviceWhenDisabled: true)
        let result = await AssetNotificationService.sendStrategyTestNotification(
            strategyTitle: content.title,
            body: content.body
        )
        if case .failed(let message) = result {
            print("[AssetTimeMachine] send strategy test notification failed: \(message)")
        }
        return result
    }
}
