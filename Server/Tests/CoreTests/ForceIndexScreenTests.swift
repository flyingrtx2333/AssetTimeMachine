import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class ForceIndexScreenTests: XCTestCase {
    typealias Screen = ForceIndexScreen
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

    func testHandThirteenFlowSeedAndFrozenRecursiveOperationOrder() throws {
        var prices = [1000.0]
        for change in 1...15 { prices.append(prices.last! + Double(change)) }
        let s = try signals(bars(prices))
        XCTAssertTrue(s.prefix(13).allSatisfy { $0.forceEMA13 == nil && $0.weight == 0 && !$0.seedReady })
        XCTAssertNil(s[0].previousClose)
        XCTAssertNil(s[0].rawForce)
        XCTAssertEqual(s[0].seedFlowCount, 0)
        XCTAssertEqual(s[12].seedFlowCount, 12)
        XCTAssertEqual(s[13].completedBarsInEpoch, 14)
        XCTAssertEqual(s[13].seedFlowCount, 13)
        XCTAssertEqual(s[13].seedSum, 91)
        XCTAssertEqual(s[13].forceEMA13, 7)
        XCTAssertEqual(s[13].emaUpdateKind, "sma13-seed")
        XCTAssertEqual(s[14].forceEMA13, 8)
        XCTAssertEqual(s[15].forceEMA13, 9)
        XCTAssertEqual(s[15].seedSum, 91) // Seed evidence remains the initial13, not a rolling window.
        XCTAssertEqual(s[15].seedEndDate, s[13].date)
        XCTAssertEqual(s[15].seedStartDate, s[1].date)
        XCTAssertTrue(s.dropFirst(13).allSatisfy(\.seedReady))
        for i in 14..<s.count {
            let alpha = 2.0 / 14.0, beta = 1.0 - alpha
            XCTAssertEqual(s[i].forceEMA13, alpha * s[i].rawForce! + beta * s[i - 1].forceEMA13!)
            XCTAssertEqual(s[i].previousEMA, s[i - 1].forceEMA13)
            XCTAssertEqual(s[i].emaUpdateKind, "ema13-recursion")
        }
    }

    func testStrictZeroAxisAndTinyPositiveForceHaveNoDeadZoneOrLatch() throws {
        let flat = try signals(bars(Array(repeating: 10, count: 14)))
        XCTAssertEqual(flat[13].forceEMA13, 0)
        XCTAssertEqual(flat[13].weight, 0)
        let up = try signals(bars(Array(repeating: 1, count: 13) + [Double(1).nextUp]))
        XCTAssertGreaterThan(up[13].forceEMA13!, 0)
        XCTAssertEqual(up[13].weight, 1)
        let down = try signals(bars(Array(repeating: Double(1).nextUp, count: 13) + [1]))
        XCTAssertLessThan(down[13].forceEMA13!, 0)
        XCTAssertEqual(down[13].weight, 0)
        let reversal = try signals(bars((0..<14).map { Double(100 + $0) } + [13]))
        XCTAssertEqual(reversal[13].forceEMA13, 1)
        XCTAssertEqual(reversal[13].weight, 1)
        XCTAssertEqual(reversal[14].forceEMA13!, -94.0 / 7, accuracy: 1e-12)
        XCTAssertEqual(reversal[14].weight, 0)
        XCTAssertEqual(reversal[14].stateReason, "nonpositive-force-cash")
    }

    func testRawForceUsesCurrentActualVolumeAndCloseDisplacement() throws {
        let s = try signals(bars([10, 12, 9, 9], volumes: [100, 3, 4, 999]))
        XCTAssertEqual(s[1].previousClose, 10)
        XCTAssertEqual(s[1].closeChange, 2)
        XCTAssertEqual(s[1].rawForce, 6)
        XCTAssertEqual(s[2].closeChange, -3)
        XCTAssertEqual(s[2].rawForce, -12)
        XCTAssertEqual(s[3].rawForce, 0)
        XCTAssertEqual(s[3].seedSum, -6)
        let zeroVolume = try signals(bars((0..<14).map { Double(100 + $0) }, volumes: Array(repeating: 0, count: 14)))
        XCTAssertEqual(zeroVolume[13].forceEMA13, 0)
        XCTAssertEqual(zeroVolume[13].weight, 0)
    }

    func testEffectiveSplitClearsCloseSeedEMAAndPositionBeforeProcessing() throws {
        let original = bars((0..<50).map { Double(100 + $0) }), split = original[25].date
        let b = original.map { x in
            let f = x.date < split ? 1.0 : 0.5
            return Bar(date: x.date, open: x.open * f, high: x.high * f, low: x.low * f, close: x.close * f, volume: x.volume)
        }
        let s = try signals(b, splits: [split: 2])
        XCTAssertEqual(s[24].weight, 1)
        XCTAssertEqual(s[25].previousWeight, 1)
        XCTAssertTrue(s[25].splitReset)
        XCTAssertEqual(s[25].appliedSplitDates, [split])
        XCTAssertNil(s[25].previousClose)
        XCTAssertNil(s[25].previousEMA)
        XCTAssertNil(s[25].rawForce)
        XCTAssertEqual(s[25].seedFlowCount, 0)
        XCTAssertTrue(s[25..<38].allSatisfy { $0.forceEMA13 == nil && $0.weight == 0 && $0.stateSourceDate == nil })
        XCTAssertEqual(s[38].seedFlowCount, 13)
        XCTAssertEqual(s[38].forceEMA13, 0.5)
        XCTAssertEqual(s[38].weight, 1)
        XCTAssertEqual(Screen.latestSignal(s, before: split)?.weight, 1)
        XCTAssertEqual(Screen.latestSignal(s, before: b[26].date)?.weight, 0)
    }

    func testPrefixFutureQuoteVolumeShockAndFutureSplitsCannotChangePastSignals() throws {
        let b = bars((0..<90).map { 100 + 20 * sin(Double($0) / 5) })
        let original = try signals(b)
        let prefix = try signals(Array(b.prefix(55)), splits: [b[70].date: 2])
        let changed = b.enumerated().map { i, x in
            i < 55 ? x : Bar(date: x.date, open: x.open * 100, high: x.high * 100, low: x.low * 100, close: x.close * 100, volume: 9999)
        }
        let future = try signals(changed, splits: [b[70].date: 2])
        XCTAssertEqual(Array(original.prefix(55)), prefix)
        XCTAssertEqual(Array(original.prefix(55)), Array(future.prefix(55)))
        XCTAssertNil(Screen.latestSignal(original, before: b[0].date))
        XCTAssertEqual(Screen.latestSignal(original, before: b[55].date), original[54])
    }

    func testActualBinaryEpochPriceAndVolumeConventionsScaleForceExactly() throws {
        let b = bars((0..<90).map { 100 + 20 * sin(Double($0) / 5) }, volumes: (0..<90).map { Double(100 + $0) })
        let split = b[40].date, raw = try signals(b, splits: [split: 2])
        for (priceFactor, volumeFactor) in [(0.5, 1.0), (1.0, 2.0), (1.0, 0.5), (0.5, 2.0)] {
            let adjusted = try signals(b.map { x in
                let p = x.date < split ? priceFactor : 1, v = x.date < split ? volumeFactor : 1
                return Bar(date: x.date, open: x.open * p, high: x.high * p, low: x.low * p, close: x.close * p, volume: x.volume * v)
            }, splits: [split: 2])
            XCTAssertEqual(raw.map(\.weight), adjusted.map(\.weight))
            for (a, z) in zip(raw, adjusted) {
                let scale = a.date < split ? priceFactor * volumeFactor : 1
                if let x = a.rawForce { XCTAssertEqual(x * scale, z.rawForce) } else { XCTAssertNil(z.rawForce) }
                if let e = a.forceEMA13 { XCTAssertEqual(e * scale, z.forceEMA13) } else { XCTAssertNil(z.forceEMA13) }
            }
        }
    }

    func testPreFundingOnlyWarmsIndicatorAndFirstEligibleSignalUsesCurrentAxis() throws {
        let b = bars((0..<40).map { Double(100 + $0) }, start: day("1999-12-15"))
        let s = try signals(b, eligible: day("2000-01-13"))
        XCTAssertTrue(s.filter { $0.date < day("2000-01-13") }.allSatisfy { $0.weight == 0 && !$0.fundingEligible && $0.stateSourceDate == nil })
        let eligible = s.first { $0.date == day("2000-01-13") }!
        XCTAssertEqual(eligible.previousWeight, 0)
        XCTAssertEqual(eligible.weight, 1)
        XCTAssertEqual(eligible.stateSourceDate, day("2000-01-13"))
        var changed = b
        let index = changed.firstIndex { $0.date == day("2000-01-13") }!
        let c = changed[index - 1].close - 100
        changed[index] = Bar(date: changed[index].date, open: c, high: c, low: c, close: c, volume: 1)
        let opposite = try signals(changed, eligible: day("2000-01-13"))
        XCTAssertGreaterThan(opposite[index - 1].forceEMA13!, 0)
        XCTAssertLessThan(opposite[index].forceEMA13!, 0)
        XCTAssertEqual(opposite[index].weight, 0)
    }

    func testNativeBaselineNextOpenPriorFXSplitAccountingAndFeeDelivery() throws {
        let original = bars((0..<46).map { Double(100 + $0) }, start: day("1999-12-25")), splitDay = day("2000-01-19")
        let b = original.map { x in
            let f = x.date < splitDay ? 1.0 : 0.5
            return Bar(date: x.date, open: x.open * f, high: x.high * f, low: x.low * f, close: x.close * f, volume: x.volume)
        }
        let s = try signals(b, splits: [splitDay: 2], eligible: day("2000-01-13")), p = try native(b)
        let split = BacktestShareSplit(id: "fixture:split", symbol: "QQQ", effectiveDate: splitDay, newUnitsPerOldUnit: 2)
        let run = try Screen.runAccount(preparation: p, signals: s, shareSplits: [split], role: .candidate)
        XCTAssertEqual(p.frame.pricesBySymbol["QQQ"]![0], 0)
        XCTAssertEqual(p.opens[0], 0)
        XCTAssertFalse(p.frame.observedBySymbol["QQQ"]![0])
        XCTAssertNil(p.quotes[0].fxDate)
        XCTAssertEqual(p.quotes[1].fxDate, day("2000-01-13"))
        XCTAssertEqual(run.simulation.dailyStates[0].cash, 100000)
        XCTAssertTrue(run.simulation.dailyStates[0].targetWeights.isEmpty)
        XCTAssertFalse(run.decisions[0].shouldRebalance)
        XCTAssertNil(run.decisions[0].submitted)
        XCTAssertEqual(run.simulation.trades[0].date, day("2000-01-14"))
        XCTAssertEqual(run.simulation.trades[0].price, p.opens[1])
        XCTAssertEqual(run.simulation.trades[0].units * p.opens[1], run.simulation.trades[0].cashAmount * 0.99975, accuracy: 1e-8)
        let effective = run.decisions.first { $0.date == splitDay }!
        XCTAssertEqual(effective.latestUSDBarDate, day("2000-01-18"))
        XCTAssertEqual(effective.desired, 1)
        XCTAssertFalse(effective.shouldRebalance)
        XCTAssertEqual(run.simulation.splitAdjustments.count, 1)
        let adjustment = run.simulation.splitAdjustments[0]
        XCTAssertEqual(adjustment.resultingUnits, adjustment.previousUnits * 2)
        XCTAssertEqual(run.simulation.trades[1].date, day("2000-01-20"))
        XCTAssertEqual(run.simulation.trades[1].cashAmount,
            run.simulation.trades[1].units * run.simulation.trades[1].price * 0.99975, accuracy: 1e-8)
        XCTAssertEqual(run.simulation.trades[2].date, day("2000-02-02"))
        XCTAssertEqual(run.decisions.filter(\.shouldRebalance).count, 3)
        XCTAssertEqual(run.targetMismatchCount, 0)
        XCTAssertTrue(run.simulation.dailyStates.allSatisfy { $0.cash >= -1e-8 && $0.targetWeights.values.reduce(0, +) <= 1 })
        XCTAssertThrowsError(try ChaikinMoneyFlowScreen.priorFX(dates: ["2000-01-13"], prices: [0.125], asOf: day("2000-01-13")))
        XCTAssertThrowsError(try ChaikinMoneyFlowScreen.priorFX(dates: ["2000-01-13"], prices: [0.125], asOf: day("2000-01-28")))
    }

    func testInheritedControlsPreserveWholeNativeRowsAndFullCashYieldSummary() throws {
        let b = bars((0..<40).map { Double(100 + $0) }, start: day("1999-12-15"))
        let s = try signals(b, eligible: day("2000-01-13")), p = try native(b)
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
    }

    func testIncompleteOrUnorderedInputsAndInvalidSplitsFailClosed() throws {
        XCTAssertThrowsError(try signals([]))
        let b = bars([10, 11])
        XCTAssertThrowsError(try signals([b[1], b[0]])); XCTAssertThrowsError(try signals([b[0], b[0]]))
        XCTAssertThrowsError(try signals(bars([10], volumes: [-1])))
        XCTAssertThrowsError(try signals(bars([10], volumes: [.nan])))
        XCTAssertThrowsError(try signals(bars([0])))
        XCTAssertThrowsError(try signals(b, splits: [b[1].date: 0]))
        XCTAssertEqual(Screen.savedControlIDs, ChaikinMoneyFlowScreen.savedControlIDs)
    }
}
