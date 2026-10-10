import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class ExponentiatedGradientCoreScreenTests: XCTestCase {
    typealias Screen = ExponentiatedGradientCoreScreen
    private let first = BacktestSeriesAlignment.historicalSeriesDate(from: "2025-12-29")!
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


    func testAuthorUsedEtaAndExactlyOneInitialNormalization() throws {
        XCTAssertEqual(Screen.eta, 0.05); XCTAssertEqual(Screen.sumTolerance, 1e-12)
        let u = Double(1) / Double(3)
        let U = ((0.0 + u) + u) + u
        let initial = try Screen.initialState()
        XCTAssertEqual(initial.p, [u / U, u / U, u / U])
        XCTAssertEqual(try Screen.weightCheck(initial.p).weightSum, 1)
        XCTAssertEqual(Screen.coreSymbols, ["gold_cny", "nasdaq", "sp500"])
    }
    func testIndependentSimpleThreeAssetPublishedExponentialUpdate() throws {
        let previous = Screen.ModelState(p: [0.5,0.25,0.25])
        let m = try Screen.update(previous: previous, x: [1,2,3])
        XCTAssertEqual(m.incomingP, [0.5,0.25,0.25]); XCTAssertEqual(m.priceProducts, [0.5,0.5,0.75])
        XCTAssertEqual(m.growthDenominator, 1.75)
        let expected = [exp(1.0 / 35), exp(2.0 / 35), exp(3.0 / 35)]
        for i in 0..<3 { XCTAssertEqual(m.exponentials[i], expected[i], accuracy: 1e-15) }
        let raw = [0.5 * expected[0],0.25 * expected[1],0.25 * expected[2]]
        let total = ((0.0 + raw[0]) + raw[1]) + raw[2]
        for i in 0..<3 { XCTAssertEqual(m.next.p[i], raw[i] / total, accuracy: 1e-15) }
        XCTAssertGreaterThan(m.next.p[2], 0.25); XCTAssertLessThan(m.next.p[0], 0.5)
        XCTAssertEqual(previous.p, [0.5,0.25,0.25])
    }
    func testLiteralEtaTimesXThenDivisionIsNotEtaTimesGradient() throws {
        let m = try Screen.update(previous: .init(p: [0.5,0.25,0.25]), x: [1,2,3])
        XCTAssertEqual(m.etaProducts, [0.05,0.1,0.05 * 3])
        XCTAssertEqual(m.exponents[2], (0.05 * 3) / 1.75)
        XCTAssertNotEqual(m.exponents[2], 0.05 * (3 / 1.75))
        XCTAssertEqual(m.exponentials[2], exp((0.05 * 3) / 1.75))
    }
    func testOrdinalSumsAndSingleUpdateNormalizationCopy() throws {
        let m = try Screen.update(previous: .init(p: [0.5,0.25,0.25]), x: [1e15,4,4])
        XCTAssertEqual(m.growthDenominator, ((0.0 + m.priceProducts[0]) + m.priceProducts[1]) + m.priceProducts[2])
        XCTAssertEqual(m.normalizationDenominator, ((0.0 + m.rawProducts[0]) + m.rawProducts[1]) + m.rawProducts[2])
        for i in 0..<3 {
            XCTAssertEqual(m.rawProducts[i], m.incomingP[i] * m.exponentials[i])
            XCTAssertEqual(m.next.p[i], m.rawProducts[i] / m.normalizationDenominator)
        }
    }
    func testSumCheckZeroIsLegalAndNeverRescales() throws {
        let p = [0.5,0.25,0.25], check = try Screen.weightCheck(p)
        XCTAssertEqual(check.sumError, 0); XCTAssertTrue(check.sumCheck); XCTAssertEqual(p, [0.5,0.25,0.25])
        XCTAssertThrowsError(try Screen.weightCheck([0.5,0.25,0.25000000001]))
        let close = [0.5,0.25,0.25 + 1e-13]
        XCTAssertNoThrow(try Screen.weightCheck(close)); XCTAssertEqual(close[2], 0.25 + 1e-13)
    }
    func testFlatFullPastModelAndYearBoundaryDoNotReset() throws {
        let prep = try native(prices(7)), s = try Screen.signals(frame: prep.frame)
        XCTAssertEqual(BacktestSeriesAlignment.historicalSeriesDateString(from: s[3].date), "2026-01-01")
        for i in 1..<s.count { XCTAssertEqual(s[i].update?.incomingP, s[i - 1].pNext); XCTAssertEqual(s[i].intervalCount, i) }
        let unequal = Screen.ModelState(p: [0.5,0.25,0.25]), flat = try Screen.update(previous: unequal, x: [1,1,1])
        XCTAssertEqual(flat.next.p, unequal.p)
        XCTAssertEqual(flat.growthDenominator, 1)
    }
    func testPositiveTinyLegAndProviderCleaningCannotFeedLatentModel() throws {
        let m = try Screen.update(previous: .init(p: [1e-300,0.5,0.5]), x: [1,1,1])
        XCTAssertGreaterThan(m.next.p[0], 0)
        let raw = ["gold_cny":1e-300,"nasdaq":0.5,"sp500":0.5]
        XCTAssertEqual(Screen.providerClean(raw)["gold_cny"], 1e-300)
        let over = ["gold_cny":0.5,"nasdaq":0.25,"sp500":0.25 + 1e-13]
        XCTAssertNotEqual(Screen.providerClean(over), over)
        let state = Screen.ModelState(p: [0.5,0.25,0.25 + 1e-13])
        let updated = try Screen.update(previous: state, x: [1,2,3])
        XCTAssertEqual(updated.incomingP, state.p); XCTAssertNotEqual(updated.incomingP[2], Screen.providerClean(over)["sp500"])
    }
    func testStrictNonpositiveNonfiniteAndEveryUnderflowRejectNoFallback() throws {
        for x in [0.0,-0.0,-1,Double.nan,Double.infinity,-Double.infinity] { XCTAssertThrowsError(try Screen.positive(x)) }
        XCTAssertThrowsError(try Screen.multiply(Double.leastNonzeroMagnitude, 0.5))
        XCTAssertThrowsError(try Screen.divide(Double.leastNonzeroMagnitude, 2))
        XCTAssertThrowsError(try Screen.normalize([1e308,Double.leastNonzeroMagnitude,1]))
        XCTAssertThrowsError(try Screen.sum([1e308,1e308,1]))
        XCTAssertThrowsError(try Screen.update(previous: .init(p: [0,0.5,0.5]), x: [1,1,1]))
        XCTAssertThrowsError(try Screen.update(previous: Screen.initialState(), x: [Double.nan,1,1]))
        XCTAssertThrowsError(try Screen.update(previous: Screen.initialState(), x: [Double.leastNonzeroMagnitude,1,1]))
        XCTAssertThrowsError(try Screen.update(previous: Screen.initialState(), x: [1,1]))
    }
    func testLiteralExponentialOverflowAbortsRatherThanStabilizing() throws {
        let previous = Screen.ModelState(p: [1e-8,0.5 - 0.5e-8,0.5 - 0.5e-8])
        XCTAssertThrowsError(try Screen.update(previous: previous, x: [1e8,1,1]))
        XCTAssertEqual(previous.p[0], 1e-8)
    }
    func testSourceModelClockInitialEqualAtOneAndModelOneAtTwo() throws {
        let prep = try native(prices(6)), s = try Screen.signals(frame: prep.frame)
        let run = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        XCTAssertEqual(run.simulation.dailyStates[0].cash, 100000); XCTAssertTrue(run.simulation.dailyStates[0].targetWeights.isEmpty)
        XCTAssertNil(s[0].update)
        XCTAssertEqual(run.decisions[1].signalIndex, 0); XCTAssertEqual(run.decisions[1].requestedTarget, Screen.providerClean(s[0].cleanedTarget))
        XCTAssertEqual(run.decisions[2].signalIndex, 1); XCTAssertEqual(run.decisions[2].requestedTarget, Screen.providerClean(s[1].cleanedTarget))
        XCTAssertTrue(run.decisions.dropFirst().allSatisfy(\.providerCalled)); XCTAssertFalse(run.decisions[0].providerCalled)
        XCTAssertTrue(run.simulation.trades.allSatisfy { $0.date > prep.frame.dates[0] }); assertLedger(run, prep)
    }
    func testEvidenceExplicitBaselineAndCompletedIntervalContract() throws {
        let s = try Screen.signals(frame: native(prices(3)).frame)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let rows = try Screen.signalObjects(s, encoder: encoder)
        let nullable = ["incomingP","x","priceProducts","growthDenominator","etaProducts","exponents","exponentials","rawProducts","normalizationDenominator"]
        for key in nullable { XCTAssertTrue(rows[0][key] is NSNull); XCTAssertFalse(rows[1][key] is NSNull) }
        XCTAssertNil(rows[0]["update"]); XCTAssertEqual(rows[0]["reason"] as? String, "baseline-normalized-equal")
        XCTAssertEqual(rows[1]["reason"] as? String, "sequential-basic-EG005-literal-exponential")
        XCTAssertEqual(rows[1]["incomingP"] as? [Double], s[0].pNext)
        XCTAssertEqual(rows[0]["sumError"] as? Double, 0); XCTAssertEqual(rows[0]["sumCheck"] as? Bool, true)
        XCTAssertEqual((rows[1]["roles"] as? [[String: Any]])?.count, 3)
    }
    private func state(cash: Double = 40, holdings: [String: Double] = ["gold_cny":60], nav: Double = 100,
                       targets: [String: Double] = ["gold_cny":0.6], receivable: Double? = nil) -> BacktestDailyState {
        .init(date: first, targetWeights: targets, cash: cash, holdingsBySymbol: holdings, portfolioValue: nav, distributionReceivable: receivable)
    }
    func testDiagnosticGuardExactlyMatchesOriginalAllClauses() throws {
        let fixtures = [state(), state(nav: 0), state(nav: .infinity), state(cash: -1.1e-8, holdings: ["gold_cny":100.000000011]),
            state(receivable: .infinity), state(nav: 99, receivable: -1), state(nav: 100.0001),
            state(cash: -1e-9, holdings: ["gold_cny":100.000000001]), state(targets: ["gold_cny":-0.1]),
            state(targets: ["gold_cny":.infinity]), state(targets: ["gold_cny":1 + 2e-12]),
            state(targets: ["gold_cny":1 + 1e-12]), state(cash: -1e-8, holdings: ["gold_cny":1e8 + 1e-8], nav: 1e8)]
        for s in fixtures {
            var oldPassed = true, newPassed = true
            do { _ = try DailyScreenOutput.row("fixture", states: [s], trades: [], windows: []) } catch { oldPassed = false }
            do { try Screen.validateAccounting("fixture", states: [s]) } catch { newPassed = false }
            XCTAssertEqual(newPassed, oldPassed)
        }
        XCTAssertThrowsError(try Screen.validateAccounting("fixture", states: []))
        let checked = try Screen.checkedRow("fixture", states: [state()], trades: [], windows: [])
        let original = try DailyScreenOutput.row("fixture", states: [state()], trades: [], windows: [])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(checked), try encoder.encode(original))
    }
    func testFailureDiagnosticFirstStateHasAllRawFieldsAndNonfiniteStrings() throws {
        XCTAssertThrowsError(try Screen.validateAccounting("invalid-fixture", states: [state(nav: .nan),state(nav: 0)])) { error in
            guard let e = error as? BacktestConfigurationError, case .invalidParameter(let message) = e,
                  let start = message.firstIndex(of: "{"), let data = message[start...].data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return XCTFail("missing deterministic JSON") }
            XCTAssertEqual(object["account_id"] as? String, "invalid-fixture"); XCTAssertEqual(object["portfolioValue"] as? String, "NaN")
            XCTAssertEqual((object["clauses"] as? [String: Bool])?.count, 9)
            for key in ["date","cash","receivable","holdingsBySymbol","targetWeights","held","accounting_error","accounting_error_limit","gross","target_sum"] { XCTAssertNotNil(object[key]) }
            XCTAssertEqual((object["clauses"] as? [String: Bool])?["NAV_finite"], false)
        }
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
                tradeToBandBoundary: false, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed EG005 daily core close control")
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
        XCTAssertEqual(Screen.candidateID, "eg005-three-core-daily-next-close")
        XCTAssertEqual(Screen.equalID, "equal-core100-eg005-daily-close-control")
        XCTAssertEqual(Screen.cashID, "cny-cash-eg005-native2001")
    }
    func testRapidAtoBtoAPendingRotationUsesNewestDailyTarget() throws {
        let prep = try native(constant(6), closed: ["sp500": [2]])
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic daily ABA") { c in
            c.signalIndex == 1 ? ["nasdaq": 1] : ["sp500": 1]
        }
        XCTAssertEqual(run.decisions[2].pendingAfter, ["nasdaq": 1]); XCTAssertFalse(run.decisions[2].completedToday)
        XCTAssertEqual(run.decisions[3].pendingBefore, ["nasdaq": 1]); XCTAssertEqual(run.decisions[3].requestedTarget, ["sp500": 1])
        XCTAssertTrue(run.decisions[3].completedToday); XCTAssertFalse(run.simulation.trades.contains { $0.assetSymbol == "nasdaq" })
        assertLedger(run, prep)
    }

    func testFutureFirstEventAndDuplicateSameDailyTargetStillMaintain() throws {
        let prep = try native(constant(6))
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic future first") { c in c.signalIndex < 2 ? [:] : ["gold_cny": 1] }
        XCTAssertFalse(run.decisions[0].shouldRebalance)
        XCTAssertTrue(run.decisions[1].completedToday); XCTAssertTrue(run.decisions[2].completedToday)
        XCTAssertFalse(run.simulation.trades.contains { $0.date < prep.frame.dates[3] })
        XCTAssertEqual(run.decisions[3].requestedTarget, ["gold_cny": 1])
        XCTAssertTrue(run.decisions[4].providerCalled); XCTAssertTrue(run.decisions[5].providerCalled)
        XCTAssertEqual(run.decisions[4].requestedTarget, run.decisions[5].requestedTarget)
        assertLedger(run, prep)
    }

}
