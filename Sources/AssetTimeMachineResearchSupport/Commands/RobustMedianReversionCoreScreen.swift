import Foundation
import AssetTimeMachineBacktestCore

/// Frozen whole RMR w5/epsilon5/m200 with normalized price-only spatial geometry.
/// The genuine shared account alone supplies actual cash, fills, units and NAV.
public enum RobustMedianReversionCoreScreen {
    public static let coreSymbols = RiskParityCoreScreen.coreSymbols
    public static let candidateID = "rmr5-eps5-three-core-daily-next-close"
    public static let equalID = "equal-core100-rmr5eps5-daily-close-control"
    public static let cashID = "cny-cash-rmr5eps5-native2001"
    public static let qualID = ChaikinMoneyFlowScreen.qualID
    public static var savedControlIDs: [String] { ChaikinMoneyFlowScreen.savedControlIDs }
    public typealias PriceBar = RiskParityCoreScreen.PriceBar
    public typealias FXPoint = RiskParityCoreScreen.FXPoint
    public typealias Quote = RiskParityCoreScreen.Quote
    public typealias NativePreparation = RiskParityCoreScreen.NativePreparation
    public typealias Decision = RiskParityCoreScreen.Decision
    public typealias Completion = RiskParityCoreScreen.Completion
    public typealias NativeRun = RiskParityCoreScreen.NativeRun
    public typealias Role = RiskParityCoreScreen.Role
    public static let window = 5
    public static let epsilon = 5.0
    public static let maximumUpdates = 199
    public static let tau = 1e-12
    public static let sumTolerance = 1e-12

    public static func nativePreparation(barsBySymbol: [String: [PriceBar]], fxPoints: [FXPoint], fundedDates: [Date]) throws -> NativePreparation {
        try RiskParityCoreScreen.nativePreparation(barsBySymbol: barsBySymbol, fxPoints: fxPoints, fundedDates: fundedDates)
    }
    public static func providerClean(_ weights: [String: Double]) -> [String: Double] { RiskParityCoreScreen.providerClean(weights) }
    private static func invalid(_ reason: String) -> BacktestConfigurationError { .invalidParameter("RMR5EPS5 " + reason) }
    static func finite(_ x: Double) throws -> Double {
        guard x.isFinite else { throw invalid("nonfinite arithmetic; no fallback") }; return x
    }
    static func positive(_ x: Double) throws -> Double {
        guard x.isFinite, x > 0 else { throw invalid("required finite positive arithmetic; no fallback") }; return x
    }
    static func multiply(_ a: Double, _ b: Double) throws -> Double {
        _ = try finite(a); _ = try finite(b)
        let x = try finite(a * b)
        guard a == 0 || b == 0 || x != 0 else { throw invalid("observable nonzero multiplication underflow") }; return x
    }
    static func divide(_ a: Double, _ b: Double) throws -> Double {
        _ = try finite(a); _ = try finite(b)
        guard b != 0 else { throw invalid("division by zero") }
        let x = try finite(a / b)
        guard a == 0 || x != 0 else { throw invalid("observable nonzero division underflow") }; return x
    }
    static func sum(_ values: [Double]) throws -> Double {
        var total = 0.0
        for value in values { total = try finite(total + finite(value)) }
        return total
    }
    static func weightCheck(_ p: [Double]) throws -> (weightSum: Double, sumError: Double, sumCheck: Bool) {
        guard p.count == 3, p.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw invalid("finite nonnegative exact three-vector") }
        let total = try sum(p), error = try finite(abs(total - 1))
        guard error <= sumTolerance else { throw invalid("model sum1 verification; no rescaling") }
        return (total, error, true)
    }
    public static func initialLatent() throws -> [Double] {
        let u = Double(1) / Double(3), b = [u, u, u]
        _ = try weightCheck(b); return b
    }
    public struct Projection: Encodable, Equatable {
        public let sortedOrdinals: [Int]
        public let sortedValues: [Double]
        public let prefix: [Double]
        public let candidateThresholds: [Double]
        public let activeChecks: [Bool]
        public let rho: Int
        public let theta: Double
        public let projectedLatent: [Double]
        public let weightSum: Double
        public let sumError: Double
        public let sumCheck: Bool
    }
    public static func project(_ v: [Double]) throws -> Projection {
        guard v.count == 3, v.allSatisfy(\.isFinite) else { throw invalid("projection finite three-vector") }
        let ordinals = (0..<3).sorted { v[$0] == v[$1] ? $0 < $1 : v[$0] > v[$1] }
        let sorted = ordinals.map { v[$0] }
        var prefix: [Double] = [], thresholds: [Double] = [], active: [Bool] = [], total = 0.0, rho = 0
        for k in 0..<3 {
            total = try finite(total + sorted[k]); prefix.append(total)
            let threshold = try divide(finite(total - 1), Double(k + 1))
            thresholds.append(threshold)
            let isActive = try finite(sorted[k] - threshold) > 0
            active.append(isActive); if isActive { rho = k + 1 }
        }
        guard rho > 0 else { throw invalid("projection active set empty") }
        let theta = try divide(finite(prefix[rho - 1] - 1), Double(rho))
        let p = try v.map { max(0, try finite($0 - theta)) }
        let check = try weightCheck(p) // Check only: the literal projected vector is never normalized.
        return .init(sortedOrdinals: ordinals, sortedValues: sorted, prefix: prefix, candidateThresholds: thresholds,
            activeChecks: active, rho: rho, theta: theta, projectedLatent: p,
            weightSum: check.weightSum, sumError: check.sumError, sumCheck: check.sumCheck)
    }
    public struct MedianEvaluation: Encodable, Equatable {
        public let ordinal: Int
        public let stateIndex: Int
        public let mu: [Double]
        public let coincidenceCount: Int
        public let excludedIndices: [Int]
        public let squaredDistances: [Double]
        public let distances: [Double]
        public let r: [Double]?
        public let gammaSquared: Double?
        public let gamma: Double?
        public let inverseDistances: [Double]?
        public let inverseDistanceSum: Double?
        public let weightedNumerators: [Double]?
        public let tTilde: [Double]?
        public let ratio: Double?
        public let leftCoefficient: Double?
        public let rightCoefficient: Double?
        public let newMu: [Double]?
        public let stopL1diff: Double?
        public let newL1: Double?
        public let tauTimesNewL1: Double?
        public let branch: String
    }
    public struct Median: Encodable, Equatable {
        public let windowIndices: [Int]
        public let windowVectors: [[Double]]
        public let initSortedOrdinals: [[Int]]
        public let initMu: [Double]
        public let lastMu: [Double]
        public let finalMu: [Double]
        public let updatesPerformed: Int
        public let evaluationsCount: Int
        public let lastStateIndex: Int
        public let maximumUpdates: Int
        public let capReached: Bool
        public let converged: Bool
        public let stationarityReason: String?
        public let stopReason: String
        public let stopL1diff: Double?
        public let newL1: Double?
        public let tauTimesNewL1: Double?
        public let evaluations: [MedianEvaluation]
    }
    public static func median(_ points: [[Double]], windowIndices: [Int] = [0, 1, 2, 3, 4]) throws -> Median {
        guard points.count == window, windowIndices.count == window,
              points.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && $0 > 0 } }) else { throw invalid("median positive five-by-three window") }
        let sortedOrdinals = (0..<3).map { j in (0..<window).sorted { points[$0][j] == points[$1][j] ? $0 < $1 : points[$0][j] < points[$1][j] } }
        let initial = (0..<3).map { points[sortedOrdinals[$0][2]][$0] }
        var mu = initial, lastMu = initial, evaluations: [MedianEvaluation] = [], updates = 0
        var stopDiff: Double?, stopNewL1: Double?, stopThreshold: Double?, converged = false, stationarity: String?
        var stopReason = "iteration-cap"
        while updates < maximumUpdates {
            let excluded = (0..<window).filter { points[$0] != mu }
            let count = window - excluded.count
            var distanceSquares: [Double] = [], distances: [Double] = [], differences: [[Double]] = []
            var r: [Double]?, gammaSquared: Double?, gamma: Double?, inverse: [Double]?, inverseSum: Double?, numerators: [Double]?, tTilde: [Double]?
            var ratio: Double?, left: Double?, right: Double?, next: [Double]?, diff: Double?, newL1: Double?, threshold: Double?
            var branch: String
            if excluded.isEmpty {
                branch = "all-coincident"; stationarity = branch; converged = true; stopReason = "stationary"
            } else {
                for h in excluded {
                    let d = try (0..<3).map { try finite(points[h][$0] - mu[$0]) }
                    let square = try sum(d.map { try multiply($0, $0) })
                    let distance = try positive(sqrt(positive(square)))
                    differences.append(d); distanceSquares.append(square); distances.append(distance)
                }
                let residual = try (0..<3).map { j in try sum(excluded.indices.map { try divide(differences[$0][j], distances[$0]) }) }
                let gSquare = try sum(residual.map { try multiply($0, $0) })
                let g = try finite(sqrt(gSquare)); guard g >= 0 else { throw invalid("negative residual norm") }
                r = residual; gammaSquared = gSquare; gamma = g
                if g <= Double(count) {
                    branch = g == 0 ? "objective-count-subgradient-zero-residual" : "objective-count-subgradient"
                    stationarity = branch; converged = true; stopReason = "stationary"
                } else {
                    let inv = try distances.map { try positive(divide(1, $0)) }
                    let invSum = try positive(sum(inv))
                    let nums = try (0..<3).map { j in try positive(sum(excluded.indices.map { try positive(divide(points[excluded[$0]][j], distances[$0])) })) }
                    let t = try nums.map { try positive(divide($0, invSum)) }
                    let q = try divide(Double(count), g), l = try positive(finite(1 - q))
                    guard q >= 0 else { throw invalid("negative mixture coefficient") }
                    let n = try (0..<3).map { try positive(finite(multiply(l, t[$0]) + multiply(q, mu[$0]))) }
                    let delta = try sum((0..<3).map { try finite(abs(n[$0] - mu[$0])) })
                    let norm = try positive(sum(n.map(abs)))
                    let bound = try positive(multiply(tau, norm))
                    inverse = inv; inverseSum = invSum; numerators = nums; tTilde = t
                    ratio = q; left = l; right = q; next = n; diff = delta; newL1 = norm; threshold = bound
                    branch = delta <= bound ? "stop-tolerance" : "modified-update"
                }
            }
            evaluations.append(.init(ordinal: evaluations.count, stateIndex: 1 + updates, mu: mu, coincidenceCount: count, excludedIndices: excluded,
                squaredDistances: distanceSquares, distances: distances, r: r, gammaSquared: gammaSquared, gamma: gamma,
                inverseDistances: inverse, inverseDistanceSum: inverseSum, weightedNumerators: numerators, tTilde: tTilde,
                ratio: ratio, leftCoefficient: left, rightCoefficient: right, newMu: next,
                stopL1diff: diff, newL1: newL1, tauTimesNewL1: threshold, branch: branch))
            if let n = next {
                lastMu = mu; mu = n; updates += 1
                stopDiff = diff; stopNewL1 = newL1; stopThreshold = threshold
                if branch == "stop-tolerance" { converged = true; stopReason = branch; break }
            } else { break }
        }
        return .init(windowIndices: windowIndices, windowVectors: points, initSortedOrdinals: sortedOrdinals, initMu: initial,
            lastMu: lastMu, finalMu: mu, updatesPerformed: updates, evaluationsCount: evaluations.count, lastStateIndex: 1 + updates,
            maximumUpdates: maximumUpdates, capReached: updates == maximumUpdates && !converged, converged: converged,
            stationarityReason: stationarity, stopReason: stopReason, stopL1diff: stopDiff, newL1: stopNewL1,
            tauTimesNewL1: stopThreshold, evaluations: evaluations)
    }
    public struct PA: Encodable, Equatable {
        public let forecast: [Double]
        public let xbar: Double
        public let dot: Double
        public let centered: [Double]
        public let squares: [Double]
        public let variance: Double
        public let numerator: Double?
        public let quotient: Double?
        public let alpha: Double
        public let steps: [Double]?
        public let rawPA: [Double]
        public let noDirection: Bool
        public let branch: String
        public let projection: Projection?
        public let nextLatent: [Double]
    }
    public static func passiveAggressive(previous: [Double], forecast: [Double]) throws -> PA {
        _ = try weightCheck(previous)
        guard forecast.count == 3 else { throw invalid("exact three forecasts") }; for x in forecast { _ = try positive(x) }
        let mean = try positive(divide(sum(forecast), 3))
        let dot = try sum((0..<3).map { try multiply(forecast[$0], previous[$0]) })
        let centered = try forecast.map { try finite($0 - mean) }
        let squares = try centered.map { try multiply($0, $0) }, variance = try sum(squares)
        guard variance >= 0 else { throw invalid("negative direction variance") }
        if variance == 0 {
            return .init(forecast: forecast, xbar: mean, dot: dot, centered: centered, squares: squares, variance: variance,
                numerator: nil, quotient: nil, alpha: 0, steps: nil, rawPA: previous, noDirection: true,
                branch: "no_direction", projection: nil, nextLatent: previous)
        }
        let numerator = try finite(dot - epsilon), quotient = try divide(numerator, variance), alpha = min(0, quotient)
        let steps = try centered.map { try multiply(alpha, $0) }
        let raw = try (0..<3).map { try finite(previous[$0] - steps[$0]) }
        let projection = try project(raw)
        return .init(forecast: forecast, xbar: mean, dot: dot, centered: centered, squares: squares, variance: variance,
            numerator: numerator, quotient: quotient, alpha: alpha, steps: steps, rawPA: raw, noDirection: false,
            branch: "relaxed-PA-then-simplex", projection: projection, nextLatent: projection.projectedLatent)
    }
    public struct RoleDiagnostic: Encodable, Equatable { public let symbol: String; public let rawWeight: Double; public let cleanedWeight: Double }
    public struct Signal: Encodable, Equatable {
        public let signalIndex: Int
        public let date: Date
        public let intervalCount: Int
        public let reason: String
        public let normalizedPricePrevious: [Double]?
        public let x: [Double]?
        public let normalizedPrice: [Double]
        public let incomingLatent: [Double]
        public let median: Median?
        public let pa: PA?
        public let pNext: [Double]
        public let roles: [RoleDiagnostic]
        public let rawTarget: [String: Double]
        public let cleanedTarget: [String: Double]
        public let weightSum: Double
        public let sumError: Double
        public let sumCheck: Bool
    }
    public static func signals(frame: MarketDataFrame) throws -> [Signal] {
        guard !frame.dates.isEmpty, coreSymbols.allSatisfy({ symbol in
            guard let p = frame.pricesBySymbol[symbol], p.count == frame.dates.count else { return false }
            return p.allSatisfy { $0.isFinite && $0 > 0 }
        }) else { throw invalid("full positive canonical frame") }
        var latent = try initialLatent(), normalized = [1.0, 1.0, 1.0], history: [[Double]] = []
        return try frame.dates.indices.map { s in
            let incoming = latent, prior = s > 0 ? normalized : nil
            var x: [Double]?, medianEvidence: Median?, paEvidence: PA?
            if s > 0 {
                let relative = try coreSymbols.map { try positive(divide(frame.pricesBySymbol[$0]![s], frame.pricesBySymbol[$0]![s - 1])) }
                x = relative; normalized = try (0..<3).map { try positive(multiply(relative[$0], normalized[$0])) }
            }
            history.append(normalized)
            if s >= window - 1 {
                let indices = (0..<window).map { s - $0 }
                let m = try median(indices.map { history[$0] }, windowIndices: indices)
                let forecast = try (0..<3).map { try positive(divide(m.finalMu[$0], normalized[$0])) }
                let pa = try passiveAggressive(previous: incoming, forecast: forecast)
                medianEvidence = m; paEvidence = pa; latent = pa.nextLatent
            }
            let check = try weightCheck(latent), raw = Dictionary(uniqueKeysWithValues: coreSymbols.indices.map { (coreSymbols[$0], latent[$0]) }), clean = providerClean(raw)
            let reason = s == 0 ? "baseline-initial-equal" : s < window - 1 ? "formation-retained-uniform" : paEvidence!.noDirection ? "full-window-RMR-no-direction" : "full-window-RMR-relaxed-PA-simplex"
            return .init(signalIndex: s, date: frame.dates[s], intervalCount: s, reason: reason, normalizedPricePrevious: prior, x: x,
                normalizedPrice: normalized, incomingLatent: incoming, median: medianEvidence, pa: paEvidence, pNext: latent,
                roles: coreSymbols.indices.map { .init(symbol: coreSymbols[$0], rawWeight: latent[$0], cleanedWeight: clean[coreSymbols[$0]] ?? 0) },
                rawTarget: raw, cleanedTarget: clean, weightSum: check.weightSum, sumError: check.sumError, sumCheck: check.sumCheck)
        }
    }
    /// Same compound clauses, operation order and thresholds as unchanged DailyScreenOutput.row.
    /// This wrapper only reports the first invalid state before any metrics are computed.
    static func checkedRow(_ id: String, states: [BacktestDailyState], trades: [AdvancedBacktestTrade],
                           windows: [(String, String, String)]) throws -> DailyScreenOutput.Row {
        try validateAccounting(id, states: states)
        return try DailyScreenOutput.row(id, states: states, trades: trades, windows: windows)
    }
    static func validateAccounting(_ id: String, states: [BacktestDailyState]) throws {
        guard !states.isEmpty else { throw BacktestConfigurationError.missingData(id) }
        for s in states {
            let held = s.holdingsBySymbol.values.reduce(0, +)
            let receivable = s.distributionReceivable ?? 0
            guard s.portfolioValue > 0, s.portfolioValue.isFinite, s.cash >= -1e-8,
                  receivable.isFinite, receivable >= 0,
                  abs(held + s.cash + receivable - s.portfolioValue) <= max(1e-8, abs(s.portfolioValue) * 1e-12),
                  held / s.portfolioValue <= 1 + 1e-12,
                  s.targetWeights.values.allSatisfy({ $0 >= 0 && $0.isFinite }),
                  s.targetWeights.values.reduce(0, +) <= 1 + 1e-12 else {
                func number(_ x: Double) -> Any { x.isFinite ? x as Any : (x.isNaN ? "NaN" : (x > 0 ? "+Infinity" : "-Infinity")) }
                let error = abs(held + s.cash + receivable - s.portfolioValue), limit = max(1e-8, abs(s.portfolioValue) * 1e-12)
                let gross = held / s.portfolioValue, targetSum = s.targetWeights.values.reduce(0, +)
                let clauses: [String: Bool] = ["NAV_positive": s.portfolioValue > 0, "NAV_finite": s.portfolioValue.isFinite,
                    "cash_nonnegative": s.cash >= -1e-8, "receivable_finite": receivable.isFinite, "receivable_nonnegative": receivable >= 0,
                    "accounting_identity": error <= limit, "gross_le_one": gross <= 1 + 1e-12,
                    "targets_finite_nonnegative": s.targetWeights.values.allSatisfy({ $0 >= 0 && $0.isFinite }), "target_sum_le_one": targetSum <= 1 + 1e-12]
                let diagnostic: [String: Any] = ["account_id": id, "date": ISO8601DateFormatter().string(from: s.date),
                    "clauses": clauses, "portfolioValue": number(s.portfolioValue), "cash": number(s.cash), "receivable": number(receivable),
                    "holdingsBySymbol": s.holdingsBySymbol.mapValues(number), "targetWeights": s.targetWeights.mapValues(number),
                    "held": number(held), "accounting_error": number(error), "accounting_error_limit": number(limit),
                    "gross": number(gross), "target_sum": number(targetSum)]
                let data = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys, .withoutEscapingSlashes])
                throw BacktestConfigurationError.invalidParameter("RMR5EPS5 accounting diagnostic " + String(decoding: data, as: UTF8.self))
            }
        }
    }
    static func signalObjects(_ signals: [Signal], encoder: JSONEncoder) throws -> [[String: Any]] {
        var rows = try JSONSerialization.jsonObject(with: encoder.encode(signals)) as! [[String: Any]]
        func materialize(_ object: inout [String: Any], _ keys: [String]) {
            for key in keys where object[key] == nil { object[key] = NSNull() }
        }
        for i in rows.indices {
            materialize(&rows[i], ["normalizedPricePrevious", "x", "median", "pa"])
            if var m = rows[i]["median"] as? [String: Any] {
                materialize(&m, ["stationarityReason", "stopL1diff", "newL1", "tauTimesNewL1"])
                var evaluations = m["evaluations"] as! [[String: Any]]
                for e in evaluations.indices {
                    materialize(&evaluations[e], ["r", "gammaSquared", "gamma", "inverseDistances", "inverseDistanceSum", "weightedNumerators", "tTilde", "ratio", "leftCoefficient", "rightCoefficient", "newMu", "stopL1diff", "newL1", "tauTimesNewL1"])
                }
                m["evaluations"] = evaluations; rows[i]["median"] = m
            }
            if var pa = rows[i]["pa"] as? [String: Any] {
                materialize(&pa, ["numerator", "quotient", "steps", "projection"]); rows[i]["pa"] = pa
            }
        }
        return rows
    }
    public static func runAccount(preparation: NativePreparation, signals: [Signal], role: Role) throws -> NativeRun {
        guard signals.count == preparation.frame.dates.count,
              signals.enumerated().allSatisfy({ $0.offset == $0.element.signalIndex && $0.element.date == preparation.frame.dates[$0.offset] }) else {
            throw BacktestConfigurationError.invalidParameter("RMR5EPS5 exact funded signal alignment")
        }
        return try simulate(preparation: preparation,
            buyReason: role == .candidate ? "fixed RMR5EPS5 core close research" : "fixed RMR5EPS5 daily core close control") { context in
            switch role {
            case .candidate: return signals[context.signalIndex].cleanedTarget
            case .equal: return Dictionary(uniqueKeysWithValues: coreSymbols.map { ($0, 1.0 / 3) })
            case .cash: return [:]
            }
        }
    }
    /// This internal adapter is also exercised with synthetic target fixtures.
    /// Production callers use only the fixed role switch above.
    static func simulate(preparation: NativePreparation, buyReason: String,
                         target: @escaping (StrategyTargetContext) -> [String: Double]) throws -> NativeRun {
        let frame = preparation.frame
        guard frame.simulationRange.lowerBound == 0 else { throw BacktestConfigurationError.invalidParameter("RMR5EPS5 full funded baseline") }
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, tradeToBandBoundary: false, financingAnnualRate: 0,
            allowsFinancedExposure: false, buyReason: buyReason)
        var lastDidExecute = Int.min / 2, retained: [String: Double] = [:], pending: [String: Double]?
        var decisions: [Decision] = [], completions: [Completion] = [], expected: [[String: Double]] = []
        guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
            provider: .init { context in
                let weights = providerClean(target(context))
                retained = weights; pending = weights
                decisions[decisions.count - 1].providerCalled = true
                decisions[decisions.count - 1].requestedTarget = weights
                decisions[decisions.count - 1].pendingAfter = weights
                return weights
            }, rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
            contextualRebalanceDecision: { c in
                let age = c.index - lastDidExecute
                let due = c.index >= 1
                decisions.append(.init(index: c.index, date: c.date, signalIndex: c.signalIndex, signalDate: c.signalDate,
                    shouldRebalance: due, providerCalled: false, lastDidExecuteBefore: lastDidExecute,
                    lastDidExecuteAfter: lastDidExecute, reviewAgeBefore: age, retainedTargetBefore: retained,
                    requestedTarget: nil, acceptedAfter: [:], pendingBefore: pending, pendingAfter: pending, completedToday: false))
                expected.append(retained)
                return .init(shouldRebalance: due, refreshOverlay: false)
            }, didExecuteTarget: { index in
                lastDidExecute = index; pending = nil
                decisions[decisions.count - 1].lastDidExecuteAfter = index
                decisions[decisions.count - 1].pendingAfter = nil
                decisions[decisions.count - 1].completedToday = true
                completions.append(.init(index: index, date: frame.dates[index], target: retained))
            }, executionPricesBySymbol: preparation.executionPrices, buyBudgetPolicy: .symbolOrder) else {
            throw BacktestConfigurationError.computationFailed
        }
        guard run.dailyStates.count == decisions.count,
              run.dailyStates.first?.portfolioValue == 100000, run.dailyStates.first?.cash == 100000,
              run.dailyStates.first?.targetWeights.isEmpty == true,
              !run.trades.contains(where: { $0.date == frame.dates[0] }) else {
            throw BacktestConfigurationError.invalidParameter("RMR5EPS5 unchanged cash baseline/full formation history")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].acceptedAfter = run.dailyStates[i].targetWeights
            let desired = decisions[i].requestedTarget ?? expected[i]
            if decisions[i].acceptedAfter != desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("RMR5EPS5 target adapter delivery") }
        return .init(simulation: run, decisions: decisions, completions: completions, targetMismatchCount: mismatches)
    }

    private struct Input: Decodable {
        let schema: String; let cutoff: String; let baseline: String
        let role_to_source_symbol: [String: String]
        let source_history_sha256: String
        let series: [String: [Bar]]
        let original_strictprior_FX_observations: [FX]
        let funded_union_calendar: [String]
        let saved_long_comparison_dates: [String]
        let saved_short_comparison_dates: [String]
        struct Bar: Decodable { let date: String; let valuation_price: Double }
        struct FX: Decodable { let date: String; let usd_per_cny: Double }
    }
    private struct Sources: Decodable {
        let schema: String; let files: [File]
        struct File: Decodable { let path: String; let sha256: String; let ids: [String] }
    }
    private struct Saved: Decodable { let id: String; let dailyStates: [BacktestDailyState] }
    private struct Account {
        let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade]; let savedObject: [String: Any]?
    }
    private static func cashObject(_ s: CashYieldSummary) -> [String: Any] {
        let date = ISO8601DateFormatter().string(from:)
        return ["title": s.title, "source": s.source, "sourceDetail": s.sourceDetail,
            "startDate": s.startDate.map(date) as Any? ?? NSNull(), "endDate": s.endDate.map(date) as Any? ?? NSNull(),
            "latestRateDate": s.latestRateDate.map(date) as Any? ?? NSNull(),
            "latestAnnualRate": s.latestAnnualRate, "averageAnnualRate": s.averageAnnualRate,
            "averageCashRatio": s.averageCashRatio, "totalCashInterest": s.totalCashInterest,
            "ratePoints": s.ratePoints.map { ["date": date($0.date), "annualRate": $0.annualRate] as [String: Any] }]
    }
    public static func run(primitivesPath: String, accountsPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: primitivesPath))
        let savedRaw = try Data(contentsOf: URL(fileURLWithPath: accountsPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        let sources = try JSONDecoder().decode(Sources.self, from: savedRaw)
        guard ResearchRunEvidence.sha256(raw) == "290d8a36402dcc467b6450370b72e4baae6f222a6e432e927f123d732f546946",
              ResearchRunEvidence.sha256(savedRaw) == "a898b763729cb57bd1586e29a8efd17ad5eb7ded042c7ad6b19f685a381ef7c7",
              input.schema == "fixed-rp63-core-source-primitives-v1", input.cutoff == "2026-10-06", input.baseline == "2001-06-25",
              input.role_to_source_symbol == ["gold_cny": "gold_cny", "nasdaq": "nasdaq_composite", "sp500": "sp500"],
              input.source_history_sha256 == "86c62407994fdc49ec41ba891a44373201335a4ff0670310a6098c2b1de2dedb",
              coreSymbols.map({ input.series[$0]?.count ?? 0 }) == [6423, 6732, 6743],
              input.funded_union_calendar.count == 6452, input.funded_union_calendar.first == "2001-06-25", input.funded_union_calendar.last == "2026-10-06",
              sources.schema == "fixed-rp63-core-saved-v1", !sources.files.isEmpty,
              sources.files.flatMap(\.ids) == savedControlIDs, savedControlIDs.count == 31,
              sources.files.allSatisfy({ $0.sha256 == "2555a5234bc949de465e00781b39a05871edf9ef28a1bc03002ce4551f15d2ce" }) else {
            throw BacktestConfigurationError.invalidParameter("RMR5EPS5 frozen canonical source and 31 saved controls")
        }
        func date(_ day: String) throws -> Date {
            guard let d = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { throw BacktestConfigurationError.invalidParameter("RMR5EPS5 source session date") }
            return d
        }
        var bars: [String: [PriceBar]] = [:]
        for symbol in coreSymbols { bars[symbol] = try input.series[symbol]!.map { .init(date: try date($0.date), price: $0.valuation_price) } }
        let fx = try input.original_strictprior_FX_observations.map { FXPoint(date: try date($0.date), usdPerCNY: $0.usd_per_cny) }
        let preparation = try nativePreparation(barsBySymbol: bars, fxPoints: fx, fundedDates: input.funded_union_calendar.map(date))
        let signalEvidence = try signals(frame: preparation.frame)
        var accounts: [Account] = [], decisions: [String: [Decision]] = [:], completions: [String: [Completion]] = [:]
        var cashEvidence: [String: Any] = [:], targetAudits: [String: [String: Int]] = [:]
        var accounting: [String: [[String: Any]]] = [:], fills: [String: [[String: Any]]] = [:]
        let iso = ISO8601DateFormatter().string(from:)
        for (id, role) in [(candidateID, Role.candidate), (equalID, Role.equal), (cashID, Role.cash)] {
            let run = try runAccount(preparation: preparation, signals: signalEvidence, role: role)
            let simulation = run.simulation
            decisions[id] = run.decisions; completions[id] = run.completions
            cashEvidence[id] = cashObject(simulation.cashYieldSummary)
            targetAudits[id] = ["desired_accepted_mismatches": run.targetMismatchCount, "state_count": simulation.dailyStates.count]
            accounts.append(.init(id: id, states: simulation.dailyStates, trades: simulation.trades, savedObject: nil))
            accounting[id] = simulation.dailyStates.enumerated().map { index, state in
                let previous = index > 0 ? simulation.dailyStates[index - 1] : nil
                let period = previous.map { CashYieldCNY.periodReturn(from: $0.date, to: state.date) } ?? 0
                let interest = previous.map { max($0.cash, 0) * period } ?? 0
                let units = Dictionary(uniqueKeysWithValues: coreSymbols.map { symbol in
                    (symbol, (state.holdingsBySymbol[symbol] ?? 0) / preparation.frame.pricesBySymbol[symbol]![index])
                })
                let held = coreSymbols.reduce(0.0) { $0 + (state.holdingsBySymbol[$1] ?? 0) }
                return ["index": index, "date": iso(state.date), "targetWeights": state.targetWeights, "cash": state.cash,
                    "holdingsBySymbol": state.holdingsBySymbol, "unitsBySymbol": units, "portfolioValue": state.portfolioValue,
                    "grossExposure": held / state.portfolioValue, "cashInterest": interest,
                    "cashPeriodReturn": period, "cashAnnualRate": previous.map { CashYieldCNY.annualRate(on: $0.date) } as Any? ?? NSNull()]
            }
            fills[id] = simulation.trades.enumerated().map { order, trade in
                let buy = trade.action == .buy
                let fee = buy ? trade.cashAmount * 0.00025 : trade.units * trade.price * 0.00025
                return ["order": order, "date": iso(trade.date), "symbol": trade.assetSymbol, "action": buy ? "buy" : "sell",
                    "price": trade.price, "units": trade.units, "cashAmount": trade.cashAmount,
                    "cashDelta": buy ? -trade.cashAmount : trade.cashAmount, "fee": fee]
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var selectedIDs: [String] = []
        for file in sources.files {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
            guard ResearchRunEvidence.sha256(data) == file.sha256,
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BacktestConfigurationError.invalidParameter("RMR5EPS5 saved raw hash/rows") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }), !selectedIDs.contains(id) else {
                    throw BacktestConfigurationError.invalidParameter("RMR5EPS5 saved identity/state order")
                }
                selectedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("RMR5EPS5 one candidate / 3 fresh / 31 saved") }
        let text = BacktestSeriesAlignment.historicalSeriesDateString(from:)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func object(_ row: DailyScreenOutput.Row, account: Account) throws -> [String: Any] {
            var result = try JSONSerialization.jsonObject(with: encoder.encode(row)) as! [String: Any]
            if let saved = account.savedObject { result["trades"] = saved["trades"] ?? [] }
            return result
        }
        func comparison(_ selected: [Account]) throws -> ([[String: Any]], [Date]) {
            let common = selected.reduce(Set(selected[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("RMR5EPS5 complete mechanical comparison calendar") }
            let commonSet = Set(common), last = common.last!
            let ten = BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding: .year, value: -10, to: last)!
            let windows = [("full", text(common.first!), text(last)), ("trailing10Y", text(ten), text(last)),
                ("since2020", "2020-01-01", text(last)), ("since2022", "2022-01-01", text(last)),
                ("crisis2008", "2008-01-01", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"), ("crisis2022", "2022-01-01", "2022-12-31")]
            return (try selected.map { a in
                let states = a.states.filter { commonSet.contains($0.date) }
                let row = a.savedObject == nil ? try checkedRow(a.id, states: states, trades: a.trades, windows: windows)
                    : try DailyScreenOutput.row(a.id, states: states, trades: a.trades, windows: windows)
                return try object(row, account: a)
            }, common)
        }
        let (longRows, longDates) = try comparison(accounts.filter { $0.id != qualID })
        let (allRows, allDates) = try comparison(accounts)
        guard longDates.map(text) == input.saved_long_comparison_dates, longDates.count == 5595,
              text(longDates.first!) == "2002-09-18", text(longDates.last!) == "2026-09-30",
              allDates.map(text) == input.saved_short_comparison_dates, allDates.count == 3086,
              text(allDates.first!) == "2013-07-18", text(allDates.last!) == "2026-09-30" else {
            throw BacktestConfigurationError.invalidParameter("RMR5EPS5 no comparison-day deletion")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(checkedRow(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        let signalObjects = try Self.signalObjects(signalEvidence, encoder: encoder)
        var quoteObjects = try JSONSerialization.jsonObject(with: encoder.encode(preparation.quotes)) as! [[String: Any]]
        for i in quoteObjects.indices { for key in ["fxDate", "usdPerCNY", "cnyPerUSD", "fxAgeDays"] where quoteObjects[i][key] == nil { quoteObjects[i][key] = NSNull() } }
        var decisionObjects = try JSONSerialization.jsonObject(with: encoder.encode(decisions)) as! [String: [[String: Any]]]
        for id in decisionObjects.keys { for i in decisionObjects[id]!.indices {
            for key in ["requestedTarget", "pendingBefore", "pendingAfter"] where decisionObjects[id]![i][key] == nil { decisionObjects[id]![i][key] = NSNull() }
        } }
        let frameObject: [String: Any] = ["dates": preparation.frame.dates.map(text), "prices": preparation.frame.pricesBySymbol,
            "execution_prices": preparation.executionPrices, "observed": preparation.frame.observedBySymbol,
            "core_symbol_order": coreSymbols, "simulation_first": 0, "simulation_last": preparation.frame.dates.count - 1]
        var outputs: [String: Data] = [:]
        for (name, object) in [("result.json", longRows as Any), ("native-full.json", nativeRows as Any), ("all20.json", allRows as Any),
            ("signals.json", signalObjects as Any), ("decisions.json", decisionObjects as Any), ("quotes.json", quoteObjects as Any),
            ("native-frame.json", frameObject as Any), ("cash-yield.json", cashEvidence as Any), ("accounting.json", accounting as Any), ("fill-audit.json", fills as Any)] {
            outputs[name] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        outputs["completion-events.json"] = try encoder.encode(completions)
        let hashes = outputs.mapValues(ResearchRunEvidence.sha256)
        let evidence: [String: Any] = ["completed_at": iso(Date()), "source_commit": sourceCommit,
            "evidence_class": "POST_HOC_RELATED_D0_WHOLE_RMR_NORMALIZED_PRICE_GEOMETRY_MULTIPLICITY_NUMERICS_STARTUP_AND_NEXT_CLOSE_ADAPTATION", "formal_validation": false, "recommendation_eligible": false,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "pre_specification_sha256": "276a24e9a577b0f4d9994741b39ba334844f282154b9328b0b72cc0196f89d60",
            "original_definition": "HuangZhouLiHoiZhou2013_WHOLE_RMR_W5_EPS5_M200_EXPLICIT_ENGINEERED_STARTUP_MULTIPLICITY_AND_BINARY64",
            "source_primary_sha256": "2f38f0ae3e0ce3d93565a664d7c1e16d699a803842b571484245ac0dea01e9c6",
            "source_engineering_proposal_sha256": "9c4f0eb8b0a5d95f54ce893f74400ad1da2be978f95f158f291eae2907e6963f",
            "signal_schema": "fixed-rmr5-eps5-core-signal-v1", "window": window, "epsilon": epsilon, "m": 200, "maximum_actual_updates": maximumUpdates, "tau": tau, "model_sum_tolerance": sumTolerance,
            "model_policy": "Price-only p0ones and literal x*p products; initial/warm direct Double1/3 checksum only; full5window newest-first from signal4; coordinate seed/joint objective multiplicity-count modified Weiszfeld/max199/new-iterate tau; relaxed PA/once Euclidean simplex/no latent normalization or account feedback",
            "numerical_policy": "Finite required domains; signed/zero cancellation legal; observable nonzero mul/div underflow0 rejects; positive prices/mu/forecast required; exact count/coincidence/support and checksum only; no floor/clip/reset/ridge/cash fallback",
            "failure_diagnostic_policy": "Before fresh account row same unchanged DailyScreenOutput clauses/order/Dictionary.values.reduce/thresholds, firstfailure deterministic JSON allclauses/rawvalues/nonfinite string labels; successful metrics path unchanged",
            "primitives_sha256": ResearchRunEvidence.sha256(raw), "accounts_sha256": ResearchRunEvidence.sha256(savedRaw),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "output_sha256": hashes, "candidate_count": 1, "new_funded_account_count": 3, "saved_control_count": 31, "account_count": 34,
            "parameter_search_budget": 0, "native_state_count": 6452, "native_start": "2001-06-25", "native_end": "2026-10-06",
            "long_common_dates": longDates.map(text), "all20_common_dates": allDates.map(text), "long_comparison_count": longRows.count,
            "all20_comparison_count": allRows.count, "long_excluded_id": qualID, "saved_control_ids": selectedIDs,
            "saved_source_files": sources.files.map { ["path": $0.path, "sha256": $0.sha256, "ids": $0.ids] as [String: Any] },
            "target_audits": targetAudits, "fee_rate": 0.00025, "slippage_rate": 0, "cash": "CashYieldCNY",
            "primary_metric": "App complete funded-native daily NAV Sharpe Rf=0", "primary": ["threshold": 1.2, "require_native_full": true,
                "require_long_common19_sharpe_at_least_1_2": true, "require_beat_strongest19": true, "all20_supplement_only": true],
            "strongest19_control_ids": BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs,
            "price_policy": "canonical valuation_price source-close only; signal/execution/mark identical; gold CNY; USD / strictly prior quote-day usd_per_cny max14 days once; carry valuation only",
            "cadence_policy": "initial sentinel Int.min/2; index0cash/initialequalmodel; index1execsignal0; model interval1 from close1 delivered index2; full window signal4 delivered index5; daily index>=1/latestprior replacespending; band0/gross1",
            "ideal_book_actual_NAV_identity_claimed": false, "old_RP_GMV_Cover_control_parity_claimed": false,
            "dual_clock_limitation": "Paper immediate-price portfolio process differs from true next-close/strictpriorFX/cost/settlement single account. Price-only normalized geometry/latent RMR is separate from actual NAV; no source Sharpe guarantee or epsilon-feasibility guarantee.",
            "units_policy": "accounting unitsBySymbol derived from genuine shared state holding value divided by canonical mark; ordered fills allow independent units reconstruction",
            "limitations": ["Price proxies; no directly executable securities/closing-auction, publication-vintage, futures-roll or total-return certification.",
                "Author-used w5/epsilon5/m200; tau/startup/multiplicity/scalar order/finite median/simplex/next-close are explicit engineering. Related reversion exposure/census UNKNOWN; no original driver/helper numerical parity, exact median/joint PA optimizer, fresh alpha or OOS claim.",
                "No dividends/tax/USD wallet/FX spreads; 31 prior native whole objects preserved with original limitations; short calendar supplemental only."]]
        outputs["evidence.json"] = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in outputs.keys.sorted() { try outputs[name]!.write(to: output.appendingPathComponent(name)) }
        print("Fixed RMR5EPS5 core: 1 candidate, 3 fresh accounts, 31 saved controls; native6452/long5595/short3086 dates.")
    }
}
