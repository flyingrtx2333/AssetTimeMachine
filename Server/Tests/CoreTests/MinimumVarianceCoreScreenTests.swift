import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class MinimumVarianceCoreScreenTests: XCTestCase {
    typealias Screen = MinimumVarianceCoreScreen
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

    func testHandSimpleReturnsAndAllNineSampleCovariances() throws {
        var p = constant(65)
        p["gold_cny"] = (0..<65).map { $0 % 2 == 0 ? 100 : 125 }
        p["nasdaq"] = (0..<65).map { $0 % 2 == 0 ? 100 : 90 }
        p["sp500"] = (0..<65).map { $0 % 2 == 0 ? 100 : 100.125 }
        let s = try Screen.signals(frame: native(p).frame)
        XCTAssertTrue(s.prefix(63).allSatisfy { $0.cleanedTarget.isEmpty && $0.gridVariances.isEmpty && $0.covariance == nil })
        XCTAssertEqual(s[19].reason, "early-guard-cash"); XCTAssertEqual(s[20].reason, "undefined63-returns")
        let r = [[125.0 / 100 - 1, 100.0 / 125 - 1], [90.0 / 100 - 1, 100.0 / 90 - 1], [100.125 / 100 - 1, 100 / 100.125 - 1]]
        let means = r.map { (32 * $0[0] + 31 * $0[1]) / 63 }
        for i in 0..<3 {
            XCTAssertEqual(s[63].roles[i].returnCount, 63)
            XCTAssertEqual(Array(s[63].roles[i].returns.prefix(2)), r[i])
            XCTAssertEqual(s[63].roles[i].mean!, means[i], accuracy: 1e-15)
            for j in 0..<3 {
                let sum = 32 * (r[i][0] - means[i]) * (r[j][0] - means[j]) + 31 * (r[i][1] - means[i]) * (r[j][1] - means[j])
                XCTAssertEqual(s[63].covarianceSums![i][j], sum, accuracy: 1e-13)
                XCTAssertEqual(s[63].covariance![i][j], sum / 62, accuracy: 1e-15)
            }
        }
        XCTAssertLessThan(s[63].covariance![0][1], 0)
        XCTAssertNotEqual(s[63].roles[0].mean!, (32 * log(1.25) + 31 * log(0.8)) / 63)
        XCTAssertNotEqual(s[63].covariance![0][0], s[63].covarianceSums![0][0] / 63)
        XCTAssertNotEqual(s[63].covariance![0][0], s[63].covarianceSums![0][0] / 62 * 252)
        XCTAssertNil(s[62].priceStartIndex); XCTAssertEqual(s[63].priceStartIndex, 0)
        XCTAssertEqual(s[63].returnStartIndex, 1); XCTAssertEqual(s[63].windowEndIndex, 63)
    }

    func testOffDiagonalRiskChangesOptimalAllocation() throws {
        let diagonal = try Screen.gridEvaluation(covariance: [[1, 0, 0], [0, 1, 0], [0, 0, 4]])
        let cross = try Screen.gridEvaluation(covariance: [[1, -0.9, 0], [-0.9, 1, 0], [0, 0, 4]])
        XCTAssertEqual(diagonal.winningWeights, [0.45, 0.45, 0.1])
        XCTAssertEqual(cross.winningWeights, [0.5, 0.5, 0])
        XCTAssertNotEqual(diagonal.winningOrdinal, cross.winningOrdinal)
        XCTAssertEqual(cross.winningVariance, 0.05, accuracy: 1e-15)
    }

    func testFixedGridOrderNineTermAccumulationAndFirstActualTie() throws {
        let covariance = [[0.125, -0.0625, 0.03125], [-0.0625, 0.25, -0.015625], [0.03125, -0.015625, 0.5]]
        let grid = try Screen.gridEvaluation(covariance: covariance)
        XCTAssertEqual(grid.gridVariances.count, 231)
        XCTAssertEqual(grid.gridVariances[0], 0.5)
        XCTAssertEqual(grid.gridVariances[20], 0.25)
        XCTAssertEqual(grid.gridVariances[230], 0.125)
        // Ordinal 21 is gi=1,ni=0,si=19; fixed left-associated 9 terms.
        let w = [0.05, 0.0, 0.95]
        let terms = [w[0] * w[0] * covariance[0][0], w[0] * w[1] * covariance[0][1], w[0] * w[2] * covariance[0][2],
            w[1] * w[0] * covariance[1][0], w[1] * w[1] * covariance[1][1], w[1] * w[2] * covariance[1][2],
            w[2] * w[0] * covariance[2][0], w[2] * w[1] * covariance[2][1], w[2] * w[2] * covariance[2][2]]
        XCTAssertEqual(grid.gridVariances[21], terms.reduce(0, +))
        XCTAssertEqual(grid.winningOrdinal, grid.minimumTieOrdinals.first)
        XCTAssertEqual(grid.winningVariance, grid.gridVariances.min())
        XCTAssertEqual(grid.winningSI, 20 - grid.winningGI - grid.winningNI)
        XCTAssertEqual(grid.winningWeights, [Double(grid.winningGI) / 20, Double(grid.winningNI) / 20, Double(grid.winningSI) / 20])
        // Zero-variance gold/Nasdaq vertices are an exact non-global-flat tie.
        let tied = try Screen.gridEvaluation(covariance: [[0, 0, 0], [0, 0, 0], [0, 0, 1]])
        XCTAssertEqual(tied.winningOrdinal, 20); XCTAssertEqual(tied.winningWeights, [0, 1, 0])
        XCTAssertEqual(tied.minimumTieOrdinals.first, 20); XCTAssertEqual(tied.minimumTieOrdinals.last, 230)
    }

    func testNegativeRiskIsNotClampedAndSmallRiskHasNoFloor() throws {
        let negative = try Screen.gridEvaluation(covariance: [[-2, 0, 0], [0, 1, 0], [0, 0, 1]])
        XCTAssertEqual(negative.winningOrdinal, 230); XCTAssertEqual(negative.winningVariance, -2)
        let small = [[1e-12, 0.0, 0.0], [0.0, 4e-12, 0.0], [0.0, 0.0, 4e-12]]
        let a = try Screen.gridEvaluation(covariance: small)
        let b = try Screen.gridEvaluation(covariance: small.map { $0.map { $0 * 1048576 } })
        XCTAssertGreaterThan(a.winningWeights[0], 0.6)
        XCTAssertEqual(a.winningOrdinal, b.winningOrdinal)
        XCTAssertEqual(a.gridVariances.map { $0 * 1048576 }, b.gridVariances)
        XCTAssertLessThan(a.winningVariance, 1e-12)
    }

    func testDefinedZeroCovarianceSelectsFirstSP50095RatherThanRPCash() throws {
        let prep = try native(constant(70)), s = try Screen.signals(frame: prep.frame)
        XCTAssertEqual(s[63].covariance, Array(repeating: Array(repeating: 0.0, count: 3), count: 3))
        XCTAssertEqual(s[63].gridVariances, Array(repeating: 0, count: 231))
        XCTAssertEqual(s[63].minimumTieOrdinals, Array(0..<231))
        XCTAssertEqual(s[63].winningOrdinal, 0); XCTAssertEqual(s[63].winningWeights, [0, 0, 1])
        XCTAssertEqual(s[63].rawTarget, ["gold_cny": 0, "nasdaq": 0, "sp500": 0.95])
        XCTAssertEqual(s[63].cleanedTarget, ["sp500": 0.95])
        XCTAssertEqual(s[63].roles[0].rawWeight, 0); XCTAssertEqual(s[63].roles[0].cleanedWeight, 0)
        XCTAssertEqual(try RiskParityCoreScreen.signals(frame: prep.frame)[63].cleanedTarget, [:])
        XCTAssertEqual(Screen.capped(["gold_cny": 1e-6, "nasdaq": 0.5]), ["nasdaq": 0.5])
        XCTAssertEqual(Screen.providerClean(["gold_cny": .infinity, "nasdaq": 0.5, "unused": 1]), ["nasdaq": 0.5])
    }

    func testInvalidMathAndStrictPriorSourceLimits() throws {
        XCTAssertThrowsError(try Screen.gridEvaluation(covariance: [[1]]))
        XCTAssertThrowsError(try Screen.gridEvaluation(covariance: [[.nan, 0, 0], [0, 1, 0], [0, 0, 1]]))
        let d = dates(1)
        let bars = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0, [Screen.PriceBar(date: d[0], price: 100)]) })
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: bars, fxPoints: [.init(date: d[0], usdPerCNY: 0.125)], fundedDates: d))
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: bars, fxPoints: [.init(date: d[0].addingTimeInterval(-15 * 86400), usdPerCNY: 0.125)], fundedDates: d))
        XCTAssertNoThrow(try Screen.nativePreparation(barsBySymbol: bars, fxPoints: [.init(date: d[0].addingTimeInterval(-14 * 86400), usdPerCNY: 0.125)], fundedDates: d))
        var missing = bars; missing["gold_cny"] = [.init(date: d[0].addingTimeInterval(86400), price: 100)]
        XCTAssertThrowsError(try Screen.nativePreparation(barsBySymbol: missing, fxPoints: [.init(date: d[0].addingTimeInterval(-86400), usdPerCNY: 0.125)], fundedDates: d))
    }

    func testFullFormationAndEmptyCompletionCadence21_42_63_84() throws {
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
        XCTAssertTrue(run.simulation.trades.allSatisfy { $0.reason == "fixed GMV63 core close research" })
        assertLedger(run, prep)
    }

    func testCarryQuoteWaitUsesLatestPriorSignalAndCompletionAnchor() throws {
        let prep = try native(constant(110), closed: ["sp500": [84, 85]])
        let s = try Screen.signals(frame: prep.frame), run = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        XCTAssertEqual(prep.executionPrices["sp500"]![84], 0)
        XCTAssertFalse(prep.frame.observedBySymbol["sp500"]![84])
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

    func testCandidateCrossAssetSettlementUsesOldCashNotTodaySales() throws {
        var p = constant(130)
        for i in 85..<130 { p["sp500"]![i] = i % 2 == 0 ? 100 : 200 }
        let prep = try native(p), s = try Screen.signals(frame: prep.frame)
        XCTAssertEqual(s[83].cleanedTarget, ["sp500": 0.95])
        XCTAssertEqual(s[104].cleanedTarget, ["nasdaq": 0.95])
        let run = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        let on105 = run.simulation.trades.filter { $0.date == prep.frame.dates[105] }
        XCTAssertEqual(on105.map(\.action), [.sell, .buy])
        XCTAssertEqual(on105.map(\.assetSymbol), ["sp500", "nasdaq"])
        XCTAssertLessThan(on105[1].cashAmount, 6000)
        XCTAssertFalse(run.decisions[105].completedToday)
        XCTAssertEqual(run.decisions[105].pendingAfter, s[104].cleanedTarget)
        XCTAssertTrue(run.decisions[106].providerCalled); XCTAssertTrue(run.decisions[106].completedToday)
        XCTAssertEqual(run.decisions[106].requestedTarget, s[105].cleanedTarget)
        XCTAssertGreaterThan(run.simulation.trades.first { $0.date == prep.frame.dates[106] }!.cashAmount, 85000)
        assertLedger(run, prep)
    }

    func testEqualAndCashControlsRetainExactRPObjectsAndSortedFills() throws {
        let prep = try native(prices(90)), s = try Screen.signals(frame: prep.frame)
        let rp = try RiskParityCoreScreen.signals(frame: prep.frame)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        for role in [Screen.Role.equal, Screen.Role.cash] {
            let a = try Screen.runAccount(preparation: prep, signals: s, role: role)
            let b = try RiskParityCoreScreen.runAccount(preparation: prep, signals: rp, role: role)
            XCTAssertEqual(try encoder.encode(a.simulation.dailyStates), try encoder.encode(b.simulation.dailyStates))
            XCTAssertEqual(a.simulation.trades.count, b.simulation.trades.count)
            for (x, y) in zip(a.simulation.trades, b.simulation.trades) {
                XCTAssertEqual(x.assetSymbol, y.assetSymbol); XCTAssertEqual(x.assetTitle, y.assetTitle)
                XCTAssertEqual(x.date, y.date); XCTAssertEqual(x.action, y.action); XCTAssertEqual(x.price, y.price)
                XCTAssertEqual(x.cashAmount, y.cashAmount); XCTAssertEqual(x.units, y.units); XCTAssertEqual(x.reason, y.reason)
                XCTAssertEqual(x.realizedProfit, y.realizedProfit); XCTAssertEqual(x.realizedReturn, y.realizedReturn)
                XCTAssertEqual(x.holdingDays, y.holdingDays)
            }
            XCTAssertEqual(a.decisions, b.decisions); XCTAssertEqual(a.completions, b.completions)
            XCTAssertEqual(a.simulation.cashYieldSummary.totalCashInterest, b.simulation.cashYieldSummary.totalCashInterest)
            XCTAssertEqual(a.simulation.cashYieldSummary.averageCashRatio, b.simulation.cashYieldSummary.averageCashRatio)
            XCTAssertEqual(a.simulation.cashYieldSummary.averageAnnualRate, b.simulation.cashYieldSummary.averageAnnualRate)
            XCTAssertEqual(a.completions.map(\.index), [21, 42, 63, 84])
            assertLedger(a, prep)
        }
        let equal = try Screen.runAccount(preparation: prep, signals: s, role: .equal)
        XCTAssertEqual(equal.simulation.trades.prefix(3).map(\.assetSymbol), ["gold_cny", "nasdaq", "sp500"])
        XCTAssertEqual(equal.decisions[21].requestedTarget, Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0, 0.95 / 3) }))
        XCTAssertEqual(Screen.savedControlIDs, ChaikinMoneyFlowScreen.savedControlIDs)
        XCTAssertEqual(Screen.savedControlIDs.count, 31)
        XCTAssertEqual(Set(Screen.savedControlIDs).count, 31)
        XCTAssertEqual(Screen.candidateID, "gmv63-three-core-close")
        XCTAssertEqual(Screen.equalID, "equal-core95-gmv63-close-control")
        XCTAssertEqual(Screen.cashID, "cny-cash-gmv63-native2001")
    }
}
