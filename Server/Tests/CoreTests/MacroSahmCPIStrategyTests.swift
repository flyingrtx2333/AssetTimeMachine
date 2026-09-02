import XCTest
@testable import AssetTimeMachineBacktestCore

final class MacroSahmCPIStrategyTests: XCTestCase {
    private var shanghaiCalendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    private func date(_ value: String, hour: Int = 0) throws -> Date {
        let parts = value.split(separator: "-").compactMap { Int(String($0)) }
        return try XCTUnwrap(shanghaiCalendar.date(from: DateComponents(
            timeZone: shanghaiCalendar.timeZone,
            year: parts[0], month: parts[1], day: parts[2], hour: hour
        )))
    }

    private func month(_ start: String, offset: Int) throws -> String {
        let base = try date(start + "-01")
        let shifted = try XCTUnwrap(shanghaiCalendar.date(byAdding: .month, value: offset, to: base))
        let components = shanghaiCalendar.dateComponents([.year, .month], from: shifted)
        return String(format: "%04d-%02d", components.year!, components.month!)
    }

    private func rows(
        count: Int,
        start: String = "2020-01",
        unemployment: (Int) -> Double = { _ in 4.0 },
        cpi: (Int) -> Double = { 100 + Double($0) * 0.1 },
        releaseOrderCPIFirst: Bool = false,
        missingOffsets: Set<Int> = []
    ) throws -> MacroInitialReleaseDataset {
        var unrate: [MacroInitialReleaseRow] = []
        var cpiRows: [MacroInitialReleaseRow] = []
        for offset in 0..<count where !missingOffsets.contains(offset) {
            let reference = try month(start, offset: offset)
            let monthDate = try date(reference + "-01")
            let unrateRelease = try XCTUnwrap(shanghaiCalendar.date(byAdding: .day, value: releaseOrderCPIFirst ? 12 : 5, to: monthDate))
            let cpiRelease = try XCTUnwrap(shanghaiCalendar.date(byAdding: .day, value: releaseOrderCPIFirst ? 5 : 12, to: monthDate))
            unrate.append(MacroInitialReleaseRow(
                seriesID: "UNRATE", referenceMonth: reference, releaseDate: unrateRelease,
                initialValue: unemployment(offset), snapshotSHA256: String(repeating: "a", count: 64)
            ))
            cpiRows.append(MacroInitialReleaseRow(
                seriesID: "CPIAUCSL", referenceMonth: reference, releaseDate: cpiRelease,
                initialValue: cpi(offset), snapshotSHA256: String(repeating: "b", count: 64)
            ))
        }
        return try MacroInitialReleaseDataset(unrateRows: unrate, cpiRows: cpiRows)
    }

    private func frame(
        start: String,
        days: Int,
        closed: Set<Int> = [],
        badFX: Set<Int> = []
    ) throws -> MarketDataFrame {
        let first = try date(start)
        let dates = try (0..<days).map { try XCTUnwrap(shanghaiCalendar.date(byAdding: .day, value: $0, to: first)) }
        let symbols = ["gold_cny", "nasdaq", "usd_per_cny"]
        var observed: [String: [Bool]] = [:]
        for symbol in symbols {
            observed[symbol] = (0..<days).map { !closed.contains($0) }
        }
        var fx = Array(repeating: 7.0, count: days)
        for index in badFX { fx[index] = .nan }
        func option(_ symbol: String) -> BacktestAssetOption {
            BacktestAssetOption(symbol: symbol, title: symbol, color: .blue, requiresHistoricalFX: false, historicalFXSymbol: nil)
        }
        return MarketDataFrame(
            dates: dates,
            pricesBySymbol: [
                "gold_cny": Array(repeating: 100, count: days),
                "nasdaq": Array(repeating: 100, count: days),
                "usd_per_cny": fx
            ],
            observedBySymbol: observed,
            ohlcBySymbol: [:],
            tradableSymbols: ["gold_cny", "nasdaq"],
            optionBySymbol: ["gold_cny": option("gold_cny"), "nasdaq": option("nasdaq")],
            simulationRange: 1...(days - 1)
        )
    }

    func testThresholdEqualitySahm050IsCashAndCPI200IsGold() throws {
        let sahmRows = try rows(count: 15, unemployment: { $0 < 12 ? 4.0 : 4.5 }, cpi: { 100 + Double($0) })
        let recession = MacroSahmCPIStrategy.classify(referenceMonth: "2021-03", dataset: sahmRows, variant: .candidate)
        XCTAssertEqual(recession?.targetWeights, MacroSahmCPIStrategy.cashTarget)
        XCTAssertEqual(recession?.reason, "sahm_ge_0_50_cash")

        let inflationRows = try rows(count: 15, unemployment: { _ in 4.0 }, cpi: { $0 == 14 ? 102 : 100 })
        let inflation = MacroSahmCPIStrategy.classify(referenceMonth: "2021-03", dataset: inflationRows, variant: .candidate)
        XCTAssertEqual(inflation?.targetWeights, [MacroSahmCPIStrategy.goldSymbol: 1])
        XCTAssertEqual(inflation?.reason, "non_recession_cpi_ge_2_gold")
    }

    func testWarmupRequires15UNRATERowsAnd13CPIRows() throws {
        let fourteen = try rows(count: 14)
        XCTAssertNil(MacroSahmCPIStrategy.classify(referenceMonth: "2021-01", dataset: fourteen, variant: .candidate))
        let fifteen = try rows(count: 15)
        XCTAssertNotNil(MacroSahmCPIStrategy.classify(referenceMonth: "2021-03", dataset: fifteen, variant: .candidate))
    }

    func testAvailableAtAndStrictShanghaiBoundaryUseLaterReleaseOnly() throws {
        let dataset = try rows(count: 15, releaseOrderCPIFirst: true)
        let market = try frame(start: "2021-03-13", days: 4)
        let schedule = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(frame: market, dataset: dataset))
        XCTAssertEqual(schedule.events.first?.signalDate, try date("2021-03-15"))
        XCTAssertEqual(schedule.events.first?.referenceMonth, "2021-03")
    }

    func testCommonRealObservationAndForwardFillDoNotAdvanceReview() throws {
        let dataset = try rows(count: 15)
        let market = try frame(start: "2021-03-13", days: 5, closed: [2], badFX: [3])
        let schedule = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(frame: market, dataset: dataset))
        XCTAssertEqual(schedule.events.first?.signalIndex, 4)
    }

    func testLookupIsImmutableAndEventContainsAuditFields() throws {
        let schedule = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(
            frame: frame(start: "2021-03-13", days: 5), dataset: rows(count: 15)
        ))
        let event = try XCTUnwrap(schedule.events.first)
        XCTAssertEqual(schedule.event(signalIndex: event.signalIndex), event)
        XCTAssertNil(schedule.event(signalIndex: event.signalIndex + 1))
        XCTAssertEqual(event.referenceMonth, "2021-03")
        XCTAssertEqual(Set(event.macroRowHashes.keys), ["UNRATE", "CPIAUCSL"])
        XCTAssertEqual(schedule.fingerprint, schedule.fingerprint)
    }

    func testSameTargetSuppressionAndPlaceboOnlySwapsNonRecessionMapping() throws {
        let dataset = try rows(count: 17, cpi: { _ in 100 })
        let market = try frame(start: "2021-03-13", days: 70)
        let candidate = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(frame: market, dataset: dataset))
        XCTAssertEqual(candidate.events.filter { $0.targetWeights == ["nasdaq": 1] }.count, 1)
        let placebo = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(frame: market, dataset: dataset, variant: .swapPlacebo))
        XCTAssertEqual(placebo.events.first?.targetWeights, ["gold_cny": 1])
    }

    func testNatural5050ControlEstablishesAtFirstWarmClassificationEvenDuringRecession() throws {
        let dataset = try rows(
            count: 15,
            unemployment: { $0 < 12 ? 4.0 : 4.5 },
            cpi: { _ in 100 }
        )
        let schedule = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(
            frame: frame(start: "2021-03-13", days: 10),
            dataset: dataset,
            variant: .naturallyDrifting5050Control
        ))
        XCTAssertEqual(schedule.events.count, 1)
        XCTAssertEqual(schedule.events.first?.targetWeights, ["gold_cny": 0.5, "nasdaq": 0.5])
        XCTAssertEqual(schedule.events.first?.reason, "first_warm_control_50_50_no_rebalance")
    }

    func testMultipleBackloggedPairsOnOneMarketDayEmitOnlyFinalNetTarget() throws {
        let dataset = try rows(
            count: 16,
            unemployment: { $0 == 15 ? 5.5 : 4.0 },
            cpi: { $0 == 14 ? 102 : 100 }
        )
        let schedule = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(
            frame: frame(start: "2021-05-01", days: 5),
            dataset: dataset
        ))
        XCTAssertTrue(schedule.events.isEmpty)
    }

    func testMissingMonthForcesCashAndRequiresFreshContinuousWarmupAfterGap() throws {
        let dataset = try rows(count: 31, missingOffsets: [15])
        XCTAssertNil(MacroSahmCPIStrategy.classify(referenceMonth: try month("2020-01", offset: 16), dataset: dataset, variant: .candidate))
        XCTAssertNil(MacroSahmCPIStrategy.classify(referenceMonth: try month("2020-01", offset: 29), dataset: dataset, variant: .candidate))
        XCTAssertNotNil(MacroSahmCPIStrategy.classify(referenceMonth: try month("2020-01", offset: 30), dataset: dataset, variant: .candidate))
    }

    func testFreshnessExpiresAfter62DaysAndRestoresOnlyOnValidPair() throws {
        let base = try rows(count: 16, cpi: { _ in 100 })
        let delayedMonth = "2021-04"
        let delayedRelease = try date("2021-06-05")
        let unrate = base.unrateByMonth.values.map { row in
            row.referenceMonth == delayedMonth
                ? MacroInitialReleaseRow(seriesID: row.seriesID, referenceMonth: row.referenceMonth,
                    releaseDate: delayedRelease, initialValue: row.initialValue, snapshotSHA256: row.snapshotSHA256)
                : row
        }
        let cpi = base.cpiByMonth.values.map { row in
            row.referenceMonth == delayedMonth
                ? MacroInitialReleaseRow(seriesID: row.seriesID, referenceMonth: row.referenceMonth,
                    releaseDate: delayedRelease, initialValue: row.initialValue, snapshotSHA256: row.snapshotSHA256)
                : row
        }
        let dataset = try MacroInitialReleaseDataset(unrateRows: unrate, cpiRows: cpi)
        let market = try frame(start: "2021-03-13", days: 100)
        let schedule = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(frame: market, dataset: dataset))
        let cash = try XCTUnwrap(schedule.events.first { $0.reason == "complete_pair_stale_gt_62_days_cash" })
        XCTAssertEqual(cash.targetWeights, MacroSahmCPIStrategy.cashTarget)
        XCTAssertTrue(schedule.events.contains { $0.referenceMonth == "2021-04" && $0.signalIndex > cash.signalIndex })
    }

    func testPrefixAppendCallbackAndCostCannotChangeSchedule() throws {
        let dataset = try rows(count: 18, cpi: { $0 % 2 == 0 ? 100 : 103 })
        let fullFrame = try frame(start: "2021-03-13", days: 100)
        let prefixFrame = try frame(start: "2021-03-13", days: 50)
        let full = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(frame: fullFrame, dataset: dataset))
        let prefix = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(frame: prefixFrame, dataset: dataset))
        XCTAssertEqual(full.events.filter { $0.signalIndex < 50 }, prefix.events)
        let fingerprint = full.fingerprint
        for _ in 0..<20 { _ = full.event(signalIndex: 20) }
        XCTAssertEqual(full.fingerprint, fingerprint)
        XCTAssertEqual(MacroSahmCPIStrategy.makeSchedule(frame: fullFrame, dataset: dataset, feeRateIgnored: 0.01)?.fingerprint, fingerprint)
    }

    func testCandidateAndControlsShareTheSameMacroReviewClock() throws {
        let dataset = try rows(count: 18, cpi: { $0 % 2 == 0 ? 100 : 103 })
        let market = try frame(start: "2021-03-13", days: 100)
        let candidate = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(frame: market, dataset: dataset))
        let control = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(
            frame: market, dataset: dataset, variant: .naturallyDrifting5050Control
        ))
        let placebo = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(
            frame: market, dataset: dataset, variant: .swapPlacebo
        ))
        XCTAssertNotNil(candidate.reviewClockFingerprint)
        XCTAssertEqual(candidate.reviewClockFingerprint, control.reviewClockFingerprint)
        XCTAssertEqual(candidate.reviewClockFingerprint, placebo.reviewClockFingerprint)
    }

    func testDuplicateConflictAndNonFiniteRowsMakeAffectedReviewCash() throws {
        let valid = MacroInitialReleaseRow(
            seriesID: "UNRATE", referenceMonth: "2020-01", releaseDate: try date("2020-02-07"),
            initialValue: 4, snapshotSHA256: String(repeating: "a", count: 64)
        )
        let conflict = MacroInitialReleaseRow(
            seriesID: "UNRATE", referenceMonth: "2020-01", releaseDate: try date("2020-02-07"),
            initialValue: 5, snapshotSHA256: String(repeating: "b", count: 64)
        )
        let conflictDataset = try MacroInitialReleaseDataset(unrateRows: [valid, conflict], cpiRows: [])
        XCTAssertTrue(conflictDataset.invalidUNRATEMonths.contains("2020-01"))
        let nonFinite = MacroInitialReleaseRow(
            seriesID: "UNRATE", referenceMonth: "2020-02", releaseDate: try date("2020-03-06"),
            initialValue: .nan, snapshotSHA256: String(repeating: "a", count: 64)
        )
        let nonFiniteDataset = try MacroInitialReleaseDataset(unrateRows: [nonFinite], cpiRows: [])
        XCTAssertTrue(nonFiniteDataset.invalidUNRATEMonths.contains("2020-02"))

        let base = try rows(count: 15)
        let affectedMonth = "2021-03"
        let affected = try MacroInitialReleaseDataset(
            unrateRows: Array(base.unrateByMonth.values) + [MacroInitialReleaseRow(
                seriesID: "UNRATE", referenceMonth: affectedMonth, releaseDate: try date("2021-04-20"),
                initialValue: 9, snapshotSHA256: String(repeating: "c", count: 64)
            )],
            cpiRows: Array(base.cpiByMonth.values)
        )
        let schedule = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(
            frame: frame(start: "2021-04-22", days: 5), dataset: affected
        ))
        XCTAssertTrue(schedule.events.isEmpty)
    }

    func testFrozenLoaderConsumesCommittedCSVAndPreservesKnownGap() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dataURL = root.appendingPathComponent("tools/research-results/macro-vintages/alfred-initial-release")
        let dataset = try MacroInitialReleaseCSVLoader.load(directory: dataURL)
        XCTAssertEqual(dataset.unrateByMonth.keys.min(), "1999-12")
        XCTAssertEqual(dataset.cpiByMonth.keys.max(), "2026-07")
        XCTAssertNil(dataset.unrateByMonth["2025-10"])
        XCTAssertNil(dataset.cpiByMonth["2025-10"])
    }

    func testTargetsAreLongOnlyUnlevered() throws {
        let schedule = try XCTUnwrap(MacroSahmCPIStrategy.makeSchedule(
            frame: frame(start: "2021-03-13", days: 100), dataset: rows(count: 18)
        ))
        for event in schedule.events {
            XCTAssertTrue(event.targetWeights.values.allSatisfy { $0.isFinite && $0 >= 0 })
            XCTAssertLessThanOrEqual(event.targetWeights.values.reduce(0, +), 1.0)
        }
    }
}
