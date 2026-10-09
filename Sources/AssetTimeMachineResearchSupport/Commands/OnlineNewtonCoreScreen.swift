import Foundation
import AssetTimeMachineBacktestCore

/// Frozen original ONS full-past price-only gradient curvature.
/// All actual cash, units, fills and NAV come from one unchanged shared account.
public enum OnlineNewtonCoreScreen {
    public static let coreSymbols = RiskParityCoreScreen.coreSymbols
    public static let candidateID = "ons-three-core-daily-next-close"
    public static let equalID = "equal-core100-ons-daily-close-control"
    public static let cashID = "cny-cash-ons-native2001"
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

    public static func nativePreparation(barsBySymbol: [String: [PriceBar]], fxPoints: [FXPoint], fundedDates: [Date]) throws -> NativePreparation {
        try RiskParityCoreScreen.nativePreparation(barsBySymbol: barsBySymbol, fxPoints: fxPoints, fundedDates: fundedDates)
    }
    public static func providerClean(_ weights: [String: Double]) -> [String: Double] { RiskParityCoreScreen.providerClean(weights) }

    public static let eta = 0.0
    public static let beta = 1.0
    public static let delta = 0.125
    private static func invalid(_ reason: String) -> BacktestConfigurationError { .invalidParameter("ONS " + reason) }
    private static func finite(_ x: Double) throws -> Double {
        guard x.isFinite else { throw invalid("nonfinite arithmetic; no fallback") }; return x
    }
    static func multiply(_ a: Double, _ b: Double) throws -> Double {
        guard a.isFinite, b.isFinite else { throw invalid("nonfinite operands") }
        let x = try finite(a * b)
        guard a == 0 || b == 0 || x != 0 else { throw invalid("signed nonzero product underflow") }; return x
    }
    static func divide(_ a: Double, _ b: Double) throws -> Double {
        guard a.isFinite, b.isFinite, b > 0 else { throw invalid("finite positive divisor") }
        let x = try finite(a / b)
        guard a == 0 || x != 0 else { throw invalid("signed nonzero division underflow") }; return x
    }
    static func sum(_ values: [Double]) throws -> Double {
        var value = 0.0
        for x in values { value = try finite(value + x) }; return value
    }
    static func normalize(_ p: [Double]) throws -> (weights: [Double], denominator: Double) {
        guard p.count == 3, p.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw invalid("nonnegative three-vector") }
        let total = try sum(p)
        guard total > 0 else { throw invalid("nonempty support") }
        return (try p.map { try divide($0, total) }, total)
    }
    public struct ModelState: Encodable, Equatable {
        public let p: [Double]
        public let A: [Double]
        public let b: [Double]
    }
    public static func initialState() throws -> ModelState {
        let p = try normalize(Array(repeating: 1.0 / 3, count: 3)).weights
        return .init(p: p, A: [1,0,0,0,1,0,0,0,1], b: [0,0,0])
    }
    public struct CholeskyEvidence: Encodable, Equatable {
        public let dimension: Int
        public let submatrix: [Double]
        public let residuals: [Double]
        public let lower: [Double]
        public let pivots: [Double]
    }
    public struct SolveEvidence: Encodable, Equatable {
        public let rhs: [Double]
        public let forward: [Double]
        public let solution: [Double]
    }
    static func cholesky(_ matrix: [Double], dimension n: Int) throws -> CholeskyEvidence {
        guard n > 0, matrix.count == n * n, matrix.allSatisfy(\.isFinite) else { throw invalid("finite square Cholesky") }
        var lower = Array(repeating: 0.0, count: n * n), residuals = lower
        var pivots = Array(repeating: 0.0, count: n)
        for i in 0..<n { for j in 0...i {
            var residual = matrix[i * n + j]
            for k in 0..<j { residual = try finite(residual - multiply(lower[i * n + k], lower[j * n + k])) }
            residuals[i * n + j] = residual
            if i == j {
                guard residual > 0 else { throw invalid("strict SPD diagonal residual; no jitter") }
                let pivot = try finite(sqrt(residual))
                guard pivot > 0 else { throw invalid("positive pivot") }
                lower[i * n + j] = pivot; pivots[i] = pivot
            } else { lower[i * n + j] = try divide(residual, lower[j * n + j]) }
        } }
        return .init(dimension: n, submatrix: matrix, residuals: residuals, lower: lower, pivots: pivots)
    }
    static func solve(_ factor: CholeskyEvidence, rhs: [Double]) throws -> SolveEvidence {
        let n = factor.dimension
        guard rhs.count == n, rhs.allSatisfy(\.isFinite) else { throw invalid("signed finite RHS") }
        var forward = Array(repeating: 0.0, count: n), solution = forward
        for i in 0..<n {
            var residual = rhs[i]
            for j in 0..<i { residual = try finite(residual - multiply(factor.lower[i * n + j], forward[j])) }
            forward[i] = try divide(residual, factor.lower[i * n + i])
        }
        for i in (0..<n).reversed() {
            var residual = forward[i]
            for j in (i + 1)..<n { residual = try finite(residual - multiply(factor.lower[j * n + i], solution[j])) }
            solution[i] = try divide(residual, factor.lower[i * n + i])
        }
        return .init(rhs: rhs, forward: forward, solution: solution)
    }
    public struct Objective: Encodable, Equatable {
        public let Ap: [Double]
        public let quadratic: Double
        public let linear: Double
        public let scaledLinear: Double
        public let Q: Double
    }
    static func objective(A: [Double], b: [Double], p: [Double]) throws -> Objective {
        var rows: [Double] = []
        for i in 0..<3 {
            var row = 0.0
            for j in 0..<3 { row = try finite(row + multiply(A[i * 3 + j], p[j])) }; rows.append(row)
        }
        var quadratic = 0.0, linear = 0.0
        for i in 0..<3 {
            quadratic = try finite(quadratic + multiply(p[i], rows[i]))
            linear = try finite(linear + multiply(b[i], p[i]))
        }
        let scaled = try multiply(2 * delta, linear)
        return .init(Ap: rows, quadratic: quadratic, linear: linear, scaledLinear: scaled, Q: try finite(quadratic - scaled))
    }
    public struct Face: Encodable, Equatable {
        public let mask: Int
        public let activeIndices: [Int]
        public let status: String
        public let feasible: Bool
        public let rawWeights: [Double]
        public let rawSum: Double?
        public let normalizedWeights: [Double]?
        public let objective: Objective?
        public let cholesky: CholeskyEvidence?
        public let uSolve: SolveEvidence?
        public let vSolve: SolveEvidence?
        public let u: [Double]?
        public let v: [Double]?
        public let sumU: Double?
        public let sumV: Double?
        public let lambda: Double?
    }
    public struct KKT: Encodable, Equatable {
        public let positiveSupport: [Int]
        public let zeroSupport: [Int]
        public let h: [Double]
        public let d: [Double]
        public let a: [Double]
        public let lambda: Double
        public let residuals: [Double]
        public let scales: [Double]
        public let tolerances: [Double]
        public let coordinateChecks: [Bool]
        public let weightSum: Double
        public let sumError: Double
        public let sumCheck: Bool
        public let passed: Bool
    }
    static func winnerKKT(A: [Double], b: [Double], p: [Double]) throws -> KKT {
        let active = p.indices.filter { p[$0] > 0 }, zero = p.indices.filter { p[$0] == 0 }
        guard !active.isEmpty else { throw invalid("winner nonempty support") }
        let h = try objective(A: A, b: b, p: p).Ap
        let d = try b.map { try multiply(delta, $0) }
        let a = try p.indices.map { try finite(d[$0] - h[$0]) }
        let lambda = try divide(sum(active.map { a[$0] }), Double(active.count))
        var residuals: [Double] = [], scales: [Double] = [], tolerances: [Double] = [], checks: [Bool] = []
        for i in 0..<3 {
            let residual = try finite((h[i] - d[i]) + lambda)
            let scale = max(1, max(abs(h[i]), max(abs(d[i]), abs(lambda))))
            let tolerance = try finite(1e-9 + multiply(1e-9, scale))
            residuals.append(residual); scales.append(scale); tolerances.append(tolerance)
            checks.append(p[i] > 0 ? abs(residual) <= tolerance : residual >= -tolerance)
        }
        let weightSum = try sum(p), error = abs(weightSum - 1), sumCheck = error <= 1e-12
        return .init(positiveSupport: active, zeroSupport: zero, h: h, d: d, a: a, lambda: lambda,
            residuals: residuals, scales: scales, tolerances: tolerances, coordinateChecks: checks,
            weightSum: weightSum, sumError: error, sumCheck: sumCheck, passed: checks.allSatisfy { $0 } && sumCheck)
    }
    public struct Projection: Encodable, Equatable {
        public let faces: [Face]
        public let winningMask: Int
        public let winningOrdinal: Int
        public let minimumTieMasks: [Int]
        public let winningQ: Double
        public let pNext: [Double]
        public let kkt: KKT
    }
    public static func project(A: [Double], b: [Double]) throws -> Projection {
        guard A.count == 9, b.count == 3, A.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { throw invalid("finite symmetric3 projection") }
        for i in 0..<3 {
            for j in 0..<3 {
                guard A[i * 3 + j] == A[j * 3 + i] else { throw invalid("finite symmetric3 projection") }
            }
        }
        var faces: [Face] = [], winner: Int?
        for mask in 1...7 {
            let active = (0..<3).filter { (mask & (1 << $0)) != 0 }
            var raw = [0.0, 0.0, 0.0]
            var factor: CholeskyEvidence?, uSolve: SolveEvidence?, vSolve: SolveEvidence?
            var u: [Double]?, v: [Double]?, sumU: Double?, sumV: Double?, lambda: Double?
            if active.count == 1 { raw[active[0]] = 1 } else {
                let matrix = active.flatMap { i in active.map { j in A[i * 3 + j] } }
                factor = try cholesky(matrix, dimension: active.count)
                uSolve = try solve(factor!, rhs: active.map { try multiply(delta, b[$0]) })
                vSolve = try solve(factor!, rhs: Array(repeating: 1, count: active.count))
                u = uSolve!.solution; v = vSolve!.solution
                sumU = try sum(u!); sumV = try sum(v!)
                guard sumV! > 0 else { throw invalid("positive sumv") }
                lambda = try divide(finite(sumU! - 1), sumV!)
                for (j, i) in active.enumerated() { raw[i] = try finite(u![j] - multiply(lambda!, v![j])) }
            }
            let feasible = active.allSatisfy { raw[$0] >= 0 }
            let normalization = feasible ? try normalize(raw) : nil
            let value = try normalization.map { try objective(A: A, b: b, p: $0.weights) }
            faces.append(.init(mask: mask, activeIndices: active,
                status: !feasible ? "outside-face-negative-coordinate" : (active.count == 1 ? "singleton-exact-vertex" : "feasible-stationary"),
                feasible: feasible, rawWeights: raw, rawSum: normalization?.denominator,
                normalizedWeights: normalization?.weights, objective: value, cholesky: factor,
                uSolve: uSolve, vSolve: vSolve, u: u, v: v, sumU: sumU, sumV: sumV, lambda: lambda))
            if let value, winner == nil || value.Q < faces[winner!].objective!.Q { winner = faces.count - 1 }
        }
        guard let winner else { throw invalid("projection has no feasible face") }
        let chosen = faces[winner], p = chosen.normalizedWeights! // Exact copy; no second normalization.
        let kkt = try winnerKKT(A: A, b: b, p: p)
        guard kkt.passed else { throw invalid("winner KKT qualification failed; no retry") }
        let ties = faces.compactMap { $0.objective?.Q == chosen.objective!.Q ? $0.mask : nil }
        return .init(faces: faces, winningMask: chosen.mask, winningOrdinal: winner, minimumTieMasks: ties,
            winningQ: chosen.objective!.Q, pNext: p, kkt: kkt)
    }
    public struct ModelUpdate: Encodable, Equatable {
        public let incomingP: [Double]
        public let incomingA: [Double]
        public let incomingB: [Double]
        public let x: [Double]
        public let priceProducts: [Double]
        public let growthDenominator: Double
        public let gradient: [Double]
        public let outerProducts: [Double]
        public let linearIncrements: [Double]
        public let projection: Projection
        public let next: ModelState
    }
    public static func update(previous: ModelState, x: [Double]) throws -> ModelUpdate {
        guard previous.p.count == 3, previous.A.count == 9, previous.b.count == 3,
              previous.p.allSatisfy({ $0.isFinite && $0 >= 0 }), previous.A.allSatisfy(\.isFinite), previous.b.allSatisfy(\.isFinite),
              x.count == 3, x.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw invalid("valid model and positive relatives") }
        let products = try (0..<3).map { try multiply(previous.p[$0], x[$0]) }
        let denominator = try sum(products)
        guard denominator > 0 else { throw invalid("positive p dot x") }
        let gradient = try x.map { try divide($0, denominator) }
        guard gradient.allSatisfy({ $0 > 0 }) else { throw invalid("positive gradients") }
        var outer = Array(repeating: 0.0, count: 9), A = previous.A
        for i in 0..<3 { for j in 0...i {
            let product = try multiply(gradient[i], gradient[j])
            let value = try finite(A[i * 3 + j] + product)
            guard value > 0 else { throw invalid("positive updated curvature") }
            outer[i * 3 + j] = product; outer[j * 3 + i] = product
            A[i * 3 + j] = value; A[j * 3 + i] = value
        } }
        let increments = try gradient.map { try multiply(2, $0) }
        let b = try (0..<3).map { try finite(previous.b[$0] + increments[$0]) }
        guard b.allSatisfy({ $0 > 0 }) else { throw invalid("positive updated linear state") }
        let projection = try project(A: A, b: b)
        return .init(incomingP: previous.p, incomingA: previous.A, incomingB: previous.b, x: x,
            priceProducts: products, growthDenominator: denominator, gradient: gradient,
            outerProducts: outer, linearIncrements: increments, projection: projection,
            next: .init(p: projection.pNext, A: A, b: b))
    }
    public struct RoleDiagnostic: Encodable, Equatable { public let symbol: String; public let rawWeight: Double; public let cleanedWeight: Double }
    public struct Signal: Encodable, Equatable {
        public let signalIndex: Int
        public let date: Date
        public let intervalCount: Int
        public let reason: String
        public let update: ModelUpdate?
        public let pNext: [Double]
        public let ANext: [Double]
        public let bNext: [Double]
        public let roles: [RoleDiagnostic]
        public let rawTarget: [String: Double]
        public let cleanedTarget: [String: Double]
    }
    public static func signals(frame: MarketDataFrame) throws -> [Signal] {
        guard coreSymbols.allSatisfy({ symbol in
            guard let p = frame.pricesBySymbol[symbol], p.count == frame.dates.count else { return false }
            return p.allSatisfy { $0.isFinite && $0 > 0 }
        }) else { throw invalid("full positive canonical frame") }
        var previous = try initialState()
        return try frame.dates.indices.map { s in
            var model: ModelUpdate?
            if s > 0 {
                let x = try coreSymbols.map { try divide(frame.pricesBySymbol[$0]![s], frame.pricesBySymbol[$0]![s - 1]) }
                model = try update(previous: previous, x: x); previous = model!.next
            }
            let raw = Dictionary(uniqueKeysWithValues: coreSymbols.indices.map { (coreSymbols[$0], previous.p[$0]) })
            let clean = providerClean(raw)
            return .init(signalIndex: s, date: frame.dates[s], intervalCount: s,
                reason: s == 0 ? "baseline-normalized-equal-I-zero" : "sequential-ONS-fullpast-gradient-curvature",
                update: model, pNext: previous.p, ANext: previous.A, bNext: previous.b,
                roles: coreSymbols.indices.map { .init(symbol: coreSymbols[$0], rawWeight: previous.p[$0], cleanedWeight: clean[coreSymbols[$0]] ?? 0) },
                rawTarget: raw, cleanedTarget: clean)
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
                throw BacktestConfigurationError.invalidParameter("ONS accounting diagnostic " + String(decoding: data, as: UTF8.self))
            }
        }
    }
    static func signalObjects(_ evidence: [Signal], encoder: JSONEncoder) throws -> [[String: Any]] {
        var rows = try JSONSerialization.jsonObject(with: encoder.encode(evidence)) as! [[String: Any]]
        let keys = ["incomingP", "incomingA", "incomingB", "x", "priceProducts", "growthDenominator", "gradient", "outerProducts", "linearIncrements", "projection"]
        let faceKeys = ["rawSum", "normalizedWeights", "objective", "cholesky", "uSolve", "vSolve", "u", "v", "sumU", "sumV", "lambda"]
        for i in rows.indices {
            if var model = rows[i].removeValue(forKey: "update") as? [String: Any] {
                model.removeValue(forKey: "next") // Outgoing state already explicit pNext/ANext/bNext.
                if var projection = model["projection"] as? [String: Any], var faces = projection["faces"] as? [[String: Any]] {
                    for j in faces.indices { for key in faceKeys where faces[j][key] == nil { faces[j][key] = NSNull() } }
                    projection["faces"] = faces; model["projection"] = projection
                }
                for (key, value) in model { rows[i][key] = value }
            }
            for key in keys where rows[i][key] == nil { rows[i][key] = NSNull() }
        }
        return rows
    }
    public static func runAccount(preparation: NativePreparation, signals: [Signal], role: Role) throws -> NativeRun {
        guard signals.count == preparation.frame.dates.count,
              signals.enumerated().allSatisfy({ $0.offset == $0.element.signalIndex && $0.element.date == preparation.frame.dates[$0.offset] }) else {
            throw BacktestConfigurationError.invalidParameter("ONS exact funded signal alignment")
        }
        return try simulate(preparation: preparation,
            buyReason: role == .candidate ? "fixed ONS core close research" : "fixed ONS daily core close control") { context in
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
        guard frame.simulationRange.lowerBound == 0 else { throw BacktestConfigurationError.invalidParameter("ONS full funded baseline") }
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
            throw BacktestConfigurationError.invalidParameter("ONS unchanged cash baseline/full formation history")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].acceptedAfter = run.dailyStates[i].targetWeights
            let desired = decisions[i].requestedTarget ?? expected[i]
            if decisions[i].acceptedAfter != desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("ONS target adapter delivery") }
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
            throw BacktestConfigurationError.invalidParameter("ONS frozen canonical source and 31 saved controls")
        }
        func date(_ day: String) throws -> Date {
            guard let d = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { throw BacktestConfigurationError.invalidParameter("ONS source session date") }
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
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BacktestConfigurationError.invalidParameter("ONS saved raw hash/rows") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }), !selectedIDs.contains(id) else {
                    throw BacktestConfigurationError.invalidParameter("ONS saved identity/state order")
                }
                selectedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("ONS one candidate / 3 fresh / 31 saved") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("ONS complete mechanical comparison calendar") }
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
            throw BacktestConfigurationError.invalidParameter("ONS no comparison-day deletion")
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
            "evidence_class": "POST_HOC_RELATED_D0_ORIGINAL_ONS_NEXT_CLOSE_AND_FACE_SOLVER_ADAPTATION", "formal_validation": false, "recommendation_eligible": false,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "pre_specification_sha256": "7840b07020c00e6a246195a27a031262fdf36948fdc5003e3c3b8b5591163229",
            "original_definition": "AgarwalHazanKaleSchapire2006_ONS_eta0_beta1_delta0_125_root_face_projection",
            "source_primary_sha256": "86adbb483c8c8b50baaa7e3609b85f73c89f530388a2a58e08021e5c49ccbac1",
            "source_engineering_proposal_sha256": "c9c367d29896e18abac5b480cbf1131666d42b8853064f355e7e91744ec640f6",
            "signal_schema": "fixed-ons-core-signal-v1", "eta": eta, "beta": beta, "delta": delta,
            "model_policy": "Normalized initial equal/I/zero; price-only fullpast normalized log gradient, exact lower-triangle mirrored I+sum outerproducts and b+=2g; no account/provider feedback, reset, discount, risk covariance or expert wealth",
            "solver_policy": "All7 ascending masks; singleton exact vertex; signed/zero strict no-pivot Cholesky and solves; negative raw face infeasible; one unconditional ordinal feasible-face normalization then ordered Ametric Q; strict firsttie; winner exact copy; winner-only fixed KKT diagnostics no adjustment",
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
            "cadence_policy": "initial sentinel Int.min/2; index0cash/initialequalmodel; index1execsignal0; model1fromclose1deliveredindex2; daily scheduled maintenance index>=1/latestprior model replacespending; sourceprice/account split; band0/gross1",
            "ideal_book_actual_NAV_identity_claimed": false, "old_RP_GMV_Cover_control_parity_claimed": false,
            "dual_clock_limitation": "Paper immediate-period ideal wealth differs from root nofinancing single-account canonical next-close/strictpriorFX/cost/settlement. Raw price-only ONS model is separate from genuine actual NAV. No source Sharpe guarantee.",
            "units_policy": "accounting unitsBySymbol derived from genuine shared state holding value divided by canonical mark; ordered fills allow independent units reconstruction",
            "limitations": ["Price proxies; no directly executable securities/closing-auction, publication-vintage, futures-roll or total-return certification.",
                "Original eta0/beta1/delta1/8 plus root signed seven-face/one-normalization/KKT and three-coreCNY daily next-close adaptation; related price-only allocation exposure/census UNKNOWN; no author code/empirical or theorem-default parity, pristine OOS or formal promotion.",
                "No dividends/tax/USD wallet/FX spreads; 31 prior native whole objects preserved with original limitations; short calendar supplemental only."]]
        outputs["evidence.json"] = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in outputs.keys.sorted() { try outputs[name]!.write(to: output.appendingPathComponent(name)) }
        print("Fixed ONS core: 1 candidate, 3 fresh accounts, 31 saved controls; native6452/long5595/short3086 dates.")
    }
}
