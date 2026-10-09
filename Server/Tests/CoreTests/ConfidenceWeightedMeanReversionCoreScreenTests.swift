import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class ConfidenceWeightedMeanReversionCoreScreenTests: XCTestCase {
    typealias Screen = ConfidenceWeightedMeanReversionCoreScreen
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


    /// Independent original AppendixB form with unexpanded coefficients,
    /// ordinary roots and reciprocal diagonal update; no production helpers.
    func testLiteralNegativeEpsilonLogStdevAndTraceSourceIdentities() throws {
        let mu = [0.25, 0.5, 0.25], d = [0.0625, 0.125, 0.25], x = [0.75, 1.0, 1.5]
        let u = try Screen.update(mu: mu, d: d, x: x)
        let M = zip(mu, x).reduce(0.0) { $0 + $1.0 * $1.1 }
        let S0 = d.reduce(0.0, +), Sx = zip(d, x).reduce(0.0) { $0 + $1.0 * $1.1 }
        let V = zip(d, x).reduce(0.0) { $0 + $1.0 * $1.1 * $1.1 }, xbar = Sx / S0
        let k = (V - xbar * Sx) / (M * M), delta = -0.5 - log(M)
        let a = (k + V * 4 / 2) * (k + V * 4 / 2) - V * V * 16 / 4
        let b = 2 * delta * (k + V * 4 / 2), c = delta * delta - V * 4
        let discriminant = b * b - 4 * a * c
        let lambda = max((-b + sqrt(discriminant)) / (2 * a), (-b - sqrt(discriminant)) / (2 * a), 0)
        let sqrtU = (-lambda * V * 2 + sqrt(lambda * lambda * V * V * 4 + 4 * V)) / 2
        XCTAssertEqual(Screen.phi, 2); XCTAssertEqual(Screen.epsilon, -0.5)
        XCTAssertEqual(u.M, M); XCTAssertEqual(u.delta, delta); XCTAssertNotEqual(u.delta, 0.5 - log(M))
        XCTAssertNotEqual(u.delta, -0.5 - M)
        for (left, right) in [(u.D, V - xbar * Sx), (u.a, a), (u.b, b), (u.c, c), (u.discriminant, discriminant), (u.lambda, lambda), (u.sqrtU, sqrtU)] {
            XCTAssertEqual(left, right, accuracy: 1e-12)
        }
        for i in 0..<3 {
            let diagonal = 1 / (1 / d[i] + 2 * lambda / sqrtU * x[i] * x[i])
            XCTAssertEqual(u.dRaw[i], diagonal, accuracy: 1e-14)
            XCTAssertNotEqual(u.dRaw[i], 1 / (1 / d[i] + 2 * lambda * 2 * x[i] * x[i])) // Var update differs.
            XCTAssertEqual(u.muRaw[i], mu[i] - lambda * d[i] * (x[i] - xbar) / M, accuracy: 1e-14)
            XCTAssertEqual(u.dNext[i], u.dRaw[i] / (9 * u.traceRaw))
        }
        XCTAssertNotEqual(u.dNext.max(), 1.0 / 9) // Algorithm trace, not prose maximum.
    }

    func testAllEqualNaturallyLinearLambdaZeroStillProjectsAndNormalizesTrace() throws {
        let mu = Array(repeating: 1.0 / 3, count: 3), d = Array(repeating: 1.0 / 9, count: 3)
        let u = try Screen.update(mu: mu, d: d, x: [1, 1, 1])
        XCTAssertEqual(u.branch, "linear"); XCTAssertNil(u.q); XCTAssertEqual(u.roots.count, 1)
        XCTAssertEqual(u.D, 0); XCTAssertEqual(u.K, 0); XCTAssertEqual(u.a, 0); XCTAssertEqual(u.lambda, 0)
        XCTAssertEqual(u.meanSteps, [0, 0, 0]); XCTAssertEqual(u.muRaw, mu); XCTAssertEqual(u.dRaw, d)
        XCTAssertEqual(u.sortedOrdinals, [0, 1, 2]); XCTAssertEqual(u.rho, 3)
        XCTAssertNotEqual(u.dNext, d)
        for value in u.dNext { XCTAssertEqual(value, 1.0 / 27, accuracy: 1e-16) }
        XCTAssertEqual(u.traceDenominator, 9 * u.traceRaw)
    }

    func testAllEqualActiveLinearConfidenceChangesWithoutMeanBypass() throws {
        let mu = [0.25, 0.25, 0.5], d = [0.0625, 0.125, 0.25]
        let u = try Screen.update(mu: mu, d: d, x: [0.5, 0.5, 0.5])
        XCTAssertEqual(u.branch, "linear"); XCTAssertEqual(u.D, 0); XCTAssertGreaterThan(u.lambda, 0)
        XCTAssertEqual(u.muNext, mu); XCTAssertEqual(u.meanSteps, [0, 0, 0])
        XCTAssertNotEqual(u.dRaw, d); XCTAssertNotEqual(u.dNext[0] / u.dNext[2], d[0] / d[2])
        XCTAssertTrue(u.dNext.allSatisfy { $0 > 0 && $0.isFinite })
    }

    func testPolynomialQuadraticLinearRepeatedAllzeroAndConstantFailure() throws {
        let quadratic = try Screen.solveMultiplier(a: 1, b: -3, c: 2, discriminant: 1)
        XCTAssertEqual(quadratic.branch, "quadratic-stable-q"); XCTAssertEqual(quadratic.q, 2)
        XCTAssertEqual(quadratic.roots, [2, 1]); XCTAssertEqual(quadratic.lambda, 2)
        let repeated = try Screen.solveMultiplier(a: 1, b: -2, c: 1, discriminant: 0)
        XCTAssertEqual(repeated.branch, "quadratic-repeated-root"); XCTAssertEqual(repeated.roots, [1]); XCTAssertNil(repeated.q)
        let linear = try Screen.solveMultiplier(a: 0, b: -2, c: 4, discriminant: 4)
        XCTAssertEqual(linear.branch, "linear"); XCTAssertEqual(linear.roots, [2]); XCTAssertEqual(linear.lambda, 2)
        XCTAssertEqual(try Screen.solveMultiplier(a: 0, b: 2, c: 4, discriminant: 4).lambda, 0)
        let zero = try Screen.solveMultiplier(a: 0, b: 0, c: 0, discriminant: 0)
        XCTAssertEqual(zero.branch, "all-zero-polynomial"); XCTAssertTrue(zero.roots.isEmpty); XCTAssertEqual(zero.lambda, 0)
        XCTAssertThrowsError(try Screen.solveMultiplier(a: 0, b: 0, c: 1, discriminant: 0))
        XCTAssertThrowsError(try Screen.solveMultiplier(a: 1, b: 0, c: 1, discriminant: -4))
        XCTAssertThrowsError(try Screen.solveMultiplier(a: -1, b: 0, c: 1, discriminant: 4))
        XCTAssertThrowsError(try Screen.solveMultiplier(a: .infinity, b: 0, c: 1, discriminant: 4))
    }

    func testStableRootPreservesCancellationLostRootAndNoNearzeroBranch() throws {
        let r = try Screen.solveMultiplier(a: 1, b: 1e16, c: 1, discriminant: 1e32)
        XCTAssertEqual(r.roots[0], -1e16); XCTAssertEqual(r.roots[1], -1e-16)
        XCTAssertNotEqual(r.roots[1], (-1e16 + sqrt(1e32)) / 2)
        XCTAssertEqual(r.roots[0] * r.roots[1], 1)
        let tinyA = try Screen.solveMultiplier(a: 1e-12, b: -1, c: 0, discriminant: 1)
        XCTAssertEqual(tinyA.branch, "quadratic-stable-q"); XCTAssertEqual(tinyA.lambda, 1e12)
    }

    func testEuclideanProjectionOrdinalTiesKKTLegalZerosAndTinySupport() throws {
        let p = try Screen.project([0.75, 0.75, -0.5])
        XCTAssertEqual(p.sortedOrdinals, [0, 1, 2]); XCTAssertEqual(p.rho, 2); XCTAssertEqual(p.theta, 0.25)
        XCTAssertEqual(p.projected, [0.5, 0.5, 0]); XCTAssertEqual(p.muNext, p.projected)
        XCTAssertEqual(try Screen.project([0.1, 0.9, 0.9]).sortedOrdinals, [1, 2, 0])
        let raw = [1.25, 0.5, -0.25], general = try Screen.project(raw)
        for i in 0..<3 {
            if general.projected[i] > 0 { XCTAssertEqual(raw[i] - general.projected[i], general.theta, accuracy: 1e-15) }
            else { XCTAssertLessThanOrEqual(raw[i], general.theta) }
        }
        let tiny = pow(2.0, -40.0), t = try Screen.project([1 - tiny, tiny, 0])
        XCTAssertEqual(t.muNext, [1 - tiny, tiny, 0]); XCTAssertGreaterThan(t.muNext[1], 0); XCTAssertLessThan(t.muNext[1], 1e-6)
        let clean = Screen.providerClean(Dictionary(uniqueKeysWithValues: zip(Screen.coreSymbols, t.muNext)))
        XCTAssertEqual(clean["nasdaq"], tiny); XCTAssertNil(clean["sp500"])
        XCTAssertEqual(try Screen.project(t.muNext).muNext, t.muNext)
    }

    func testStrictStateUnderflowOverflowAndIllegalProjectionRejectWithoutFallback() throws {
        let mu = [0.25, 0.5, 0.25], d = [0.0625, 0.125, 0.25]
        for x in [[0.0, 1, 1], [-1.0, 1, 1], [Double.nan, 1, 1], [Double.infinity, 1, 1], [Double.leastNonzeroMagnitude, 1, 1], [1e200, 1, 1]] {
            XCTAssertThrowsError(try Screen.update(mu: mu, d: d, x: x))
        }
        XCTAssertThrowsError(try Screen.update(mu: [0, 0, 0], d: d, x: [1, 1, 1]))
        XCTAssertThrowsError(try Screen.update(mu: [-0.1, 0.5, 0.6], d: d, x: [1, 1, 1]))
        XCTAssertThrowsError(try Screen.update(mu: mu, d: [0, 1, 1], x: [1, 1, 1]))
        XCTAssertThrowsError(try Screen.multiply(.leastNonzeroMagnitude, 0.5))
        XCTAssertThrowsError(try Screen.divide(.leastNonzeroMagnitude, 2))
        XCTAssertThrowsError(try Screen.divide(1, 0))
        XCTAssertThrowsError(try Screen.project([.nan, 0, 1]))
        XCTAssertThrowsError(try Screen.project([.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude]))
        XCTAssertEqual(try Screen.multiply(0, 1), 0); XCTAssertEqual(try Screen.divide(0, 2), 0)
    }

    func testSequentialPriceOnlyModelNoNewYearResetAndInitialDualClock() throws {
        let prep = try native(prices(8)), s = try Screen.signals(frame: prep.frame)
        XCTAssertNil(s[0].update); XCTAssertEqual(s[0].reason, "baseline-explicit-equal-prior")
        XCTAssertEqual(s[0].muNext, [1.0 / 3, 1.0 / 3, 1.0 / 3]); XCTAssertEqual(s[0].dNext, [1.0 / 9, 1.0 / 9, 1.0 / 9])
        for i in 1..<s.count {
            XCTAssertEqual(s[i].update!.incomingMu, s[i - 1].muNext)
            XCTAssertEqual(s[i].update!.incomingD, s[i - 1].dNext)
            XCTAssertEqual(s[i].update!.x, Screen.coreSymbols.map { prep.frame.pricesBySymbol[$0]![i] / prep.frame.pricesBySymbol[$0]![i - 1] })
        }
        XCTAssertEqual(BacktestSeriesAlignment.historicalSeriesDateString(from: s[3].date), "2026-01-01")
        XCTAssertEqual(s[3].update!.incomingD, s[2].dNext)
        let run = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        XCTAssertEqual(run.decisions[1].requestedTarget, Screen.providerClean(s[0].cleanedTarget))
        XCTAssertEqual(run.decisions[2].requestedTarget, Screen.providerClean(s[1].cleanedTarget))
        XCTAssertNotEqual(s[0].rawTarget, s[1].rawTarget)
        XCTAssertEqual(s, try Screen.signals(frame: prep.frame)) // Neither genuine ledger nor provider target feeds learned state.
        assertLedger(run, prep)
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
        XCTAssertTrue(run.simulation.trades.filter { $0.action == .buy }.allSatisfy { $0.reason == "fixed CWMR-Stdev core close research" })
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
            XCTAssertEqual(run.decisions[i].pendingAfter, Screen.providerClean(s[i - 1].cleanedTarget))
            XCTAssertEqual(run.decisions[i].lastDidExecuteAfter, Int.min / 2)
        }
        XCTAssertEqual(run.decisions[3].pendingBefore, Screen.providerClean(s[1].cleanedTarget))
        XCTAssertEqual(run.decisions[3].requestedTarget, Screen.providerClean(s[2].cleanedTarget))
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
                tradeToBandBoundary: false, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed CWMR daily core close control")
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
        XCTAssertEqual(Screen.candidateID, "cwmr-stdev-three-core-daily-next-close")
        XCTAssertEqual(Screen.equalID, "equal-core100-cwmr-daily-close-control")
        XCTAssertEqual(Screen.cashID, "cny-cash-cwmr-native2001")
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
