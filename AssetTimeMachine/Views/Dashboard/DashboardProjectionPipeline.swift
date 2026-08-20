import Foundation
import SwiftData

nonisolated struct DashboardEntryProjectionInput: Sendable {
    let amount: Double
    let isLiability: Bool
    let allocationName: String?
}

nonisolated struct DashboardSnapshotProjectionInput: Sendable {
    let date: Date
    let isLatest: Bool
    let totalAssets: Double
    let totalLiabilities: Double
    let goldAnchorPriceCNY: Double?
    let goldAnchorDate: Date?
    let btcAnchorPriceUSD: Double?
    let btcAnchorPriceCNY: Double?
    let btcAnchorDate: Date?
    let nasdaqAnchorPriceUSD: Double?
    let nasdaqAnchorPriceCNY: Double?
    let nasdaqAnchorDate: Date?
    /// Allocation detail is only needed for the newest snapshot. Historical snapshots carry
    /// totals alone so the cross-actor payload stays small even with years of records.
    let allocationEntries: [DashboardEntryProjectionInput]
}

nonisolated struct DashboardLiveMarketProjectionInput: Sendable {
    let goldPriceCNY: Double?
    let btcPriceUSD: Double?
    let btcPriceCNY: Double?
    let nasdaqPriceUSD: Double?
    let nasdaqPriceCNY: Double?
}

nonisolated struct DashboardDataProjectionInput: Sendable {
    let snapshots: [DashboardSnapshotProjectionInput]
    let liveMarket: DashboardLiveMarketProjectionInput
    let otherAllocationTitle: String
}

/// Reads the dashboard's SwiftData graph on a dedicated model executor and emits value-only
/// projection input. This actor must be constructed inside `BackgroundTaskWork.run`; otherwise
/// its model context can inherit the main executor from the caller that created it.
@ModelActor
actor DashboardProjectionRepository {
    private struct SnapshotAccumulator {
        var totalAssets = 0.0
        var totalLiabilities = 0.0
        var allocationEntries: [DashboardEntryProjectionInput] = []
    }

    func captureDataInput(
        liveMarket: DashboardLiveMarketProjectionInput,
        otherAllocationTitle: String,
        unnamedAllocationTitle: String
    ) async throws -> DashboardDataProjectionInput {
        try Task.checkCancellation()

        var snapshotDescriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse)]
        )
        snapshotDescriptor.fetchLimit = 400
        let newestFirstSnapshots = try modelContext.fetch(snapshotDescriptor)
        try Task.checkCancellation()

        let sourceSnapshots = Self.sourceSnapshots(from: newestFirstSnapshots)
        guard let latestSnapshotID = newestFirstSnapshots.first?.id else {
            return DashboardDataProjectionInput(
                snapshots: [],
                liveMarket: liveMarket,
                otherAllocationTitle: otherAllocationTitle
            )
        }

        var snapshotInputs: [DashboardSnapshotProjectionInput] = []
        snapshotInputs.reserveCapacity(sourceSnapshots.count)
        var seenEntryIDs = Set<UUID>()
        var processedEntryCount = 0
        for (index, snapshot) in sourceSnapshots.enumerated() {
            if index.isMultiple(of: 32) {
                try Task.checkCancellation()
                await Task.yield()
            }

            // Fault only the relationships in the selected dashboard window. A global
            // `FetchDescriptor<AssetEntry>()` grows with the entire archive and made opening the
            // dashboard progressively slower even though only the recent year is displayed.
            var accumulator = SnapshotAccumulator()
            for entry in snapshot.entries {
                guard seenEntryIDs.insert(entry.id).inserted else { continue }
                processedEntryCount += 1
                if processedEntryCount.isMultiple(of: 64) {
                    try Task.checkCancellation()
                    await Task.yield()
                }

                let item = entry.item
                let amount = entry.amount ?? {
                    guard let quantity = entry.quantity, let unitPrice = entry.unitPrice else { return 0 }
                    return quantity * unitPrice
                }()
                let isLiability = item?.category?.groupRawValue == AssetGroup.liability.rawValue
                if isLiability {
                    accumulator.totalLiabilities += amount
                } else {
                    accumulator.totalAssets += amount
                    if snapshot.id == latestSnapshotID {
                        accumulator.allocationEntries.append(
                            DashboardEntryProjectionInput(
                                amount: amount,
                                isLiability: false,
                                allocationName: item?.name ?? unnamedAllocationTitle
                            )
                        )
                    }
                }
            }

            snapshotInputs.append(
                DashboardSnapshotProjectionInput(
                    date: snapshot.date,
                    isLatest: snapshot.id == latestSnapshotID,
                    totalAssets: accumulator.totalAssets,
                    totalLiabilities: accumulator.totalLiabilities,
                    goldAnchorPriceCNY: snapshot.goldAnchorPriceCNY,
                    goldAnchorDate: snapshot.goldAnchorPriceDate,
                    btcAnchorPriceUSD: snapshot.btcAnchorPriceUSD,
                    btcAnchorPriceCNY: snapshot.btcAnchorPriceCNY,
                    btcAnchorDate: snapshot.btcAnchorPriceDate,
                    nasdaqAnchorPriceUSD: snapshot.nasdaqAnchorPriceUSD,
                    nasdaqAnchorPriceCNY: snapshot.nasdaqAnchorPriceCNY,
                    nasdaqAnchorDate: snapshot.nasdaqAnchorPriceDate,
                    allocationEntries: accumulator.allocationEntries
                )
            )
        }

        try Task.checkCancellation()
        return DashboardDataProjectionInput(
            snapshots: snapshotInputs,
            liveMarket: liveMarket,
            otherAllocationTitle: otherAllocationTitle
        )
    }

    private static func sourceSnapshots(from newestFirstSnapshots: [AssetSnapshot]) -> [AssetSnapshot] {
        let orderedSnapshots = Array(newestFirstSnapshots.reversed())
        guard let latestDate = newestFirstSnapshots.first?.date else { return orderedSnapshots }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: latestDate) else {
            return orderedSnapshots
        }

        let recentSnapshots = orderedSnapshots.filter { $0.date >= oneYearAgo }
        return recentSnapshots.count >= 2 ? recentSnapshots : orderedSnapshots
    }
}

nonisolated struct DashboardFreedomProjectionInput: Equatable, Sendable {
    let monthlySalary: Double
    let annualReturnRate: Double
    let monthlyExpense: Double
    let annualInflationRate: Double
    let usesCurrentAssets: Bool
}

nonisolated struct DashboardAllocationDetailValue: Sendable {
    let title: String
    let amount: Double
}

nonisolated struct DashboardAllocationSliceValue: Sendable {
    let title: String
    let amount: Double
    let details: [DashboardAllocationDetailValue]
}

nonisolated struct DashboardTrendPointValue: Sendable {
    let date: Date
    let mainAssets: Double
    let netAssets: Double
    let liabilities: Double
    let goldEquivalent: Double?
    let btcEquivalent: Double?
    let nasdaqEquivalent: Double?
    let goldAnchorPriceCNY: Double?
    let goldAnchorDate: Date?
    let btcAnchorPriceUSD: Double?
    let btcAnchorPriceCNY: Double?
    let btcAnchorDate: Date?
    let nasdaqAnchorPriceUSD: Double?
    let nasdaqAnchorPriceCNY: Double?
    let nasdaqAnchorDate: Date?

    @MainActor var trendPoint: TimeMachineTrendPoint {
        TimeMachineTrendPoint(
            date: date,
            mainAssets: mainAssets,
            netAssets: netAssets,
            liabilities: liabilities,
            goldEquivalent: goldEquivalent,
            btcEquivalent: btcEquivalent,
            nasdaqEquivalent: nasdaqEquivalent,
            goldAnchorPriceCNY: goldAnchorPriceCNY,
            goldAnchorDate: goldAnchorDate,
            btcAnchorPriceUSD: btcAnchorPriceUSD,
            btcAnchorPriceCNY: btcAnchorPriceCNY,
            btcAnchorDate: btcAnchorDate,
            nasdaqAnchorPriceUSD: nasdaqAnchorPriceUSD,
            nasdaqAnchorPriceCNY: nasdaqAnchorPriceCNY,
            nasdaqAnchorDate: nasdaqAnchorDate
        )
    }
}

nonisolated struct DashboardDataProjectionOutput: Sendable {
    let totalAssets: Double?
    let allocationSlices: [DashboardAllocationSliceValue]
    let trendPoints: [DashboardTrendPointValue]
}

nonisolated struct DashboardFreedomProjectionPointValue: Sendable {
    let monthOffset: Int
    let date: Date
    let projectedPassiveIncome: Double
    let projectedMonthlyExpense: Double
    let projectedTotalAssets: Double

    var projectionPoint: FinancialFreedomProjectionPoint {
        FinancialFreedomProjectionPoint(
            monthOffset: monthOffset,
            date: date,
            projectedPassiveIncome: projectedPassiveIncome,
            projectedMonthlyExpense: projectedMonthlyExpense,
            projectedTotalAssets: projectedTotalAssets
        )
    }
}

nonisolated struct DashboardFreedomProjectionValue: Sendable {
    enum Status: Sendable {
        case alreadyFree
        case projected(months: Int)
        case unreachable
    }

    let status: Status
    let monthlySalary: Double
    let annualReturnRate: Double
    let currentMonthlyExpense: Double
    let currentPassiveIncome: Double
    let maximumReachableMonthlyExpense: Double
    let requiredMonthlySalaryToReachFreedom: Double?
    let currentNetAssets: Double
    let currentTotalAssets: Double
    let projectedAnnualSurplus: Double
    let yearToDateAnnualSurplus: Double?
    let yearToDateMonthlyAverageSurplus: Double?
    let yearToDateStartNetAssets: Double?
    let yearToDateEndNetAssets: Double?
    let yearToDateStartDate: Date?
    let yearToDateEndDate: Date?
    let yearToDateMonthsCounted: Int?
    let projectionPoints: [DashboardFreedomProjectionPointValue]

    init(_ projection: FinancialFreedomProjection) {
        switch projection.status {
        case .alreadyFree:
            status = .alreadyFree
        case .projected(let months):
            status = .projected(months: months)
        case .unreachable:
            status = .unreachable
        }
        monthlySalary = projection.monthlySalary
        annualReturnRate = projection.annualReturnRate
        currentMonthlyExpense = projection.currentMonthlyExpense
        currentPassiveIncome = projection.currentPassiveIncome
        maximumReachableMonthlyExpense = projection.maximumReachableMonthlyExpense
        requiredMonthlySalaryToReachFreedom = projection.requiredMonthlySalaryToReachFreedom
        currentNetAssets = projection.currentNetAssets
        currentTotalAssets = projection.currentTotalAssets
        projectedAnnualSurplus = projection.projectedAnnualSurplus
        yearToDateAnnualSurplus = projection.yearToDateAnnualSurplus
        yearToDateMonthlyAverageSurplus = projection.yearToDateMonthlyAverageSurplus
        yearToDateStartNetAssets = projection.yearToDateStartNetAssets
        yearToDateEndNetAssets = projection.yearToDateEndNetAssets
        yearToDateStartDate = projection.yearToDateStartDate
        yearToDateEndDate = projection.yearToDateEndDate
        yearToDateMonthsCounted = projection.yearToDateMonthsCounted
        projectionPoints = projection.projectionPoints.map {
            DashboardFreedomProjectionPointValue(
                monthOffset: $0.monthOffset,
                date: $0.date,
                projectedPassiveIncome: $0.projectedPassiveIncome,
                projectedMonthlyExpense: $0.projectedMonthlyExpense,
                projectedTotalAssets: $0.projectedTotalAssets
            )
        }
    }

    var projection: FinancialFreedomProjection {
        let projectionStatus: FinancialFreedomProjection.Status
        switch status {
        case .alreadyFree:
            projectionStatus = .alreadyFree
        case .projected(let months):
            projectionStatus = .projected(months: months)
        case .unreachable:
            projectionStatus = .unreachable
        }

        return FinancialFreedomProjection(
            status: projectionStatus,
            monthlySalary: monthlySalary,
            annualReturnRate: annualReturnRate,
            currentMonthlyExpense: currentMonthlyExpense,
            currentPassiveIncome: currentPassiveIncome,
            maximumReachableMonthlyExpense: maximumReachableMonthlyExpense,
            requiredMonthlySalaryToReachFreedom: requiredMonthlySalaryToReachFreedom,
            currentNetAssets: currentNetAssets,
            currentTotalAssets: currentTotalAssets,
            projectedAnnualSurplus: projectedAnnualSurplus,
            yearToDateAnnualSurplus: yearToDateAnnualSurplus,
            yearToDateMonthlyAverageSurplus: yearToDateMonthlyAverageSurplus,
            yearToDateStartNetAssets: yearToDateStartNetAssets,
            yearToDateEndNetAssets: yearToDateEndNetAssets,
            yearToDateStartDate: yearToDateStartDate,
            yearToDateEndDate: yearToDateEndDate,
            yearToDateMonthsCounted: yearToDateMonthsCounted,
            projectionPoints: projectionPoints.map(\.projectionPoint)
        )
    }
}

nonisolated enum DashboardProjectionPipeline {
    static func buildData(from input: DashboardDataProjectionInput) -> DashboardDataProjectionOutput? {
        var latestTotalAssets: Double?
        var latestAllocationEntries: [DashboardEntryProjectionInput] = []
        var trendPoints: [DashboardTrendPointValue] = []
        trendPoints.reserveCapacity(input.snapshots.count)

        for snapshot in input.snapshots {
            guard !Task.isCancelled else { return nil }

            if snapshot.isLatest {
                latestTotalAssets = snapshot.totalAssets
                latestAllocationEntries = snapshot.allocationEntries
            }

            trendPoints.append(
                makeTrendPoint(
                    snapshot: snapshot,
                    liveMarket: input.liveMarket
                )
            )
        }

        guard !Task.isCancelled else { return nil }
        let allocationSlices = makeAllocationSlices(
            from: latestAllocationEntries,
            otherTitle: input.otherAllocationTitle
        )
        guard !Task.isCancelled else { return nil }
        return DashboardDataProjectionOutput(
            totalAssets: latestTotalAssets,
            allocationSlices: allocationSlices,
            trendPoints: trendPoints
        )
    }

    static func estimateFreedom(
        trendPoints: [DashboardTrendPointValue],
        input: DashboardFreedomProjectionInput
    ) -> DashboardFreedomProjectionValue? {
        guard !Task.isCancelled else { return nil }
        let projection = FinancialFreedomEstimator.estimate(
            points: trendPoints.map {
                FinancialFreedomHistoryPoint(
                    date: $0.date,
                    mainAssets: $0.mainAssets,
                    netAssets: $0.netAssets,
                    liabilities: $0.liabilities
                )
            },
            monthlySalary: input.monthlySalary,
            annualReturnRate: input.annualReturnRate,
            monthlyExpense: input.monthlyExpense,
            annualInflationRate: input.annualInflationRate,
            usesCurrentAssets: input.usesCurrentAssets
        )
        guard !Task.isCancelled, let projection else { return nil }
        return DashboardFreedomProjectionValue(projection)
    }

    private static func makeTrendPoint(
        snapshot: DashboardSnapshotProjectionInput,
        liveMarket: DashboardLiveMarketProjectionInput
    ) -> DashboardTrendPointValue {
        let isToday = Calendar.current.isDateInToday(snapshot.date)
        let goldAnchorPriceCNY = snapshot.goldAnchorPriceCNY ?? (isToday ? liveMarket.goldPriceCNY : nil)
        let btcAnchorPriceCNY = snapshot.btcAnchorPriceCNY ?? (isToday ? liveMarket.btcPriceCNY : nil)
        let nasdaqAnchorPriceCNY = snapshot.nasdaqAnchorPriceCNY ?? (isToday ? liveMarket.nasdaqPriceCNY : nil)
        let btcAnchorPriceUSD = snapshot.btcAnchorPriceUSD ?? (isToday ? liveMarket.btcPriceUSD : nil)
        let nasdaqAnchorPriceUSD = snapshot.nasdaqAnchorPriceUSD ?? (isToday ? liveMarket.nasdaqPriceUSD : nil)

        return DashboardTrendPointValue(
            date: snapshot.date,
            mainAssets: snapshot.totalAssets,
            netAssets: snapshot.totalAssets - snapshot.totalLiabilities,
            liabilities: snapshot.totalLiabilities,
            goldEquivalent: positiveRatio(snapshot.totalAssets, dividedBy: goldAnchorPriceCNY),
            btcEquivalent: positiveRatio(snapshot.totalAssets, dividedBy: btcAnchorPriceCNY),
            nasdaqEquivalent: positiveRatio(snapshot.totalAssets, dividedBy: nasdaqAnchorPriceCNY),
            goldAnchorPriceCNY: goldAnchorPriceCNY,
            goldAnchorDate: snapshot.goldAnchorDate ?? anchorDateIfToday(isToday, hasValue: goldAnchorPriceCNY != nil, snapshotDate: snapshot.date),
            btcAnchorPriceUSD: btcAnchorPriceUSD,
            btcAnchorPriceCNY: btcAnchorPriceCNY,
            btcAnchorDate: snapshot.btcAnchorDate ?? anchorDateIfToday(isToday, hasValue: btcAnchorPriceUSD != nil, snapshotDate: snapshot.date),
            nasdaqAnchorPriceUSD: nasdaqAnchorPriceUSD,
            nasdaqAnchorPriceCNY: nasdaqAnchorPriceCNY,
            nasdaqAnchorDate: snapshot.nasdaqAnchorDate ?? anchorDateIfToday(isToday, hasValue: nasdaqAnchorPriceUSD != nil, snapshotDate: snapshot.date)
        )
    }

    private static func makeAllocationSlices(
        from entries: [DashboardEntryProjectionInput],
        otherTitle: String
    ) -> [DashboardAllocationSliceValue] {
        var amountByName: [String: Double] = [:]
        for (index, entry) in entries.enumerated() {
            guard !entry.isLiability, entry.amount > 0 else { continue }
            let title = entry.allocationName ?? ""
            amountByName[title, default: 0] += entry.amount

            if index.isMultiple(of: 64), Task.isCancelled {
                return []
            }
        }

        let sortedDetails = amountByName
            .map { DashboardAllocationDetailValue(title: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }

        let topLimit = 5
        var slices = sortedDetails.prefix(topLimit).map {
            DashboardAllocationSliceValue(title: $0.title, amount: $0.amount, details: [$0])
        }

        if sortedDetails.count > topLimit {
            let otherDetails = Array(sortedDetails.dropFirst(topLimit))
            let otherAmount = otherDetails.reduce(0) { $0 + $1.amount }
            if otherAmount > 0 {
                slices.append(
                    DashboardAllocationSliceValue(
                        title: otherTitle,
                        amount: otherAmount,
                        details: otherDetails
                    )
                )
            }
        }

        return slices
    }

    private static func positiveRatio(_ numerator: Double, dividedBy denominator: Double?) -> Double? {
        guard let denominator, denominator > 0 else { return nil }
        return numerator / denominator
    }

    private static func anchorDateIfToday(_ isToday: Bool, hasValue: Bool, snapshotDate: Date) -> Date? {
        hasValue && isToday ? snapshotDate : nil
    }
}
