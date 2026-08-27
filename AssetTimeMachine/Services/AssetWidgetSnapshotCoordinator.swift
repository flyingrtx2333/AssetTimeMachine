import Foundation
import SwiftData
import WidgetKit

@MainActor
enum AssetWidgetSnapshotCoordinator {
    static func refresh(
        modelContext: ModelContext,
        marketStore: RemoteMarketStore
    ) async {
        let defaults = UserDefaults.standard
        let settings = DashboardFreedomProjectionInput(
            monthlySalary: defaults.doubleValue(forKey: "dashboard.monthlySalary", fallback: 10_000),
            annualReturnRate: defaults.doubleValue(forKey: "dashboard.annualReturnRate", fallback: 0.03),
            monthlyExpense: defaults.doubleValue(forKey: "dashboard.monthlyExpense", fallback: 3_000),
            annualInflationRate: defaults.doubleValue(forKey: "dashboard.inflationRate", fallback: 0.05),
            usesCurrentAssets: defaults.boolValue(forKey: "dashboard.freedomUsesCurrentAssets", fallback: true)
        )
        let amountsVisible = defaults.boolValue(forKey: "dashboard.amountsVisible", fallback: true)
        let theme: AssetWidgetTheme
        switch AppAppearanceMode(
            rawValue: defaults.string(forKey: AppAppearanceMode.defaultsKey) ?? ""
        ) ?? .system {
        case .system:
            theme = .system
        case .light:
            theme = .daylightGold
        case .dark:
            theme = .darkGold
        }
        let languageIdentifier = AppLocalization.currentLanguage.rawValue
        let liveAnchors = TimeMachineLiveMarketAnchors.from(marketStore: marketStore)
        let liveMarket = DashboardLiveMarketProjectionInput(
            goldPriceCNY: liveAnchors.goldPriceCNY,
            btcPriceUSD: liveAnchors.btcPriceUSD,
            btcPriceCNY: liveAnchors.btcPriceCNY,
            nasdaqPriceUSD: liveAnchors.nasdaqPriceUSD,
            nasdaqPriceCNY: liveAnchors.nasdaqPriceCNY
        )
        let container = modelContext.container
        let otherTitle = AppLocalization.string("其他")
        let unnamedTitle = AppLocalization.string("未命名")

        do {
            let input = try await BackgroundTaskWork.run {
                let repository = DashboardProjectionRepository(modelContainer: container)
                return try await repository.captureDataInput(
                    liveMarket: liveMarket,
                    otherAllocationTitle: otherTitle,
                    unnamedAllocationTitle: unnamedTitle
                )
            }
            try Task.checkCancellation()

            let worker = Task.detached(priority: .utility) {
                guard let data = DashboardProjectionPipeline.buildData(from: input) else {
                    return nil as AssetWidgetSnapshot?
                }
                let freedom = DashboardProjectionPipeline.estimateFreedom(
                    trendPoints: data.trendPoints,
                    input: settings
                )
                return makeSnapshot(
                    data: data,
                    freedom: freedom,
                    amountsVisible: amountsVisible,
                    languageIdentifier: languageIdentifier,
                    theme: theme
                )
            }
            let snapshot = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            try Task.checkCancellation()
            guard let snapshot, AssetWidgetSnapshotStore.save(snapshot) else { return }
            WidgetCenter.shared.reloadAllTimelines()
        } catch is CancellationError {
            return
        } catch {
            print("[AssetTimeMachine] widget snapshot refresh failed: \(error)")
        }
    }

    nonisolated private static func makeSnapshot(
        data: DashboardDataProjectionOutput,
        freedom: DashboardFreedomProjectionValue?,
        amountsVisible: Bool,
        languageIdentifier: String,
        theme: AssetWidgetTheme
    ) -> AssetWidgetSnapshot {
        let recentPoints = thirtyDayPoints(from: data.trendPoints)
        let change = thirtyDayChange(from: recentPoints)
        let sampledTrendPoints = sampled(recentPoints, maximumCount: 18)
        let visibleTrendValues = amountsVisible
            ? sampledTrendPoints.map(\.mainAssets)
            : normalizedTrendValues(sampledTrendPoints.map(\.mainAssets))
        let widgetTrendPoints = zip(sampledTrendPoints, visibleTrendValues).map { point, value in
            AssetWidgetTrendPoint(date: point.date, value: value)
        }

        let freedomProgress: Double
        if let freedom,
           freedom.currentMonthlyExpense.isFinite,
           freedom.currentMonthlyExpense > 0,
           freedom.currentPassiveIncome.isFinite {
            freedomProgress = clampedProgress(freedom.currentPassiveIncome / freedom.currentMonthlyExpense)
        } else {
            freedomProgress = 0
        }

        let status: AssetWidgetFreedomStatus
        let months: Int?
        switch freedom?.status {
        case .alreadyFree:
            status = .alreadyFree
            months = 0
        case .projected(let projectedMonths):
            status = .projected
            months = projectedMonths
        case .unreachable:
            status = .unreachable
            months = nil
        case nil:
            status = .unavailable
            months = nil
        }

        let surplusActual = freedom?.yearToDateAnnualSurplus
        let surplusTarget = freedom?.projectedAnnualSurplus
        return AssetWidgetSnapshot(
            version: AssetWidgetSnapshot.currentVersion,
            updatedAt: .now,
            totalAssets: amountsVisible ? finite(data.totalAssets) : nil,
            thirtyDayChange: finite(change),
            trendPoints: widgetTrendPoints,
            surplusActual: amountsVisible ? finite(surplusActual) : nil,
            surplusTarget: amountsVisible ? finite(surplusTarget) : nil,
            surplusProgress: surplusProgress(actual: surplusActual, target: surplusTarget),
            freedomProgress: freedomProgress,
            freedomStatus: status,
            freedomMonths: months,
            amountsVisible: amountsVisible,
            languageIdentifier: languageIdentifier,
            theme: theme
        )
    }

    nonisolated private static func thirtyDayPoints(
        from points: [DashboardTrendPointValue]
    ) -> [DashboardTrendPointValue] {
        guard let latest = points.last else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: latest.date) ?? latest.date
        return points.filter { $0.date >= cutoff && $0.mainAssets.isFinite }
    }

    nonisolated private static func thirtyDayChange(
        from points: [DashboardTrendPointValue]
    ) -> Double? {
        guard let first = points.first,
              let latest = points.last,
              abs(first.mainAssets) > .ulpOfOne else { return nil }
        return (latest.mainAssets / first.mainAssets) - 1
    }

    nonisolated private static func sampled<T>(_ values: [T], maximumCount: Int) -> [T] {
        guard values.count > maximumCount, maximumCount > 1 else { return values }
        let lastIndex = values.count - 1
        return (0..<maximumCount).map { index in
            let position = Double(index) * Double(lastIndex) / Double(maximumCount - 1)
            return values[Int(position.rounded())]
        }
    }

    nonisolated private static func normalizedTrendValues(_ values: [Double]) -> [Double] {
        guard let first = values.first, abs(first) > .ulpOfOne else {
            return values.indices.map { _ in 1 }
        }
        return values.map { $0 / first }
    }

    nonisolated private static func surplusProgress(actual: Double?, target: Double?) -> Double {
        guard let actual, let target,
              actual.isFinite, target.isFinite,
              abs(target) > .ulpOfOne else { return 0 }
        if target < 0 {
            return actual >= target ? 1 : 0
        }
        return clampedProgress(actual / target)
    }

    nonisolated private static func clampedProgress(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    nonisolated private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

private extension UserDefaults {
    func doubleValue(forKey key: String, fallback: Double) -> Double {
        guard let number = object(forKey: key) as? NSNumber else { return fallback }
        return number.doubleValue
    }

    func boolValue(forKey key: String, fallback: Bool) -> Bool {
        guard let number = object(forKey: key) as? NSNumber else { return fallback }
        return number.boolValue
    }
}
