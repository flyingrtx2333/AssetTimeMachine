import Foundation
import AssetTimeMachineBacktestCore

/// Root-frozen modern excess-mean/full-covariance endogenous-cash utility.
/// Source state is price/cash-history only; actual NAV comes from one shared account.
public enum MeanVarianceUtilityCoreScreen {
    public static let coreSymbols = RiskParityCoreScreen.coreSymbols
    public static let candidateID = "mvu252-g20-cad21-three-core-next-close"
    public static let equalID = "equal-core100-mvu252g20cad21-daily-close-control"
    public static let cashID = "cny-cash-mvu252g20cad21-native2001"
    public static let qualID = ChaikinMoneyFlowScreen.qualID
    public static var savedControlIDs: [String] { ChaikinMoneyFlowScreen.savedControlIDs }
    public static let window = 252, cadence = 21
    public static let gamma = 20.0
    public typealias PriceBar = RiskParityCoreScreen.PriceBar
    public typealias FXPoint = RiskParityCoreScreen.FXPoint
    public typealias Quote = RiskParityCoreScreen.Quote
    public typealias NativePreparation = RiskParityCoreScreen.NativePreparation
    public typealias Completion = RiskParityCoreScreen.Completion
    public typealias Role = RiskParityCoreScreen.Role
    public static func nativePreparation(barsBySymbol: [String: [PriceBar]], fxPoints: [FXPoint], fundedDates: [Date]) throws -> NativePreparation {
        try RiskParityCoreScreen.nativePreparation(barsBySymbol: barsBySymbol, fxPoints: fxPoints, fundedDates: fundedDates)
    }
    public static func providerClean(_ weights: [String: Double]) -> [String: Double] { RiskParityCoreScreen.providerClean(weights) }
    public static func eligible(_ s: Int) -> Bool { s >= window && (s - window) % cadence == 0 }

    private struct Math {
        var signalIndex: Int? = nil
        var date: Date? = nil
        var stage: String
        func at(_ stage: String) -> Math { .init(signalIndex: signalIndex, date: date, stage: stage) }
        func scalar(_ value: Double) -> [String: Any] {
            ["category": value.isFinite ? "finite" : (value.isNaN ? "NaN" : (value > 0 ? "+Infinity" : "-Infinity")),
             "finiteValue": value.isFinite ? value as Any : NSNull(), "signBit": value.sign == .minus]
        }
        func fail(_ field: String, _ operation: String, _ operands: [Double], _ result: Double?, _ reason: String) -> BacktestConfigurationError {
            let object: [String: Any] = ["status": "SOURCE_INVALID", "signalIndex": signalIndex as Any? ?? NSNull(),
                "date": date.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                "stage": stage, "field": field, "operation": operation, "operands": operands.map(scalar),
                "result": result.map(scalar) as Any? ?? NSNull(), "reason": reason, "fallbackUsed": false]
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            return .invalidParameter("MVU252G20CAD21 source diagnostic " + String(decoding: data, as: UTF8.self))
        }
        func finite(_ value: Double, _ field: String) throws -> Double {
            guard value.isFinite else { throw fail(field, "input-domain", [value], value, "nonfinite") }; return value
        }
        func positive(_ value: Double, _ field: String) throws -> Double {
            _ = try finite(value, field)
            guard value > 0 else { throw fail(field, "input-domain", [value], value, "required-positive") }; return value
        }
        func add(_ a: Double, _ b: Double, _ field: String) throws -> Double {
            _ = try finite(a, field); _ = try finite(b, field)
            let r = a + b; guard r.isFinite else { throw fail(field, "add", [a,b], r, "nonfinite") }; return r
        }
        func sub(_ a: Double, _ b: Double, _ field: String) throws -> Double {
            _ = try finite(a, field); _ = try finite(b, field)
            let r = a - b; guard r.isFinite else { throw fail(field, "subtract", [a,b], r, "nonfinite") }; return r
        }
        func mul(_ a: Double, _ b: Double, _ field: String) throws -> Double {
            _ = try finite(a, field); _ = try finite(b, field)
            let r = a * b
            guard r.isFinite else { throw fail(field, "multiply", [a,b], r, "nonfinite") }
            guard a == 0 || b == 0 || r != 0 else { throw fail(field, "multiply", [a,b], r, "observable-underflow") }; return r
        }
        func div(_ a: Double, _ b: Double, _ field: String) throws -> Double {
            _ = try finite(a, field); _ = try finite(b, field)
            guard b != 0 else { throw fail(field, "divide", [a,b], nil, "required-positive") }
            let r = a / b
            guard r.isFinite else { throw fail(field, "divide", [a,b], r, "nonfinite") }
            guard a == 0 || r != 0 else { throw fail(field, "divide", [a,b], r, "observable-underflow") }; return r
        }
        func sum(_ values: [Double], _ field: String) throws -> Double {
            var r = 0.0
            for i in values.indices { r = try add(r, values[i], field + "[\(i)]") }; return r
        }
    }
    public struct CholeskyStep: Encodable, Equatable {
        public let row: Int, column: Int
        public let products: [Double], productSum: Double, residual: Double
        public let isDiagonal: Bool
        public let value: Double
    }
    public struct Cholesky: Encodable, Equatable {
        public let matrix: [[Double]], lower: [[Double]]
        public let steps: [CholeskyStep]
    }
    public static func cholesky(_ matrix: [[Double]]) throws -> Cholesky {
        try factor(matrix, math: .init(stage: "covariance-cholesky"))
    }
    private static func factor(_ matrix: [[Double]], math m: Math) throws -> Cholesky {
        let n = matrix.count
        guard (1...3).contains(n), matrix.allSatisfy({ $0.count == n }) else {
            throw m.fail("matrix", "input-domain", [], nil, "source-contract mismatch")
        }
        for i in 0..<n { for j in 0..<n { _ = try m.finite(matrix[i][j], "matrix[\(i)][\(j)]") } }
        guard (0..<n).allSatisfy({ i in (0..<n).allSatisfy { matrix[i][$0] == matrix[$0][i] } }) else {
            throw m.fail("matrix.symmetry", "input-domain", [], nil, "source-contract mismatch")
        }
        var lower = Array(repeating: Array(repeating: 0.0, count: n), count: n), steps: [CholeskyStep] = []
        for i in 0..<n { for j in 0...i {
            _ = try m.finite(matrix[i][j], "matrix[\(i)][\(j)]")
            var products: [Double] = []
            for k in 0..<j { products.append(try m.mul(lower[i][k], lower[j][k], "cholesky.products[\(i)][\(j)][\(k)]")) }
            let sum = try m.sum(products, "cholesky.sum[\(i)][\(j)]")
            let residual = try m.sub(matrix[i][j], sum, "cholesky.residual[\(i)][\(j)]")
            let value: Double
            if i == j {
                guard residual > 0 else { throw m.fail("cholesky.residual[\(i)][\(j)]", "sqrt", [residual], nil, "whole-not-SPD") }
                value = try m.positive(sqrt(residual), "cholesky.diagonal[\(i)]")
            } else { value = try m.div(residual, lower[j][j], "cholesky.offDiagonal[\(i)][\(j)]") }
            lower[i][j] = value
            steps.append(.init(row: i, column: j, products: products, productSum: sum, residual: residual, isDiagonal: i == j, value: value))
        } }
        return .init(matrix: matrix, lower: lower, steps: steps)
    }
    public struct LinearSolve: Encodable, Equatable {
        public let rhs: [Double], forwardProducts: [[Double]], forwardSums: [Double], forwardResiduals: [Double], forward: [Double]
        public let backwardProducts: [[Double]], backwardSums: [Double], backwardResiduals: [Double], solution: [Double]
        public let residualProducts: [[Double]], residualSums: [Double], residuals: [Double]
    }
    private static func solve(_ f: Cholesky, rhs: [Double], math m: Math) throws -> LinearSolve {
        let n = rhs.count
        var fp = Array(repeating: [Double](), count: n), bp = fp
        var fs = Array(repeating: 0.0, count: n), fr = fs, forward = fs, bs = fs, br = fs, z = fs
        for i in 0..<n {
            for k in 0..<i { fp[i].append(try m.mul(f.lower[i][k], forward[k], "forward.products[\(i)][\(k)]")) }
            fs[i] = try m.sum(fp[i], "forward.sum[\(i)]"); fr[i] = try m.sub(rhs[i], fs[i], "forward.residual[\(i)]")
            forward[i] = try m.div(fr[i], f.lower[i][i], "forward[\(i)]")
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            if i + 1 < n { for k in (i + 1)..<n { bp[i].append(try m.mul(f.lower[k][i], z[k], "backward.products[\(i)][\(k)]")) } }
            bs[i] = try m.sum(bp[i], "backward.sum[\(i)]"); br[i] = try m.sub(forward[i], bs[i], "backward.residual[\(i)]")
            z[i] = try m.div(br[i], f.lower[i][i], "solution[\(i)]")
        }
        var rp: [[Double]] = [], rs: [Double] = [], residuals: [Double] = []
        for i in 0..<n {
            let row = try (0..<n).map { try m.mul(f.matrix[i][$0], z[$0], "solveResidual.products[\(i)][\($0)]") }
            let sum = try m.sum(row, "solveResidual.sum[\(i)]")
            rp.append(row); rs.append(sum); residuals.append(try m.sub(sum, rhs[i], "solveResidual[\(i)]"))
        }
        return .init(rhs: rhs, forwardProducts: fp, forwardSums: fs, forwardResiduals: fr, forward: forward,
            backwardProducts: bp, backwardSums: bs, backwardResiduals: br, solution: z, residualProducts: rp, residualSums: rs, residuals: residuals)
    }
    public struct SubsetSolve: Encodable, Equatable {
        public let mask: Int, activeIndices: [Int], matrixA: [[Double]], cholesky: Cholesky
        public let uSolve: LinearSolve, vSolve: LinearSolve
        public let sumU: Double, sumV: Double, fullBudgetLambda: Double
    }
    public struct BudgetClosure: Encodable, Equatable {
        public let coreIndex: Int, earlierCoreIndices: [Int], earlierWeights: [Double]
        public let earlierSum: Double, rawCoordinate: Double, closedCoordinate: Double
    }
    public struct Objective: Encodable, Equatable {
        public let expectedProducts: [Double], expectedTerm: Double, rowProducts: [[Double]], rowSums: [Double], outerProducts: [Double]
        public let quadraticTerm: Double, riskTerm: Double, value: Double
    }
    public static func objective(mu: [Double], covariance: [[Double]], weights: [Double]) throws -> Objective {
        try objective(mu: mu, covariance: covariance, weights: weights, math: .init(stage: "objective"))
    }
    private static func objective(mu: [Double], covariance: [[Double]], weights: [Double], math m: Math) throws -> Objective {
        guard mu.count == 3, weights.count == 3, covariance.count == 3, covariance.allSatisfy({ $0.count == 3 }) else {
            throw m.fail("objective.shape", "input-domain", [], nil, "source-contract mismatch")
        }
        let expectedProducts = try (0..<3).map { try m.mul(mu[$0], weights[$0], "objective.expectedProducts[\($0)]") }
        let expected = try m.sum(expectedProducts, "objective.expectedTerm")
        var rows: [[Double]] = [], sums: [Double] = [], outer: [Double] = []
        for a in 0..<3 {
            let row = try (0..<3).map { try m.mul(covariance[a][$0], weights[$0], "objective.rowProducts[\(a)][\($0)]") }
            let sum = try m.sum(row, "objective.rowSums[\(a)]")
            rows.append(row); sums.append(sum); outer.append(try m.mul(weights[a], sum, "objective.outerProducts[\(a)]"))
        }
        let quad = try m.sum(outer, "objective.quadraticTerm")
        guard quad >= 0 else { throw m.fail("objective.quadraticTerm", "input-domain", [quad], quad, "negative-quadratic") }
        let risk = try m.mul(gamma / 2, quad, "objective.riskTerm"), value = try m.sub(expected, risk, "objective.value")
        return .init(expectedProducts: expectedProducts, expectedTerm: expected, rowProducts: rows, rowSums: sums, outerProducts: outer,
            quadraticTerm: quad, riskTerm: risk, value: value)
    }
    public struct Face: Encodable, Equatable {
        public let ordinal: Int, mask: Int, activeIndices: [Int], subsetSolveIndex: Int?
        public let solverLabel: String, economicLabel: String, lambda: Double, rawWeights: [Double], budgetClosure: BudgetClosure?
        public let weights: [Double], gross: Double, positiveSupportCount: Int, activePositiveChecks: [Bool], strictBudgetCheck: Bool
        public let fullBudgetChecksumError: Double?, fullBudgetChecksumCheck: Bool?, feasible: Bool, rejectReason: String?, objective: Objective?
    }
    public struct SelectionStep: Encodable, Equatable {
        public let candidateOrdinal: Int, incumbentOrdinalBefore: Int?, selected: Bool, comparison: String, incumbentOrdinalAfter: Int
    }
    public static func preferred(_ candidate: Face, over incumbent: Face) -> (Bool, String) {
        let a = candidate.objective!.value, b = incumbent.objective!.value
        if a > b { return (true, "objective_greater") }; if a < b { return (false, "objective_lower") }
        if candidate.gross < incumbent.gross { return (true, "equal_objective_lower_gross") }
        if candidate.gross > incumbent.gross { return (false, "equal_objective_higher_gross") }
        if candidate.positiveSupportCount < incumbent.positiveSupportCount { return (true, "equal_objective_lower_support") }
        if candidate.positiveSupportCount > incumbent.positiveSupportCount { return (false, "equal_objective_higher_support") }
        for i in 0..<3 {
            if candidate.weights[i] < incumbent.weights[i] { return (true, "equal_objective_lexicographic_smaller") }
            if candidate.weights[i] > incumbent.weights[i] { return (false, "equal_objective_lexicographic_larger") }
        }
        if candidate.ordinal < incumbent.ordinal { return (true, "equal_objective_lower_ordinal") }; return (false, "exact_tie_retained")
    }
    public struct KKTCheck: Encodable, Equatable {
        public let name: String, coreIndex: Int?, direction: String, lhs: Double, rhs: Double, scale: Double, tolerance: Double
        public let signedResidual: Double, absoluteResidual: Double, upperBound: Double?, passed: Bool
    }
    public struct KKT: Encodable, Equatable {
        public let weights: [Double], lambda: Double, sigmaProducts: [[Double]], sigmaW: [Double], gradients: [Double], gross: Double, budgetSlack: Double
        public let budgetBinding: Bool, activeIndices: [Int], checks: [KKTCheck], valid: Bool
    }
    public static func verifyKKT(mu: [Double], covariance: [[Double]], weights: [Double], lambda: Double) throws -> KKT {
        try kkt(mu: mu, covariance: covariance, weights: weights, lambda: lambda, math: .init(stage: "winner-kkt"))
    }
    private static func kkt(mu: [Double], covariance: [[Double]], weights: [Double], lambda: Double, math m: Math) throws -> KKT {
        let gross = try m.sum(weights, "kkt.gross"), slack = try m.sub(1, gross, "kkt.budgetSlack")
        guard weights.count == 3, weights.allSatisfy({ $0 >= 0 }), gross <= 1 else {
            throw m.fail("kkt.primal", "feasibility", weights, gross, "winner-KKT-invalid")
        }
        var rows: [[Double]] = [], sums: [Double] = [], gradients: [Double] = []
        for i in 0..<3 {
            let row = try (0..<3).map { try m.mul(covariance[i][$0], weights[$0], "kkt.sigmaProducts[\(i)][\($0)]") }
            let sum = try m.sum(row, "kkt.sigmaW[\(i)]")
            rows.append(row); sums.append(sum); gradients.append(try m.sub(mu[i], m.mul(gamma, sum, "kkt.gammaSigma[\(i)]"), "kkt.gradients[\(i)]"))
        }
        func check(_ name: String, _ core: Int?, _ eq: Bool, _ lhs: Double, _ rhs: Double) throws -> KKTCheck {
            _ = try m.finite(lhs, name); _ = try m.finite(rhs, name)
            let scale = max(abs(lhs), abs(rhs)), tolerance = try m.add(1e-10, m.mul(1e-10, scale, name + ".relativeTolerance"), name + ".tolerance")
            let residual = try m.sub(lhs, rhs, name + ".residual")
            let upper: Double? = eq ? nil : try m.add(rhs, tolerance, name + ".upperBound")
            return .init(name: name, coreIndex: core, direction: eq ? "equal" : "less-or-equal", lhs: lhs, rhs: rhs, scale: scale, tolerance: tolerance,
                signedResidual: residual, absoluteResidual: abs(residual), upperBound: upper, passed: eq ? abs(residual) <= tolerance : lhs <= upper!)
        }
        var checks = try (0..<3).map { try check("stationarity_core\($0)", $0, weights[$0] > 0, gradients[$0], lambda) }
        checks.append(try check("nonnegative_multiplier", nil, false, 0, lambda))
        checks.append(try check("budget_complementarity", nil, true, m.mul(lambda, slack, "kkt.complementarity"), 0))
        guard checks.allSatisfy(\.passed) else { throw m.fail("kkt.checks", "KKT-check", gradients + [lambda, gross], nil, "winner-KKT-invalid") }
        return .init(weights: weights, lambda: lambda, sigmaProducts: rows, sigmaW: sums, gradients: gradients, gross: gross, budgetSlack: slack,
            budgetBinding: gross == 1, activeIndices: (0..<3).filter { weights[$0] > 0 }, checks: checks, valid: true)
    }
    public struct Optimization: Encodable, Equatable {
        public let subsets: [SubsetSolve], faces: [Face], selectionSteps: [SelectionStep]
        public let winningOrdinal: Int, winningMask: Int, winningSolverLabel: String, winningEconomicLabel: String
        public let winningLambda: Double, winningWeights: [Double], winningGross: Double, winningCashWeight: Double, winningObjective: Double, kkt: KKT
    }
    public static func optimize(mu: [Double], covariance: [[Double]]) throws -> Optimization {
        try optimize(mu: mu, covariance: covariance, math: .init(stage: "covariance-cholesky"))
    }
    private static func optimize(mu: [Double], covariance: [[Double]], math m: Math) throws -> Optimization {
        guard mu.count == 3, covariance.count == 3, covariance.allSatisfy({ $0.count == 3 }) else { throw m.fail("optimizer.shape", "input-domain", [], nil, "source-contract mismatch") }
        _ = try factor(covariance, math: m.at("covariance-cholesky"))
        for i in mu.indices { _ = try m.finite(mu[i], "mu[\(i)]") }
        var subsets: [SubsetSolve] = [], faces: [Face] = []
        func face(_ mask: Int, _ active: [Int], _ full: Bool, _ u: [Double], _ lambda: Double) throws -> Face {
            let fm = m.at("face-closure"), ordinal = mask == 0 ? 0 : (full ? 2 * mask : 2 * mask - 1)
            var raw = [0.0,0.0,0.0]
            for local in active.indices { raw[active[local]] = full ? try fm.sub(u[local], fm.mul(lambda, subsets[mask-1].vSolve.solution[local], "face[\(ordinal)].lambdaV[\(local)]"), "face[\(ordinal)].raw[\(local)]") : u[local] }
            var weights = raw, closure: BudgetClosure?
            if full {
                let coordinate = active.last!, earlier = Array(active.dropLast()), values = earlier.map { raw[$0] }
                let sum = try fm.sum(values, "face[\(ordinal)].closure.earlierSum"), closed = try fm.sub(1, sum, "face[\(ordinal)].closure.closed")
                closure = .init(coreIndex: coordinate, earlierCoreIndices: earlier, earlierWeights: values, earlierSum: sum, rawCoordinate: raw[coordinate], closedCoordinate: closed)
                weights[coordinate] = closed
            }
            let gross = try fm.sum(weights, "face[\(ordinal)].gross"), positives = active.map { weights[$0] > 0 }
            let checksum = full ? abs(try fm.sub(gross, 1, "face[\(ordinal)].checksum")) : nil
            let checksumOK = checksum.map { $0 <= 1e-12 }
            let reject: String? = positives.contains(false) ? "active_nonpositive" : (gross > 1 ? "gross_above_one" : (checksumOK == false ? "full_budget_checksum_failed" : nil))
            let feasible = reject == nil
            let label = !feasible ? "algebraic_face_rejected" : (mask == 0 ? "cash" : (full ? "full_budget_face" : (gross == 1 ? "full_budget_unconstrained_lambda_zero" : "strict_slack")))
            let objective = feasible ? try objective(mu: mu, covariance: covariance, weights: weights, math: m.at("objective")) : nil
            return .init(ordinal: ordinal, mask: mask, activeIndices: active, subsetSolveIndex: mask == 0 ? nil : mask-1, solverLabel: mask == 0 ? "cash" : (full ? "full_budget" : "slack"),
                economicLabel: label, lambda: lambda, rawWeights: raw, budgetClosure: closure, weights: weights, gross: gross,
                positiveSupportCount: weights.filter { $0 > 0 }.count, activePositiveChecks: positives, strictBudgetCheck: gross <= 1,
                fullBudgetChecksumError: checksum, fullBudgetChecksumCheck: checksumOK, feasible: feasible, rejectReason: reject, objective: objective)
        }
        faces.append(try face(0, [], false, [], 0))
        for mask in 1...7 {
            let active = (0..<3).filter { mask & (1 << $0) != 0 }, sm = m.at("subset-cholesky")
            let block = try active.map { i in try active.map { j in try sm.mul(gamma, covariance[i][j], "subset[\(mask)].A[\(i)][\(j)]") } }
            let f = try factor(block, math: sm), solveMath = m.at("linear-solve")
            let u = try solve(f, rhs: active.map { mu[$0] }, math: solveMath), v = try solve(f, rhs: Array(repeating: 1, count: active.count), math: solveMath)
            let sumU = try solveMath.sum(u.solution, "subset[\(mask)].sumU"), sumV = try solveMath.positive(solveMath.sum(v.solution, "subset[\(mask)].sumV"), "subset[\(mask)].sumV")
            let lambda = try solveMath.div(solveMath.sub(sumU, 1, "subset[\(mask)].lambdaNumerator"), sumV, "subset[\(mask)].lambda")
            subsets.append(.init(mask: mask, activeIndices: active, matrixA: block, cholesky: f, uSolve: u, vSolve: v, sumU: sumU, sumV: sumV, fullBudgetLambda: lambda))
            faces.append(try face(mask, active, false, u.solution, 0)); faces.append(try face(mask, active, true, u.solution, lambda))
        }
        var best: Face?, selection: [SelectionStep] = []
        for f in faces where f.feasible {
            let before = best?.ordinal, result = best.map { preferred(f, over: $0) } ?? (true, "initial")
            if result.0 { best = f }
            selection.append(.init(candidateOrdinal: f.ordinal, incumbentOrdinalBefore: before, selected: result.0, comparison: result.1, incumbentOrdinalAfter: best!.ordinal))
        }
        let w = best!, check = try kkt(mu: mu, covariance: covariance, weights: w.weights, lambda: w.lambda, math: m.at("winner-kkt"))
        return .init(subsets: subsets, faces: faces, selectionSteps: selection, winningOrdinal: w.ordinal, winningMask: w.mask,
            winningSolverLabel: w.solverLabel, winningEconomicLabel: w.economicLabel, winningLambda: w.lambda, winningWeights: w.weights,
            winningGross: w.gross, winningCashWeight: try m.sub(1, w.gross, "winner.cashWeight"), winningObjective: w.objective!.value, kkt: check)
    }
    public struct CashRateSegment: Encodable, Equatable { public let effectiveDate: Date, segmentStart: Date, segmentEnd: Date, annualRate: Double }
    public struct CashInterval: Encodable, Equatable { public let intervalIndex: Int, fromDate: Date, toDate: Date, periodReturn: Double, effectiveRateSegments: [CashRateSegment] }
    public struct CovariancePair: Encodable, Equatable { public let row: Int, column: Int, products: [Double], sum: Double, covariance: Double }
    public struct Estimator: Encodable, Equatable {
        public let priceStartIndex: Int, returnStartIndex: Int, returnEndIndex: Int, intervalIndices: [Int]
        public let pricePrevious: [[Double]], priceCurrent: [[Double]], simpleReturns: [[Double]], cashIntervals: [CashInterval], excessReturns: [[Double]]
        public let meanSums: [Double], means: [Double], centeredExcess: [[Double]], covariancePairs: [CovariancePair], covarianceSums: [[Double]], covariance: [[Double]], covarianceCholesky: Cholesky
    }
    private static func segments(from: Date, to: Date) -> [CashRateSegment] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: from), end = calendar.startOfDay(for: to)
        let points = CashYieldCNY.ratePoints
        let first = points.last(where: { $0.date <= start })!
        let used = [first] + points.filter { $0.date > start && $0.date < end }
        return used.indices.map { i in .init(effectiveDate: used[i].date, segmentStart: i == 0 ? start : used[i].date,
            segmentEnd: i + 1 < used.count ? used[i + 1].date : end, annualRate: used[i].annualRate) }
    }
    public static func estimate(frame: MarketDataFrame, signalIndex s: Int) throws -> Estimator {
        let m = Math(signalIndex: s, date: frame.dates.indices.contains(s) ? frame.dates[s] : nil, stage: "estimator")
        guard s >= window, s < frame.dates.count else { throw m.fail("signalIndex", "input-domain", [], nil, "source-contract mismatch") }
        let indices = Array((s - 251)...s)
        let previous = coreSymbols.map { symbol in indices.map { frame.pricesBySymbol[symbol]![$0 - 1] } }
        let current = coreSymbols.map { symbol in indices.map { frame.pricesBySymbol[symbol]![$0] } }
        var returns: [[Double]] = []
        for a in 0..<3 { returns.append(try indices.indices.map { k in
            _ = try m.positive(previous[a][k], "previous[\(a)][\(k)]"); _ = try m.positive(current[a][k], "current[\(a)][\(k)]")
            return try m.sub(m.div(current[a][k], previous[a][k], "ratio[\(a)][\(k)]"), 1, "return[\(a)][\(k)]")
        }) }
        let cash = try indices.map { t -> CashInterval in
            let r = try m.finite(CashYieldCNY.periodReturn(from: frame.dates[t - 1], to: frame.dates[t]), "cashInterval[\(t)]")
            guard r >= 0 else { throw m.fail("cashInterval[\(t)]", "input-domain", [r], r, "source-contract mismatch") }
            return .init(intervalIndex: t, fromDate: frame.dates[t-1], toDate: frame.dates[t], periodReturn: r, effectiveRateSegments: segments(from: frame.dates[t-1], to: frame.dates[t]))
        }
        var excess: [[Double]] = [], sums: [Double] = [], means: [Double] = [], centered: [[Double]] = []
        for a in 0..<3 {
            let e = try indices.indices.map { try m.sub(returns[a][$0], cash[$0].periodReturn, "excess[\(a)][\($0)]") }
            let sum = try m.sum(e, "meanSum[\(a)]"), mean = try m.div(sum, 252, "mean[\(a)]")
            excess.append(e); sums.append(sum); means.append(mean)
            centered.append(try e.indices.map { try m.sub(e[$0], mean, "centered[\(a)][\($0)]") })
        }
        var pairs: [CovariancePair] = [], covarianceSums = Array(repeating: Array(repeating: 0.0, count: 3), count: 3), covariance = covarianceSums
        for a in 0..<3 { for b in a..<3 {
            let products = try indices.indices.map { try m.mul(centered[a][$0], centered[b][$0], "covarianceProducts[\(a)][\(b)][\($0)]") }
            let sum = try m.sum(products, "covarianceSum[\(a)][\(b)]"), value = try m.div(sum, 251, "covariance[\(a)][\(b)]")
            covarianceSums[a][b] = sum; covarianceSums[b][a] = sum; covariance[a][b] = value; covariance[b][a] = value
            pairs.append(.init(row: a, column: b, products: products, sum: sum, covariance: value))
        } }
        let lower = try factor(covariance, math: m.at("covariance-cholesky"))
        return .init(priceStartIndex: s-window, returnStartIndex: s-251, returnEndIndex: s, intervalIndices: indices,
            pricePrevious: previous, priceCurrent: current, simpleReturns: returns, cashIntervals: cash, excessReturns: excess,
            meanSums: sums, means: means, centeredExcess: centered, covariancePairs: pairs, covarianceSums: covarianceSums, covariance: covariance, covarianceCholesky: lower)
    }
    public struct RoleDiagnostic: Encodable, Equatable { public let symbol: String, ordinal: Int, mean: Double?, rawWeight: Double, cleanedWeight: Double, reason: String }
    public struct Signal: Encodable, Equatable {
        public let signalIndex: Int, date: Date, intervalCount: Int, sourceAnchor: Int, sourceCadence: Int, isEligible: Bool, reason: String
        public let incomingLatent: [Double], retainedFromSignalIndex: Int?, firstAllowedExecutionIndex: Int?, estimator: Estimator?, optimization: Optimization?
        public let latentWeights: [Double], latentGross: Double, latentCashWeight: Double, rawTarget: [String: Double], cleanedTarget: [String: Double], roles: [RoleDiagnostic], budgetCheck: Bool
    }
    public static func signals(frame: MarketDataFrame) throws -> [Signal] {
        guard !frame.dates.isEmpty, frame.simulationRange.lowerBound == 0,
              coreSymbols.allSatisfy({ frame.pricesBySymbol[$0]?.count == frame.dates.count }),
              zip(frame.dates, frame.dates.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw Math(stage: "input").fail("frame", "input-domain", [], nil, "source-contract mismatch")
        }
        var latent = [0.0,0.0,0.0], latest: Int?
        var rows: [Signal] = []
        for s in frame.dates.indices {
            let m = Math(signalIndex: s, date: frame.dates[s], stage: "input")
            for symbol in coreSymbols { _ = try m.positive(frame.pricesBySymbol[symbol]![s], "price.\(symbol)") }
            let incoming = latent, due = eligible(s)
            var estimator: Estimator?, optimization: Optimization?
            if due {
                let e = try estimate(frame: frame, signalIndex: s), o = try optimize(mu: e.means, covariance: e.covariance, math: m.at("covariance-cholesky"))
                estimator = e; optimization = o; latent = o.winningWeights; latest = s
            }
            let gross = try m.sum(latent, "latentGross"), cash = try m.sub(1, gross, "latentCashWeight")
            let check = latent.allSatisfy { $0.isFinite && $0 >= 0 } && gross <= 1
            guard check else { throw m.fail("latentWeights", "feasibility", latent, gross, "source-contract mismatch") }
            let raw = Dictionary(uniqueKeysWithValues: coreSymbols.indices.map { (coreSymbols[$0], latent[$0]) }), clean = providerClean(raw)
            let reason = s < window ? "formation-cash" : (due ? "eligible-MVU252-G20-CAD21" : "off-cycle-retained")
            let roles = coreSymbols.indices.map { RoleDiagnostic(symbol: coreSymbols[$0], ordinal: $0, mean: estimator?.means[$0],
                rawWeight: latent[$0], cleanedWeight: clean[coreSymbols[$0]] ?? 0, reason: reason) }
            rows.append(.init(signalIndex: s, date: frame.dates[s], intervalCount: s, sourceAnchor: window, sourceCadence: cadence,
                isEligible: due, reason: reason, incomingLatent: incoming, retainedFromSignalIndex: latest, firstAllowedExecutionIndex: due ? s+1 : nil,
                estimator: estimator, optimization: optimization, latentWeights: latent, latentGross: gross, latentCashWeight: cash,
                rawTarget: raw, cleanedTarget: clean, roles: roles, budgetCheck: check))
        }
        return rows
    }
    static func signalObjects(_ signals: [Signal], encoder: JSONEncoder) throws -> [[String: Any]] {
        var rows = try JSONSerialization.jsonObject(with: encoder.encode(signals)) as! [[String: Any]]
        func nulls(_ object: inout [String: Any], _ keys: [String]) { for key in keys where object[key] == nil { object[key] = NSNull() } }
        for i in rows.indices {
            nulls(&rows[i], ["retainedFromSignalIndex","firstAllowedExecutionIndex","estimator","optimization"])
            var roles = rows[i]["roles"] as! [[String: Any]]
            for j in roles.indices { nulls(&roles[j], ["mean"]) }; rows[i]["roles"] = roles
            if var o = rows[i]["optimization"] as? [String: Any] {
                var faces = o["faces"] as! [[String: Any]]
                for j in faces.indices { nulls(&faces[j], ["subsetSolveIndex","budgetClosure","fullBudgetChecksumError","fullBudgetChecksumCheck","rejectReason","objective"]) }
                o["faces"] = faces
                var steps = o["selectionSteps"] as! [[String: Any]]
                for j in steps.indices { nulls(&steps[j], ["incumbentOrdinalBefore"]) }; o["selectionSteps"] = steps
                var kkt = o["kkt"] as! [String: Any], checks = kkt["checks"] as! [[String: Any]]
                for j in checks.indices { nulls(&checks[j], ["coreIndex","upperBound"]) }; kkt["checks"] = checks; o["kkt"] = kkt
                rows[i]["optimization"] = o
            }
        }
        return rows
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
                throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 accounting diagnostic " + String(decoding: data, as: UTF8.self))
            }
        }
    }
    public struct ExecutionQuoteFact: Encodable, Equatable { public let symbol: String, sourceDate: Date, observed: Bool, executionPrice: Double, positiveActualQuote: Bool }
    public struct Decision: Encodable, Equatable {
        public let index: Int, date: Date, signalIndex: Int, signalDate: Date, scheduleMode: String, scheduledReview: Bool, transportOnly: Bool, requestKind: String, shouldRebalance: Bool
        public var providerCalled: Bool
        public let lastDidExecuteBefore: Int
        public var lastDidExecuteAfter: Int
        public let reviewAgeBefore: Int, latestDeliverySignalIndexBefore: Int?, latestDeliverySignalIndexAfter: Int?, deliverySignalIndex: Int?, deliverySignalDate: Date?
        public let sourceLatentTarget: [String: Double], retainedTargetBefore: [String: Double]
        public var requestedTarget: [String: Double]?, acceptedAfter: [String: Double]
        public let pendingBefore: [String: Double]?
        public var pendingAfter: [String: Double]?, completedToday: Bool, heldOrTargetSymbols: [String], quoteFacts: [ExecutionQuoteFact], acceptedMatchesDesired: Bool
    }
    public struct NativeRun {
        public let simulation: BacktestDailySimulationResult, decisions: [Decision], completions: [Completion], targetMismatchCount: Int
    }
    public static func runAccount(preparation: NativePreparation, signals: [Signal], role: Role) throws -> NativeRun {
        guard signals.count == preparation.frame.dates.count,
              signals.enumerated().allSatisfy({ $0.offset == $0.element.signalIndex && $0.element.date == preparation.frame.dates[$0.offset] }) else {
            throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 funded signal alignment")
        }
        let candidate = role == .candidate
        return try simulate(preparation: preparation,
            buyReason: candidate ? "fixed MVU252 G20 CAD21 core close research" : "fixed MVU core daily close control",
            scheduleMode: candidate ? "candidate-cad21" : (role == .equal ? "equal-daily" : "cash-daily"),
            schedule: { i in i >= 1 && (candidate ? eligible(i-1) : true) },
            sourceTarget: { s in
                switch role { case .candidate: return signals[s].rawTarget
                case .equal: return Dictionary(uniqueKeysWithValues: coreSymbols.map { ($0, 1.0 / 3) })
                case .cash: return [:] }
            }, target: { s in
                switch role { case .candidate: return signals[s].cleanedTarget
                case .equal: return Dictionary(uniqueKeysWithValues: coreSymbols.map { ($0, 1.0 / 3) })
                case .cash: return [:] }
            })
    }
    /// Pure artificial fixture seam, never a CLI economic parameter.
    static func simulate(preparation: NativePreparation, buyReason: String, scheduleMode: String = "candidate-cad21",
                         schedule: @escaping (Int) -> Bool, sourceTarget: ((Int) -> [String: Double])? = nil,
                         target: @escaping (Int) -> [String: Double]) throws -> NativeRun {
        let frame = preparation.frame
        guard frame.simulationRange.lowerBound == 0 else { throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 full funded baseline") }
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, tradeToBandBoundary: false, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: buyReason)
        var latest: Int?, lastDidExecute = Int.min / 2, retained: [String: Double] = [:], pending: [String: Double]?
        var decisions: [Decision] = [], completions: [Completion] = [], expected: [[String: Double]] = []
        guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
            provider: .init { context in
                // Only a scheduled request cleans the latest source target. Pending
                // transport re-delivers the saved actual map verbatim, without cleaning again.
                let weights = decisions.last!.scheduledReview ? providerClean(target(latest!)) : pending!
                retained = weights; pending = weights
                decisions[decisions.count-1].providerCalled = true
                decisions[decisions.count-1].requestedTarget = weights
                decisions[decisions.count-1].pendingAfter = weights
                return weights
            }, rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
            contextualRebalanceDecision: { c in
                let sourceIndex = c.index == 0 ? 0 : c.signalIndex
                let before = latest, scheduled = c.index >= 1 && schedule(c.index)
                if scheduled { latest = sourceIndex }
                let transport = !scheduled && pending != nil, due = scheduled || transport
                decisions.append(.init(index: c.index, date: c.date, signalIndex: sourceIndex, signalDate: frame.dates[sourceIndex],
                    scheduleMode: scheduleMode, scheduledReview: scheduled, transportOnly: transport, requestKind: scheduled ? "scheduled" : (transport ? "pending-only" : "none"),
                    shouldRebalance: due, providerCalled: false, lastDidExecuteBefore: lastDidExecute, lastDidExecuteAfter: lastDidExecute,
                    reviewAgeBefore: c.index-lastDidExecute, latestDeliverySignalIndexBefore: before, latestDeliverySignalIndexAfter: latest,
                    deliverySignalIndex: due ? latest : nil, deliverySignalDate: due ? latest.map { frame.dates[$0] } : nil,
                    sourceLatentTarget: sourceTarget?(sourceIndex) ?? [:], retainedTargetBefore: retained, requestedTarget: nil,
                    acceptedAfter: [:], pendingBefore: pending, pendingAfter: pending, completedToday: false,
                    heldOrTargetSymbols: [], quoteFacts: [], acceptedMatchesDesired: false))
                expected.append(retained)
                return .init(shouldRebalance: due, refreshOverlay: false)
            }, didExecuteTarget: { i in
                lastDidExecute = i; pending = nil
                decisions[decisions.count-1].lastDidExecuteAfter = i
                decisions[decisions.count-1].pendingAfter = nil
                decisions[decisions.count-1].completedToday = true
                completions.append(.init(index: i, date: frame.dates[i], target: retained))
            }, executionPricesBySymbol: preparation.executionPrices, buyBudgetPolicy: .symbolOrder) else {
            throw BacktestConfigurationError.computationFailed
        }
        guard run.dailyStates.count == decisions.count,
              run.dailyStates.first?.portfolioValue == 100000, run.dailyStates.first?.cash == 100000,
              run.dailyStates.first?.targetWeights.isEmpty == true,
              !run.trades.contains(where: { $0.date == frame.dates[0] }) else {
            throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 unchanged cash baseline/formation")
        }
        var mismatches = 0
        for i in decisions.indices {
            let desired = decisions[i].requestedTarget ?? expected[i]
            decisions[i].acceptedAfter = run.dailyStates[i].targetWeights
            decisions[i].acceptedMatchesDesired = decisions[i].acceptedAfter == desired
            if !decisions[i].acceptedMatchesDesired { mismatches += 1 }
            let priorHeld = i > 0 ? run.dailyStates[i-1].holdingsBySymbol : [:]
            let symbols = Set(priorHeld.filter { $0.value > 0 }.keys).union(desired.filter { $0.value > 0 }.keys).sorted()
            decisions[i].heldOrTargetSymbols = symbols
            decisions[i].quoteFacts = symbols.map { symbol in
                let quote = preparation.quotes.first { $0.symbol == symbol && $0.index == i }!
                return .init(symbol: symbol, sourceDate: quote.sourceDate, observed: quote.quoteToday,
                    executionPrice: quote.executionPrice, positiveActualQuote: quote.quoteToday && quote.executionPrice.isFinite && quote.executionPrice > 0)
            }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 desired/accepted delivery") }
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
            throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 frozen canonical source and 31 saved controls")
        }
        func date(_ day: String) throws -> Date {
            guard let d = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 source session date") }
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
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 saved raw hash/rows") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }), !selectedIDs.contains(id) else {
                    throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 saved identity/state order")
                }
                selectedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 one candidate / 3 fresh / 31 saved") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("MVU252G20CAD21 complete mechanical comparison calendar") }
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
            throw BacktestConfigurationError.invalidParameter("MVU252G20CAD21 no comparison-day deletion")
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
            for key in ["latestDeliverySignalIndexBefore", "latestDeliverySignalIndexAfter", "deliverySignalIndex", "deliverySignalDate", "requestedTarget", "pendingBefore", "pendingAfter"] where decisionObjects[id]![i][key] == nil { decisionObjects[id]![i][key] = NSNull() }
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
        let evidence: [String: Any] = [
            "completed_at": iso(Date()), "source_commit": sourceCommit,
            "evidence_class": "POST_HOC_RELATED_D0_HISTORY_EXPOSED_ROOT_MODERN_EXCESS_MEAN_FULL_COVARIANCE_ENDOGENOUS_CASH_UTILITY",
            "formal_validation": false, "recommendation_eligible": false, "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "pre_specification_sha256": "f974e6954fb47470f34bb860172d13e7f4e1264ff63b4a3f20e4f25d03148a5b",
            "original_definition": "ROOT_MODERN_TOBIN1958_INSPIRED_WHOLE_ENDOGENOUS_CASH_MVU252_G20_CAD21_EXPLICIT_BINARY64_ACTIVE_FACES",
            "source_engineering_proposal_sha256": "b6d867ec22d334a91029135bcb3ca9e869fb2a903e41b6ff4e88da016c2d0d69",
            "source_input_review_sha256": "9f707d2ca3bf155e0bf305ac297c3ec7216ad0999351518da1e7d357f36edc4d",
            "source_cash_dependency_sha256": "00c61022360960efa18c3c7e5b55bf8d7b37e553d4c7cf8a70fa7ac827886ac6",
            "export_contract_sha256": "b0ee19a01580fda0b12e00e48a50681bfaace3fad9dc856370fc6ebb61f1ece9",
            "signal_schema": "fixed-mvu252-g20-cad21-core-signal-v1",
            "sample_window_intervals": window, "sample_covariance_denominator": 251, "risk_aversion_per_interval": gamma,
            "source_cadence": cadence, "first_signal_index": 252, "first_scheduled_execution_index": 253, "provider_clean_is_model_feedback": false,
            "model_policy": "Fixed252 completed simple CNY excess returns minus past CashYieldCNY calendar return; sample251 full uppertriangle/mirror covariance; gamma20 endogenous risky/cash utility; strictSPD/cash+14activefaces/exactJties/originallambda/winnerKKT; no latent normalization",
            "numerical_policy": "Literal Binary64 ordered sums from+0/noFMA/BLAS/reassociation; signed/truezero/cancellation legal, observable nonzero mul/div->0 or nonfinite invalid; whole/subset strictSPD no PSD repair/floor/ridge/shrinkage/cash fallback",
            "cadence_policy": "Source252+21k fixed; firstscheduledexec253 from signal252. Offschedule pending-only transport saved actual map verbatim; no pending means no fresh request. Scheduled even same target replaces pending; completion never reanchors. Equal/cash independently daily diagnostics.",
            "failure_diagnostic_policy": "Fresh3 only identical original9compoundaccountguard/order/Dictionary.reduce/thresholds, enriched firstfailure JSON; success unchanged sharedrow.",
            "primitives_sha256": ResearchRunEvidence.sha256(raw), "accounts_sha256": ResearchRunEvidence.sha256(savedRaw),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "output_sha256": hashes, "candidate_count": 1, "new_funded_account_count": 3, "saved_control_count": 31, "account_count": 34,
            "parameter_search_budget": 0, "native_state_count": 6452, "native_start": "2001-06-25", "native_end": "2026-10-06",
            "long_common_dates": longDates.map(text), "all20_common_dates": allDates.map(text), "long_comparison_count": longRows.count,
            "all20_comparison_count": allRows.count, "long_excluded_id": qualID, "saved_control_ids": selectedIDs,
            "saved_source_files": sources.files.map { ["path": $0.path, "sha256": $0.sha256, "ids": $0.ids] as [String: Any] },
            "target_audits": targetAudits, "fee_rate": 0.00025, "slippage_rate": 0, "cash": "CashYieldCNY",
            "primary_metric": "App complete funded-native daily NAV Sharpe Rf=0",
            "primary": ["threshold": 1.2, "require_native_full": true, "require_long_common19_sharpe_at_least_1_2": true,
                "require_beat_strongest19": true, "all20_supplement_only": true],
            "strongest19_control_ids": BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs,
            "price_policy": "canonical valuation_price sourceclose signal/fill/mark; goldCNY; USD/strictpriorquote-dayFX<=14once; carry mark/model only",
            "ideal_book_actual_NAV_identity_claimed": false, "old_RP_GMV_Cover_control_parity_claimed": false,
            "units_policy": "Genuine shared state holding value/canonicalmark; actualorderfills/fees/settlement auditable",
            "limitations": ["Modern root-engineered utility omits Tobin Eq14 mean-square term;252/gamma20/21/strictSPD/faces/ties/KKT are explicit engineering, not author defaults/theorem/numeric parity or fresh alpha/OOS.",
                "Historical effective Appcash schedule not original announcement-vintage/PIT/livecash guarantee. Price proxies/canonicalclose not executable security/auction/futures-roll/totalreturn certification.",
                "Actualnextclose/strictpriorFX/cost/settlement account distinct from latent ideal source optimizer; no NAV blend/offApp funding/leverage/crypto.",
                "No dividends/tax/USDwallet/FXspreads; prior31whole retained with original limitations; short calendar diagnostic only; source/numeric/unique-finance failure closes exact whole architecture without rule rescue."]
        ]
        outputs["evidence.json"] = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in outputs.keys.sorted() { try outputs[name]!.write(to: output.appendingPathComponent(name)) }
        print("Fixed MVU252G20CAD21 core: 1 candidate, 3 fresh accounts, 31 saved controls; native6452/long5595/short3086 dates.")
    }
}
