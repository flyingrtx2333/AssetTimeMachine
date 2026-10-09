import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class RiskParityCoreScreenTests: XCTestCase {
    typealias Screen = RiskParityCoreScreen
    private let first = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-01-01")!
    private func dates(_ count: Int) -> [Date] { (0..<count).map { first.addingTimeInterval(Double($0) * 86400) } }
    private func prices(_ count: Int) -> [String: [Double]] {
        Dictionary(uniqueKeysWithValues: Screen.coreSymbols.enumerated().map { offset, symbol in
            (symbol, (0..<count).map { i in 100 + Double(i) * Double(offset + 1) / 8 + (i % 2 == 0 ? 0 : 0.5) })
        })
    }
    private func native(_ p: [String: [Double]], closed: [String: Set<Int>] = [:], fxRate: Double = 0.125) throws -> Screen.NativePreparation {
        let count = p["gold_cny"]!.count, d = dates(count)
        let bars = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { symbol in
            (symbol, d.indices.filter { !(closed[symbol]?.contains($0) ?? false) }.map {
                Screen.PriceBar(date: d[$0], price: p[symbol]![$0] * (symbol == "gold_cny" ? 1 : fxRate))
            })
        })
        let fx = (-1..<count).map { Screen.FXPoint(date: first.addingTimeInterval(Double($0) * 86400), usdPerCNY: fxRate) }
        return try Screen.nativePreparation(barsBySymbol: bars, fxPoints: fx, fundedDates: d)
    }
    private func constant(_ count: Int) -> [String: [Double]] {
        Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0, Array(repeating: 100.0, count: count)) })
    }
    private func assertLedger(_ run: Screen.NativeRun, _ prep: Screen.NativePreparation, file: StaticString = #filePath, line: UInt = #line) {
        var cash = 100000.0, units: [String: Double] = [:], totalInterest = 0.0
        for (i, state) in run.simulation.dailyStates.enumerated() {
            if i > 0 {
                let interest = max(cash, 0) * CashYieldCNY.periodReturn(from: prep.frame.dates[i - 1], to: state.date)
                cash += interest; totalInterest += interest
            }
            for trade in run.simulation.trades.filter({ $0.date == state.date }) {
                XCTAssertTrue(prep.frame.observedBySymbol[trade.assetSymbol]![i], file: file, line: line)
                XCTAssertEqual(trade.price, prep.executionPrices[trade.assetSymbol]![i], file: file, line: line)
                if trade.action == .buy {
                    cash -= trade.cashAmount
                    units[trade.assetSymbol, default: 0] += trade.units
                    XCTAssertEqual(trade.units * trade.price, trade.cashAmount * (1 - 0.00025), accuracy: 1e-8, file: file, line: line)
                } else {
                    cash += trade.cashAmount
                    units[trade.assetSymbol, default: 0] -= trade.units
                    XCTAssertEqual(trade.cashAmount, trade.units * trade.price * (1 - 0.00025), accuracy: 1e-8, file: file, line: line)
                }
            }
            let holding = Screen.coreSymbols.reduce(0.0) { $0 + (units[$1] ?? 0) * prep.frame.pricesBySymbol[$1]![i] }
            XCTAssertEqual(state.cash, cash, accuracy: 1e-7, file: file, line: line)
            XCTAssertEqual(state.portfolioValue, cash + holding, accuracy: 1e-7, file: file, line: line)
            XCTAssertGreaterThanOrEqual(state.cash, -1e-8, file: file, line: line)
            XCTAssertLessThanOrEqual(holding, state.portfolioValue + 1e-7, file: file, line: line)
            for symbol in Screen.coreSymbols {
                XCTAssertEqual(state.holdingsBySymbol[symbol] ?? 0, (units[symbol] ?? 0) * prep.frame.pricesBySymbol[symbol]![i], accuracy: 1e-7, file: file, line: line)
            }
        }
        XCTAssertEqual(run.simulation.cashYieldSummary.totalCashInterest, totalInterest, accuracy: 1e-8, file: file, line: line)
    }

    func testHandSimpleReturnSampleVarianceAndOrderedWeights() throws {
        var p = constant(65)
        p["gold_cny"] = (0..<65).map { $0 % 2 == 0 ? 100 : 125 }
        p["sp500"] = (0..<65).map { $0 % 2 == 0 ? 100 : 100.125 }
        let prep = try native(p), s = try Screen.signals(frame: prep.frame)
        XCTAssertTrue(s.prefix(63).allSatisfy { $0.cleanedTarget.isEmpty })
        let gold = s[63].roles[0], zero = s[63].roles[1], floor = s[63].roles[2]
        let mean = (32.0 * 0.25 + 31.0 * (-0.2)) / 63
        let ss = 32 * pow(0.25 - mean, 2) + 31 * pow(-0.2 - mean, 2)
        let variance = ss / 62, vol = sqrt(variance) * sqrt(252)
        XCTAssertEqual(gold.mean!, mean, accuracy: 1e-15)
        XCTAssertEqual(gold.sumSquares!, ss, accuracy: 1e-13)
        XCTAssertEqual(gold.sampleVariance!, variance, accuracy: 1e-15)
        XCTAssertEqual(gold.annualVol!, vol, accuracy: 1e-13)
        XCTAssertNotEqual(gold.mean!, (32 * log(1.25) + 31 * log(0.8)) / 63)
        XCTAssertNotEqual(gold.sampleVariance!, gold.sumSquares! / 63)
        XCTAssertEqual(zero.annualVol, 0); XCTAssertNil(zero.score); XCTAssertNil(zero.rawWeight)
        XCTAssertEqual(zero.cleanedWeight, 0); XCTAssertEqual(zero.reason, "zero-vol-omitted-before-floor")
        XCTAssertGreaterThan(floor.annualVol!, 0); XCTAssertLessThan(floor.annualVol!, 0.04)
        XCTAssertEqual(floor.score, 25)
        let denominator = gold.score! + 25
        XCTAssertEqual(s[63].denominator, denominator)
        XCTAssertEqual(gold.rawWeight, 0.95 * gold.score! / denominator)
        XCTAssertEqual(floor.rawWeight, 0.95 * 25 / denominator)
        XCTAssertNil(s[62].priceStartIndex); XCTAssertEqual(s[63].priceStartIndex, 0)
        XCTAssertEqual(s[63].returnStartIndex, 1); XCTAssertEqual(s[63].windowEndIndex, 63)
        XCTAssertEqual(Screen.coreSymbols, ["gold_cny", "nasdaq", "sp500"])
    }

    func testZeroVolCashTinyFilterAndGenericProviderCleaning() throws {
        let prep = try native(constant(70)), s = try Screen.signals(frame: prep.frame)
        XCTAssertEqual(s[63].denominator, 0); XCTAssertEqual(s[63].cleanedTarget, [:])
        XCTAssertEqual(Screen.capped(["gold_cny": 1e-6, "nasdaq": 0.5]), ["nasdaq": 0.5])
        XCTAssertEqual(Screen.capped(["gold_cny": 2, "nasdaq": 1]), ["gold_cny": 2.0 / 3, "nasdaq": 1.0 / 3])
        XCTAssertEqual(Screen.providerClean(["gold_cny": 0.25, "nasdaq": .nan, "sp500": -0.1, "unused": 0.5]), ["gold_cny": 0.25])
        XCTAssertEqual(Screen.providerClean(["gold_cny": 1.5, "nasdaq": 0.5]), ["gold_cny": 0.75, "nasdaq": 0.25])
        XCTAssertEqual(Screen.providerClean(["gold_cny": .infinity]), [:])
    }

    func testFullCashFormationAndCompletionAnchors21_42_63_84() throws {
        let prep = try native(prices(106)), s = try Screen.signals(frame: prep.frame)
        let run = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        XCTAssertEqual(run.decisions.count, 106); XCTAssertEqual(run.simulation.dailyStates.first?.cash, 100000)
        XCTAssertEqual(run.decisions[0].signalIndex, -1); XCTAssertEqual(run.decisions[0].signalDate, prep.frame.dates[0])
        XCTAssertEqual(run.decisions[0].lastDidExecuteBefore, Int.min / 2)
        XCTAssertEqual(Array(run.completions.prefix(5)).map(\.index), [21, 42, 63, 84, 105])
        for i in [21, 42, 63] {
            XCTAssertEqual(run.decisions[i].requestedTarget, [:]); XCTAssertTrue(run.decisions[i].completedToday)
            XCTAssertNil(run.decisions[i].pendingAfter)
        }
        XCTAssertTrue(run.simulation.dailyStates.prefix(84).allSatisfy { $0.holdingsBySymbol.isEmpty })
        XCTAssertEqual(run.simulation.trades.first?.date, prep.frame.dates[84])
        XCTAssertEqual(run.decisions[84].requestedTarget, s[83].cleanedTarget)
        XCTAssertFalse(run.decisions[64].providerCalled); XCTAssertFalse(run.decisions[83].shouldRebalance)
        XCTAssertEqual(run.decisions[85].retainedTargetBefore, s[83].cleanedTarget)
        assertLedger(run, prep)
    }

    func testStrictPriorFXOnceAndCarriedHolidayHasNoExecutionQuote() throws {
        let d = dates(4)
        let bars = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { symbol in
            (symbol, [0, 2, 3].map { Screen.PriceBar(date: d[$0], price: symbol == "gold_cny" ? 100 : 10) })
        })
        let fx: [Screen.FXPoint] = [.init(date: d[0].addingTimeInterval(-86400), usdPerCNY: 0.125),
            .init(date: d[0], usdPerCNY: 0.25), .init(date: d[1], usdPerCNY: 0.5), .init(date: d[2], usdPerCNY: 1)]
        let prep = try Screen.nativePreparation(barsBySymbol: bars, fxPoints: fx, fundedDates: d)
        XCTAssertEqual(prep.frame.pricesBySymbol["nasdaq"], [80, 80, 20, 10])
        XCTAssertEqual(prep.executionPrices["nasdaq"], [80, 0, 20, 10])
        XCTAssertEqual(prep.frame.observedBySymbol["nasdaq"], [true, false, true, true])
        let q = prep.quotes.first { $0.symbol == "nasdaq" && $0.index == 1 }!
        XCTAssertEqual(q.fxDate, d[0].addingTimeInterval(-86400)); XCTAssertEqual(q.sourceDate, d[0])
        XCTAssertEqual(q.quoteAgeDays, 1); XCTAssertEqual(q.fxAgeDays, 1); XCTAssertEqual(q.cnyPerUSD, 8)
        XCTAssertTrue(prep.quotes.filter { $0.symbol == "gold_cny" }.allSatisfy { $0.fxDate == nil && $0.usdPerCNY == nil && $0.cnyClose == 100 })
        // The canonical-only API has no OHLC-support input that could veto gold.
        XCTAssertEqual(prep.executionPrices["gold_cny"], [100, 0, 100, 100])
    }

    func testMissingSameDayStaleFXAndNoPreGoldAreRejected() throws {
        let d = dates(1), all = constant(1)
        let bars = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0, [Screen.PriceBar(date: d[0], price: all[$0]![0])]) })
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: bars, fxPoints: [.init(date: d[0], usdPerCNY: 0.125)], fundedDates: d))
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: bars, fxPoints: [.init(date: d[0].addingTimeInterval(-15 * 86400), usdPerCNY: 0.125)], fundedDates: d))
        XCTAssertNoThrow(try Screen.nativePreparation(barsBySymbol: bars, fxPoints: [.init(date: d[0].addingTimeInterval(-14 * 86400), usdPerCNY: 0.125)], fundedDates: d))
        var missing = bars; missing["gold_cny"] = [.init(date: d[0].addingTimeInterval(86400), price: 100)]
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: missing, fxPoints: [.init(date: d[0].addingTimeInterval(-86400), usdPerCNY: 0.125)], fundedDates: d))
        var bad = bars; bad["gold_cny"] = [.init(date: d[0], price: 0)]
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: bad, fxPoints: [.init(date: d[0].addingTimeInterval(-86400), usdPerCNY: 0.125)], fundedDates: d))
    }

    func testQuoteWaitReviewsLatestSignalAndShiftsCompletionAnchor() throws {
        let prep = try native(prices(110), closed: ["sp500": [84, 85]])
        let s = try Screen.signals(frame: prep.frame), run = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        XCTAssertEqual(run.completions.map(\.index), [21, 42, 63, 86, 107])
        for i in [84, 85] {
            XCTAssertTrue(run.decisions[i].providerCalled); XCTAssertFalse(run.decisions[i].completedToday)
            XCTAssertEqual(run.decisions[i].requestedTarget, s[i - 1].cleanedTarget)
            XCTAssertEqual(run.decisions[i].lastDidExecuteAfter, 63)
            XCTAssertEqual(run.decisions[i].pendingAfter, s[i - 1].cleanedTarget)
        }
        XCTAssertEqual(run.decisions[86].pendingBefore, s[84].cleanedTarget)
        XCTAssertEqual(run.decisions[86].requestedTarget, s[85].cleanedTarget)
        XCTAssertEqual(run.simulation.trades.first?.date, prep.frame.dates[86])
        XCTAssertFalse(run.decisions[105].shouldRebalance); XCTAssertNil(run.decisions[87].requestedTarget)
        assertLedger(run, prep)
    }

    func testFuturePriceAndFXShocksCannotChangePrefix() throws {
        let p = prices(130), d = dates(130), cut = 100
        func preparation(shock: Bool) throws -> Screen.NativePreparation {
            let bars = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { symbol in
                (symbol, d.indices.map { i in Screen.PriceBar(date: d[i], price: p[symbol]![i] * (symbol == "gold_cny" ? 1 : 0.125) * (shock && i >= cut ? 32 : 1)) })
            })
            let fx = (-1..<130).map { i in Screen.FXPoint(date: first.addingTimeInterval(Double(i) * 86400), usdPerCNY: 0.125 * (shock && i >= cut ? 64 : 1)) }
            return try Screen.nativePreparation(barsBySymbol: bars, fxPoints: fx, fundedDates: d)
        }
        let a = try preparation(shock: false), b = try preparation(shock: true)
        let sa = try Screen.signals(frame: a.frame), sb = try Screen.signals(frame: b.frame)
        XCTAssertEqual(Array(sa.prefix(cut)), Array(sb.prefix(cut)))
        XCTAssertEqual(a.quotes.filter { $0.index < cut }, b.quotes.filter { $0.index < cut })
        let ra = try Screen.runAccount(preparation: a, signals: sa, role: .candidate)
        let rb = try Screen.runAccount(preparation: b, signals: sb, role: .candidate)
        XCTAssertEqual(Array(ra.decisions.prefix(cut)), Array(rb.decisions.prefix(cut)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(Array(ra.simulation.dailyStates.prefix(cut))), try encoder.encode(Array(rb.simulation.dailyStates.prefix(cut))))
        let prefix = try native(p.mapValues { Array($0.prefix(cut)) })
        XCTAssertEqual(try Screen.signals(frame: prefix.frame), Array(sa.prefix(cut)))
    }

    func testBinaryCurrencyUnitsAndSourceScalingDoNotChangeTargets() throws {
        let p = prices(100), a = try native(p), b = try native(p, fxRate: 0.25)
        XCTAssertEqual(a.frame.pricesBySymbol, b.frame.pricesBySymbol)
        let sa = try Screen.signals(frame: a.frame), sb = try Screen.signals(frame: b.frame)
        XCTAssertEqual(sa, sb)
        let c = try native(p.mapValues { $0.map { $0 * 2 } })
        XCTAssertEqual(sa, try Screen.signals(frame: c.frame))
        let ra = try Screen.runAccount(preparation: a, signals: sa, role: .candidate)
        let rc = try Screen.runAccount(preparation: c, signals: sa, role: .candidate)
        for (x, y) in zip(ra.simulation.dailyStates, rc.simulation.dailyStates) { XCTAssertEqual(x.portfolioValue, y.portfolioValue, accuracy: 1e-8) }
        for (x, y) in zip(ra.simulation.trades, rc.simulation.trades) { XCTAssertEqual(x.units, y.units * 2); XCTAssertEqual(x.cashAmount, y.cashAmount) }
    }

    func testSettlementUsesOldCashButNotSameDaySaleProceeds() throws {
        let prep = try native(constant(70))
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic settlement") { $0.index < 42 ? ["nasdaq": 0.95] : ["gold_cny": 0.95] }
        let day42 = run.simulation.trades.filter { $0.date == prep.frame.dates[42] }
        XCTAssertEqual(day42.map(\.action), [.sell, .buy])
        XCTAssertEqual(day42.map(\.assetSymbol), ["nasdaq", "gold_cny"])
        XCTAssertLessThan(day42[1].cashAmount, 6000)
        XCTAssertFalse(run.decisions[42].completedToday); XCTAssertNotNil(run.decisions[42].pendingAfter)
        XCTAssertTrue(run.decisions[43].providerCalled); XCTAssertTrue(run.decisions[43].completedToday)
        XCTAssertEqual(run.completions.map(\.index), [21, 43, 64])
        XCTAssertGreaterThan(run.simulation.trades.first { $0.date == prep.frame.dates[43] }!.cashAmount, 85000)
        assertLedger(run, prep)
    }

    func testOverdueCashReplacementCancelsSettlementDeferredBuy() throws {
        let prep = try native(constant(66))
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic cancellation") { c in
            c.index < 42 ? ["nasdaq": 0.95] : (c.index == 42 ? ["gold_cny": 0.95] : [:])
        }
        XCTAssertFalse(run.decisions[42].completedToday)
        XCTAssertEqual(run.decisions[43].pendingBefore, ["gold_cny": 0.95])
        XCTAssertEqual(run.decisions[43].requestedTarget, [:]); XCTAssertTrue(run.decisions[43].completedToday)
        XCTAssertFalse(run.simulation.trades.contains { $0.date >= prep.frame.dates[43] && $0.action == .buy })
        XCTAssertTrue(run.simulation.dailyStates[43].holdingsBySymbol.isEmpty)
        assertLedger(run, prep)
    }

    func testRelativeBandCompletesNoFillAndTradesToTargetWithSymbolOrder() throws {
        var p = constant(66)
        for i in 42..<63 { p["gold_cny"]![i] = 102 }
        for i in 63..<66 { p["gold_cny"]![i] = 120 }
        let prep = try native(p)
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic relative band") { _ in ["gold_cny": 0.5, "nasdaq": 0.45] }
        XCTAssertEqual(run.simulation.trades.filter { $0.date == prep.frame.dates[21] }.map(\.assetSymbol), ["gold_cny", "nasdaq"])
        XCTAssertTrue(run.simulation.trades.filter { $0.date == prep.frame.dates[42] }.isEmpty)
        XCTAssertTrue(run.decisions[42].completedToday)
        let trades = run.simulation.trades.filter { $0.date == prep.frame.dates[63] }
        XCTAssertEqual(trades.map(\.action), [.sell, .buy])
        let previous = run.simulation.dailyStates[62]
        let pre = previous.cash * (1 + CashYieldCNY.periodReturn(from: previous.date, to: prep.frame.dates[63]))
            + previous.holdingsBySymbol["gold_cny"]! / 102 * 120 + previous.holdingsBySymbol["nasdaq"]!
        XCTAssertEqual(run.simulation.dailyStates[63].holdingsBySymbol["gold_cny"]!, pre * 0.5, accuracy: 1e-7)
        assertLedger(run, prep)
    }

    func testMatchedEqualAndCashControlScopeRetainsNativeBaseline() throws {
        let prep = try native(prices(90)), s = try Screen.signals(frame: prep.frame)
        let equal = try Screen.runAccount(preparation: prep, signals: s, role: .equal)
        let cash = try Screen.runAccount(preparation: prep, signals: s, role: .cash)
        XCTAssertEqual(equal.completions.map(\.index), [21, 42, 63, 84])
        XCTAssertEqual(equal.decisions[21].requestedTarget, Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0, 0.95 / 3) }))
        XCTAssertEqual(equal.simulation.trades.first?.date, prep.frame.dates[21])
        XCTAssertEqual(equal.simulation.trades.prefix(3).map(\.assetSymbol), ["gold_cny", "nasdaq", "sp500"])
        XCTAssertTrue(cash.simulation.trades.isEmpty); XCTAssertEqual(cash.simulation.dailyStates.count, 90)
        XCTAssertEqual(cash.completions.map(\.index), [21, 42, 63, 84])
        XCTAssertEqual(Screen.savedControlIDs, ChaikinMoneyFlowScreen.savedControlIDs)
        XCTAssertEqual(Screen.savedControlIDs.count, 31)
        XCTAssertEqual(Set(Screen.savedControlIDs).count, 31)
        XCTAssertFalse(Screen.savedControlIDs.contains(Screen.candidateID))
        assertLedger(equal, prep); assertLedger(cash, prep)
    }
}
