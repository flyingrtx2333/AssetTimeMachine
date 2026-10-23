import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class RobustMedianReversionCoreScreenTests: XCTestCase {
    typealias Screen = RobustMedianReversionCoreScreen
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


    func testSourceConstantsAndDirectInitialChecksumWithoutNormalization() throws {
        XCTAssertEqual(Screen.window, 5); XCTAssertEqual(Screen.epsilon, 5)
        XCTAssertEqual(Screen.maximumUpdates, 199); XCTAssertEqual(Screen.tau, 1e-12)
        let u = Double(1) / Double(3)
        XCTAssertEqual(try Screen.initialLatent(), [u,u,u])
        XCTAssertEqual(Screen.coreSymbols, ["gold_cny","nasdaq","sp500"])
        let near = [0.5,0.25,0.25 + 1e-13]
        XCTAssertNoThrow(try Screen.weightCheck(near)); XCTAssertEqual(near[2], 0.25 + 1e-13)
        XCTAssertThrowsError(try Screen.weightCheck([0.5,0.25,0.25 + 1e-10]))
        XCTAssertNoThrow(try Screen.weightCheck([0,0.5,0.5]))
    }
    func testAllCoincidentWindowReturnsBeforeAnyDivisionWithZeroUpdates() throws {
        let point = [2.0,3.0,4.0], m = try Screen.median(Array(repeating: point, count: 5))
        XCTAssertEqual(m.initMu, point); XCTAssertEqual(m.finalMu, point)
        XCTAssertEqual(m.updatesPerformed, 0); XCTAssertEqual(m.evaluationsCount, 1)
        XCTAssertEqual(m.lastStateIndex, 1); XCTAssertTrue(m.converged); XCTAssertFalse(m.capReached)
        XCTAssertEqual(m.stationarityReason, "all-coincident")
        XCTAssertEqual(m.evaluations[0].coincidenceCount, 5); XCTAssertTrue(m.evaluations[0].excludedIndices.isEmpty)
        XCTAssertNil(m.evaluations[0].gamma); XCTAssertNil(m.evaluations[0].inverseDistanceSum)
        XCTAssertNil(m.stopL1diff); XCTAssertNil(m.newL1); XCTAssertNil(m.tauTimesNewL1)
    }
    func testDuplicateObservationsCountStationarityRatherThanBinaryEta() throws {
        let m = try Screen.median([[2,2,2],[2,2,2],[3,2,2],[2,3,2],[1,1,2]])
        let e = m.evaluations[0]
        XCTAssertEqual(m.initMu, [2,2,2]); XCTAssertEqual(e.coincidenceCount, 2)
        XCTAssertEqual(e.excludedIndices, [2,3,4]); XCTAssertEqual(e.distances, [1,1,sqrt(2)])
        XCTAssertEqual(e.r![0], 1 - 1 / sqrt(2)); XCTAssertEqual(e.r![1], 1 - 1 / sqrt(2))
        XCTAssertLessThanOrEqual(e.gamma!, 2); XCTAssertEqual(m.updatesPerformed, 0)
        XCTAssertEqual(m.finalMu, m.initMu); XCTAssertNil(e.ratio)
        // A second count fixture has residual2, strictly above the paper's printed binary1.
        let count = try Screen.median([[2,2,2],[2,2,2],[2,2,2],[3,2,2],[4,2,2]])
        XCTAssertEqual(count.evaluations[0].coincidenceCount, 3)
        XCTAssertEqual(count.evaluations[0].gamma, 2); XCTAssertEqual(count.updatesPerformed, 0)
    }
    func testLegitimateZeroResidualAndNearCoincidenceRemainExact() throws {
        let m = try Screen.median([[2,2,2],[1,2,2],[3,2,2],[2,1,2],[2,3,2]])
        XCTAssertEqual(m.evaluations[0].r, [0,0,0]); XCTAssertEqual(m.evaluations[0].gamma, 0)
        XCTAssertEqual(m.stationarityReason, "objective-count-subgradient-zero-residual")
        XCTAssertEqual(m.updatesPerformed, 0)
        let near = try Screen.median([[2,2,2],[Double(2).nextUp,2,2],[1,2,2],[3,2,2],[2,3,2]])
        XCTAssertEqual(near.evaluations[0].coincidenceCount, 1)
        XCTAssertTrue(near.evaluations[0].excludedIndices.contains(1))
        XCTAssertEqual(near.evaluations[0].distances[0], Double(2).nextUp - 2)
    }
    func testCoordinateSeedIsNotTheJointSpatialMedianAndScalarTransitionIsLiteral() throws {
        let points = [[1.0,1,2],[1,2,1],[2,1,1],[2,2,2],[3,3,3]], m = try Screen.median(points)
        XCTAssertEqual(m.initMu, [2,2,2]); XCTAssertGreaterThan(m.updatesPerformed, 0)
        XCTAssertNotEqual(m.finalMu, m.initMu)
        let e = m.evaluations[0]
        let inverseSum = ((0.0 + 1 / sqrt(2)) + 1 / sqrt(2)) + 1 / sqrt(2) + 1 / sqrt(3)
        let numerator = ((0.0 + 1 / sqrt(2)) + 1 / sqrt(2)) + 2 / sqrt(2) + 3 / sqrt(3)
        XCTAssertEqual(e.inverseDistanceSum, inverseSum)
        XCTAssertEqual(e.weightedNumerators![0], numerator)
        XCTAssertEqual(e.tTilde![0], numerator / inverseSum)
        for j in 0..<3 {
            XCTAssertEqual(e.newMu![j], (1 - 1 / e.gamma!) * e.tTilde![j] + (1 / e.gamma!) * 2)
        }
        XCTAssertLessThanOrEqual(m.updatesPerformed, 199)
    }
    func testNewIterateStopAndActualUpdateCountAreIndependentOfEvaluations() throws {
        let m = try Screen.median([[1,1,2],[1,2,1],[2,1,1],[2,2,2],[3,3,3]])
        let assigned = m.evaluations.filter { $0.newMu != nil }
        XCTAssertEqual(assigned.count, m.updatesPerformed)
        XCTAssertEqual(m.lastStateIndex, 1 + assigned.count)
        XCTAssertEqual(m.evaluationsCount, m.evaluations.count)
        for (i, e) in m.evaluations.enumerated() {
            XCTAssertEqual(e.ordinal, i)
            if let n = e.newMu {
                let norm = ((0.0 + abs(n[0])) + abs(n[1])) + abs(n[2])
                XCTAssertEqual(e.newL1, norm); XCTAssertEqual(e.tauTimesNewL1, 1e-12 * norm)
                let delta = ((0.0 + abs(n[0] - e.mu[0])) + abs(n[1] - e.mu[1])) + abs(n[2] - e.mu[2])
                XCTAssertEqual(e.stopL1diff, delta)
                if i + 1 < m.evaluations.count { XCTAssertEqual(m.evaluations[i + 1].mu, n) }
            } else { XCTAssertNil(e.stopL1diff); XCTAssertNil(e.newL1); XCTAssertNil(e.tauTimesNewL1) }
        }
        XCTAssertEqual(m.lastMu, assigned.last!.mu); XCTAssertEqual(m.finalMu, assigned.last!.newMu)
    }
    func testCapKeepsLastApproximationWithoutExactMedianClaim() throws {
        // Four symmetric rays have x component1/4; their residual balances the apex.
        // This near-stationary geometry approaches the apex slowly from the coordinate seed.
        let r = sqrt(15.0) / 4
        let m = try Screen.median([[2,2,2],[2.25,2+r,2],[2.25,2-r,2],[2.25,2,2+r],[2.25,2,2-r]])
        XCTAssertEqual(m.maximumUpdates, 199)
        XCTAssertTrue(m.capReached)
        XCTAssertEqual(m.updatesPerformed, 199); XCTAssertEqual(m.lastStateIndex, 200)
        XCTAssertFalse(m.converged); XCTAssertEqual(m.stopReason, "iteration-cap")
        XCTAssertEqual(m.finalMu, m.evaluations.last!.newMu)
    }
    func testZeroDirectionRetainsExactPreviousStateWithoutProjectionOrFeasibilityClaim() throws {
        let previous = [0.5,0.25,0.25 + 1e-13], pa = try Screen.passiveAggressive(previous: previous, forecast: [1,1,1])
        XCTAssertEqual(pa.variance, 0); XCTAssertEqual(pa.alpha, 0); XCTAssertTrue(pa.noDirection)
        XCTAssertEqual(pa.nextLatent, previous); XCTAssertNil(pa.projection); XCTAssertNil(pa.quotient)
        XCTAssertLessThan(pa.dot, Screen.epsilon); XCTAssertEqual(pa.branch, "no_direction")
    }
    func testSourceRelaxedPASignedStepsThenSimplexDoesNotGuaranteeEpsilon() throws {
        let pa = try Screen.passiveAggressive(previous: [0.5,0.25,0.25], forecast: [1,2,3])
        XCTAssertEqual(pa.xbar, 2); XCTAssertEqual(pa.dot, 1.75); XCTAssertEqual(pa.variance, 2)
        XCTAssertEqual(pa.alpha, -1.625); XCTAssertEqual(pa.rawPA, [-1.125,0.25,1.875])
        XCTAssertEqual(pa.nextLatent, [0,0,1]); XCTAssertLessThan(3, Screen.epsilon)
        XCTAssertEqual(pa.projection!.rho, 1); XCTAssertEqual(pa.projection!.sortedOrdinals, [2,1,0])
        let satisfied = try Screen.passiveAggressive(previous: [0.5,0.25,0.25], forecast: [8,9,10])
        XCTAssertEqual(satisfied.alpha, 0); XCTAssertEqual(satisfied.nextLatent, [0.5,0.25,0.25])
    }
    func testSimplexStableTiesSignedZerosTinySupportAndNoRenormalization() throws {
        let tie = try Screen.project([0,0,-0.0])
        XCTAssertEqual(tie.sortedOrdinals, [0,1,2]); XCTAssertEqual(tie.rho, 3)
        XCTAssertEqual(tie.projectedLatent, Array(repeating: 1.0 / 3, count: 3))
        let tiny = try Screen.project([1e-300,0.5,0.5])
        XCTAssertEqual(tiny.projectedLatent, [1e-300,0.5,0.5])
        let raw = [0.6,0.3,0.1 + 1e-13], p = try Screen.project(raw)
        XCTAssertEqual(p.theta, ((((0.0 + raw[0]) + raw[1]) + raw[2]) - 1) / 3)
        for j in 0..<3 { XCTAssertEqual(p.projectedLatent[j], max(0, raw[j] - p.theta)) }
        XCTAssertNotEqual(p.projectedLatent, raw.map { $0 / ((raw[0] + raw[1]) + raw[2]) })
        XCTAssertThrowsError(try Screen.project([1e308,1e308,1e308]))
    }
    func testObservableUnderflowNonfiniteRejectAndLegalSignedCancellation() throws {
        XCTAssertEqual(try Screen.multiply(-0.0, 1e300), 0)
        XCTAssertEqual(try Screen.divide(0, -1), 0)
        XCTAssertEqual(try Screen.sum([1,-1,0]), 0)
        XCTAssertEqual(try Screen.multiply(-2, 3), -6)
        XCTAssertThrowsError(try Screen.multiply(Double.leastNonzeroMagnitude, 0.5))
        XCTAssertThrowsError(try Screen.divide(Double.leastNonzeroMagnitude, 2))
        XCTAssertThrowsError(try Screen.multiply(1e-200, 1e-200))
        XCTAssertThrowsError(try Screen.divide(1,0))
        for x in [Double.nan,Double.infinity,-Double.infinity,0,-1] { XCTAssertThrowsError(try Screen.positive(x)) }
        XCTAssertThrowsError(try Screen.median([[1e-200,1,1],[2e-200,1,1],[3e-200,1,1],[4e-200,1,1],[5e-200,1,1]]))
        XCTAssertThrowsError(try Screen.passiveAggressive(previous: [0.5,0.25,0.25], forecast: [1e-200,2e-200,3e-200]))
    }
    func testLiteralNormalizedGeometryFormationAndFirstWindowNextClose() throws {
        let prep = try native(prices(8)), s = try Screen.signals(frame: prep.frame), u = try Screen.initialLatent()
        XCTAssertEqual(s[0].normalizedPrice, [1,1,1]); XCTAssertNil(s[0].normalizedPricePrevious); XCTAssertNil(s[0].x)
        var p = [1.0,1.0,1.0]
        for i in 1..<s.count {
            for j in 0..<3 {
                let symbol = Screen.coreSymbols[j], x = prep.frame.pricesBySymbol[symbol]![i] / prep.frame.pricesBySymbol[symbol]![i - 1]
                p[j] = x * p[j]
                XCTAssertEqual(s[i].x![j], x); XCTAssertEqual(s[i].normalizedPrice[j], p[j])
            }
            XCTAssertEqual(s[i].incomingLatent, s[i - 1].pNext)
        }
        for i in 0..<4 { XCTAssertEqual(s[i].pNext, u); XCTAssertNil(s[i].median); XCTAssertNil(s[i].pa) }
        XCTAssertEqual(s[4].median!.windowIndices, [4,3,2,1,0])
        XCTAssertEqual(s[4].median!.windowVectors, [s[4],s[3],s[2],s[1],s[0]].map(\.normalizedPrice))
        let run = try Screen.runAccount(preparation: prep, signals: s, role: .candidate)
        XCTAssertEqual(run.simulation.dailyStates[0].cash, 100000); XCTAssertTrue(run.simulation.dailyStates[0].targetWeights.isEmpty)
        XCTAssertEqual(run.decisions[1].signalIndex, 0); XCTAssertEqual(run.decisions[1].requestedTarget, Screen.providerClean(s[0].cleanedTarget))
        XCTAssertEqual(run.decisions[5].signalIndex, 4); XCTAssertEqual(run.decisions[5].requestedTarget, Screen.providerClean(s[4].cleanedTarget))
        XCTAssertTrue(run.decisions.dropFirst().allSatisfy(\.providerCalled)); assertLedger(run, prep)
    }
    func testMixedRawAssetUnitsCannotChangeNormalizedMedianGeometry() throws {
        let p = prices(10), units = ["gold_cny":8.0,"nasdaq":0.25,"sp500":4.0]
        let base = try native(p), changed = try native(Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { symbol in (symbol,p[symbol]!.map { $0 * units[symbol]! }) }))
        XCTAssertEqual(try Screen.signals(frame: base.frame), try Screen.signals(frame: changed.frame))
    }
    func testModelProviderCleanAndActualHoldingsAreSeparateFromLatentInputs() throws {
        let prep = try native(prices(8)), signals = try Screen.signals(frame: prep.frame)
        let a = try Screen.runAccount(preparation: prep, signals: signals, role: .candidate)
        _ = try Screen.runAccount(preparation: prep, signals: signals, role: .cash)
        XCTAssertEqual(signals, try Screen.signals(frame: prep.frame))
        for i in 1..<signals.count { XCTAssertEqual(signals[i].incomingLatent, signals[i - 1].pNext) }
        let near = ["gold_cny":0.5,"nasdaq":0.25,"sp500":0.25 + 1e-13]
        XCTAssertNotEqual(Screen.providerClean(near), near)
        XCTAssertEqual(try Screen.passiveAggressive(previous: [0.5,0.25,0.25 + 1e-13], forecast: [1,1,1]).nextLatent, [0.5,0.25,0.25 + 1e-13])
        assertLedger(a, prep)
    }
    func testExplicitNullFormationStationarityAndNoDirectionExport() throws {
        let s = try Screen.signals(frame: native(constant(6)).frame)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let rows = try Screen.signalObjects(s, encoder: encoder)
        for i in 0..<4 { XCTAssertTrue(rows[i]["median"] is NSNull); XCTAssertTrue(rows[i]["pa"] is NSNull) }
        XCTAssertTrue(rows[0]["x"] is NSNull); XCTAssertTrue(rows[0]["normalizedPricePrevious"] is NSNull)
        let m = rows[4]["median"] as! [String: Any], pa = rows[4]["pa"] as! [String: Any]
        for key in ["stopL1diff","newL1","tauTimesNewL1"] { XCTAssertTrue(m[key] is NSNull) }
        for key in ["numerator","quotient","steps","projection"] { XCTAssertTrue(pa[key] is NSNull) }
        let e = (m["evaluations"] as! [[String: Any]])[0]
        for key in ["r","gamma","inverseDistances","newMu"] { XCTAssertTrue(e[key] is NSNull) }
        XCTAssertEqual(rows[0]["reason"] as? String, "baseline-initial-equal")
        XCTAssertEqual(rows[3]["reason"] as? String, "formation-retained-uniform")
        XCTAssertEqual(rows[4]["reason"] as? String, "full-window-RMR-no-direction")
    }
    func testExportFrozenSourceMath() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ASSET_RMR_SOURCE_PRIMITIVES_PATH"], let dump = env["ASSET_RMR_SOURCE_DUMP_PATH"] else {
            throw XCTSkip("Root-controlled source-only export: no historical source read without both explicit paths")
        }
        struct Primitive: Decodable {
            struct Bar: Decodable { let date: String; let valuation_price: Double }
            struct FX: Decodable { let date: String; let usd_per_cny: Double }
            let schema: String; let cutoff: String; let baseline: String
            let series: [String: [Bar]]; let funded_union_calendar: [String]
            let original_strictprior_FX_observations: [FX]
        }
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        guard ResearchRunEvidence.sha256(raw) == "290d8a36402dcc467b6450370b72e4baae6f222a6e432e927f123d732f546946" else { throw BacktestConfigurationError.invalidParameter("Frozen RMR source-only raw hash") }
        let input = try JSONDecoder().decode(Primitive.self, from: raw)
        guard input.schema == "fixed-rp63-core-source-primitives-v1", input.cutoff == "2026-10-06", input.baseline == "2001-06-25",
              input.funded_union_calendar.count == 6452 else { throw BacktestConfigurationError.invalidParameter("Frozen RMR source-only primitive contract") }
        func date(_ day: String) throws -> Date { try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: day)) }
        var bars: [String: [Screen.PriceBar]] = [:]
        for symbol in Screen.coreSymbols { bars[symbol] = try XCTUnwrap(input.series[symbol]).map { .init(date: try date($0.date), price: $0.valuation_price) } }
        let fx = try input.original_strictprior_FX_observations.map { Screen.FXPoint(date: try date($0.date), usdPerCNY: $0.usd_per_cny) }
        let prep = try Screen.nativePreparation(barsBySymbol: bars, fxPoints: fx, fundedDates: input.funded_union_calendar.map(date))
        let sourceSignals = try Screen.signals(frame: prep.frame)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let objects = try Screen.signalObjects(sourceSignals, encoder: encoder)
        guard !FileManager.default.fileExists(atPath: dump) else { throw CocoaError(.fileWriteFileExists) }
        try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]).write(to: URL(fileURLWithPath: dump))
        XCTAssertEqual(sourceSignals.count, 6452)
        // Deliberately no accounts decode, shared simulator, NAV, performance or account interest call.
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
                tradeToBandBoundary: false, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed RMR5EPS5 daily core close control")
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
        XCTAssertEqual(Screen.candidateID, "rmr5-eps5-three-core-daily-next-close")
        XCTAssertEqual(Screen.equalID, "equal-core100-rmr5eps5-daily-close-control")
        XCTAssertEqual(Screen.cashID, "cny-cash-rmr5eps5-native2001")
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
