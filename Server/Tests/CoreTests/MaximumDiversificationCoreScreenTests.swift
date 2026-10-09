import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class MaximumDiversificationCoreScreenTests: XCTestCase {
    typealias Screen = MaximumDiversificationCoreScreen
    private let first = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-01-01")!
    private func dates(_ count: Int) -> [Date] { (0..<count).map { first.addingTimeInterval(Double($0) * 86400) } }
    private func days(_ strings: [String]) -> [Date] { strings.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! } }
    private func prices(_ count: Int) -> [String: [Double]] {
        let periods = [2, 3, 5]
        return Dictionary(uniqueKeysWithValues: Screen.coreSymbols.enumerated().map { leg, symbol in
            var result = [100.0]
            for i in 1..<count {
                let r = Double(i % periods[leg] - periods[leg] / 2) * Double(leg + 1) / 512
                result.append(result.last! * (1 + r))
            }
            return (symbol, result)
        })
    }
    private func native(_ p: [String: [Double]], dates supplied: [Date]? = nil,
                        closed: [String: Set<Int>] = [:], fxRate: Double = 0.125) throws -> Screen.NativePreparation {
        let d = supplied ?? dates(p["gold_cny"]!.count)
        let bars = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { symbol in
            (symbol, d.indices.filter { !(closed[symbol]?.contains($0) ?? false) }.map {
                Screen.PriceBar(date: d[$0], price: p[symbol]![$0] * (symbol == "gold_cny" ? 1 : fxRate))
            })
        })
        let fx = d.map { Screen.FXPoint(date: $0.addingTimeInterval(-86400), usdPerCNY: fxRate) }
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


    func testPaperTwoAndThreeAssetExamplesAndDiversificationMapping() throws {
        let two = try Screen.optimize(covariance: [[0.15 * 0.15, 0.15 * 0.30 * 0.5], [0.15 * 0.30 * 0.5, 0.30 * 0.30]])
        XCTAssertEqual(two.weights[0], 2.0 / 3, accuracy: 1e-14)
        XCTAssertEqual(two.weights[1], 1.0 / 3, accuracy: 1e-14)
        let v = [[1.0, 0.9, 0.1], [0.9, 1.0, 0.1], [0.1, 0.1, 1.0]]
        let three = try Screen.optimize(covariance: v)
        for (actual, expected) in zip(three.weights, [9.0 / 35, 9.0 / 35, 17.0 / 35]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-14)
        }
        let h = zip(three.weights, three.sigma).reduce(0.0) { $0 + $1.0 * $1.1 }
        var variance = 0.0
        for i in 0..<3 { for j in 0..<3 { variance += three.weights[i] * three.weights[j] * v[i][j] } }
        XCTAssertEqual(h / sqrt(variance), 1 / sqrt(three.winningQ), accuracy: 1e-14)
    }

    func testSevenFacesScalarOrderKKTAndOffDiagonalEffect() throws {
        let v = [[4.0, 1.0, -0.5], [1.0, 9.0, 1.5], [-0.5, 1.5, 16.0]]
        let o = try Screen.optimize(covariance: v)
        XCTAssertEqual(o.faces.map(\.mask), Array(1...7))
        for face in o.faces {
            XCTAssertEqual(face.activeIndices, (0..<3).filter { face.mask & (1 << $0) != 0 })
            for row in face.activeIndices.indices {
                var scalar = 0.0
                for col in face.activeIndices.indices { scalar += o.correlation[face.activeIndices[row]][face.activeIndices[col]] * face.z[col] }
                XCTAssertEqual(scalar, 1, accuracy: 1e-14)
            }
            if let s = face.s {
                var q = 0.0
                for i in 0..<3 { for j in 0..<3 { q += s[i] * s[j] * o.correlation[i][j] } }
                XCTAssertEqual(q, face.q)
            }
        }
        for i in 0..<3 {
            var derivative = 0.0
            for j in 0..<3 { derivative += o.correlation[i][j] * o.winningS[j] }
            if o.winningS[i] > 0 { XCTAssertEqual(derivative, o.winningQ, accuracy: 1e-14) }
            else { XCTAssertGreaterThanOrEqual(derivative + 1e-14, o.winningQ) }
        }
        let independent = try Screen.optimize(covariance: [[4, 0, 0], [0, 9, 0], [0, 0, 16]])
        XCTAssertNotEqual(o.weights, independent.weights)
        XCTAssertEqual(o, try Screen.optimize(covariance: v))
    }

    func testNegativeStationaryFaceSkippedAndExactBoundaryFirstTie() throws {
        let negative = try Screen.optimize(covariance: [[1, 0, 0.625], [0, 1, 0.625], [0.625, 0.625, 1]])
        let full = try XCTUnwrap(negative.faces.last)
        XCTAssertFalse(full.feasible); XCTAssertEqual(full.status, "negative-stationary-face-skipped")
        XCTAssertLessThan(full.z[2], 0); XCTAssertNil(full.s); XCTAssertNil(full.q)
        XCTAssertEqual(negative.winningMask, 3); XCTAssertEqual(negative.weights, [0.5, 0.5, 0])
        let tie = try Screen.optimize(covariance: [[1, 0, 0.5], [0, 1, 0.5], [0.5, 0.5, 1]])
        XCTAssertEqual(tie.faces[2].q, tie.faces[6].q)
        XCTAssertEqual(tie.faces[6].z[2], 0)
        XCTAssertEqual(tie.winningMask, 3); XCTAssertEqual(tie.weights, [0.5, 0.5, 0])
        XCTAssertEqual(Screen.providerClean(["gold_cny": 0.5, "nasdaq": 0.5, "sp500": 0]), ["gold_cny": 0.5, "nasdaq": 0.5])
    }

    func testStrictSPDFailureNonfiniteAndUnderflowNoFallbackTinyPositivePreserved() throws {
        for v in [[[0.0, 0, 0], [0, 1, 0], [0, 0, 1]], [[1.0, 1, 0], [1, 1, 0], [0, 0, 1]],
                  [[1.0, 2, 0], [2, 1, 0], [0, 0, 1]], [[Double.infinity, 0, 0], [0, 1, 0], [0, 0, 1]],
                  [[1.0, Double.nan, 0], [Double.nan, 1, 0], [0, 0, 1]]] {
            XCTAssertThrowsError(try Screen.optimize(covariance: v))
        }
        // A nonzero off-diagonal divided by this finite Cholesky diagonal becomes
        // zero: reject that loss rather than treating it as an independent asset.
        XCTAssertThrowsError(try Screen.cholesky([[1e300, Double.leastNonzeroMagnitude], [Double.leastNonzeroMagnitude, 1]]))
        let small = try Screen.optimize(covariance: [[1, 0, 0], [0, 1e20, 0], [0, 0, 4]])
        XCTAssertGreaterThan(small.weights[1], 0); XCTAssertLessThan(small.weights[1], 1e-6)
        let clean = Screen.providerClean(Dictionary(uniqueKeysWithValues: zip(Screen.coreSymbols, small.weights)))
        XCTAssertEqual(clean["nasdaq"], small.weights[1])
        XCTAssertThrowsError(try Screen.signals(frame: native(constant(280)).frame))
    }

    func testExact250SimpleSample249ChronologicalCovarianceAndReviewOnly() throws {
        let prep = try native(prices(310)), s = try Screen.signals(frame: prep.frame)
        let review = try XCTUnwrap(s.first { $0.reason == "formed250-strictSPD-MDP" })
        XCTAssertEqual(review.signalIndex, 272); XCTAssertEqual(review.evaluationIndex, 273)
        XCTAssertEqual(review.priceStartIndex, 22); XCTAssertEqual(review.returnStartIndex, 23)
        var reference: [[Double]] = []
        for symbol in Screen.coreSymbols {
            reference.append((23...272).map { prep.frame.pricesBySymbol[symbol]![$0] / prep.frame.pricesBySymbol[symbol]![$0 - 1] - 1 })
        }
        XCTAssertEqual(review.returns, reference)
        let means = reference.map { $0.reduce(0.0, +) / 250 }
        XCTAssertEqual(review.means, means)
        for i in 0..<3 { for j in 0..<3 {
            var sum = 0.0
            for t in 0..<250 { sum += (reference[i][t] - means[i]) * (reference[j][t] - means[j]) }
            XCTAssertEqual(review.covarianceSums![i][j], sum)
            XCTAssertEqual(review.covariance![i][j], sum / 249)
            if i == j { XCTAssertNotEqual(review.covariance![i][j], sum / 250) }
        } }
        XCTAssertNotEqual(reference[0][1], log(prep.frame.pricesBySymbol["gold_cny"]![24] / prep.frame.pricesBySymbol["gold_cny"]![23]))
        for row in s where !row.isMonthlyReview {
            XCTAssertEqual(row.reason, "not-month-end-review"); XCTAssertNil(row.covariance)
            XCTAssertTrue(row.faces.isEmpty); XCTAssertTrue(row.returns.isEmpty); XCTAssertTrue(row.rawTarget.isEmpty)
        }
        XCTAssertFalse(s.last!.isMonthlyReview); XCTAssertNil(s.last!.evaluationDate)
    }

    func testFundedCashFormationCalendarYearAndPartialCutoffPreserved() throws {
        let prep = try native(prices(280)), s = try Screen.signals(frame: prep.frame)
        for role in [Screen.Role.candidate, Screen.Role.equal, Screen.Role.cash] {
            let run = try Screen.runAccount(preparation: prep, signals: s, role: role)
            XCTAssertEqual(run.simulation.dailyStates.count, 280)
            XCTAssertEqual(run.simulation.dailyStates.first?.portfolioValue, 100000)
            XCTAssertFalse(run.simulation.trades.contains { $0.date < prep.frame.dates[273] })
            XCTAssertFalse(run.decisions[250].providerCalled)
            XCTAssertTrue(run.decisions[243].scheduledReview) // September1, still forming.
            XCTAssertEqual(run.decisions[243].requestedTarget, [:]); XCTAssertTrue(run.decisions[243].completedToday)
            if role != .cash { XCTAssertFalse(run.decisions[273].requestedTarget!.isEmpty) }
            assertLedger(run, prep)
        }
        let y = days(["2025-12-31", "2026-01-01", "2026-01-02"])
        XCTAssertTrue(Screen.monthChanged(y[0], y[1])); XCTAssertFalse(Screen.monthChanged(y[1], y[2]))
        let short = try Screen.signals(frame: native(constant(3), dates: y).frame)
        XCTAssertTrue(short[0].isMonthlyReview); XCTAssertEqual(short[0].reason, "formation-cash")
        XCTAssertFalse(short[2].isMonthlyReview)
    }

    func testMonthlySettlementUsesOldCashSameMonthlySignalTransportThenStops() throws {
        let d = days(["2026-01-31", "2026-02-01", "2026-02-02", "2026-02-28", "2026-03-01", "2026-03-02", "2026-03-03", "2026-03-04"])
        let prep = try native(constant(d.count), dates: d)
        var deliveries: [Int] = []
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic monthly settlement") { signal in
            deliveries.append(signal)
            return signal == 0 ? ["sp500": 0.95] : ["nasdaq": 1]
        }
        XCTAssertFalse(run.decisions[0].providerCalled); XCTAssertTrue(run.decisions[1].completedToday)
        XCTAssertFalse(run.decisions[2].shouldRebalance); XCTAssertFalse(run.decisions[3].shouldRebalance)
        let trades = run.simulation.trades.filter { $0.date == d[4] }
        XCTAssertEqual(trades.map(\.assetSymbol), ["sp500", "nasdaq"]); XCTAssertEqual(trades.map(\.action), [.sell, .buy])
        XCTAssertLessThan(trades[1].cashAmount, 5200)
        XCTAssertFalse(run.decisions[4].completedToday); XCTAssertTrue(run.decisions[5].transportOnly)
        XCTAssertEqual(run.decisions[5].signalIndex, 4); XCTAssertEqual(run.decisions[5].deliverySignalIndex, 3)
        XCTAssertEqual(run.decisions[5].requestedTarget, ["nasdaq": 1]); XCTAssertTrue(run.decisions[5].completedToday)
        XCTAssertEqual(deliveries, [0, 3, 3])
        XCTAssertFalse(run.decisions[6].shouldRebalance); XCTAssertFalse(run.decisions[7].shouldRebalance)
        assertLedger(run, prep)
    }

    func testClosedHeldMarketAndNewMonthlyAtoBtoAReplacesPending() throws {
        let d = days(["2026-01-31", "2026-02-01", "2026-02-28", "2026-03-01", "2026-03-31", "2026-04-01", "2026-04-02"])
        let prep = try native(constant(d.count), dates: d, closed: ["sp500": [3, 4]])
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic monthly A B A") { signal in
            signal == 2 ? ["nasdaq": 1] : ["sp500": 1]
        }
        XCTAssertEqual(run.decisions[3].pendingAfter, ["nasdaq": 1]); XCTAssertFalse(run.decisions[3].completedToday)
        XCTAssertTrue(run.decisions[4].transportOnly); XCTAssertEqual(run.decisions[4].deliverySignalIndex, 2)
        XCTAssertEqual(run.decisions[5].pendingBefore, ["nasdaq": 1]); XCTAssertTrue(run.decisions[5].scheduledReview)
        XCTAssertEqual(run.decisions[5].requestedTarget, ["sp500": 1]); XCTAssertTrue(run.decisions[5].completedToday)
        XCTAssertFalse(run.simulation.trades.contains { $0.assetSymbol == "nasdaq" })
        XCTAssertFalse(run.decisions[6].shouldRebalance)
        assertLedger(run, prep)
    }

    func testCashExitReplacesPendingAtNewMonthAndDuplicateMonthlyCashCompletes() throws {
        let d = days(["2026-01-31", "2026-02-01", "2026-02-28", "2026-03-01", "2026-03-31", "2026-04-01", "2026-04-02", "2026-05-01", "2026-05-02"])
        let prep = try native(constant(d.count), dates: d, closed: ["sp500": [3, 4]])
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic monthly cash cancel") { signal in
            signal == 0 ? ["sp500": 1] : signal == 2 ? ["nasdaq": 1] : [:]
        }
        XCTAssertEqual(run.decisions[5].pendingBefore, ["nasdaq": 1]); XCTAssertEqual(run.decisions[5].requestedTarget, [:])
        XCTAssertTrue(run.decisions[5].completedToday); XCTAssertNil(run.decisions[5].pendingAfter)
        XCTAssertEqual(run.simulation.trades.filter { $0.date == d[5] }.map(\.action), [.sell])
        XCTAssertFalse(run.simulation.trades.contains { $0.assetSymbol == "nasdaq" })
        XCTAssertFalse(run.decisions[6].shouldRebalance); XCTAssertTrue(run.decisions[7].scheduledReview)
        XCTAssertTrue(run.decisions[7].completedToday); XCTAssertEqual(run.decisions[7].requestedTarget, [:])
        XCTAssertFalse(run.decisions[8].shouldRebalance)
        assertLedger(run, prep)
    }

    func testFirstFutureMonthlyEventQuoteWaitAndNoIntraMonthRebalance() throws {
        let d = days(["2026-01-29", "2026-01-30", "2026-01-31", "2026-02-01", "2026-02-02", "2026-02-03", "2026-02-04"])
        let prep = try native(constant(d.count), dates: d, closed: ["nasdaq": [3, 4]])
        let run = try Screen.simulate(preparation: prep, buyReason: "synthetic future monthly") { _ in ["nasdaq": 1] }
        XCTAssertTrue(run.decisions.prefix(3).allSatisfy { !$0.providerCalled && $0.latestMonthlySignalIndexAfter == nil })
        XCTAssertEqual(run.decisions[3].deliverySignalIndex, 2); XCTAssertFalse(run.decisions[3].completedToday)
        XCTAssertEqual(run.decisions[4].deliverySignalIndex, 2); XCTAssertTrue(run.decisions[4].transportOnly)
        XCTAssertTrue(run.decisions[5].completedToday); XCTAssertFalse(run.decisions[6].shouldRebalance)
        XCTAssertEqual(run.simulation.trades.first?.date, d[5])
        assertLedger(run, prep)
    }

    func testStrictPriorFXOnceActualCloseAndCarryCannotExecute() throws {
        let d = dates(3)
        let bars = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { symbol in
            (symbol, [Screen.PriceBar(date: d[0], price: symbol == "gold_cny" ? 100 : 10), .init(date: d[2], price: symbol == "gold_cny" ? 110 : 12)])
        })
        let fx = [Screen.FXPoint(date: first.addingTimeInterval(-86400), usdPerCNY: 0.125), .init(date: d[0], usdPerCNY: 0.25), .init(date: d[2], usdPerCNY: 1)]
        let prep = try Screen.nativePreparation(barsBySymbol: bars, fxPoints: fx, fundedDates: d)
        XCTAssertEqual(prep.frame.pricesBySymbol["nasdaq"], [80, 80, 48])
        let q = prep.quotes.filter { $0.symbol == "nasdaq" }
        XCTAssertEqual(q[0].fxDate, first.addingTimeInterval(-86400)); XCTAssertEqual(q[1].fxDate, q[0].fxDate)
        XCTAssertFalse(q[1].quoteToday); XCTAssertEqual(q[1].executionPrice, 0); XCTAssertEqual(q[2].fxDate, d[0])
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: bars, fxPoints: [.init(date: d[0], usdPerCNY: 0.125)], fundedDates: d))
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: bars, fxPoints: [.init(date: first.addingTimeInterval(-15 * 86400), usdPerCNY: 0.125)], fundedDates: d))
    }

    func testFuturePriceFXAndPrefixKeepAlreadyKnownMonthlyTargetsAndStates() throws {
        let p = prices(330), d = dates(330), cut = 300
        func prep(_ shock: Bool) throws -> Screen.NativePreparation {
            let bars = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { symbol in
                (symbol, d.indices.map { i in Screen.PriceBar(date: d[i], price: p[symbol]![i] * (symbol == "gold_cny" ? 1 : 0.125) * (shock && i >= cut ? 4 : 1)) })
            })
            let fx = (-1..<330).map { Screen.FXPoint(date: first.addingTimeInterval(Double($0) * 86400), usdPerCNY: 0.125 * (shock && $0 >= cut ? 2 : 1)) }
            return try Screen.nativePreparation(barsBySymbol: bars, fxPoints: fx, fundedDates: d)
        }
        let a = try prep(false), b = try prep(true), sa = try Screen.signals(frame: a.frame), sb = try Screen.signals(frame: b.frame)
        XCTAssertEqual(Array(sa.prefix(cut)), Array(sb.prefix(cut)))
        let ra = try Screen.runAccount(preparation: a, signals: sa, role: .candidate), rb = try Screen.runAccount(preparation: b, signals: sb, role: .candidate)
        XCTAssertEqual(Array(ra.decisions.prefix(cut)), Array(rb.decisions.prefix(cut)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(Array(ra.simulation.dailyStates.prefix(cut))), try encoder.encode(Array(rb.simulation.dailyStates.prefix(cut))))
        let prefix = try native(p.mapValues { Array($0.prefix(cut)) })
        XCTAssertEqual(try Screen.signals(frame: prefix.frame), Array(sa.prefix(cut)))
        let rp = try Screen.runAccount(preparation: prefix, signals: Array(sa.prefix(cut)), role: .candidate)
        XCTAssertEqual(try encoder.encode(rp.simulation.dailyStates), try encoder.encode(Array(ra.simulation.dailyStates.prefix(cut))))
    }

    func testBinaryPriceFXUnitsPreserveMathAndActualLedger() throws {
        let p = prices(280), a = try native(p), b = try native(p, fxRate: 0.25), c = try native(p.mapValues { $0.map { $0 * 2 } })
        let sa = try Screen.signals(frame: a.frame)
        XCTAssertEqual(a.frame.pricesBySymbol, b.frame.pricesBySymbol)
        XCTAssertEqual(sa, try Screen.signals(frame: b.frame)); XCTAssertEqual(sa, try Screen.signals(frame: c.frame))
        let ra = try Screen.runAccount(preparation: a, signals: sa, role: .candidate), rc = try Screen.runAccount(preparation: c, signals: sa, role: .candidate)
        for (x, y) in zip(ra.simulation.dailyStates, rc.simulation.dailyStates) { XCTAssertEqual(x.portfolioValue, y.portfolioValue) }
        for (x, y) in zip(ra.simulation.trades, rc.simulation.trades) { XCTAssertEqual(x.units, y.units * 2); XCTAssertEqual(x.cashAmount, y.cashAmount) }
        assertLedger(ra, a); assertLedger(rc, c)
    }

    func testEqualAndCashControlsAgainstDirectMonthlySharedSimulatorAndFixedIDs() throws {
        let prep = try native(prices(280)), s = try Screen.signals(frame: prep.frame)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for role in [Screen.Role.equal, Screen.Role.cash] {
            let a = try Screen.runAccount(preparation: prep, signals: s, role: role)
            let config = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0, rebalanceBand: 0,
                tradeToBandBoundary: false, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed MDP monthend core close control")
            let equal = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0, 1.0 / 3) })
            let b = try XCTUnwrap(BacktestDailySimulator.run(frame: prep.frame, execution: config,
                provider: .init { c in role == .equal && c.signalIndex >= 250 ? equal : [:] },
                rebalanceDecision: { i, _ in .init(shouldRebalance: i >= 1 && Screen.monthChanged(prep.frame.dates[i - 1], prep.frame.dates[i]), refreshOverlay: false) },
                executionPricesBySymbol: prep.executionPrices, buyBudgetPolicy: .symbolOrder))
            XCTAssertEqual(try encoder.encode(a.simulation.dailyStates), try encoder.encode(b.dailyStates))
            XCTAssertEqual(a.simulation.trades.count, b.trades.count)
            for (x, y) in zip(a.simulation.trades, b.trades) {
                XCTAssertEqual(x.assetSymbol, y.assetSymbol); XCTAssertEqual(x.action, y.action); XCTAssertEqual(x.price, y.price)
                XCTAssertEqual(x.units, y.units); XCTAssertEqual(x.cashAmount, y.cashAmount); XCTAssertEqual(x.reason, y.reason)
            }
            assertLedger(a, prep)
        }
        let equal = try Screen.runAccount(preparation: prep, signals: s, role: .equal)
        XCTAssertEqual(equal.simulation.trades.prefix(3).map(\.assetSymbol), ["gold_cny", "nasdaq", "sp500"])
        XCTAssertFalse(equal.decisions.last!.shouldRebalance)
        XCTAssertEqual(Screen.savedControlIDs, ChaikinMoneyFlowScreen.savedControlIDs); XCTAssertEqual(Screen.savedControlIDs.count, 31)
        XCTAssertEqual(Set(Screen.savedControlIDs).count, 31)
        XCTAssertEqual(Screen.candidateID, "mdp250-three-core-monthend-close")
        XCTAssertEqual(Screen.equalID, "equal-core100-mdp-monthend-close-control")
        XCTAssertEqual(Screen.cashID, "cny-cash-mdp-native2001")
    }
}
