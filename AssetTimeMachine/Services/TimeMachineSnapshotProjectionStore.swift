#if !os(macOS) || targetEnvironment(macCatalyst)
import AssetTimeMachineBacktestCore
#endif
import Foundation
import SwiftData
#if os(macOS) || targetEnvironment(macCatalyst)
import SQLite3
#endif

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

#if os(macOS) || targetEnvironment(macCatalyst)
/// Shares the small value-only history between the Home and Time Machine pages.
/// SwiftData revisions invalidate the cache after edits, imports, and cloud restores.
actor MacSnapshotSummaryCache {
    static let shared = MacSnapshotSummaryCache()

    private var containerID: ObjectIdentifier?
    private var revision: UInt64?
    private var cached: [TimeMachineSnapshotProjection] = []

    func projections(in container: ModelContainer, revision requestedRevision: UInt64) async throws
        -> [TimeMachineSnapshotProjection] {
        let identifier = ObjectIdentifier(container)
        if containerID == identifier, revision == requestedRevision {
            return cached
        }
        let store = TimeMachineSnapshotProjectionStore(modelContainer: container)
        let projections = try await store.fetchAll()
        if ModelStoreRevisionClock.shared.currentRevision() == requestedRevision {
            containerID = identifier
            revision = requestedRevision
            cached = projections
        }
        return projections
    }
}
#endif

@ModelActor
actor TimeMachineSnapshotProjectionStore {
    private static let batchSize = 128

    func fetchAll() async throws -> [TimeMachineSnapshotProjection] {
        #if os(macOS) || targetEnvironment(macCatalyst)
        if let configuration = modelContainer.configurations.first,
           !configuration.isStoredInMemoryOnly,
           configuration.url.isFileURL {
            do {
                let projections = try await fetchSQLiteProjections(at: configuration.url)
                try validateSQLiteProjections(projections)
                return projections
            } catch {
                // SwiftData owns the store format. If it changes, use the public model API.
                NSLog("[AssetTimeMachine] fast history read unavailable: %@", String(describing: error))
            }
        }
        #endif
        var projections: [TimeMachineSnapshotProjection] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let batchCount: Int = try autoreleasepool {
                let context = ModelContext(modelContainer)
                var descriptor = FetchDescriptor<AssetSnapshot>(
                    sortBy: [SortDescriptor(\AssetSnapshot.date, order: .forward),
                             SortDescriptor(\AssetSnapshot.id, order: .forward)]
                )
                descriptor.fetchLimit = Self.batchSize
                descriptor.fetchOffset = offset
                let snapshots = try context.fetch(descriptor)
                for snapshot in snapshots {
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
                            id: snapshot.id, date: snapshot.date, updatedAt: snapshot.updatedAt,
                            totalAssets: totalAssets, totalLiabilities: totalLiabilities,
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
                }
                return snapshots.count
            }
            offset += batchCount
            if batchCount < Self.batchSize { break }
            await Task.yield()
        }

        return projections
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    private func validateSQLiteProjections(_ projections: [TimeMachineSnapshotProjection]) throws {
        guard !projections.isEmpty else { return }
        let context = ModelContext(modelContainer)
        let sampleIndices = Set([0, projections.count / 2, projections.count - 1])
        for index in sampleIndices {
            let projection = projections[index]
            let id = projection.id
            var descriptor = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let snapshot = try context.fetch(descriptor).first else {
                throw NSError(domain: "TimeMachineSQLiteProjectionStore", code: 1)
            }
            var assets = 0.0
            var liabilities = 0.0
            for entry in snapshot.entries {
                if (entry.item?.category?.group ?? .financial) == .liability {
                    liabilities += entry.resolvedAmount
                } else {
                    assets += entry.resolvedAmount
                }
            }
            guard abs(assets - projection.totalAssets) < 0.01,
                  abs(liabilities - projection.totalLiabilities) < 0.01,
                  abs(snapshot.date.timeIntervalSince(projection.date)) < 1 else {
                throw NSError(domain: "TimeMachineSQLiteProjectionStore", code: 2)
            }
        }
    }

    private func fetchSQLiteProjections(at url: URL) async throws -> [TimeMachineSnapshotProjection] {
        enum ReadError: Error { case open, prepare, step, invalidID }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw ReadError.open
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)

        // A single read transaction gives a consistent view while edits or sync may be saving.
        // SwiftData's schema is checked by prepare; a changed schema falls back to ModelContext.
        let query = """
        SELECT s.ZID, s.ZDATE, s.ZUPDATEDAT,
               COALESCE(SUM(CASE WHEN c.ZGROUPRAWVALUE = 'liability' THEN 0
                                 ELSE COALESCE(e.ZAMOUNT, e.ZQUANTITY * e.ZUNITPRICE, 0) END), 0),
               COALESCE(SUM(CASE WHEN c.ZGROUPRAWVALUE = 'liability'
                                 THEN COALESCE(e.ZAMOUNT, e.ZQUANTITY * e.ZUNITPRICE, 0) ELSE 0 END), 0),
               s.ZGOLDANCHORPRICECNY, s.ZGOLDANCHORPRICEDATE,
               s.ZBTCANCHORPRICEUSD, s.ZUSDPERCNY, s.ZBTCANCHORPRICEDATE,
               s.ZNASDAQANCHORPRICEUSD, s.ZNASDAQANCHORPRICEDATE
        FROM ZASSETSNAPSHOT s
        LEFT JOIN ZASSETENTRY e ON e.ZSNAPSHOT = s.Z_PK
        LEFT JOIN ZASSETITEM i ON i.Z_PK = e.ZITEM
        LEFT JOIN ZASSETCATEGORY c ON c.Z_PK = i.ZCATEGORY
        GROUP BY s.Z_PK
        ORDER BY s.ZDATE, s.ZID
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ReadError.prepare }
        defer { sqlite3_finalize(statement) }

        func optionalDouble(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }
        func optionalDate(_ column: Int32) -> Date? {
            optionalDouble(column).map(Date.init(timeIntervalSinceReferenceDate:))
        }

        var projections: [TimeMachineSnapshotProjection] = []
        while true {
            try Task.checkCancellation()
            var batchCount = 0
            while batchCount < Self.batchSize {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return projections }
                guard result == SQLITE_ROW else { throw ReadError.step }
                guard sqlite3_column_bytes(statement, 0) == 16,
                      let idBlob = sqlite3_column_blob(statement, 0) else { throw ReadError.invalidID }
                let bytes = idBlob.assumingMemoryBound(to: UInt8.self)
                let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                                     bytes[4], bytes[5], bytes[6], bytes[7],
                                     bytes[8], bytes[9], bytes[10], bytes[11],
                                     bytes[12], bytes[13], bytes[14], bytes[15]))
                let usdPerCNY = optionalDouble(8)
                let btcUSD = optionalDouble(7)
                let nasdaqUSD = optionalDouble(10)
                let btcCNY = (usdPerCNY ?? 0) > 0 ? btcUSD.map { $0 / usdPerCNY! } : nil
                let nasdaqCNY = (usdPerCNY ?? 0) > 0 ? nasdaqUSD.map { $0 / usdPerCNY! } : nil
                projections.append(TimeMachineSnapshotProjection(
                    id: id,
                    date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
                    updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
                    totalAssets: sqlite3_column_double(statement, 3),
                    totalLiabilities: sqlite3_column_double(statement, 4),
                    goldAnchorPriceCNY: optionalDouble(5),
                    goldAnchorDate: optionalDate(6),
                    btcAnchorPriceUSD: btcUSD,
                    btcAnchorPriceCNY: btcCNY,
                    btcAnchorDate: optionalDate(9),
                    nasdaqAnchorPriceUSD: nasdaqUSD,
                    nasdaqAnchorPriceCNY: nasdaqCNY,
                    nasdaqAnchorDate: optionalDate(11)
                ))
                batchCount += 1
            }
            await Task.yield()
        }
    }
    #endif

    func fetchArchiveProjections() async throws -> [SnapshotArchiveProjection] {
        #if os(macOS) || targetEnvironment(macCatalyst)
        if let configuration = modelContainer.configurations.first,
           !configuration.isStoredInMemoryOnly,
           configuration.url.isFileURL {
            do {
                let projections = try await fetchSQLiteArchive(at: configuration.url)
                try validateSQLiteArchiveProjections(projections)
                return projections
            } catch {
                NSLog("[AssetTimeMachine] fast archive read unavailable: %@", String(describing: error))
            }
        }
        #endif
        var projections: [SnapshotArchiveProjection] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let batchCount: Int = try autoreleasepool {
                let context = ModelContext(modelContainer)
                var descriptor = FetchDescriptor<AssetSnapshot>(
                    sortBy: [SortDescriptor(\AssetSnapshot.date, order: .reverse),
                             SortDescriptor(\AssetSnapshot.id, order: .reverse)]
                )
                descriptor.fetchLimit = Self.batchSize
                descriptor.fetchOffset = offset
                let snapshots = try context.fetch(descriptor)
                for snapshot in snapshots {
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
                            id: snapshot.id, date: snapshot.date, entryCount: entryCount,
                            totalLiabilities: totalLiabilities,
                            netAssets: totalAssets - totalLiabilities
                        )
                    )
                }
                return snapshots.count
            }
            offset += batchCount
            if batchCount < Self.batchSize { break }
            await Task.yield()
        }

        return projections
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    private func validateSQLiteArchiveProjections(_ projections: [SnapshotArchiveProjection]) throws {
        guard !projections.isEmpty else { return }
        let context = ModelContext(modelContainer)
        let sampleIndices = Set([0, projections.count / 2, projections.count - 1])
        for index in sampleIndices {
            let projection = projections[index]
            let id = projection.id
            var descriptor = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let snapshot = try context.fetch(descriptor).first else {
                throw NSError(domain: "TimeMachineSQLiteArchive", code: 1)
            }
            let entries = snapshot.entries
            var assets = 0.0
            var liabilities = 0.0
            for entry in entries {
                if (entry.item?.category?.group ?? .financial) == .liability {
                    liabilities += entry.resolvedAmount
                } else {
                    assets += entry.resolvedAmount
                }
            }
            guard entries.count == projection.entryCount,
                  abs(liabilities - projection.totalLiabilities) < 0.01,
                  abs(assets - liabilities - projection.netAssets) < 0.01 else {
                throw NSError(domain: "TimeMachineSQLiteArchive", code: 2)
            }
        }
    }

    private func fetchSQLiteArchive(at url: URL) async throws -> [SnapshotArchiveProjection] {
        enum ReadError: Error { case open, prepare, step, invalidID }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw ReadError.open
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        let query = """
        SELECT s.ZID, s.ZDATE, COUNT(e.Z_PK),
               COALESCE(SUM(CASE WHEN c.ZGROUPRAWVALUE = 'liability' THEN 0
                                 ELSE COALESCE(e.ZAMOUNT, e.ZQUANTITY * e.ZUNITPRICE, 0) END), 0),
               COALESCE(SUM(CASE WHEN c.ZGROUPRAWVALUE = 'liability'
                                 THEN COALESCE(e.ZAMOUNT, e.ZQUANTITY * e.ZUNITPRICE, 0) ELSE 0 END), 0)
        FROM ZASSETSNAPSHOT s
        LEFT JOIN ZASSETENTRY e ON e.ZSNAPSHOT = s.Z_PK
        LEFT JOIN ZASSETITEM i ON i.Z_PK = e.ZITEM
        LEFT JOIN ZASSETCATEGORY c ON c.Z_PK = i.ZCATEGORY
        GROUP BY s.Z_PK
        ORDER BY s.ZDATE DESC, s.ZID DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ReadError.prepare }
        defer { sqlite3_finalize(statement) }

        var projections: [SnapshotArchiveProjection] = []
        while true {
            try Task.checkCancellation()
            var batchCount = 0
            while batchCount < Self.batchSize {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return projections }
                guard result == SQLITE_ROW else { throw ReadError.step }
                guard sqlite3_column_bytes(statement, 0) == 16,
                      let idBlob = sqlite3_column_blob(statement, 0) else { throw ReadError.invalidID }
                let bytes = idBlob.assumingMemoryBound(to: UInt8.self)
                let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                                     bytes[4], bytes[5], bytes[6], bytes[7],
                                     bytes[8], bytes[9], bytes[10], bytes[11],
                                     bytes[12], bytes[13], bytes[14], bytes[15]))
                let assets = sqlite3_column_double(statement, 3)
                let liabilities = sqlite3_column_double(statement, 4)
                projections.append(SnapshotArchiveProjection(
                    id: id,
                    date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
                    entryCount: Int(sqlite3_column_int(statement, 2)),
                    totalLiabilities: liabilities,
                    netAssets: assets - liabilities
                ))
                batchCount += 1
            }
            await Task.yield()
        }
    }
    #endif
}

#if !os(macOS)
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

#endif
