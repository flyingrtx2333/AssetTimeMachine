import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class CoverUniversalCoreScreenTests: XCTestCase {
    typealias Screen = CoverUniversalCoreScreen
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


    /// Independent scalar reference: enumerate each integer identity, carry its
    /// raw product through every completed interval, then form ordinal sums.
    private func reference(_ p: [String: [Double]], end: Int) -> ([Double], [Double], Double, [Double]) {
        var book: [Double] = [], factors: [Double] = [], grid: [[Double]] = []
        for gold in 0...20 {
            for nasdaq in 0...(20 - gold) {
                let weights = [Double(gold) / 20, Double(nasdaq) / 20, Double(20 - gold - nasdaq) / 20]
                grid.append(weights)
                var value = 1.0, lastFactor = 0.0
                if end > 0 {
                    for day in 1...end {
                        lastFactor = weights[0] * (p["gold_cny"]![day] / p["gold_cny"]![day - 1])
                        lastFactor += weights[1] * (p["nasdaq"]![day] / p["nasdaq"]![day - 1])
                        lastFactor += weights[2] * (p["sp500"]![day] / p["sp500"]![day - 1])
                        value *= lastFactor
                    }
                }
                book.append(value); factors.append(lastFactor)
            }
        }
        var denominator = 0.0
        for value in book { denominator += value }
        var numerators = [0.0, 0.0, 0.0]
        for leg in 0..<3 { for j in book.indices { numerators[leg] += grid[j][leg] * book[j] } }
        return (book, factors, denominator, numerators)
    }

    func testOriginalTwoStock21FinitePosteriorAndIdealMeanIdentity() throws {
        let w = (0...20).map { [Double($0) / 20, Double(20 - $0) / 20] }
        let a = try Screen.updateBook(expertWeights: w, previousWealth: Array(repeating: 1, count: 21), relatives: [2, 1])
        XCTAssertEqual(a.denominator, 31.5, accuracy: 1e-14)
        XCTAssertEqual(a.numerators[0], 17.675, accuracy: 1e-14)
        XCTAssertEqual(a.weights[0], 17.675 / 31.5, accuracy: 1e-15)
        XCTAssertEqual(a.grossFactors.first, 1); XCTAssertEqual(a.grossFactors.last, 2)
        let b = try Screen.updateBook(expertWeights: w, previousWealth: a.expertWealth, relatives: [0.5, 2])
        let idealPortfolio = (a.denominator / 21) * (a.weights[0] * 0.5 + a.weights[1] * 2)
        XCTAssertEqual(idealPortfolio, b.denominator / 21, accuracy: 1e-15)
        // This is the ideal period-start identity; no genuine account NAV used.
        let flat = try Screen.updateBook(expertWeights: w, previousWealth: Array(repeating: 1, count: 21), relatives: [1, 1])
        XCTAssertEqual(flat.weights[0], 0.5, accuracy: 1e-15)
    }

    func test231IdentitiesUniformPriorAndExplicitBaseline() throws {
        XCTAssertEqual(Screen.experts.count, 231)
        XCTAssertEqual(Screen.experts.map(\.ordinal), Array(0..<231))
        XCTAssertEqual(Screen.experts[0].weights, [0, 0, 1])
        XCTAssertEqual(Screen.experts[20].weights, [0, 1, 0])
        XCTAssertEqual(Screen.experts[21].weights, [0.05, 0, 0.95])
        XCTAssertEqual(Screen.experts[230].weights, [1, 0, 0])
        XCTAssertTrue(Screen.experts.allSatisfy { $0.si == 20 - $0.gi - $0.ni && $0.weights.allSatisfy { $0 >= 0 } })
        let s = try Screen.signals(frame: native(prices(4)).frame)
        XCTAssertEqual(s[0].expertWealth, Array(repeating: 1, count: 231))
        XCTAssertEqual(s[0].expertWealthBefore, []); XCTAssertEqual(s[0].grossFactors, [])
        XCTAssertNil(s[0].relatives); XCTAssertNil(s[0].numerators)
        XCTAssertEqual(s[0].denominator, 231)
        XCTAssertEqual(s[0].reason, "baseline-explicit-equal-prior")
        XCTAssertEqual(s[0].rawTarget, Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0, 1.0 / 3) }))
    }

    func testExactChronologicalRawProductsAndSumsRetainAllPast() throws {
        let p = prices(70), s = try Screen.signals(frame: native(p).frame)
        for end in [1, 2, 21, 63, 69] {
            let r = reference(p, end: end)
            XCTAssertEqual(s[end].expertWealth, r.0)
            XCTAssertEqual(s[end].grossFactors, r.1)
            XCTAssertEqual(s[end].denominator, r.2)
            XCTAssertEqual(s[end].numerators, r.3)
            XCTAssertEqual(s[end].expertWealthBefore, s[end - 1].expertWealth)
            XCTAssertEqual(s[end].intervalCount, end)
            for leg in 0..<3 { XCTAssertEqual(s[end].rawTarget[Screen.coreSymbols[leg]], r.3[leg] / r.2) }
        }
        XCTAssertEqual(s[69].expertWealth[230], p["gold_cny"]!.dropFirst().enumerated().reduce(1.0) { $0 * ($1.element / p["gold_cny"]![$1.offset]) })
        let reset = try Screen.signals(frame: native(p.mapValues { Array($0.suffix(7)) }).frame)
        XCTAssertNotEqual(s[69].expertWealth, reset.last!.expertWealth)
    }

    func testFlatThreeCoreUsesActualScalarReferenceWithoutForcedEquality() throws {
        let p = constant(50), s = try Screen.signals(frame: native(p).frame)
        for end in [1, 2, 49] {
            let r = reference(p, end: end)
            XCTAssertEqual(s[end].expertWealth, r.0); XCTAssertEqual(s[end].grossFactors, r.1)
            XCTAssertEqual(s[end].denominator, r.2); XCTAssertEqual(s[end].numerators, r.3)
            for leg in 0..<3 { XCTAssertEqual(s[end].rawTarget[Screen.coreSymbols[leg]], r.3[leg] / r.2) }
        }
    }

    func testNumericUnderflowOverflowAndInvalidInputFailWithoutFallback() throws {
        XCTAssertThrowsError(try Screen.updateBook(expertWeights: [[1]], previousWealth: [.leastNonzeroMagnitude], relatives: [0.5]))
        XCTAssertThrowsError(try Screen.updateBook(expertWeights: [[1]], previousWealth: [.greatestFiniteMagnitude], relatives: [2]))
        XCTAssertThrowsError(try Screen.updateBook(expertWeights: [[1], [1]], previousWealth: [.greatestFiniteMagnitude, .greatestFiniteMagnitude], relatives: [1]))
        // Both raw expert values and the denominator remain positive finite;
        // this final leg quotient underflows, so dropping it is forbidden.
        XCTAssertThrowsError(try Screen.updateBook(expertWeights: [[1, 0], [0, 1]], previousWealth: [1e-300, 1e300], relatives: [1, 1]))
        for invalid in [0.0, -1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try Screen.updateBook(expertWeights: [[1]], previousWealth: [1], relatives: [invalid]))
            XCTAssertThrowsError(try Screen.updateBook(expertWeights: [[1]], previousWealth: [invalid], relatives: [1]))
        }
        XCTAssertThrowsError(try Screen.updateBook(expertWeights: [[-1]], previousWealth: [1], relatives: [1]))
        var p = constant(2); p["gold_cny"] = [.leastNonzeroMagnitude, .greatestFiniteMagnitude]
        XCTAssertThrowsError(try Screen.signals(frame: native(p).frame))
    }

    func testProviderCleaningPreservesTinyPositiveWeightsAndCapsOnlyGross() {
        XCTAssertEqual(Screen.providerClean(["gold_cny": 1e-12, "nasdaq": 0.5]), ["gold_cny": 1e-12, "nasdaq": 0.5])
        XCTAssertEqual(Screen.providerClean(["gold_cny": 2, "nasdaq": 1]), ["gold_cny": 2.0 / 3, "nasdaq": 1.0 / 3])
        XCTAssertEqual(Screen.providerClean(["gold_cny": .nan, "nasdaq": -1, "sp500": 0, "unused": 1]), [:])
    }

    func testDailyFirstIndex1PriorSignalAndFullCashBaseline() throws {
        let prep = try native(prices(8)), s = try Screen.signals(frame: prep.frame)
        let run = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        XCTAssertEqual(run.decisions[0].signalIndex, -1); XCTAssertEqual(run.decisions[0].signalDate, prep.frame.dates[0])
        XCTAssertEqual(run.decisions[0].lastDidExecuteBefore, Int.min / 2)
        XCTAssertFalse(run.decisions[0].providerCalled); XCTAssertFalse(run.decisions[0].shouldRebalance)
        XCTAssertEqual(run.simulation.dailyStates[0].cash, 100000); XCTAssertTrue(run.simulation.dailyStates[0].holdingsBySymbol.isEmpty)
        XCTAssertEqual(run.simulation.trades.first?.date, prep.frame.dates[1])
        for i in 1..<8 {
            XCTAssertTrue(run.decisions[i].providerCalled); XCTAssertTrue(run.decisions[i].shouldRebalance)
            XCTAssertEqual(run.decisions[i].requestedTarget, Screen.providerClean(s[i - 1].cleanedTarget))
            XCTAssertEqual(run.decisions[i].acceptedAfter, Screen.providerClean(s[i - 1].cleanedTarget))
            XCTAssertEqual(run.decisions[i].signalIndex, i - 1)
        }
        XCTAssertEqual(run.targetMismatchCount, 0)
        XCTAssertTrue(run.simulation.trades.filter { $0.action == .buy }.allSatisfy { $0.reason == "fixed Cover q20 core close research" })
        assertLedger(run, prep)
    }

    func testQuoteWaitCarryAndPendingReplacementUseLatestPriorSignal() throws {
        let prep = try native(prices(7), closed: ["sp500": [1, 2]])
        let s = try Screen.signals(frame: prep.frame), run = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        XCTAssertEqual(prep.executionPrices["sp500"]![1], 0)
        XCTAssertFalse(prep.frame.observedBySymbol["sp500"]![1])
        XCTAssertEqual(prep.frame.pricesBySymbol["sp500"]![1], prep.frame.pricesBySymbol["sp500"]![0])
        for i in [1, 2] {
            XCTAssertFalse(run.decisions[i].completedToday); XCTAssertTrue(run.decisions[i].providerCalled)
            XCTAssertEqual(run.decisions[i].pendingAfter, s[i - 1].cleanedTarget)
            XCTAssertEqual(run.decisions[i].lastDidExecuteAfter, Int.min / 2)
        }
        XCTAssertEqual(run.decisions[3].pendingBefore, s[1].cleanedTarget)
        XCTAssertEqual(run.decisions[3].requestedTarget, s[2].cleanedTarget)
        XCTAssertEqual(run.simulation.trades.first?.date, prep.frame.dates[3])
        assertLedger(run, prep)
    }

    func testStrictPriorFXConvertedOnceAndMissingSourceRejected() throws {
        let d = dates(3)
        let bars = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { symbol in
            (symbol, [Screen.PriceBar(date: d[0], price: symbol == "gold_cny" ? 100 : 10), Screen.PriceBar(date: d[2], price: symbol == "gold_cny" ? 110 : 12)])
        })
        let fx = [Screen.FXPoint(date: first.addingTimeInterval(-86400), usdPerCNY: 0.125), .init(date: d[0], usdPerCNY: 0.25), .init(date: d[2], usdPerCNY: 1)]
        let prep = try Screen.nativePreparation(barsBySymbol: bars, fxPoints: fx, fundedDates: d)
        XCTAssertEqual(prep.frame.pricesBySymbol["nasdaq"], [80, 80, 48])
        let q = prep.quotes.filter { $0.symbol == "nasdaq" }
        XCTAssertEqual(q[0].fxDate, first.addingTimeInterval(-86400)); XCTAssertEqual(q[1].fxDate, q[0].fxDate)
        XCTAssertEqual(q[2].fxDate, d[0]); XCTAssertFalse(q[1].quoteToday); XCTAssertEqual(q[1].executionPrice, 0)
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: bars, fxPoints: [.init(date: d[0], usdPerCNY: 0.125)], fundedDates: d))
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: bars, fxPoints: [.init(date: first.addingTimeInterval(-15 * 86400), usdPerCNY: 0.125)], fundedDates: d))
        var missing = bars; missing["gold_cny"] = [.init(date: d[1], price: 100)]
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: missing, fxPoints: fx, fundedDates: d))
    }

    func testFuturePriceFXAndPrefixCannotAlterPriorStateOrTarget() throws {
        let p = prices(12), d = dates(12), cut = 7
        func prep(_ shock: Bool) throws -> Screen.NativePreparation {
            let bars = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { symbol in
                (symbol, d.indices.map { i in Screen.PriceBar(date: d[i], price: p[symbol]![i] * (symbol == "gold_cny" ? 1 : 0.125) * (shock && i >= cut ? 32 : 1)) })
            })
            let fx = (-1..<12).map { Screen.FXPoint(date: first.addingTimeInterval(Double($0) * 86400), usdPerCNY: 0.125 * (shock && $0 >= cut ? 64 : 1)) }
            return try Screen.nativePreparation(barsBySymbol: bars, fxPoints: fx, fundedDates: d)
        }
        let a = try prep(false), b = try prep(true)
        let sa = try Screen.signals(frame: a.frame), sb = try Screen.signals(frame: b.frame)
        XCTAssertEqual(Array(sa.prefix(cut)), Array(sb.prefix(cut)))
        let ra = try Screen.runAccount(preparation: a, signals: sa, role: .candidate)
        let rb = try Screen.runAccount(preparation: b, signals: sb, role: .candidate)
        XCTAssertEqual(Array(ra.decisions.prefix(cut)), Array(rb.decisions.prefix(cut)))
        XCTAssertEqual(ra.decisions[cut].requestedTarget, rb.decisions[cut].requestedTarget)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(Array(ra.simulation.dailyStates.prefix(cut))), try encoder.encode(Array(rb.simulation.dailyStates.prefix(cut))))
        XCTAssertEqual(try Screen.signals(frame: native(p.mapValues { Array($0.prefix(cut)) }).frame), Array(sa.prefix(cut)))
    }

    func testBinaryPriceFXUnitsLeaveCoefficientsAndActualCashInvariant() throws {
        let p = prices(8), a = try native(p), b = try native(p, fxRate: 0.25), c = try native(p.mapValues { $0.map { $0 * 2 } })
        XCTAssertEqual(a.frame.pricesBySymbol, b.frame.pricesBySymbol)
        let sa = try Screen.signals(frame: a.frame)
        XCTAssertEqual(sa, try Screen.signals(frame: b.frame)); XCTAssertEqual(sa, try Screen.signals(frame: c.frame))
        let ra = try Screen.runAccount(preparation: a, signals: sa, role: .candidate), rc = try Screen.runAccount(preparation: c, signals: sa, role: .candidate)
        for (x, y) in zip(ra.simulation.dailyStates, rc.simulation.dailyStates) { XCTAssertEqual(x.portfolioValue, y.portfolioValue) }
        for (x, y) in zip(ra.simulation.trades, rc.simulation.trades) { XCTAssertEqual(x.units, y.units * 2); XCTAssertEqual(x.cashAmount, y.cashAmount) }
    }

    func testDailySettlementUsesOldCashAndNextDayCanReplacePending() throws {
        let prep = try native(constant(6))
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic daily settlement") { c in
            switch c.signalIndex { case 0: return ["sp500": 0.95]; case 1: return ["nasdaq": 1]; default: return ["gold_cny": 1] }
        }
        let trades = run.simulation.trades.filter { $0.date == prep.frame.dates[2] }
        XCTAssertEqual(trades.map(\.assetSymbol), ["sp500", "nasdaq"])
        XCTAssertEqual(trades.map(\.action), [.sell, .buy])
        XCTAssertLessThan(trades[1].cashAmount, 5100)
        XCTAssertFalse(run.decisions[2].completedToday); XCTAssertEqual(run.decisions[2].pendingAfter, ["nasdaq": 1])
        XCTAssertEqual(run.decisions[3].pendingBefore, ["nasdaq": 1]); XCTAssertEqual(run.decisions[3].requestedTarget, ["gold_cny": 1])
        XCTAssertTrue(run.decisions[3].providerCalled)
        XCTAssertEqual(run.simulation.trades.filter { $0.date == prep.frame.dates[3] }.first?.assetSymbol, "nasdaq")
        assertLedger(run, prep)
    }

    func testHeldQuoteWaitThenLatestCashCancellationAndEmptyCompletion() throws {
        let prep = try native(constant(6), closed: ["sp500": [2]])
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic cancel") { c in
            c.signalIndex == 0 ? ["sp500": 1] : c.signalIndex == 1 ? ["nasdaq": 1] : [:]
        }
        XCTAssertFalse(run.decisions[2].completedToday); XCTAssertEqual(run.decisions[2].pendingAfter, ["nasdaq": 1])
        XCTAssertEqual(run.decisions[3].pendingBefore, ["nasdaq": 1]); XCTAssertEqual(run.decisions[3].requestedTarget, [:])
        XCTAssertTrue(run.decisions[3].completedToday); XCTAssertNil(run.decisions[3].pendingAfter)
        XCTAssertFalse(run.simulation.trades.contains { $0.assetSymbol == "nasdaq" })
        XCTAssertTrue(run.decisions[4].completedToday); XCTAssertTrue(run.decisions[5].completedToday)
        XCTAssertEqual(run.completions.map(\.index), [1, 3, 4, 5])
        assertLedger(run, prep)
    }

    func testZeroBandSortedFillsFeesAndMatchedDirectDailyControls() throws {
        let prep = try native(prices(6)), s = try Screen.signals(frame: prep.frame)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for role in [Screen.Role.equal, Screen.Role.cash] {
            let a = try Screen.runAccount(preparation: prep, signals: s, role: role)
            let config = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0, rebalanceBand: 0,
                tradeToBandBoundary: false, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed Cover daily core close control")
            let target = role == .equal ? Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0, 1.0 / 3) }) : [:]
            let b = try XCTUnwrap(BacktestDailySimulator.run(frame: prep.frame, execution: config, provider: .init { _ in target },
                rebalanceDecision: { i, _ in .init(shouldRebalance: i >= 1, refreshOverlay: false) }, executionPricesBySymbol: prep.executionPrices, buyBudgetPolicy: .symbolOrder))
            XCTAssertEqual(try encoder.encode(a.simulation.dailyStates), try encoder.encode(b.dailyStates))
            XCTAssertEqual(a.simulation.trades.count, b.trades.count)
            for (x, y) in zip(a.simulation.trades, b.trades) {
                XCTAssertEqual(x.assetSymbol, y.assetSymbol); XCTAssertEqual(x.action, y.action); XCTAssertEqual(x.price, y.price)
                XCTAssertEqual(x.cashAmount, y.cashAmount); XCTAssertEqual(x.units, y.units); XCTAssertEqual(x.reason, y.reason)
            }
            assertLedger(a, prep)
        }
        let equal = try Screen.runAccount(preparation: prep, signals: s, role: .equal)
        XCTAssertEqual(equal.simulation.trades.prefix(3).map(\.assetSymbol), ["gold_cny", "nasdaq", "sp500"])
        XCTAssertTrue(equal.decisions.dropFirst().allSatisfy(\.providerCalled))
        XCTAssertEqual(Screen.savedControlIDs, ChaikinMoneyFlowScreen.savedControlIDs); XCTAssertEqual(Screen.savedControlIDs.count, 31)
        XCTAssertEqual(Set(Screen.savedControlIDs).count, 31)
        XCTAssertEqual(Screen.candidateID, "cover-q20-three-core-close")
        XCTAssertEqual(Screen.equalID, "equal-core100-cover-daily-close-control")
        XCTAssertEqual(Screen.cashID, "cny-cash-cover-native2001")
    }
}
