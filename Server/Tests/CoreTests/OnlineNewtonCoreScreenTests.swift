import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class OnlineNewtonCoreScreenTests: XCTestCase {
    typealias Screen = OnlineNewtonCoreScreen
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


    func testOriginalDefaultsAndPublishedInitialIdentity() throws {
        XCTAssertEqual(Screen.eta, 0); XCTAssertEqual(Screen.beta, 1); XCTAssertEqual(Screen.delta, 0.125)
        let initial = try Screen.initialState()
        XCTAssertEqual(initial.p, [1.0 / 3, 1.0 / 3, 1.0 / 3])
        XCTAssertEqual(initial.A, [1,0,0,0,1,0,0,0,1]); XCTAssertEqual(initial.b, [0,0,0])
    }
    func testIndependentRationalGradientAndUncenteredCurvature() throws {
        let previous = Screen.ModelState(p: [0.5,0.25,0.25], A: [1,0,0,0,1,0,0,0,1], b: [0,0,0])
        let m = try Screen.update(previous: previous, x: [1,2,3])
        XCTAssertEqual(m.priceProducts, [0.5,0.5,0.75]); XCTAssertEqual(m.growthDenominator, 1.75)
        let g = [4.0 / 7, 8.0 / 7, 12.0 / 7]
        XCTAssertEqual(m.gradient, g)
        let products = [16.0,32,48,32,64,96,48,96,144].map { $0 / 49 }
        for i in 0..<9 {
            XCTAssertEqual(m.outerProducts[i], products[i], accuracy: 1e-14)
            XCTAssertEqual(m.next.A[i], products[i] + (i % 4 == 0 ? 1 : 0), accuracy: 1e-14)
        }
        XCTAssertEqual(m.next.b, [8.0 / 7,16.0 / 7,24.0 / 7]); XCTAssertEqual(m.next.p, m.projection.pNext)
        XCTAssertEqual(previous.A, [1,0,0,0,1,0,0,0,1]) // Input state never mutated.
    }
    func testAllPastFlatReturnsStillAccumulateNoCovarianceFloorOrReset() throws {
        let initial = try Screen.initialState(), one = try Screen.update(previous: initial, x: [1,1,1])
        XCTAssertEqual(one.gradient, [1,1,1]); XCTAssertEqual(one.next.A, [2,1,1,1,2,1,1,1,2]); XCTAssertEqual(one.next.b, [2,2,2])
        let two = try Screen.update(previous: one.next, x: [1,1,1])
        for i in 0..<9 { XCTAssertEqual(two.next.A[i], one.next.A[i] + two.outerProducts[i]) }
        for i in 0..<3 { XCTAssertEqual(two.next.b[i], one.next.b[i] + two.linearIncrements[i]) }
        let s = try Screen.signals(frame: native(constant(6)).frame)
        XCTAssertEqual(s[4].update!.incomingA, s[3].ANext); XCTAssertEqual(s[4].update!.incomingB, s[3].bNext)
        XCTAssertEqual(s[4].date, BacktestSeriesAlignment.historicalSeriesDate(from: "2026-01-02"))
    }
    func testSevenOrderedFacesAndSingletonsHaveNoSolve() throws {
        let p = try Screen.project(A: [1,0,0,0,1,0,0,0,1], b: [0,0,0])
        XCTAssertEqual(p.faces.map(\.mask), Array(1...7)); XCTAssertEqual(p.winningMask, 7); XCTAssertEqual(p.winningOrdinal, 6)
        for (index, count) in [1:1,2:1,3:2,4:1,5:2,6:2,7:3] {
            let f = p.faces[index - 1]; XCTAssertEqual(f.activeIndices.count, count); XCTAssertTrue(f.feasible)
            XCTAssertEqual(f.objective!.Q, 1.0 / Double(count), accuracy: 1e-15)
            if count == 1 {
                XCTAssertEqual(f.status, "singleton-exact-vertex"); XCTAssertNil(f.cholesky); XCTAssertNil(f.u); XCTAssertNil(f.lambda)
                XCTAssertEqual(f.rawWeights[f.activeIndices[0]], 1); XCTAssertEqual(f.rawSum, 1)
            }
        }
        let full = p.faces[6]; XCTAssertEqual(full.u!, [0,0,0]); XCTAssertEqual(full.v!, [1,1,1]); XCTAssertEqual(full.lambda, -1.0 / 3)
        XCTAssertTrue(p.kkt.passed)
    }
    func testSignedAndExactZeroCholeskyAndSubstitution() throws {
        let l = try Screen.cholesky([4,-2,0,-2,5,0,0,0,9], dimension: 3)
        XCTAssertEqual(l.lower, [2,0,0,-1,2,0,0,0,3]); XCTAssertEqual(l.pivots, [2,2,3])
        let x = try Screen.solve(l, rhs: [-2,4,0])
        XCTAssertEqual(x.forward, [-1,1.5,0]); XCTAssertEqual(x.solution, [-0.125,0.75,0])
        let cancelled = try Screen.solve(l, rhs: [0,4,0])
        XCTAssertEqual(cancelled.forward[0], 0)
        XCTAssertEqual(try Screen.sum([1,-1]), 0); XCTAssertEqual(try Screen.multiply(-2,0), 0)
    }
    func testNegativeFaceExcludedWithoutClippingOrSolverRetry() throws {
        let p = try Screen.project(A: [1,0,0,0,1,0,0,0,1], b: [16,0,0])
        XCTAssertEqual(p.winningMask, 1); XCTAssertEqual(p.pNext, [1,0,0])
        let f = p.faces[2]; XCTAssertEqual(f.rawWeights, [1.5,-0.5,0]); XCTAssertFalse(f.feasible)
        XCTAssertEqual(f.status, "outside-face-negative-coordinate"); XCTAssertNil(f.rawSum); XCTAssertNil(f.normalizedWeights); XCTAssertNil(f.objective)
        XCTAssertNotNil(f.uSolve); XCTAssertNotNil(f.vSolve); XCTAssertEqual(p.kkt.positiveSupport, [0]); XCTAssertEqual(p.kkt.zeroSupport, [1,2])
    }
    func testExactBoundaryAndStrictFirstFloatingTie() throws {
        let p = try Screen.project(A: [1,0,0,0,1,0,0,0,1], b: [8,0,0])
        XCTAssertEqual(p.minimumTieMasks, [1,3,5,7]); XCTAssertEqual(p.winningMask, 1); XCTAssertEqual(p.pNext, [1,0,0])
        XCTAssertEqual(p.faces[6].rawWeights, [1,0,0]); XCTAssertTrue(p.faces[6].feasible)
        XCTAssertEqual(p.faces[6].normalizedWeights, [1,0,0]); XCTAssertEqual(p.winningQ, -1)
        XCTAssertTrue(p.kkt.coordinateChecks.allSatisfy { $0 })
    }
    func testEachFeasibleFaceOnceNormalizedWinnerCopiedBitExactly() throws {
        let p = try Screen.project(A: [1.1,0.2,0.3,0.2,2.7,0.4,0.3,0.4,4.3], b: [1.3,0.7,2.4])
        for f in p.faces where f.feasible {
            var denominator = 0.0
            for value in f.rawWeights { denominator += value }
            let reference = f.rawWeights.map { $0 / denominator }
            XCTAssertEqual(f.rawSum, denominator)
            XCTAssertEqual(f.normalizedWeights!.map(\.bitPattern), reference.map(\.bitPattern))
            let q = try Screen.objective(A: [1.1,0.2,0.3,0.2,2.7,0.4,0.3,0.4,4.3], b: [1.3,0.7,2.4], p: reference)
            XCTAssertEqual(f.objective, q)
        }
        XCTAssertEqual(p.pNext.map(\.bitPattern), p.faces[p.winningOrdinal].normalizedWeights!.map(\.bitPattern))
    }
    func testPositiveTinyAndLegalZerosNeverThresholded() throws {
        let tiny = 1e-20
        let n = try Screen.normalize([1,tiny,0]); XCTAssertEqual(n.weights, [1,tiny,0])
        XCTAssertEqual(Screen.providerClean(["gold_cny": 1,"nasdaq": tiny,"sp500": 0]), ["gold_cny": 1,"nasdaq": tiny])
        let p = try Screen.project(A: [1,0,0,0,1,0,0,0,1], b: [8,8e-20,0])
        XCTAssertEqual(p.faces[2].normalizedWeights![1], tiny)
        XCTAssertGreaterThan(p.faces[2].normalizedWeights![1], 0)
    }
    func testWinnerOnlyKKTAndFrozenScaleSumChecks() throws {
        let p = try Screen.project(A: [1,0,0,0,1,0,0,0,1], b: [0,0,0])
        let badVertex = try Screen.winnerKKT(A: [1,0,0,0,1,0,0,0,1], b: [0,0,0], p: [1,0,0])
        XCTAssertFalse(badVertex.passed); XCTAssertTrue(p.kkt.passed) // Losing faces are not vetoes.
        let big = try Screen.winnerKKT(A: [1e12,0,0,0,1e12,0,0,0,1e12], b: [0,0,0], p: [1.0 / 3,1.0 / 3,1.0 / 3])
        for i in 0..<3 {
            let scale = max(1, max(abs(big.h[i]), max(abs(big.d[i]),abs(big.lambda))))
            XCTAssertEqual(big.scales[i], scale); XCTAssertEqual(big.tolerances[i], 1e-9 + 1e-9 * scale)
            XCTAssertEqual(big.residuals[i], (big.h[i] - big.d[i]) + big.lambda)
        }
        let wrongSum = try Screen.winnerKKT(A: [1,0,0,0,1,0,0,0,1], b: [0,0,0], p: [0.3,0.3,0.3])
        XCTAssertFalse(wrongSum.sumCheck); XCTAssertFalse(wrongSum.passed)
    }
    func testStrictSPDNonfiniteAndSignedUnderflowRejectNoFallback() throws {
        XCTAssertThrowsError(try Screen.project(A: Array(repeating: 1, count: 9), b: [0,0,0]))
        XCTAssertThrowsError(try Screen.project(A: [1,0,0,0,Double.infinity,0,0,0,1], b: [0,0,0]))
        XCTAssertThrowsError(try Screen.multiply(-Double.leastNonzeroMagnitude, 0.5))
        XCTAssertThrowsError(try Screen.divide(-Double.leastNonzeroMagnitude, 2))
        XCTAssertThrowsError(try Screen.normalize([2,Double.leastNonzeroMagnitude,0]))
        XCTAssertThrowsError(try Screen.update(previous: Screen.initialState(), x: [Double.leastNonzeroMagnitude,1,1]))
        XCTAssertThrowsError(try Screen.update(previous: Screen.initialState(), x: [0,1,1]))
        XCTAssertThrowsError(try Screen.update(previous: Screen.initialState(), x: [Double.nan,1,1]))
        XCTAssertThrowsError(try Screen.cholesky([1,1,1,1], dimension: 2))
    }
    func testSourceModelClockInitialEqualAtOneAndModelOneAtTwo() throws {
        let prep = try native(prices(6)), s = try Screen.signals(frame: prep.frame)
        let run = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        XCTAssertEqual(run.simulation.dailyStates[0].cash, 100000); XCTAssertTrue(run.simulation.dailyStates[0].targetWeights.isEmpty)
        XCTAssertNil(s[0].update); XCTAssertEqual(s[0].ANext, [1,0,0,0,1,0,0,0,1])
        XCTAssertEqual(run.decisions[1].signalIndex, 0); XCTAssertEqual(run.decisions[1].requestedTarget, Screen.providerClean(s[0].cleanedTarget))
        XCTAssertEqual(run.decisions[2].signalIndex, 1); XCTAssertEqual(run.decisions[2].requestedTarget, Screen.providerClean(s[1].cleanedTarget))
        XCTAssertTrue(run.decisions.dropFirst().allSatisfy(\.providerCalled)); XCTAssertFalse(run.decisions[0].providerCalled)
        XCTAssertTrue(run.simulation.trades.allSatisfy { $0.date > prep.frame.dates[0] }); assertLedger(run, prep)
    }
    func testEvidenceExplicitBaselineAndSingletonNullableContract() throws {
        let s = try Screen.signals(frame: native(constant(3)).frame)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let rows = try Screen.signalObjects(s, encoder: encoder)
        let nullable = ["incomingP","incomingA","incomingB","x","priceProducts","growthDenominator","gradient","outerProducts","linearIncrements","projection"]
        for key in nullable { XCTAssertTrue(rows[0][key] is NSNull) }
        XCTAssertNil(rows[0]["update"]); XCTAssertEqual(rows[0]["reason"] as? String, "baseline-normalized-equal-I-zero")
        let projection = try XCTUnwrap(rows[1]["projection"] as? [String: Any]), faces = try XCTUnwrap(projection["faces"] as? [[String: Any]])
        XCTAssertEqual(faces.count, 7)
        for i in [0,1,3] { for key in ["cholesky","uSolve","vSolve","u","v","sumU","sumV","lambda"] { XCTAssertTrue(faces[i][key] is NSNull) } }
        XCTAssertEqual(rows[1]["incomingA"] as? [Double], s[0].ANext)
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
                tradeToBandBoundary: false, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed ONS daily core close control")
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
        XCTAssertEqual(Screen.candidateID, "ons-three-core-daily-next-close")
        XCTAssertEqual(Screen.equalID, "equal-core100-ons-daily-close-control")
        XCTAssertEqual(Screen.cashID, "cny-cash-ons-native2001")
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
