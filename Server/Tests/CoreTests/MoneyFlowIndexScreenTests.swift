import XCTest
import AssetTimeMachineBacktestCore
import AssetTimeMachineResearchSupport

final class MoneyFlowIndexScreenTests: XCTestCase {
    typealias Screen = MoneyFlowIndexScreen
    typealias Bar = Screen.Bar
    private let epoch = Date(timeIntervalSince1970: 0)
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

    func testHandSeedFourteenComparisonsAndRollingFlowSums() throws {
        // TP10 seed, TP12*V2 positive24, TP9*V3 negative27, then ties.
        let b = bars([10, 12, 9, 9] + Array(repeating: 9, count: 11), volumes: [1, 2, 3, 100] + Array(repeating: 1, count: 11))
        let s = try signals(b)
        XCTAssertTrue(s.prefix(14).allSatisfy { $0.mfi14 == nil && $0.weight == 0 })
        XCTAssertNil(s[0].previousTypicalPrice)
        XCTAssertEqual(s[0].windowCount, 0)
        XCTAssertEqual(s[0].direction, "seed")
        XCTAssertEqual(s[1].positiveFlow, 24)
        XCTAssertEqual(s[2].negativeFlow, 27)
        XCTAssertEqual(s[3].direction, "tie")
        XCTAssertEqual(s[3].positiveFlow + s[3].negativeFlow, 0)
        XCTAssertEqual(s[14].windowCount, 14)
        XCTAssertEqual(s[14].completedBarsInEpoch, 15)
        XCTAssertEqual(s[14].sumPositiveFlow, 24)
        XCTAssertEqual(s[14].sumNegativeFlow, 27)
        XCTAssertEqual(s[14].mfi14!, 800.0 / 17, accuracy: 1e-12)
        XCTAssertEqual(s[14].windowStartDate, b[1].date)
        let extended = try signals(b + bars([8], start: b.last!.date.addingTimeInterval(86400)))
        XCTAssertEqual(extended[15].sumPositiveFlow, 0)
        XCTAssertEqual(extended[15].sumNegativeFlow, 35)
        XCTAssertEqual(extended[15].mfi14, 0)
        XCTAssertEqual(extended[15].weight, 1)
    }

    func testStrictSignsNearEqualityAndNeutralZeroFlow() throws {
        let b = bars([1, Double(1).nextUp, 1, 1])
        let s = try signals(b)
        XCTAssertGreaterThan(s[1].typicalPrice, s[0].typicalPrice)
        XCTAssertEqual(s[1].direction, "up")
        XCTAssertGreaterThan(s[1].positiveFlow, 0)
        XCTAssertEqual(s[2].direction, "down")
        XCTAssertGreaterThan(s[2].negativeFlow, 0)
        XCTAssertEqual(s[3].direction, "tie")
        let flat = try signals(bars(Array(repeating: 10, count: 15)))
        XCTAssertEqual(flat[14].sumPositiveFlow + flat[14].sumNegativeFlow, 0)
        XCTAssertEqual(flat[14].mfi14, 50)
        XCTAssertEqual(flat[14].weight, 0)
        let noVolume = try signals(bars((0..<15).map { Double(100 - $0) }, volumes: Array(repeating: 0, count: 15)))
        XCTAssertEqual(noVolume[14].mfi14, 50)
        XCTAssertEqual(noVolume[14].weight, 0)
        let heldFlat = try signals(bars((0..<15).map { Double(100 - $0) } + Array(repeating: 86, count: 14)))
        XCTAssertEqual(heldFlat[14].weight, 1)
        XCTAssertEqual(heldFlat.last!.mfi14, 50)
        XCTAssertEqual(heldFlat.last!.weight, 1)
        XCTAssertEqual(heldFlat.last!.stateReason, "middle-hold")
        XCTAssertEqual(heldFlat.last!.stateSourceDate, heldFlat[heldFlat.count - 2].stateSourceDate)
    }

    private func equalityFixture(positive: Double, negative: Double, initiallyHeld: Bool) -> [Bar] {
        let prefix = initiallyHeld ? (0..<15).map { Double(16 - $0) } : [2]
        let tail = (1...14).map { $0 % 2 == 1 ? 4.0 : 2.0 }
        let volumes = Array(repeating: 1.0, count: prefix.count) + tail.enumerated().map { i, tp in
            (i % 2 == 0 ? positive : negative) / tp
        }
        return bars(prefix + tail, volumes: volumes)
    }
    func testExactTwentyAndEightyHoldBothCashAndKnownLong() throws {
        for (positive, negative, boundary) in [(1.0, 4.0, 20.0), (4.0, 1.0, 80.0)] {
            for held in [false, true] {
                let s = try signals(equalityFixture(positive: positive, negative: negative, initiallyHeld: held))
                XCTAssertEqual(s.last!.mfi14!, boundary, accuracy: 1e-12)
                XCTAssertEqual(s.last!.weight, held ? 1 : 0)
                XCTAssertEqual(s.last!.stateReason, "middle-hold")
                XCTAssertEqual(s.last!.stateSourceDate, s[s.count - 2].stateSourceDate)
            }
        }
        let atTwenty = equalityFixture(positive: 1, negative: 4, initiallyHeld: false)
        let entry = try signals(atTwenty + bars([1], volumes: [10000], start: atTwenty.last!.date.addingTimeInterval(86400)))
        XCTAssertLessThan(entry.last!.mfi14!, 20)
        XCTAssertEqual(entry.last!.weight, 1)
        let atEighty = equalityFixture(positive: 4, negative: 1, initiallyHeld: true)
        let exit = try signals(atEighty + bars([4], volumes: [2500], start: atEighty.last!.date.addingTimeInterval(86400)))
        XCTAssertGreaterThan(exit.last!.mfi14!, 80)
        XCTAssertEqual(exit.last!.weight, 0)
    }

    func testPreFundingThresholdDoesNotInitializePositionAndJanThirteenMaySetState() throws {
        let b = bars((0..<40).map { Double(100 - $0) }, start: day("1999-12-15"))
        let s = try signals(b, eligible: day("2000-01-13"))
        XCTAssertTrue(s.filter { $0.date < day("2000-01-13") }.allSatisfy { $0.weight == 0 && !$0.fundingEligible && $0.stateSourceDate == nil })
        XCTAssertEqual(s.first { $0.date == day("2000-01-12") }!.mfi14, 0)
        let firstEligible = s.first { $0.date == day("2000-01-13") }!
        XCTAssertEqual(firstEligible.previousWeight, 0)
        XCTAssertEqual(firstEligible.weight, 1)
        XCTAssertEqual(firstEligible.stateSourceDate, day("2000-01-13"))
        // Earlier oversold observations cannot be inherited through a neutral funding bar.
        let neutralBars = bars((0..<15).map { Double(100 - $0) } + Array(repeating: 86, count: 14))
        let neutral = try signals(neutralBars, eligible: neutralBars.last!.date)
        XCTAssertEqual(neutral.last!.mfi14, 50)
        XCTAssertEqual(neutral.last!.weight, 0)
        XCTAssertNil(neutral.last!.stateSourceDate)
    }

    func testSplitClearsTPWindowAndPositionBeforeSeedAndFourteenWarmupBars() throws {
        let original = bars((0..<50).map { Double(100 - $0) })
        let split = original[25].date
        let b = original.map { x in
            let f = x.date < split ? 1.0 : 0.5
            return Bar(date: x.date, open: x.open * f, high: x.high * f, low: x.low * f, close: x.close * f, volume: x.volume)
        }
        let s = try signals(b, splits: [split: 2])
        XCTAssertEqual(s[24].weight, 1)
        XCTAssertEqual(s[25].previousWeight, 1)
        XCTAssertNil(s[25].previousTypicalPrice)
        XCTAssertEqual(s[25].windowCount, 0)
        XCTAssertEqual(s[25].positiveFlow + s[25].negativeFlow, 0)
        XCTAssertEqual(s[25].stateReason, "split-seed-cash")
        XCTAssertTrue(s[25..<39].allSatisfy { $0.mfi14 == nil && $0.weight == 0 })
        XCTAssertEqual(s[39].mfi14, 0)
        XCTAssertEqual(s[39].windowCount, 14)
        XCTAssertEqual(s[39].weight, 1)
        XCTAssertEqual(Screen.latestSignal(s, before: split)?.weight, 1)
        XCTAssertEqual(Screen.latestSignal(s, before: b[26].date)?.weight, 0)
    }

    func testPrefixFuturePricesAndFutureSplitsCannotChangePastIndicatorOrState() throws {
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

    func testCoherentEpochTPAndVolumeUnitsPreserveRatiosAndState() throws {
        let b = bars((0..<90).map { 100 + 20 * sin(Double($0) / 5) }, volumes: (0..<90).map { Double(100 + $0) })
        let split = b[40].date
        let raw = try signals(b, splits: [split: 2])
        let adjusted = try signals(b.map { x in
            let p = x.date < split ? 2.0 : 4.0, v = x.date < split ? 7.0 : 3.0
            return Bar(date: x.date, open: x.open * p, high: x.high * p, low: x.low * p, close: x.close * p, volume: x.volume * v)
        }, splits: [split: 2])
        XCTAssertEqual(raw.map(\.direction), adjusted.map(\.direction))
        XCTAssertEqual(raw.map(\.weight), adjusted.map(\.weight))
        for (a, z) in zip(raw, adjusted) {
            if let value = a.mfi14 { XCTAssertEqual(value, z.mfi14!, accuracy: 1e-12) }
            else { XCTAssertNil(z.mfi14) }
        }
    }

    func testSharedNativeFXBaselineNextOpenFeeAndControlCashTransport() throws {
        let b = bars((0..<40).map { Double(100 - $0) }, start: day("1999-12-15"))
        let s = try signals(b, eligible: day("2000-01-13")), p = try native(b)
        XCTAssertEqual(p.frame.pricesBySymbol["QQQ"]![0], 0)
        XCTAssertFalse(p.frame.observedBySymbol["QQQ"]![0])
        XCTAssertEqual(p.opens[0], 0)
        XCTAssertNil(p.quotes[0].fxDate)
        XCTAssertEqual(p.quotes[1].fxDate, day("2000-01-13"))
        let run = try Screen.runAccount(preparation: p, signals: s, shareSplits: [], role: .candidate)
        XCTAssertEqual(run.simulation.dailyStates[0].cash, 100000)
        XCTAssertTrue(run.simulation.dailyStates[0].targetWeights.isEmpty)
        XCTAssertFalse(run.decisions[0].shouldRebalance)
        XCTAssertNil(run.decisions[0].submitted)
        XCTAssertEqual(run.decisions[1].latestUSDBarDate, day("2000-01-13"))
        XCTAssertEqual(run.decisions[1].desired, 1)
        XCTAssertEqual(run.decisions.filter(\.shouldRebalance).count, 1)
        let fill = run.simulation.trades[0]
        XCTAssertEqual(fill.date, day("2000-01-14"))
        XCTAssertEqual(fill.price, p.opens[1])
        XCTAssertEqual(fill.units * fill.price, fill.cashAmount * 0.99975, accuracy: 1e-8)
        XCTAssertEqual(run.targetMismatchCount, 0)
        XCTAssertTrue(run.simulation.dailyStates.allSatisfy { $0.cash >= -1e-8 && $0.targetWeights.values.reduce(0, +) <= 1 })
        let oldSignals = try ChaikinMoneyFlowScreen.signals(bars: b, splits: [:])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for role in [Screen.Role.buyHold, .cash] {
            let new = try Screen.runAccount(preparation: p, signals: s, shareSplits: [], role: role)
            let old = try ChaikinMoneyFlowScreen.runAccount(preparation: p, signals: oldSignals, shareSplits: [], role: role)
            XCTAssertEqual(try encoder.encode(new.simulation.dailyStates), try encoder.encode(old.simulation.dailyStates))
            XCTAssertEqual(new.simulation.trades.count, old.simulation.trades.count)
            XCTAssertEqual(new.simulation.cashYieldSummary.totalCashInterest, old.simulation.cashYieldSummary.totalCashInterest)
            for (a, z) in zip(new.simulation.trades, old.simulation.trades) {
                XCTAssertEqual(a.date, z.date); XCTAssertEqual(a.price, z.price)
                XCTAssertEqual(a.cashAmount, z.cashAmount); XCTAssertEqual(a.units, z.units); XCTAssertEqual(a.action, z.action)
                XCTAssertEqual(a.reason, z.reason)
            }
        }
        XCTAssertThrowsError(try ChaikinMoneyFlowScreen.priorFX(dates: ["2000-01-13"], prices: [0.125], asOf: day("2000-01-13")))
        XCTAssertThrowsError(try ChaikinMoneyFlowScreen.priorFX(dates: ["2000-01-13"], prices: [0.125], asOf: day("2000-01-28")))
    }

    func testSharedSplitAccountingKeepsPriorCompletedStateOnEffectiveOpen() throws {
        let original = bars((0..<46).map { Double(100 - $0) }, start: day("1999-12-25")), splitDay = day("2000-01-19")
        let b = original.map { x in
            let f = x.date < splitDay ? 1.0 : 0.5
            return Bar(date: x.date, open: x.open * f, high: x.high * f, low: x.low * f, close: x.close * f, volume: x.volume)
        }
        let s = try signals(b, splits: [splitDay: 2], eligible: day("2000-01-13")), p = try native(b)
        let split = BacktestShareSplit(id: "fixture:split", symbol: "QQQ", effectiveDate: splitDay, newUnitsPerOldUnit: 2)
        let run = try Screen.runAccount(preparation: p, signals: s, shareSplits: [split], role: .candidate)
        let effective = run.decisions.first { $0.date == splitDay }!
        XCTAssertEqual(effective.latestUSDBarDate, day("2000-01-18"))
        XCTAssertEqual(effective.desired, 1)
        XCTAssertFalse(effective.shouldRebalance)
        XCTAssertEqual(run.decisions.first { $0.date == day("2000-01-20") }!.desired, 0)
        XCTAssertEqual(run.simulation.splitAdjustments.count, 1)
        let adjustment = run.simulation.splitAdjustments[0]
        XCTAssertEqual(adjustment.resultingUnits, adjustment.previousUnits * 2)
        XCTAssertEqual(run.simulation.trades[1].date, day("2000-01-20"))
        XCTAssertEqual(run.simulation.trades[1].cashAmount,
            run.simulation.trades[1].units * run.simulation.trades[1].price * 0.99975, accuracy: 1e-8)
    }

    func testIncompleteOrUnorderedBarsAndInvalidSplitsFailClosed() throws {
        XCTAssertThrowsError(try signals([]))
        let b = bars([10, 9])
        XCTAssertThrowsError(try signals([b[1], b[0]]))
        XCTAssertThrowsError(try signals([b[0], b[0]]))
        XCTAssertThrowsError(try signals(bars([10], volumes: [-1])))
        XCTAssertThrowsError(try signals(bars([10], volumes: [.nan])))
        XCTAssertThrowsError(try signals(bars([0])))
        XCTAssertThrowsError(try signals(b, splits: [b[1].date: 0]))
        XCTAssertEqual(Screen.savedControlIDs, ChaikinMoneyFlowScreen.savedControlIDs)
    }
}
