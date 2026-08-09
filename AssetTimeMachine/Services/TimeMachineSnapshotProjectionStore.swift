import Foundation
import SwiftData

/// A value-only snapshot representation that can safely leave SwiftData's model executor.
/// SwiftUI charts and summaries should consume this type instead of traversing model
/// relationships on the main actor.
struct TimeMachineSnapshotProjection: Sendable {
    let id: UUID
    let date: Date
    let updatedAt: Date
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
}

struct SnapshotArchiveProjection: Identifiable, Sendable {
    let id: UUID
    let date: Date
    let entryCount: Int
    let totalLiabilities: Double
    let netAssets: Double
}

@ModelActor
actor TimeMachineSnapshotProjectionStore {
    func fetchAll() async throws -> [TimeMachineSnapshotProjection] {
        let descriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .forward)]
        )
        let snapshots = try modelContext.fetch(descriptor)
        var projections: [TimeMachineSnapshotProjection] = []
        projections.reserveCapacity(snapshots.count)

        for (index, snapshot) in snapshots.enumerated() {
            try Task.checkCancellation()

            var totalAssets = 0.0
            var totalLiabilities = 0.0
            for entry in snapshot.entries {
                if (entry.item?.category?.group ?? .financial) == .liability {
                    totalLiabilities += entry.resolvedAmount
                } else {
                    totalAssets += entry.resolvedAmount
                }
            }

            projections.append(
                TimeMachineSnapshotProjection(
                    id: snapshot.id,
                    date: snapshot.date,
                    updatedAt: snapshot.updatedAt,
                    totalAssets: totalAssets,
                    totalLiabilities: totalLiabilities,
                    goldAnchorPriceCNY: snapshot.goldAnchorPriceCNY,
                    goldAnchorDate: snapshot.goldAnchorPriceDate,
                    btcAnchorPriceUSD: snapshot.btcAnchorPriceUSD,
                    btcAnchorPriceCNY: snapshot.btcAnchorPriceCNY,
                    btcAnchorDate: snapshot.btcAnchorPriceDate,
                    nasdaqAnchorPriceUSD: snapshot.nasdaqAnchorPriceUSD,
                    nasdaqAnchorPriceCNY: snapshot.nasdaqAnchorPriceCNY,
                    nasdaqAnchorDate: snapshot.nasdaqAnchorPriceDate
                )
            )

            if index.isMultiple(of: 64) {
                await Task.yield()
            }
        }

        return projections
    }

    func fetchArchiveProjections() async throws -> [SnapshotArchiveProjection] {
        let descriptor = FetchDescriptor<AssetSnapshot>(
            sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse)]
        )
        let snapshots = try modelContext.fetch(descriptor)
        var projections: [SnapshotArchiveProjection] = []
        projections.reserveCapacity(snapshots.count)

        for (index, snapshot) in snapshots.enumerated() {
            try Task.checkCancellation()
            var totalAssets = 0.0
            var totalLiabilities = 0.0
            var entryCount = 0

            for entry in snapshot.entries {
                entryCount += 1
                if (entry.item?.category?.group ?? .financial) == .liability {
                    totalLiabilities += entry.resolvedAmount
                } else {
                    totalAssets += entry.resolvedAmount
                }
            }

            projections.append(
                SnapshotArchiveProjection(
                    id: snapshot.id,
                    date: snapshot.date,
                    entryCount: entryCount,
                    totalLiabilities: totalLiabilities,
                    netAssets: totalAssets - totalLiabilities
                )
            )

            if index.isMultiple(of: 64) {
                await Task.yield()
            }
        }

        return projections
    }
}

struct TimeMachinePreparedVisualization: Sendable {
    let trendPoints: [TimeMachineTrendPoint]
    let filteredTrendPoints: [TimeMachineTrendPoint]
    let monthlySurplusPoints: [TimeMachineMonthlySurplusPoint]
    let annualSurplusPoints: [TimeMachineAnnualSurplusPoint]
    let snapshotIDByDay: [Date: UUID]
}

struct TimeMachinePreparedHistory: Sendable {
    let pointsBySymbol: [String: [TimeMachineSingleAxisPoint]]
    let candlesticksBySymbol: [String: [TimeMachineCandlestickPoint]]
}

enum TimeMachineHistoryProjectionProcessor {
    nonisolated static func prepare(
        seriesBySymbol: [String: PublicHistorySeries]
    ) -> TimeMachinePreparedHistory {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"

        var pointsBySymbol: [String: [TimeMachineSingleAxisPoint]] = [:]
        var candlesticksBySymbol: [String: [TimeMachineCandlestickPoint]] = [:]
        pointsBySymbol.reserveCapacity(seriesBySymbol.count)
        candlesticksBySymbol.reserveCapacity(seriesBySymbol.count)

        for (symbol, series) in seriesBySymbol {
            if Task.isCancelled { break }

            let count = min(series.dates.count, series.prices.count)
            var points: [TimeMachineSingleAxisPoint] = []
            var candlesticks: [TimeMachineCandlestickPoint] = []
            points.reserveCapacity(count)
            candlesticks.reserveCapacity(count)

            let hasOHLC = series.openPrices?.count == series.dates.count
                && series.highPrices?.count == series.dates.count
                && series.lowPrices?.count == series.dates.count
                && series.closePrices?.count == series.dates.count

            for index in 0..<count {
                if index.isMultiple(of: 256), Task.isCancelled { break }
                guard let date = formatter.date(from: series.dates[index]) else { continue }

                let price = series.prices[index]
                if price.isFinite, price > 0 {
                    points.append(TimeMachineSingleAxisPoint(date: date, value: price))
                }

                guard hasOHLC,
                      let open = series.openPrices?[index],
                      let high = series.highPrices?[index],
                      let low = series.lowPrices?[index],
                      let close = series.closePrices?[index],
                      open.isFinite,
                      high.isFinite,
                      low.isFinite,
                      close.isFinite,
                      open > 0,
                      high >= max(open, close, low),
                      low <= min(open, close, high) else {
                    continue
                }

                let volume: Double?
                if let volumes = series.volumes,
                   volumes.indices.contains(index),
                   let rawVolume = volumes[index],
                   rawVolume.isFinite,
                   rawVolume >= 0 {
                    volume = rawVolume
                } else {
                    volume = nil
                }
                candlesticks.append(
                    TimeMachineCandlestickPoint(
                        date: date,
                        open: open,
                        high: high,
                        low: low,
                        close: close,
                        volume: volume
                    )
                )
            }

            if !points.isEmpty {
                pointsBySymbol[symbol] = points.sorted { $0.date < $1.date }
            }
            if !candlesticks.isEmpty {
                candlesticksBySymbol[symbol] = candlesticks.sorted { $0.date < $1.date }
            }
        }

        return TimeMachinePreparedHistory(
            pointsBySymbol: pointsBySymbol,
            candlesticksBySymbol: candlesticksBySymbol
        )
    }
}

enum TimeMachineSnapshotProjectionProcessor {
    nonisolated static func prepare(
        projections: [TimeMachineSnapshotProjection],
        range: TimeMachineRange,
        liveAnchors: TimeMachineLiveMarketAnchors,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> TimeMachinePreparedVisualization {
        var trendPoints: [TimeMachineTrendPoint] = []
        var snapshotIDByDay: [Date: UUID] = [:]
        var snapshotUpdateByDay: [Date: Date] = [:]
        trendPoints.reserveCapacity(projections.count)
        snapshotIDByDay.reserveCapacity(projections.count)
        snapshotUpdateByDay.reserveCapacity(projections.count)

        for projection in projections {
            trendPoints.append(
                makeTrendPoint(
                    from: projection,
                    liveAnchors: liveAnchors,
                    calendar: calendar
                )
            )

            let day = calendar.startOfDay(for: projection.date)
            if snapshotUpdateByDay[day].map({ projection.updatedAt > $0 }) ?? true {
                snapshotUpdateByDay[day] = projection.updatedAt
                snapshotIDByDay[day] = projection.id
            }
        }

        let filteredTrendPoints = filter(trendPoints, range: range, calendar: calendar)
        return TimeMachinePreparedVisualization(
            trendPoints: trendPoints,
            filteredTrendPoints: filteredTrendPoints,
            monthlySurplusPoints: monthlySurplusPoints(
                from: trendPoints,
                range: range,
                calendar: calendar
            ),
            annualSurplusPoints: annualSurplusPoints(
                from: trendPoints,
                range: range,
                now: now,
                calendar: calendar
            ),
            snapshotIDByDay: snapshotIDByDay
        )
    }

    nonisolated static func makeTrendPoint(
        from snapshot: TimeMachineSnapshotProjection,
        liveAnchors: TimeMachineLiveMarketAnchors?,
        calendar: Calendar = .current
    ) -> TimeMachineTrendPoint {
        let mainAssets = snapshot.totalAssets
        let isToday = calendar.isDateInToday(snapshot.date)
        let goldAnchorPriceCNY = snapshot.goldAnchorPriceCNY ?? (isToday ? liveAnchors?.goldPriceCNY : nil)
        let btcAnchorPriceCNY = snapshot.btcAnchorPriceCNY ?? (isToday ? liveAnchors?.btcPriceCNY : nil)
        let nasdaqAnchorPriceCNY = snapshot.nasdaqAnchorPriceCNY ?? (isToday ? liveAnchors?.nasdaqPriceCNY : nil)
        let btcAnchorPriceUSD = snapshot.btcAnchorPriceUSD ?? (isToday ? liveAnchors?.btcPriceUSD : nil)
        let nasdaqAnchorPriceUSD = snapshot.nasdaqAnchorPriceUSD ?? (isToday ? liveAnchors?.nasdaqPriceUSD : nil)

        return TimeMachineTrendPoint(
            date: snapshot.date,
            mainAssets: mainAssets,
            netAssets: mainAssets - snapshot.totalLiabilities,
            liabilities: snapshot.totalLiabilities,
            goldEquivalent: goldAnchorPriceCNY.flatMap { $0 > 0 ? mainAssets / $0 : nil },
            btcEquivalent: btcAnchorPriceCNY.flatMap { $0 > 0 ? mainAssets / $0 : nil },
            nasdaqEquivalent: nasdaqAnchorPriceCNY.flatMap { $0 > 0 ? mainAssets / $0 : nil },
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

    nonisolated private static func filter(
        _ points: [TimeMachineTrendPoint],
        range: TimeMachineRange,
        calendar: Calendar
    ) -> [TimeMachineTrendPoint] {
        guard let latestDate = points.last?.date,
              let startDate = startDate(for: range, from: latestDate, calendar: calendar) else {
            return points
        }
        return points.filter { $0.date >= startDate }
    }

    nonisolated private static func monthlySurplusPoints(
        from source: [TimeMachineTrendPoint],
        range: TimeMachineRange,
        calendar: Calendar
    ) -> [TimeMachineMonthlySurplusPoint] {
        guard !source.isEmpty else { return [] }
        let grouped = Dictionary(grouping: source) { point in
            calendar.dateInterval(of: .month, for: point.date)?.start ?? calendar.startOfDay(for: point.date)
        }

        var result: [TimeMachineMonthlySurplusPoint] = []
        result.reserveCapacity(grouped.count)
        var previousMonthEndNetAssets: Double?
        for monthStart in grouped.keys.sorted() {
            guard let lastPoint = grouped[monthStart]?.max(by: { $0.date < $1.date }) else { continue }
            defer { previousMonthEndNetAssets = lastPoint.netAssets }
            guard let baseline = previousMonthEndNetAssets else { continue }
            result.append(
                TimeMachineMonthlySurplusPoint(
                    monthStart: monthStart,
                    date: lastPoint.date,
                    surplus: lastPoint.netAssets - baseline,
                    monthEndNetAssets: lastPoint.netAssets
                )
            )
        }

        guard let latestDate = result.last?.date,
              let startDate = startDate(for: range, from: latestDate, calendar: calendar) else {
            return result
        }
        return result.filter { $0.date >= startDate }
    }

    nonisolated private static func annualSurplusPoints(
        from source: [TimeMachineTrendPoint],
        range: TimeMachineRange,
        now: Date,
        calendar: Calendar
    ) -> [TimeMachineAnnualSurplusPoint] {
        guard !source.isEmpty else { return [] }
        let grouped = Dictionary(grouping: source) { point in
            calendar.dateInterval(of: .year, for: point.date)?.start ?? calendar.startOfDay(for: point.date)
        }

        var result: [TimeMachineAnnualSurplusPoint] = []
        result.reserveCapacity(grouped.count)
        var previousYearEndNetAssets: Double?
        for yearStart in grouped.keys.sorted() {
            guard let lastPoint = grouped[yearStart]?.max(by: { $0.date < $1.date }) else { continue }
            defer { previousYearEndNetAssets = lastPoint.netAssets }
            guard let baseline = previousYearEndNetAssets else { continue }
            result.append(
                TimeMachineAnnualSurplusPoint(
                    yearStart: yearStart,
                    date: lastPoint.date,
                    surplus: lastPoint.netAssets - baseline,
                    yearEndNetAssets: lastPoint.netAssets,
                    isCurrentYear: calendar.isDate(lastPoint.date, equalTo: now, toGranularity: .year)
                )
            )
        }

        guard let latestDate = source.last?.date,
              let startDate = startDate(for: range, from: latestDate, calendar: calendar) else {
            return result
        }
        return result.filter { $0.date >= startDate }
    }

    nonisolated private static func startDate(
        for range: TimeMachineRange,
        from latestDate: Date,
        calendar: Calendar
    ) -> Date? {
        switch range {
        case .halfMonth:
            return calendar.date(byAdding: .day, value: -15, to: latestDate)
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: latestDate)
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: latestDate)
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: latestDate)
        case .threeYears:
            return calendar.date(byAdding: .year, value: -3, to: latestDate)
        case .all:
            return nil
        }
    }

    nonisolated private static func anchorDateIfToday(
        _ isToday: Bool,
        hasValue: Bool,
        snapshotDate: Date
    ) -> Date? {
        hasValue && isToday ? snapshotDate : nil
    }
}
