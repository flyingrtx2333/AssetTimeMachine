import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class NegativeVolumeIndexScreenTests: XCTestCase {
    typealias Screen = NegativeVolumeIndexScreen
    typealias Bar = Screen.Bar
    private func day(_ text: String) -> Date { BacktestSeriesAlignment.historicalSeriesDate(from: text)! }
    private func bars(_ prices: [Double], volumes: [Double]? = nil, start: Date = Date(timeIntervalSince1970: 0)) -> [Bar] {
        prices.enumerated().map { i, p in
            .init(date: start.addingTimeInterval(Double(i) * 86400), open: p, high: p, low: p, close: p, volume: volumes?[i] ?? 1)
        }
    }
    private func signals(_ b: [Bar], splits: [Date: Double] = [:], eligible: Date = Date(timeIntervalSince1970: 0)) throws -> [Screen.Signal] {
        try Screen.signals(bars: b, splits: splits, stateEligibleFrom: eligible)
    }
    private func native(_ b: [Bar]) throws -> Screen.NativePreparation {
        let fxDates = b.filter { $0.date >= day("2000-01-13") }.map { BacktestSeriesAlignment.historicalSeriesDateString(from: $0.date) }
        return try ChaikinMoneyFlowScreen.nativePreparation(bars: b, fxDates: fxDates,
            fxPrices: Array(repeating: 0.125, count: fxDates.count), baseline: day("2000-01-13"))
    }
    private func ascending(_ count: Int, start: Date = Date(timeIntervalSince1970: 0)) -> [Bar] {
        bars((0..<count).map { 100 + Double($0) / 10 }, volumes: (0..<count).map { 1000 - Double($0) }, start: start)
    }

    func testHandAdditivePercentagePointsAndActualStrictVolumeCondition() throws {
        let s = try signals(bars([100, 110, 121, 100, 125], volumes: [100, 90, 90, 91, 80]))
        XCTAssertEqual(s.map(\.nvi), [1000, 1010, 1010, 1010, 1035])
        XCTAssertNil(s[0].previousNVI); XCTAssertNil(s[0].previousClose); XCTAssertNil(s[0].previousVolume)
        XCTAssertNil(s[0].volumeDeclined); XCTAssertNil(s[0].percentagePriceChange)
        XCTAssertEqual(s[0].nviUpdateKind, "initial-nvi1000")
        XCTAssertEqual(s[1].percentagePriceChange, 10); XCTAssertEqual(s[1].volumeDeclined, true)
        XCTAssertEqual(s[2].previousClose, 110); XCTAssertEqual(s[2].volumeDeclined, false)
        XCTAssertNil(s[2].percentagePriceChange)
        XCTAssertEqual(s[3].previousClose, 121); XCTAssertEqual(s[3].volumeDeclined, false)
        XCTAssertEqual(s[4].previousClose, 100); XCTAssertEqual(s[4].percentagePriceChange, 25)
        // The author's additive example cannot silently become multiplicative NVI.
        XCTAssertNotEqual(s[1].nvi, 1100); XCTAssertNotEqual(s[4].nvi, s[3].nvi * 1.25)
        let zero = try signals(bars([10, 20, 30], volumes: [0, 0, 0]))
        XCTAssertEqual(zero.map(\.nvi), [1000, 1000, 1000])
    }

    func testHand255ObservationSeedIncludesInitial1000AndExactEMAOrder() throws {
        let s = try signals(bars((0..<257).map { pow(2, Double($0)) }, volumes: (0..<257).map { 1000 - Double($0) }))
        XCTAssertTrue(s.prefix(254).allSatisfy { $0.nviEMA255 == nil && $0.weight == 0 && !$0.seedReady })
        XCTAssertEqual(s[0].seedObservationCount, 1); XCTAssertEqual(s[0].seedSum, 1000)
        XCTAssertEqual(s[253].seedObservationCount, 254)
        XCTAssertEqual(s[254].observationCount, 255); XCTAssertEqual(s[254].seedObservationCount, 255)
        XCTAssertEqual(s[254].nvi, 26400); XCTAssertEqual(s[254].seedSum, 3493500)
        XCTAssertEqual(s[254].nviEMA255, 13700); XCTAssertEqual(s[254].emaUpdateKind, "sma255-seed")
        XCTAssertEqual(s[255].nviEMA255, 13800); XCTAssertEqual(s[256].nviEMA255, 13900)
        XCTAssertEqual(s[256].seedSum, 3493500); XCTAssertEqual(s[256].seedEndDate, s[254].date)
        XCTAssertEqual(s[256].seedStartDate, s[0].date)
        for i in 255..<s.count {
            let alpha = 2.0 / 256.0, beta = 1.0 - alpha
            XCTAssertEqual(s[i].nviEMA255, alpha * s[i].nvi + beta * s[i - 1].nviEMA255!)
            XCTAssertEqual(s[i].previousEMA, s[i - 1].nviEMA255)
            XCTAssertEqual(s[i].emaUpdateKind, "ema255-recursion")
        }
    }

    func testStrictIndexEMAEqualityCashAndReversalWithoutLatch() throws {
        let prices = Array(repeating: 100.0, count: 255) + [110, 99]
        let s = try signals(bars(prices, volumes: (0..<257).map { 1000 - Double($0) }))
        XCTAssertEqual(s[254].nvi, 1000); XCTAssertEqual(s[254].nviEMA255, 1000); XCTAssertEqual(s[254].weight, 0)
        XCTAssertEqual(s[255].nvi, 1010); XCTAssertEqual(s[255].nviEMA255, 1000.078125); XCTAssertEqual(s[255].weight, 1)
        XCTAssertEqual(s[256].nvi, 1000); XCTAssertGreaterThan(s[256].nviEMA255!, 1000); XCTAssertEqual(s[256].weight, 0)
        XCTAssertEqual(s[256].stateReason, "nvi-at-or-below-ema-cash")
    }

    func testEffectiveSplitBeforeSeedSkipsOneComparisonAndKeepsSeedHistory() throws {
        let original = ascending(280), split = original[100].date
        let b = original.map { x in
            let f = x.date < split ? 1.0 : 0.5
            return Bar(date: x.date, open: x.open * f, high: x.high * f, low: x.low * f, close: x.close * f, volume: x.volume)
        }
        let s = try signals(b, splits: [split: 2])
        XCTAssertEqual(s[100].nvi, s[99].nvi); XCTAssertEqual(s[100].previousNVI, s[99].nvi)
        XCTAssertNil(s[100].previousClose); XCTAssertNil(s[100].previousVolume); XCTAssertNil(s[100].percentagePriceChange)
        XCTAssertTrue(s[100].splitBoundarySkipped); XCTAssertEqual(s[100].appliedSplitDates, [split])
        XCTAssertEqual(s[100].seedObservationCount, 101); XCTAssertEqual(s[100].observationCount, 101)
        XCTAssertEqual(s[100].seedStartDate, s[0].date)
        XCTAssertEqual(s[101].previousClose, b[100].close); XCTAssertEqual(s[101].previousVolume, b[100].volume)
        XCTAssertFalse(s[101].splitBoundarySkipped); XCTAssertEqual(s[101].volumeDeclined, true)
        XCTAssertTrue(s.prefix(254).allSatisfy { $0.nviEMA255 == nil })
        XCTAssertEqual(s[254].seedObservationCount, 255); XCTAssertNotNil(s[254].nviEMA255)
    }

    func testMatureEffectiveSplitRetainsIndexEMAAndLongStateWithoutCashVeto() throws {
        let original = ascending(320), split = original[280].date
        let b = original.map { x in
            let f = x.date < split ? 1.0 : 0.5
            return Bar(date: x.date, open: x.open * f, high: x.high * f, low: x.low * f, close: x.close * f, volume: x.volume)
        }
        let s = try signals(b, splits: [split: 2]), alpha = 2.0 / 256.0
        XCTAssertEqual(s[279].weight, 1); XCTAssertEqual(s[280].previousWeight, 1); XCTAssertEqual(s[280].weight, 1)
        XCTAssertEqual(s[280].nvi, s[279].nvi); XCTAssertEqual(s[280].previousEMA, s[279].nviEMA255)
        XCTAssertEqual(s[280].nviEMA255, alpha * s[279].nvi + (1 - alpha) * s[279].nviEMA255!)
        XCTAssertEqual(s[280].emaUpdateKind, "ema255-recursion")
        XCTAssertEqual(s[280].seedObservationCount, 255); XCTAssertEqual(s[280].seedSum, s[279].seedSum)
        XCTAssertEqual(s[280].seedStartDate, s[0].date); XCTAssertEqual(s[280].seedEndDate, s[254].date)
        XCTAssertEqual(Screen.latestSignal(s, before: split), s[279])
        XCTAssertEqual(s[281].previousClose, b[280].close); XCTAssertEqual(s[281].epoch, 1)
    }

    func testPrefixFuturePriceVolumeShockAndFutureSplitCannotChangePastSignals() throws {
        let b = ascending(400), original = try signals(b)
        let prefix = try signals(Array(b.prefix(300)), splits: [b[350].date: 2])
        let changed = b.enumerated().map { i, x in
            i < 300 ? x : Bar(date: x.date, open: x.open * 100, high: x.high * 100, low: x.low * 100, close: x.close * 100, volume: 9999)
        }
        let future = try signals(changed, splits: [b[350].date: 2])
        XCTAssertEqual(Array(original.prefix(300)), prefix)
        XCTAssertEqual(Array(original.prefix(300)), Array(future.prefix(300)))
        XCTAssertNil(Screen.latestSignal(original, before: b[0].date))
        XCTAssertEqual(Screen.latestSignal(original, before: b[300].date), original[299])
    }

    func testActualBinaryEpochPriceAndVolumeUnitsPreserveIndexEMAExactly() throws {
        let b = ascending(400), split = b[280].date, raw = try signals(b, splits: [split: 2])
        for (priceFactor, volumeFactor) in [(0.5, 1.0), (1.0, 2.0), (1.0, 0.5), (0.5, 2.0)] {
            let adjusted = try signals(b.map { x in
                let p = x.date < split ? priceFactor : 1, v = x.date < split ? volumeFactor : 1
                return Bar(date: x.date, open: x.open * p, high: x.high * p, low: x.low * p, close: x.close * p, volume: x.volume * v)
            }, splits: [split: 2])
            XCTAssertEqual(raw.map(\.nvi), adjusted.map(\.nvi))
            XCTAssertEqual(raw.map(\.nviEMA255), adjusted.map(\.nviEMA255))
            XCTAssertEqual(raw.map(\.percentagePriceChange), adjusted.map(\.percentagePriceChange))
            XCTAssertEqual(raw.map(\.volumeDeclined), adjusted.map(\.volumeDeclined))
            XCTAssertEqual(raw.map(\.weight), adjusted.map(\.weight))
        }
    }

    func testPreFundingWarmsIndexAndEMAWhileKeepingAllPositionsCash() throws {
        let b = ascending(310, start: day("1999-04-01")), s = try signals(b, eligible: day("2000-01-13"))
        XCTAssertTrue(s.filter { $0.date < day("2000-01-13") }.allSatisfy { $0.weight == 0 && !$0.fundingEligible && $0.stateSourceDate == nil })
        let first = s.first { $0.date == day("2000-01-13") }!
        XCTAssertTrue(first.seedReady); XCTAssertEqual(first.previousWeight, 0); XCTAssertEqual(first.weight, 1)
        XCTAssertEqual(first.stateSourceDate, day("2000-01-13"))
        let allEligible = try signals(b)
        XCTAssertEqual(s.map(\.nvi), allEligible.map(\.nvi)); XCTAssertEqual(s.map(\.nviEMA255), allEligible.map(\.nviEMA255))
    }

    func testCalendarYearTransitionDoesNotResetIndexOrEMA() throws {
        let b = ascending(360, start: day("1999-04-01")), s = try signals(b)
        let i = s.firstIndex { $0.date == day("2000-01-01") }!
        XCTAssertEqual(s[i].epoch, 0); XCTAssertFalse(s[i].splitBoundarySkipped)
        XCTAssertEqual(s[i].previousNVI, s[i - 1].nvi); XCTAssertEqual(s[i].previousEMA, s[i - 1].nviEMA255)
        XCTAssertEqual(s[i].seedEndDate, s[254].date); XCTAssertEqual(s[i].seedObservationCount, 255)
        XCTAssertEqual(s[i].weight, 1)
    }

    func testNativeBaselineStrictPriorOpenFXSplitHoldingsAndBothFillFees() throws {
        let original = ascending(300, start: day("1999-05-01")), splitDay = day("2000-01-19")
        let b = original.map { x in
            let f = x.date < splitDay ? 1.0 : 0.5, p = x.date == day("2000-01-20") ? 0.1 : x.close * f
            return Bar(date: x.date, open: p, high: p, low: p, close: p, volume: x.volume)
        }
        let s = try signals(b, splits: [splitDay: 2], eligible: day("2000-01-13")), p = try native(b)
        let split = BacktestShareSplit(id: "fixture:split", symbol: "QQQ", effectiveDate: splitDay, newUnitsPerOldUnit: 2)
        let run = try Screen.runAccount(preparation: p, signals: s, shareSplits: [split], role: .candidate)
        XCTAssertEqual(p.frame.pricesBySymbol["QQQ"]![0], 0); XCTAssertEqual(p.opens[0], 0)
        XCTAssertFalse(p.frame.observedBySymbol["QQQ"]![0]); XCTAssertNil(p.quotes[0].fxDate)
        XCTAssertEqual(p.quotes[1].fxDate, day("2000-01-13"))
        XCTAssertEqual(run.simulation.dailyStates[0].cash, 100000); XCTAssertTrue(run.simulation.dailyStates[0].targetWeights.isEmpty)
        XCTAssertFalse(run.decisions[0].shouldRebalance); XCTAssertNil(run.decisions[0].submitted)
        XCTAssertEqual(run.simulation.trades[0].date, day("2000-01-14")); XCTAssertEqual(run.simulation.trades[0].price, p.opens[1])
        XCTAssertEqual(run.simulation.trades[0].units * p.opens[1], run.simulation.trades[0].cashAmount * 0.99975, accuracy: 1e-8)
        let effective = run.decisions.first { $0.date == splitDay }!
        XCTAssertEqual(effective.latestUSDBarDate, day("2000-01-18")); XCTAssertEqual(effective.desired, 1)
        XCTAssertFalse(effective.shouldRebalance)
        XCTAssertEqual(run.simulation.splitAdjustments.count, 1)
        let adjustment = run.simulation.splitAdjustments[0]
        XCTAssertEqual(adjustment.resultingUnits, adjustment.previousUnits * 2)
        let exit = run.simulation.trades.first { $0.date == day("2000-01-21") }!
        XCTAssertEqual(exit.cashAmount, exit.units * exit.price * 0.99975, accuracy: 1e-8)
        XCTAssertEqual(run.simulation.trades.count, 3); XCTAssertEqual(run.simulation.trades[2].date, day("2000-01-22"))
        XCTAssertEqual(run.targetMismatchCount, 0)
        XCTAssertTrue(run.simulation.dailyStates.allSatisfy { $0.cash >= -1e-8 && $0.targetWeights.values.reduce(0, +) <= 1 })
        XCTAssertThrowsError(try ChaikinMoneyFlowScreen.priorFX(dates: ["2000-01-13"], prices: [0.125], asOf: day("2000-01-13")))
        XCTAssertThrowsError(try ChaikinMoneyFlowScreen.priorFX(dates: ["2000-01-13"], prices: [0.125], asOf: day("2000-01-28")))
    }

    func testInheritedControlsPreserveWholeNativeRowsAndFullCashYieldSummary() throws {
        let b = ascending(300, start: day("1999-05-01")), s = try signals(b, eligible: day("2000-01-13")), p = try native(b)
        let oldSignals = try ChaikinMoneyFlowScreen.signals(bars: b, splits: [:])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let text = BacktestSeriesAlignment.historicalSeriesDateString(from:)
        let windows = [("native_full", text(p.frame.dates.first!), text(p.frame.dates.last!))]
        for (id, role) in [(Screen.buyHoldID, Screen.Role.buyHold), (Screen.cashID, .cash)] {
            let new = try Screen.runAccount(preparation: p, signals: s, shareSplits: [], role: role).simulation
            let old = try ChaikinMoneyFlowScreen.runAccount(preparation: p, signals: oldSignals, shareSplits: [], role: role).simulation
            XCTAssertEqual(try encoder.encode(DailyScreenOutput.row(id, states: new.dailyStates, trades: new.trades, windows: windows)),
                try encoder.encode(DailyScreenOutput.row(id, states: old.dailyStates, trades: old.trades, windows: windows)))
            for (a, z) in zip(new.trades, old.trades) { XCTAssertEqual(a.reason, z.reason); XCTAssertEqual(a.assetTitle, z.assetTitle) }
            let a = new.cashYieldSummary, z = old.cashYieldSummary
            XCTAssertEqual(a.title, z.title); XCTAssertEqual(a.source, z.source); XCTAssertEqual(a.sourceDetail, z.sourceDetail)
            XCTAssertEqual(a.startDate, z.startDate); XCTAssertEqual(a.endDate, z.endDate); XCTAssertEqual(a.latestRateDate, z.latestRateDate)
            XCTAssertEqual(a.latestAnnualRate, z.latestAnnualRate); XCTAssertEqual(a.averageAnnualRate, z.averageAnnualRate)
            XCTAssertEqual(a.averageCashRatio, z.averageCashRatio); XCTAssertEqual(a.totalCashInterest, z.totalCashInterest)
            XCTAssertEqual(a.ratePoints.count, z.ratePoints.count)
            for (x, y) in zip(a.ratePoints, z.ratePoints) { XCTAssertEqual(x.date, y.date); XCTAssertEqual(x.annualRate, y.annualRate) }
        }
        XCTAssertEqual(Screen.savedControlIDs, ChaikinMoneyFlowScreen.savedControlIDs); XCTAssertEqual(Screen.savedControlIDs.count, 31)
    }

    func testIncompleteUnorderedNonfiniteInputsAndInvalidSplitsFailClosed() throws {
        XCTAssertThrowsError(try signals([]))
        let b = bars([10, 11])
        XCTAssertThrowsError(try signals([b[1], b[0]])); XCTAssertThrowsError(try signals([b[0], b[0]]))
        XCTAssertThrowsError(try signals(bars([10], volumes: [-1])))
        XCTAssertThrowsError(try signals(bars([10], volumes: [.nan])))
        XCTAssertThrowsError(try signals(bars([0])))
        XCTAssertThrowsError(try signals(b, splits: [b[1].date: 0]))
        XCTAssertThrowsError(try signals(b, splits: [b[1].date: .infinity]))
        XCTAssertThrowsError(try signals(b, eligible: Date(timeIntervalSinceReferenceDate: .nan)))
        XCTAssertThrowsError(try signals(bars([Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude], volumes: [2, 1])))
    }
}
