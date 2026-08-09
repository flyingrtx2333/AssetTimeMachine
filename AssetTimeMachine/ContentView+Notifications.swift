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
        let assetInputs = assetOptions.map { option in
            (
                assetSeries: marketStore.history(for: option.symbol),
                assetOption: option,
                fxSeries: option.historicalFXSymbol.flatMap { marketStore.history(for: $0) }
            )
        }
        let adviceToken = "\(template.id):\(marketStore.historyRevision)"
        let advice: StrategyRebalanceAdvice?
        if cachedStrategyAdviceToken == adviceToken {
            advice = cachedStrategyAdvice
        } else {
            let mode = template.mode
            let adviceTask = Task.detached(priority: .utility) {
                BacktestEngine.advancedRotationRebalanceAdvice(assetInputs: assetInputs, mode: mode)
            }
            advice = await withTaskCancellationHandler {
                await adviceTask.value
            } onCancel: {
                adviceTask.cancel()
            }
            guard !Task.isCancelled else { return (template.title, nil) }
            cachedStrategyAdvice = advice
            cachedStrategyAdviceToken = adviceToken
        }

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
