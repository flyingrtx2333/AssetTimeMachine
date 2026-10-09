import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class AnticorrelationCoreScreenTests: XCTestCase {
    typealias Screen = AnticorrelationCoreScreen
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


    func testAnchoredChronologicalMomentsAndExactConstantVariance() throws {
        let w = try Screen.centeredWindow([[2, 0, 5], [4, 2, 5]])
        XCTAssertEqual(w.moments.anchors, [2, 0, 5]); XCTAssertEqual(w.moments.shifts, [1, 1, 0])
        XCTAssertEqual(w.moments.means, [3, 1, 5]); XCTAssertEqual(w.centeredRows, [[-1, -1, 0], [1, 1, 0]])
        XCTAssertEqual(w.moments.squareSums, [2, 2, 0]); XCTAssertEqual(w.moments.variances, [2, 2, 0])
        XCTAssertEqual(w.moments.sigmas, [sqrt(2), sqrt(2), 0])
        let repeated = Array(repeating: [log(1.01), -log(1.03), log(1.07)], count: 30)
        let flat = try Screen.centeredWindow(repeated)
        XCTAssertEqual(flat.moments.means, repeated[0]); XCTAssertEqual(flat.moments.variances, [0, 0, 0])
        XCTAssertTrue(flat.centeredRows.allSatisfy { $0 == [0, 0, 0] })
        let sample = try Screen.centeredWindow([[0, 0, 0], [2, 0, 0], [4, 0, 0]])
        XCTAssertEqual(sample.moments.variances[0], 4); XCTAssertNotEqual(sample.moments.variances[0], 8.0 / 3)
    }

    func testIndependentTwoWindowCovarianceAndEqualMeanDonorTransfers() throws {
        let logs = [[0.0, 2, 3], [2, 0, 3], [2, 0, 4], [0, 2, 4]], q = [0.5, 0.25, 0.25]
        let x = logs.last!.map { exp($0) }
        let e = try Screen.updateExpert(window: 2, previousPortfolio: q, logWealthPrevious: 0, x: x, logRelatives: logs)
        XCTAssertTrue(e.ready); XCTAssertEqual(e.window1Start, 1); XCTAssertEqual(e.window1End, 2)
        XCTAssertEqual(e.window2Start, 3); XCTAssertEqual(e.window2End, 4)
        XCTAssertEqual(e.window1!.means, [1, 1, 3]); XCTAssertEqual(e.window2!.means, [1, 1, 4])
        XCTAssertEqual(e.covarianceSums!, [-2, 2, 0, 2, -2, 0, 0, 0, 0]); XCTAssertEqual(e.covariance!, e.covarianceSums!)
        for (actual, expected) in zip(e.correlations!, [-1.0, 1, 0, 1, -1, 0, 0, 0, 0]) { XCTAssertEqual(actual, expected, accuracy: 1e-14) }
        let n = zip(q, x).map { $0 * $1 }, g = n.reduce(0.0, +), hRaw = n.map { $0 / g }, denom = hRaw.reduce(0.0, +), h = hRaw.map { $0 / denom }
        XCTAssertEqual(e.growth, g); XCTAssertEqual(e.bhat!, h)
        let transfer = try XCTUnwrap(e.transfer)
        XCTAssertTrue(transfer.claimMask[1]); XCTAssertTrue(transfer.claimMask[3]) // Equal means use >=.
        XCTAssertFalse(transfer.claimMask[0]); XCTAssertFalse(transfer.claimMask[4])
        XCTAssertEqual(transfer.rowSums[0], transfer.claims[1]); XCTAssertEqual(transfer.rowSums[1], transfer.claims[3])
        let expectedRaw = [h[1], h[0], h[2]], expectedDenom = expectedRaw.reduce(0.0, +)
        for i in 0..<3 { XCTAssertEqual(e.qNext[i], expectedRaw[i] / expectedDenom) }
        XCTAssertNotEqual(e.qNext[0], q[1]); XCTAssertEqual(e.logWealthNext, log(g))
    }

    func testDiagonalClaimConsumesRowBudgetAndExactEmptyRowRetainsMass() throws {
        let h = [0.5, 0.25, 0.25]
        let t = try Screen.applyTransfers(bhat: h, means2: [0, 0, 0], correlations: [0.5, 0.5, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(t.claims, [0.5, 0.5, 0, 0, 0, 0, 0, 0, 0]); XCTAssertEqual(t.rowSums, [1, 0, 0])
        XCTAssertEqual(t.selfTransfers, [0.25, 0, 0]); XCTAssertEqual(t.retainedMass, [0.25, 0.25, 0.25])
        XCTAssertEqual(t.incomingSums, [0, 0.25, 0]); XCTAssertEqual(t.qNext, [0.25, 0.5, 0.25])
        XCTAssertEqual(t.transfers[0], 0.25); XCTAssertEqual(t.transfers[1], 0.25)
        XCTAssertNotEqual(t.qNext, [0, 0.75, 0.25]) // Removing diagonal changes source budget.
        let zero = try Screen.applyTransfers(bhat: h, means2: [2, 1, 0], correlations: Array(repeating: 0, count: 9))
        XCTAssertEqual(zero.qNext, h); XCTAssertEqual(zero.retainedMass, h)
        XCTAssertEqual(zero.transfers, Array(repeating: 0, count: 9)); XCTAssertEqual(zero.incomingSums, [0, 0, 0])
    }

    func testNegativeOwnCorrelationBonusesAndStrictPositiveClaimPredicate() throws {
        let t = try Screen.applyTransfers(bhat: [0.5, 0.25, 0.25], means2: [2, 1, 0],
            correlations: [-0.5, 0.25, 0, 0.5, -0.25, 0, 0, 0, 0.5])
        XCTAssertEqual(t.claims[1], 1); XCTAssertFalse(t.claimMask[3]); XCTAssertEqual(t.claims[3], 0)
        XCTAssertTrue(t.claimMask[8]); XCTAssertEqual(t.qNext, [0, 0.75, 0.25])
        let tiny = Double.leastNonzeroMagnitude
        let a = try Screen.applyTransfers(bhat: [1, 0, 0], means2: [1, 0, 0],
            correlations: [0, tiny, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(a.claims[1], tiny); XCTAssertEqual(a.qNext, [0, 1, 0]) // No tiny correlation threshold.
    }

    func testEquation3MasksOnlyAppropriateRowAndColumnNotWholeAsset() throws {
        let logs = [[0.0, -1, 0], [0, 1, 0], [-1, 0, 0], [1, 0, 0]]
        let e = try Screen.updateExpert(window: 2, previousPortfolio: [1.0 / 3, 1.0 / 3, 1.0 / 3],
            logWealthPrevious: 0, x: logs.last!.map { exp($0) }, logRelatives: logs)
        XCTAssertEqual(e.window1!.sigmas[0], 0); XCTAssertEqual(e.window2!.sigmas[1], 0)
        XCTAssertEqual(Array(e.correlations!.prefix(3)), [0, 0, 0]); XCTAssertEqual(e.correlations![4], 0)
        XCTAssertFalse(e.zeroVarianceMask![3]); XCTAssertTrue(e.transfer!.claimMask[3])
        XCTAssertGreaterThan(e.qNext[0], e.bhat![0]); XCTAssertEqual(e.qNext[1], 0)
    }

    func testCorrelationDomainClampAndExactZeroNoNearZeroMask() throws {
        let high = try Screen.correlation(covariance: 1.0.nextUp, sigma1: 1, sigma2: 1)
        XCTAssertEqual(high.raw, 1.0.nextUp); XCTAssertEqual(high.value, 1); XCTAssertTrue(high.clamped)
        let low = try Screen.correlation(covariance: (-1.0).nextDown, sigma1: 1, sigma2: 1)
        XCTAssertEqual(low.value, -1); XCTAssertTrue(low.clamped)
        let tiny = try Screen.correlation(covariance: 1e-200, sigma1: 1e-100, sigma2: 1e-100)
        XCTAssertFalse(tiny.zeroVariance); XCTAssertEqual(tiny.value, 1)
        let zero = try Screen.correlation(covariance: 0, sigma1: 0, sigma2: 1)
        XCTAssertEqual(zero.raw, 0); XCTAssertEqual(zero.value, 0); XCTAssertTrue(zero.zeroVariance)
        XCTAssertFalse(zero.clamped)
    }

    func testAll29WarmThresholdsDriftNoResetAcrossYearAndFullFormation() throws {
        let prep = try native(prices(61)), s = try Screen.signals(frame: prep.frame)
        XCTAssertEqual(Screen.windows, Array(2...30)); XCTAssertEqual(s[0].experts.count, 29)
        XCTAssertEqual(s[0].latentTarget, [1.0 / 3, 1.0 / 3, 1.0 / 3]); XCTAssertNil(s[0].mix)
        for index in 1..<61 { for w in 2...30 {
            let e = s[index].experts[w - 2], prev = s[index - 1].experts[w - 2]
            XCTAssertEqual(e.window, w); XCTAssertEqual(e.expertOrdinal, w - 2); XCTAssertEqual(e.ready, index >= 2 * w)
            XCTAssertEqual(e.previousPortfolio, prev.qNext); XCTAssertEqual(e.logWealthPrevious, prev.logWealthNext)
            XCTAssertEqual(e.logWealthNext, prev.logWealthNext + e.logGrowth!)
            if index < 2 * w {
                XCTAssertEqual(e.qNext, e.bhat!); XCTAssertNil(e.window1); XCTAssertNil(e.transfer)
            }
        } }
        XCTAssertTrue(s[4].experts[0].ready); XCTAssertFalse(s[4].experts[1].ready)
        XCTAssertTrue(s[60].experts.allSatisfy(\.ready))
        XCTAssertEqual(s[3].experts[0].previousPortfolio, s[2].experts[0].qNext)
        XCTAssertNotEqual(s[1].experts[0].qNext, s[0].experts[0].qNext)
        var p = constant(3); p["gold_cny"] = [100, 200, 100]
        let warm = try Screen.signals(frame: native(p).frame)
        XCTAssertEqual(warm[1].experts[0].bhat!, [0.5, 0.25, 0.25]); XCTAssertEqual(warm[1].experts[0].qNext, [0.5, 0.25, 0.25])
        for i in 0..<3 { XCTAssertEqual(warm[2].experts[0].qNext[i], 1.0 / 3, accuracy: 1e-15) }
    }

    func testIdealExpertWealthBAHWeightsAndLogShiftNotDailyUniformAverage() throws {
        let portfolios = [[1.0, 0, 0]] + Array(repeating: [0.0, 1, 0], count: 28)
        let wealth = [log(2.0)] + Array(repeating: 0.0, count: 28)
        let m = try Screen.mix(portfolios: portfolios, logWealth: wealth)
        XCTAssertEqual(m.maxOrdinal, 0); XCTAssertEqual(m.scaledWealth[0], 1)
        XCTAssertEqual(m.latentTarget[0], 2.0 / 30, accuracy: 1e-14); XCTAssertEqual(m.latentTarget[1], 28.0 / 30, accuracy: 1e-14)
        XCTAssertEqual(m.latentTarget[2], 0); XCTAssertNotEqual(m.latentTarget[0], 1.0 / 29)
        let shifted = try Screen.mix(portfolios: portfolios, logWealth: wealth.map { $0 + 1000 })
        for i in 0..<3 { XCTAssertEqual(m.latentTarget[i], shifted.latentTarget[i], accuracy: 1e-12) }
        XCTAssertFalse(exp(1000.0).isFinite)
        let tie = try Screen.mix(portfolios: portfolios, logWealth: Array(repeating: 1000, count: 29))
        XCTAssertEqual(tie.maxOrdinal, 0); XCTAssertEqual(tie.scaledDenominator, 29)
        XCTAssertThrowsError(try Screen.mix(portfolios: Array(portfolios.dropLast()), logWealth: wealth))
    }

    func testLegalZeroTinySupportAndStrictUnderflowNonfiniteRejection() throws {
        let tiny = Double.leastNonzeroMagnitude
        let n = try Screen.normalize([0.5, 0.5, tiny]); XCTAssertEqual(n.values[2], tiny)
        XCTAssertEqual(Screen.providerClean(["gold_cny": tiny, "nasdaq": 1])["gold_cny"], tiny)
        XCTAssertEqual(try Screen.multiply(0, tiny), 0); XCTAssertEqual(try Screen.divide(0, 2), 0)
        XCTAssertThrowsError(try Screen.multiply(tiny, 0.5)); XCTAssertThrowsError(try Screen.divide(tiny, 2))
        XCTAssertThrowsError(try Screen.centeredWindow([[-1e-200, 0, 0], [1e-200, 0, 0]]))
        XCTAssertThrowsError(try Screen.correlation(covariance: 0, sigma1: tiny, sigma2: tiny))
        XCTAssertThrowsError(try Screen.normalize([0, 0, 0])); XCTAssertThrowsError(try Screen.normalize([-1, 1, 1]))
        XCTAssertThrowsError(try Screen.normalize([.infinity, 0, 0]))
        XCTAssertThrowsError(try Screen.mix(portfolios: Array(repeating: [tiny, 1, 0], count: 29), logWealth: Array(repeating: 0, count: 29)))
        XCTAssertThrowsError(try Screen.mix(portfolios: Array(repeating: [1, 0, 0], count: 29), logWealth: [0] + Array(repeating: -1000, count: 28)))
        XCTAssertThrowsError(try Screen.updateExpert(window: 2, previousPortfolio: [1, 0, 0], logWealthPrevious: 0, x: [0, 1, 1], logRelatives: [[0, 0, 0]]))
        XCTAssertThrowsError(try Screen.applyTransfers(bhat: [1, 0, 0], means2: [.nan, 0, 0], correlations: Array(repeating: 0, count: 9)))
    }

    func testInitialEqualDeliveryThenInterval1ModelOnlyAtExecution2() throws {
        var p = constant(6); p["gold_cny"] = [100, 200, 100, 200, 100, 200]
        let prep = try native(p), s = try Screen.signals(frame: prep.frame)
        let r = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        XCTAssertEqual(r.simulation.dailyStates.count, 6); XCTAssertFalse(r.decisions[0].shouldRebalance)
        XCTAssertEqual(r.simulation.dailyStates[0].cash, 100000); XCTAssertTrue(r.simulation.dailyStates[0].holdingsBySymbol.isEmpty)
        XCTAssertFalse(r.simulation.trades.contains { $0.date == prep.frame.dates[0] })
        XCTAssertEqual(r.decisions[1].signalIndex, 0); XCTAssertEqual(r.decisions[1].requestedTarget, Screen.providerClean(s[0].cleanedTarget))
        XCTAssertEqual(r.decisions[2].signalIndex, 1); XCTAssertEqual(r.decisions[2].signalDate, prep.frame.dates[1])
        XCTAssertEqual(r.decisions[2].requestedTarget, Screen.providerClean(s[1].cleanedTarget))
        XCTAssertNotEqual(r.decisions[2].requestedTarget, Screen.providerClean(s[2].cleanedTarget))
        XCTAssertTrue(r.decisions.dropFirst().allSatisfy(\.providerCalled)); assertLedger(r, prep)
    }

    func testCompactEvidenceNullsReadyBoundsAndCompleteExpertIdentity() throws {
        let s = try Screen.signals(frame: native(constant(5)).frame)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let objects = try Screen.signalObjects(s, encoder: encoder)
        for key in ["x", "logX", "mix"] { XCTAssertTrue(objects[0][key] is NSNull) }
        let baseline = objects[0]["experts"] as! [[String: Any]], warm = objects[1]["experts"] as! [[String: Any]]
        XCTAssertEqual(baseline.count, 29); XCTAssertEqual(baseline.map { $0["window"] as! Int }, Array(2...30))
        for key in ["previousPortfolio", "growth", "bhat", "window1", "covariance", "transfer"] { XCTAssertTrue(baseline[0][key] is NSNull) }
        for key in ["window1Start", "window1", "correlations", "transfer"] { XCTAssertTrue(warm[0][key] is NSNull) }
        XCTAssertFalse(warm[0]["growth"] is NSNull)
        let formed = objects[4]["experts"] as! [[String: Any]]
        XCTAssertEqual(formed[0]["window1Start"] as? Int, 1); XCTAssertEqual(formed[0]["window2End"] as? Int, 4)
        XCTAssertEqual(formed[0]["reason"] as? String, "formed-ANTICOR-transfer")
        XCTAssertEqual(formed[1]["reason"] as? String, "warm-post-price-drift")
        XCTAssertEqual(s[0].reason, "baseline-explicit-equal-prior"); XCTAssertEqual(s[1].reason, "sequential-ANTI1-all29-price-only")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]))
    }

    func testImmutableBudgetsNonnegativeMassAndIncomingParentheses() throws {
        let h = [0.125, 0.375, 0.5], corr = [0.5, 0.25, 0.25, 0.5, 0.5, 0.5, 0.25, 0.25, 0.5]
        let a = try Screen.applyTransfers(bhat: h, means2: [0, 0, 0], correlations: corr)
        var incoming = Array(repeating: 0.0, count: 3)
        for i in 0..<3 { for j in 0..<3 where j != i { incoming[i] += a.transfers[3 * j + i] } }
        XCTAssertEqual(a.incomingSums, incoming)
        for i in 0..<3 {
            XCTAssertEqual(a.qNextRaw[i], a.retainedMass[i] + incoming[i])
            let out = (0..<3).reduce(0.0) { $0 + a.transfers[3 * i + $1] }
            XCTAssertEqual(out, h[i], accuracy: 1e-15)
            XCTAssertGreaterThanOrEqual(a.qNext[i], 0)
        }
        XCTAssertEqual(a.qNext.reduce(0.0, +), 1, accuracy: 1e-15)
        XCTAssertEqual(a, try Screen.applyTransfers(bhat: h, means2: [0, 0, 0], correlations: corr))
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
                tradeToBandBoundary: false, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed ANTI1 daily core close control")
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
        XCTAssertEqual(Screen.candidateID, "anticor1-three-core-daily-next-close")
        XCTAssertEqual(Screen.equalID, "equal-core100-anticor1-daily-close-control")
        XCTAssertEqual(Screen.cashID, "cny-cash-anticor1-native2001")
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
