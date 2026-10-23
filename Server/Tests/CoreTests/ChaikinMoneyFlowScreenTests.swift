import XCTest
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class ChaikinMoneyFlowScreenTests: XCTestCase {
    typealias Screen = ChaikinMoneyFlowScreen
    typealias Bar = Screen.Bar
    private func day(_ value: String) -> Date { BacktestSeriesAlignment.historicalSeriesDate(from: value)! }
    private func bars(_ rows: [[Double]], start: Date = Date(timeIntervalSince1970: 0)) -> [Bar] {
        rows.enumerated().map { i, r in
            .init(date: start.addingTimeInterval(Double(i) * 86400), open: r[0], high: r[1], low: r[2], close: r[3], volume: r[4])
        }
    }
    private func positiveBars(_ count: Int, start: Date = Date(timeIntervalSince1970: 0)) -> [Bar] {
        bars(Array(repeating: [10, 12, 8, 11, 100], count: count), start: start)
    }

    func testHandCMFVolumeWeightedWindowAndStrictZero() throws {
        // Nineteen +0.5 multiplier bars at V=10, then -1 at V=5:
        // CMF=(19*5-5)/(19*10+5)=90/195=6/13.
        let b = bars(Array(repeating: [10, 12, 8, 11, 10], count: 19) + [[10, 12, 8, 8, 5], [10, 12, 8, 10, 10]])
        let s = try Screen.signals(bars: b, splits: [:])
        XCTAssertTrue(s.prefix(19).allSatisfy { $0.cmf20 == nil && $0.weight == 0 })
        XCTAssertEqual(s[19].windowCount, 20)
        XCTAssertEqual(s[19].sumMoneyFlowVolume, 90, accuracy: 1e-12)
        XCTAssertEqual(s[19].sumVolume, 195, accuracy: 1e-12)
        XCTAssertEqual(s[19].cmf20!, 6.0 / 13, accuracy: 1e-12)
        XCTAssertEqual(s[20].sumMoneyFlowVolume, 85, accuracy: 1e-12)
        XCTAssertEqual(s[20].sumVolume, 195, accuracy: 1e-12)
        XCTAssertEqual(s[20].windowStartDate, b[1].date)
        let balanced = bars(Array(repeating: [10, 12, 8, 12, 10], count: 10)
            + Array(repeating: [10, 12, 8, 8, 10], count: 10))
        let z = try Screen.signals(bars: balanced, splits: [:])
        XCTAssertEqual(z[19].cmf20, 0)
        XCTAssertEqual(z[19].weight, 0)
        let negative = try Screen.signals(bars: bars(Array(repeating: [10, 12, 8, 8, 10], count: 20)), splits: [:])
        XCTAssertEqual(negative[19].cmf20, -1)
        XCTAssertEqual(negative[19].weight, 0)
        let flat = try Screen.signals(bars: bars(Array(repeating: [10, 10, 10, 10, 10], count: 20)), splits: [:])
        XCTAssertTrue(flat.allSatisfy { $0.moneyFlowMultiplier == 0 && $0.moneyFlowVolume == 0 && $0.weight == 0 })
        XCTAssertEqual(flat[19].cmf20, 0)
        let emptyVolume = try Screen.signals(bars: bars(Array(repeating: [10, 12, 8, 11, 0], count: 20)), splits: [:])
        XCTAssertNil(emptyVolume[19].cmf20)
        XCTAssertEqual(emptyVolume[19].weight, 0)
    }

    func testEffectiveSplitResetsBeforeBarAndRequiresNineteenCashBars() throws {
        let b = positiveBars(65), split = b[25].date
        let s = try Screen.signals(bars: b, splits: [split: 2])
        XCTAssertEqual(s[24].weight, 1)
        XCTAssertTrue(s[25].splitReset)
        XCTAssertEqual(s[25].appliedSplitDates, [split])
        XCTAssertEqual(s[25].epochStartDate, split)
        XCTAssertEqual(s[25].windowCount, 1)
        XCTAssertTrue(s[25..<44].allSatisfy { $0.cmf20 == nil && $0.weight == 0 })
        XCTAssertEqual(s[44].windowCount, 20)
        XCTAssertEqual(s[44].cmf20!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(s[44].weight, 1)
        // On the effective opening, the previous completed close still decides.
        XCTAssertEqual(Screen.latestSignal(s, before: split)?.weight, 1)
        XCTAssertEqual(Screen.latestSignal(s, before: b[26].date)?.weight, 0)
    }

    func testPrefixFutureShockAndFutureSplitDoNotChangePastSignals() throws {
        let b = (0..<70).map { i -> Bar in
            let c = 10 + 1.5 * sin(Double(i) / 3)
            return .init(date: Date(timeIntervalSince1970: Double(i) * 86400), open: 10, high: 12, low: 8, close: c, volume: Double(i + 100))
        }
        let original = try Screen.signals(bars: b, splits: [:])
        let prefix = try Screen.signals(bars: Array(b.prefix(45)), splits: [b[55].date: 2])
        let changed = b.enumerated().map { i, x in
            i < 45 ? x : Bar(date: x.date, open: 100, high: 120, low: 80, close: 120, volume: 99999)
        }
        let future = try Screen.signals(bars: changed, splits: [b[55].date: 2])
        XCTAssertEqual(Array(original.prefix(45)), prefix)
        XCTAssertEqual(Array(original.prefix(45)), Array(future.prefix(45)))
        XCTAssertNil(Screen.latestSignal(original, before: b[0].date))
        XCTAssertEqual(Screen.latestSignal(original, before: b[45].date), original[44])
    }

    func testPriceAndEpochVolumeConventionInvariance() throws {
        let b = (0..<90).map { i -> Bar in
            .init(date: Date(timeIntervalSince1970: Double(i) * 86400), open: 10, high: 12, low: 8,
                close: 10 + 1.5 * sin(Double(i) / 3), volume: Double(100 + i))
        }
        let split = b[40].date
        let raw = try Screen.signals(bars: b, splits: [split: 2])
        // Raw and split-adjusted volume differ by a positive constant per epoch.
        // OHLC historical-unit restoration also scales all fields equally per bar.
        let adjusted = try Screen.signals(bars: b.map { x in
            let priceFactor = x.date < split ? 2.0 : 1.0, volumeFactor = x.date < split ? 7.0 : 3.0
            return Bar(date: x.date, open: x.open * priceFactor, high: x.high * priceFactor,
                low: x.low * priceFactor, close: x.close * priceFactor, volume: x.volume * volumeFactor)
        }, splits: [split: 2])
        XCTAssertEqual(raw.map(\.weight), adjusted.map(\.weight))
        XCTAssertEqual(raw.map(\.windowCount), adjusted.map(\.windowCount))
        for (a, z) in zip(raw, adjusted) {
            XCTAssertEqual(a.moneyFlowMultiplier, z.moneyFlowMultiplier, accuracy: 1e-12)
            if let value = a.cmf20 { XCTAssertEqual(value, z.cmf20!, accuracy: 1e-12) }
            else { XCTAssertNil(z.cmf20) }
        }
    }

    func testNativeCashBaselineAndStrictPriorFXPreserveEveryUSDSession() throws {
        let b = positiveBars(27, start: day("2000-01-01"))
        let fxDates = ["2000-01-13", "2000-01-14", "2000-01-26"], fxPrices = [0.125, 0.25, 0.5]
        let p = try Screen.nativePreparation(bars: b, fxDates: fxDates, fxPrices: fxPrices, baseline: day("2000-01-13"))
        XCTAssertEqual(p.frame.dates, b.filter { $0.date >= day("2000-01-13") }.map(\.date))
        XCTAssertEqual(p.frame.simulationRange, 0...14)
        XCTAssertEqual(p.frame.pricesBySymbol["QQQ"]![0], 0)
        XCTAssertEqual(p.opens[0], 0)
        XCTAssertEqual(p.frame.observedBySymbol["QQQ"]![0], false)
        XCTAssertNil(p.quotes[0].fxDate)
        XCTAssertEqual(p.quotes[0].sourceUSDDate, day("2000-01-13"))
        XCTAssertEqual(p.quotes[1].fxDate, day("2000-01-13"))
        XCTAssertEqual(p.quotes[1].openCNY, 80)
        XCTAssertEqual(p.quotes[1].closeCNY, 88)
        XCTAssertEqual(p.quotes[2].fxDate, day("2000-01-14"))
        XCTAssertEqual(p.quotes[2].closeCNY, 44)
        XCTAssertEqual(p.quotes.last?.fxDate, day("2000-01-26"))
        XCTAssertEqual(try Screen.priorFX(dates: ["2000-01-13"], prices: [0.125], asOf: day("2000-01-27")).date, day("2000-01-13"))
        XCTAssertThrowsError(try Screen.priorFX(dates: ["2000-01-13"], prices: [0.125], asOf: day("2000-01-28")))
        XCTAssertThrowsError(try Screen.priorFX(dates: fxDates, prices: fxPrices, asOf: day("2000-01-13")))
        XCTAssertThrowsError(try Screen.nativePreparation(bars: b, fxDates: ["2000-01-13"], fxPrices: [0.125], baseline: day("2000-01-12")))
    }

    func testCashBaselineChangeOnlyDeliveryFeesAndNoSameDaySignal() throws {
        let b = positiveBars(26, start: day("2000-01-01"))
        let s = try Screen.signals(bars: b, splits: [:])
        let p = try Screen.nativePreparation(bars: b, fxDates: ["2000-01-13"], fxPrices: [0.125], baseline: day("2000-01-13"))
        let r = try Screen.runAccount(preparation: p, signals: s, shareSplits: [], role: .candidate)
        XCTAssertEqual(r.simulation.dailyStates.count, 14)
        XCTAssertEqual(r.simulation.dailyStates[0].cash, 100000)
        XCTAssertEqual(r.simulation.dailyStates[0].portfolioValue, 100000)
        XCTAssertTrue(r.simulation.dailyStates[0].targetWeights.isEmpty)
        XCTAssertFalse(r.decisions[0].shouldRebalance)
        XCTAssertNil(r.decisions[0].submitted)
        XCTAssertEqual(r.decisions[0].signalDate, p.frame.dates[0])
        XCTAssertTrue(r.decisions[1].shouldRebalance) // First post-baseline known target is cash.
        XCTAssertEqual(r.decisions[1].desired, 0)
        XCTAssertEqual(r.decisions[1].submitted, 0)
        XCTAssertEqual(r.decisions.filter(\.shouldRebalance).count, 2)
        let entry = r.decisions.first { $0.desired == 1 }!
        XCTAssertEqual(entry.date, day("2000-01-21"))
        XCTAssertEqual(entry.latestUSDBarDate, day("2000-01-20"))
        XCTAssertEqual(entry.accepted, 1)
        XCTAssertEqual(r.targetMismatchCount, 0)
        XCTAssertEqual(r.simulation.trades.count, 1)
        let fill = r.simulation.trades[0]
        XCTAssertEqual(fill.date, entry.date)
        XCTAssertEqual(fill.price, 80)
        let previous = r.simulation.dailyStates[entry.index - 1]
        let funding = previous.cash * (1 + CashYieldCNY.periodReturn(from: previous.date, to: entry.date))
        // Shared App accounting deducts the fill fee from its gross cash budget.
        XCTAssertEqual(fill.cashAmount, funding, accuracy: 1e-8)
        XCTAssertEqual(fill.units * fill.price, funding * 0.99975, accuracy: 1e-8)
        XCTAssertTrue(r.simulation.dailyStates.allSatisfy { $0.cash >= -1e-8 && $0.targetWeights.values.reduce(0, +) <= 1 })
        XCTAssertEqual(r.simulation.dailyStates.last!.holdingsBySymbol["QQQ"]!, fill.units * 88, accuracy: 1e-8)
    }

    func testSplitAccountingAndPriorSignalAtEffectiveOpen() throws {
        let start = day("2000-01-01"), splitDay = day("2000-01-23")
        let b = positiveBars(27, start: start).map { x in
            let factor = x.date < splitDay ? 1.0 : 0.5
            return Bar(date: x.date, open: x.open * factor, high: x.high * factor, low: x.low * factor,
                close: x.close * factor, volume: x.volume)
        }
        let s = try Screen.signals(bars: b, splits: [splitDay: 2])
        let p = try Screen.nativePreparation(bars: b, fxDates: ["2000-01-13"], fxPrices: [0.125], baseline: day("2000-01-13"))
        let split = BacktestShareSplit(id: "fixture:split", symbol: "QQQ", effectiveDate: splitDay, newUnitsPerOldUnit: 2)
        let r = try Screen.runAccount(preparation: p, signals: s, shareSplits: [split], role: .candidate)
        let effective = r.decisions.first { $0.date == splitDay }!
        XCTAssertEqual(effective.latestUSDBarDate, day("2000-01-22"))
        XCTAssertEqual(effective.desired, 1)
        XCTAssertFalse(effective.shouldRebalance)
        XCTAssertEqual(r.decisions.first { $0.date == day("2000-01-24") }!.desired, 0)
        XCTAssertEqual(r.simulation.splitAdjustments.count, 1)
        let adjustment = r.simulation.splitAdjustments[0]
        XCTAssertEqual(adjustment.resultingUnits, adjustment.previousUnits * 2, accuracy: 1e-12)
        let before = r.simulation.dailyStates.first { $0.date == day("2000-01-22") }!
        let after = r.simulation.dailyStates.first { $0.date == splitDay }!
        XCTAssertEqual(before.holdingsBySymbol["QQQ"]!, after.holdingsBySymbol["QQQ"]!, accuracy: 1e-8)
        XCTAssertEqual(r.simulation.trades.count, 2)
        XCTAssertEqual(r.simulation.trades[1].date, day("2000-01-24"))
        XCTAssertEqual(r.simulation.trades[1].price, 40)
        XCTAssertEqual(r.simulation.trades[1].cashAmount,
            r.simulation.trades[1].units * 40 * 0.99975, accuracy: 1e-8)
        let bh = try Screen.runAccount(preparation: p, signals: s, shareSplits: [split], role: .buyHold)
        XCTAssertEqual(bh.simulation.trades.count, 1)
        XCTAssertEqual(bh.simulation.splitAdjustments.count, 1)
        let cash = try Screen.runAccount(preparation: p, signals: s, shareSplits: [split], role: .cash)
        XCTAssertTrue(cash.simulation.trades.isEmpty)
        XCTAssertTrue(cash.simulation.splitAdjustments.isEmpty)
        XCTAssertEqual(cash.simulation.dailyStates.last!.cash,
            100000 * (1 + CashYieldCNY.periodReturn(from: p.frame.dates.first!, to: p.frame.dates.last!)), accuracy: 1e-8)
    }

    func testIncompleteBarsInvalidVolumeAndUnorderedInputsFailClosed() throws {
        XCTAssertThrowsError(try Screen.signals(bars: [], splits: [:]))
        for row in [[10.0, 9, 8, 10, 100], [10, 12, 8, 11, -1], [10, 12, 8, 11, .nan], [0, 12, 0, 11, 100]] {
            XCTAssertThrowsError(try Screen.signals(bars: bars([row]), splits: [:]))
        }
        let b = positiveBars(2)
        XCTAssertThrowsError(try Screen.signals(bars: [b[1], b[0]], splits: [:]))
        XCTAssertThrowsError(try Screen.signals(bars: [b[0], b[0]], splits: [:]))
        XCTAssertThrowsError(try Screen.signals(bars: b, splits: [b[1].date: 0]))
        XCTAssertThrowsError(try Screen.priorFX(dates: ["2000-01-14", "2000-01-13"], prices: [0.1, 0.2], asOf: day("2000-01-15")))
        XCTAssertEqual(Screen.savedControlIDs.count, 31)
        XCTAssertEqual(Set(Screen.savedControlIDs).count, 31)
        XCTAssertEqual(Screen.savedControlIDs.filter { $0 == Screen.qualID }.count, 1)
        XCTAssertFalse(Screen.savedControlIDs.contains("dmi14-nasdaq-long-cash"))
    }
}
