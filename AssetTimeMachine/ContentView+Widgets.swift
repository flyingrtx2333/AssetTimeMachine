import Foundation
import SwiftUI

extension ContentView {
    @MainActor
    func scheduleWidgetSnapshotRefresh(delayNanoseconds: UInt64 = 300_000_000) {
        widgetSnapshotGeneration &+= 1
        let generation = widgetSnapshotGeneration
        pendingWidgetSnapshotRefreshTask?.cancel()

        pendingWidgetSnapshotRefreshTask = Task {
            if delayNanoseconds == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled,
                  generation == widgetSnapshotGeneration,
                  !isApplyingCloudData,
                  !cloudStore.isApplyingLocalData else { return }

            await AssetWidgetSnapshotCoordinator.refresh(
                modelContext: modelContext,
                marketStore: marketStore
            )
            guard generation == widgetSnapshotGeneration else { return }
            pendingWidgetSnapshotRefreshTask = nil
        }
    }
}
