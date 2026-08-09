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
        let didRefreshLiveData = await marketStore.refreshLiveData(commitIf: {
            canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision)
        })
        guard canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision) else { return }

        if didRefreshLiveData {
            lastMarketRefreshAt = .now
            await syncTodaySnapshotWithLatestMarketData(
                expectedCloudDataRevision: expectedCloudDataRevision
            )
            guard canCommitMarketRefresh(expectedCloudDataRevision: expectedCloudDataRevision) else { return }
        }
        scheduleSnapshotNotificationRefresh(delayNanoseconds: 0)
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
