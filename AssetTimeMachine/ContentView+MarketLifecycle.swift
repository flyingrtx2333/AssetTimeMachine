import SwiftUI
import SwiftData

extension ContentView {
    var shouldRefreshLiveMarketData: Bool {
        guard let lastMarketRefreshAt else { return true }
        return Date().timeIntervalSince(lastMarketRefreshAt) >= ContentView.foregroundMarketRefreshInterval
    }

    var nextMarketRefreshDelayNanoseconds: UInt64 {
        guard let lastMarketRefreshAt else {
            return UInt64(ContentView.foregroundMarketRefreshInterval * 1_000_000_000)
        }

        let elapsed = Date().timeIntervalSince(lastMarketRefreshAt)
        let remaining = max(60, ContentView.foregroundMarketRefreshInterval - elapsed)
        return UInt64(remaining * 1_000_000_000)
    }

    @MainActor
    func refreshLiveMarketDataIfNeeded(force: Bool) async {
        guard !isApplyingCloudData, !cloudStore.isApplyingLocalData else { return }
        guard force || shouldRefreshLiveMarketData else { return }
        let expectedCloudDataRevision = cloudStore.localDataRevision
        let trackedSecuritySymbols = trackedRecordSecuritySymbols()
        async let liveDataRefresh = marketStore.refreshLiveData(commitIf: {
            canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision)
        })
        async let securityRefresh = refreshTrackedSecurityMarketData(
            symbols: trackedSecuritySymbols,
            expectedCloudDataRevision: expectedCloudDataRevision
        )
        let (didRefreshLiveData, didRefreshSecurityData) = await (liveDataRefresh, securityRefresh)
        guard canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision) else { return }

        if didRefreshLiveData || didRefreshSecurityData {
            lastMarketRefreshAt = .now
            await syncTodaySnapshotWithLatestMarketData(
                expectedCloudDataRevision: expectedCloudDataRevision
            )
            guard canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision) else { return }
        }
        scheduleSnapshotNotificationRefresh(delayNanoseconds: 0)
    }

    @MainActor
    private func trackedRecordSecuritySymbols() -> [String] {
        guard let items = try? modelContext.fetch(FetchDescriptor<AssetItem>()) else { return [] }
        return Array(Set(items.compactMap { item in
            guard item.isActive,
                  let symbol = item.marketAssetSymbol,
                  symbol.hasPrefix(MarketAssetDescriptor.recordETFPrefix)
                    || symbol.hasPrefix(MarketAssetDescriptor.recordASharePrefix) else { return nil }
            return symbol
        })).sorted()
    }

    @MainActor
    private func refreshTrackedSecurityMarketData(
        symbols: [String],
        expectedCloudDataRevision: Int
    ) async -> Bool {
        guard !symbols.isEmpty else { return false }
        var didRefresh = false
        for symbol in symbols {
            guard canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision) else { return false }
            do {
                try await marketStore.refreshRecordSecurityHistory(symbol: symbol)
                didRefresh = marketStore.history(for: symbol)?.prices.isEmpty == false || didRefresh
            } catch {
                // Keep cached prices for a symbol when its public market endpoint is unavailable.
            }
        }
        return didRefresh
    }

    @MainActor
    func syncTodaySnapshotWithLatestMarketData(expectedCloudDataRevision: Int) async {
        guard canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision) else { return }
        do {
            let snapshot = try SnapshotService.createSnapshot(
                on: .now,
                inheritPrevious: true,
                createMissingEntries: true,
                in: modelContext
            )
            guard canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision) else { return }
            try syncAutoPricedEntries(in: snapshot)
            guard canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision) else { return }
            await SnapshotAnchorService.captureLiveAnchorsIfPossible(
                for: snapshot,
                marketStore: marketStore,
                in: modelContext,
                commitIf: {
                    canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision)
                }
            )
        } catch {
            print("[AssetTimeMachine] sync today snapshot failed: \(error)")
        }
    }

    @MainActor
    private func canCommitMarketRefresh(expectedCloudDataRevision: Int) -> Bool {
        !isApplyingCloudData
            && !cloudStore.isApplyingLocalData
            && cloudStore.localDataRevision == expectedCloudDataRevision
    }

    @MainActor
    func syncAutoPricedEntries(in snapshot: AssetSnapshot) throws {
        var didChange = false

        for entry in snapshot.entries {
            guard let item = entry.item,
                  item.valuationMethod == .quantityAndUnitPrice,
                  let liveUnitPrice = item.resolvedAutoUnitPrice(using: marketStore) else {
                continue
            }

            if entry.unitPrice == nil || abs((entry.unitPrice ?? 0) - liveUnitPrice) > 0.0001 {
                entry.unitPrice = liveUnitPrice
                entry.updatedAt = .now
                item.updatedAt = .now
                didChange = true
            }
        }

        if didChange {
            snapshot.updatedAt = .now
            try modelContext.save()
        }
    }
}
