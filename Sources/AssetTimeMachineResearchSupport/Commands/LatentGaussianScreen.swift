import Foundation
import CoreFoundation
import AssetTimeMachineBacktestCore

/// Root's frozen two-state Gaussian direction forecast. Related D0 research only.
public enum LatentGaussianScreen {
    public typealias Bar = ChaikinMoneyFlowScreen.Bar
    public typealias NativePreparation = ChaikinMoneyFlowScreen.NativePreparation
    public static let candidateID = "latent2-gaussian-qqq-long-cash"
    public static let buyHoldID = ChaikinMoneyFlowScreen.buyHoldID
    public static let cashID = ChaikinMoneyFlowScreen.cashID
    public static let qualID = ChaikinMoneyFlowScreen.qualID
    public static let formationReturns = 252
    public static let emIterations = 100

    public struct States: Codable, Equatable {
        public var periodCount = 0, returnCount = 0, fitCount = 0, lastFitReturnCount = 0, fitIterationCount = 0
        public var previousClose = 0.0, currentReturn = 0.0
        public var mu0 = 0.0, mu1 = 0.0, variance0 = 0.0, variance1 = 0.0
        public var p00 = 0.0, p01 = 0.0, p10 = 0.0, p11 = 0.0
        public var alpha0 = 0.0, alpha1 = 0.0, next0 = 0.0, next1 = 0.0
        public var predictedMean = 0.0, fitLogLikelihood = 0.0, fitLogLikelihoodGap = 0.0
        public init() {}
    }
    public struct Model: Codable, Equatable {
        public var mu0: Double, mu1: Double, variance0: Double, variance1: Double
        public var p00: Double, p01: Double, p10: Double, p11: Double
        fileprivate func mean(_ j: Int) -> Double { j == 0 ? mu0 : mu1 }
        fileprivate func variance(_ j: Int) -> Double { j == 0 ? variance0 : variance1 }
        fileprivate func transition(_ i: Int, _ j: Int) -> Double {
            i == 0 ? (j == 0 ? p00 : p01) : (j == 0 ? p10 : p11)
        }
    }
    public struct FitRecord: Codable, Equatable {
        public let fitPrefixFirstSourceDate: String
        public let fitPrefixLastSourceDate: String
        public let observedReturns: Int
        public let initialPrefixMean: Double
        public let initialPrefixVariance: Double
        public let initialModel: Model
        public let iterations: Int
        public let logLikelihoodByIteration: [Double]
    }
    public struct Signal: Codable, Equatable {
        public let date: Date
        public let sourceDate: String
        public let sourceOrdinal: Int
        public let currentBar: Int
        public let computed: Bool
        public let comparisonAvailable: Bool
        public let modelAvailable: Bool
        public let returnAvailable: Bool
        public let fitPerformed: Bool
        public let warmOverride: Bool
        public let price: Double
        public let currentUSDBar: Bar
        public let states: States
        public let priorStates: States
        public let priorStatesBeforeSplit: States
        public let appliedSplitDates: [Date]
        public let splitFactor: Double
        public let fundingEligible: Bool
        public let previousWeight: Double
        public let weight: Double
        public let stateReason: String
        public let stateSourceDate: Date?
        public let latestFitDate: Date?
        public let fitPrefixEndDate: Date?
        public let fitRecord: FitRecord?

        enum CodingKeys: String, CodingKey {
            case date, sourceDate, sourceOrdinal, currentBar, computed, comparisonAvailable, modelAvailable
            case returnAvailable, fitPerformed, warmOverride, price, currentUSDBar
            case states, priorStates, priorStatesBeforeSplit, appliedSplitDates, splitFactor
            case fundingEligible, previousWeight, weight, stateReason, stateSourceDate
            case latestFitDate, fitPrefixEndDate, fitRecord
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date); try c.encode(sourceDate, forKey: .sourceDate)
            try c.encode(sourceOrdinal, forKey: .sourceOrdinal); try c.encode(currentBar, forKey: .currentBar)
            try c.encode(computed, forKey: .computed); try c.encode(comparisonAvailable, forKey: .comparisonAvailable)
            try c.encode(modelAvailable, forKey: .modelAvailable); try c.encode(returnAvailable, forKey: .returnAvailable)
            try c.encode(fitPerformed, forKey: .fitPerformed); try c.encode(warmOverride, forKey: .warmOverride)
            try c.encode(price, forKey: .price); try c.encode(currentUSDBar, forKey: .currentUSDBar)
            try c.encode(states, forKey: .states); try c.encode(priorStates, forKey: .priorStates)
            try c.encode(priorStatesBeforeSplit, forKey: .priorStatesBeforeSplit)
            try c.encode(appliedSplitDates, forKey: .appliedSplitDates); try c.encode(splitFactor, forKey: .splitFactor)
            try c.encode(fundingEligible, forKey: .fundingEligible); try c.encode(previousWeight, forKey: .previousWeight)
            try c.encode(weight, forKey: .weight); try c.encode(stateReason, forKey: .stateReason)
            try c.encode(stateSourceDate, forKey: .stateSourceDate); try c.encode(latestFitDate, forKey: .latestFitDate)
            try c.encode(fitPrefixEndDate, forKey: .fitPrefixEndDate); try c.encode(fitRecord, forKey: .fitRecord)
        }
    }
    private struct Pair {
        var a: Double, b: Double
        init(_ a: Double, _ b: Double) { self.a = a; self.b = b }
        subscript(_ j: Int) -> Double { j == 0 ? a : b }
    }
    private struct Four {
        var a: Double, b: Double, c: Double, d: Double
        init(_ a: Double, _ b: Double, _ c: Double, _ d: Double) { self.a = a; self.b = b; self.c = c; self.d = d }
    }
    private struct ForwardPass {
        let alpha: [Pair] // Index0 is the fixed s0 distribution; index t is s_t.
        let ell: [Pair]   // Index t-1 is the density of r_t.
        let c: [Double]   // Log conditional observation normalizers.
        let likelihood: Double
    }
    private struct Fit {
        let model: Model
        let alpha: Pair
        let record: FitRecord
        let likelihood: Double
        let gap: Double
    }

    // Never inline primitive arithmetic: no FMA, reassociation, pow or numerical rescue.
    @inline(never) private static func finite(_ x: Double, _ c: String) throws -> Double {
        guard x.isFinite else { throw BacktestConfigurationError.invalidParameter(c + " nonfinite") }
        return x
    }
    @inline(never) private static func add(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a + b, c) }
    @inline(never) private static func subtract(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a - b, c) }
    @inline(never) private static func multiply(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a * b, c) }
    @inline(never) private static func divide(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a / b, c) }
    @inline(never) private static func logarithm(_ a: Double, _ c: String) throws -> Double { try finite(log(a), c) }
    @inline(never) private static func exponential(_ a: Double, _ c: String) throws -> Double { try finite(exp(a), c) }
    @inline(never) private static func squareRoot(_ a: Double, _ c: String) throws -> Double { try finite(sqrt(a), c) }

    private static func probability(_ p: Double, _ c: String) throws -> Double {
        guard p.isFinite, p >= 0, p <= 1 else { throw BacktestConfigurationError.invalidParameter(c + " probability domain") }
        return p
    }
    private static func logProbability(_ p: Double, _ c: String) throws -> Double {
        let p = try probability(p, c)
        return p == 0 ? -.infinity : try logarithm(p, c)
    }
    private static func logDomain(_ x: Double, _ c: String) throws {
        guard x.isFinite || x == -.infinity else { throw BacktestConfigurationError.invalidParameter(c + " log domain") }
    }
    private static func logAdd(_ a: Double, _ b: Double, _ c: String) throws -> Double {
        try logDomain(a, c); try logDomain(b, c)
        if a == -.infinity || b == -.infinity { return -.infinity }
        return try add(a, b, c)
    }
    private static func logSubtract(_ a: Double, _ b: Double, _ c: String) throws -> Double {
        try logDomain(a, c); _ = try finite(b, c)
        return a == -.infinity ? -.infinity : try subtract(a, b, c)
    }
    private static func expTerm(_ a: Double, maximum: Double, context: String) throws -> Double {
        try logDomain(a, context)
        if a == -.infinity { return 0 }
        return try exponential(subtract(a, maximum, context), context)
    }
    private static func lse2(_ x: Pair, _ c: String) throws -> Double {
        try logDomain(x.a, c); try logDomain(x.b, c)
        let m = max(x.a, x.b)
        guard m.isFinite else { throw BacktestConfigurationError.invalidParameter(c + " impossible LSE2") }
        let a = try expTerm(x.a, maximum: m, context: c), b = try expTerm(x.b, maximum: m, context: c)
        let sum = try add(a, b, c)
        guard sum > 0 else { throw BacktestConfigurationError.invalidParameter(c + " zero LSE2 sum") }
        return try add(logarithm(sum, c), m, c)
    }
    private static func lse4(_ x: Four, _ c: String) throws -> Double {
        try logDomain(x.a, c); try logDomain(x.b, c); try logDomain(x.c, c); try logDomain(x.d, c)
        let m = max(max(x.a, x.b), max(x.c, x.d))
        guard m.isFinite else { throw BacktestConfigurationError.invalidParameter(c + " impossible LSE4") }
        let a = try expTerm(x.a, maximum: m, context: c), b = try expTerm(x.b, maximum: m, context: c)
        let cc = try expTerm(x.c, maximum: m, context: c), d = try expTerm(x.d, maximum: m, context: c)
        let ab = try add(a, b, c), abc = try add(ab, cc, c), sum = try add(abc, d, c)
        guard sum > 0 else { throw BacktestConfigurationError.invalidParameter(c + " zero LSE4 sum") }
        return try add(logarithm(sum, c), m, c)
    }
    private static func weightExp(_ x: Double, normalizer: Double, context: String) throws -> Double {
        let v = try logSubtract(x, normalizer, context)
        return v == -.infinity ? 0 : try exponential(v, context)
    }
    private static func normalized2(_ x: Pair, _ c: String) throws -> Pair {
        _ = try probability(x.a, c); _ = try probability(x.b, c)
        let sum = try add(x.a, x.b, c)
        guard sum > 0 else { throw BacktestConfigurationError.invalidParameter(c + " zero probability sum") }
        let a = try divide(x.a, sum, c), b = try divide(x.b, sum, c)
        return Pair(try probability(a, c), try probability(b, c))
    }
    private static func normalizedLogs2(_ x: Pair, normalizer: Double? = nil, context c: String) throws -> Pair {
        let z: Double
        if let normalizer { z = normalizer } else { z = try lse2(x, c) }
        return try normalized2(Pair(weightExp(x.a, normalizer: z, context: c),
            weightExp(x.b, normalizer: z, context: c)), c)
    }
    private static func normalizedLogs4(_ x: Four, _ c: String) throws -> Four {
        let z = try lse4(x, c)
        let a = try weightExp(x.a, normalizer: z, context: c), b = try weightExp(x.b, normalizer: z, context: c)
        let cc = try weightExp(x.c, normalizer: z, context: c), d = try weightExp(x.d, normalizer: z, context: c)
        _ = try probability(a, c); _ = try probability(b, c); _ = try probability(cc, c); _ = try probability(d, c)
        let ab = try add(a, b, c), abc = try add(ab, cc, c), sum = try add(abc, d, c)
        guard sum > 0 else { throw BacktestConfigurationError.invalidParameter(c + " zero xi sum") }
        return Four(try probability(divide(a, sum, c), c), try probability(divide(b, sum, c), c),
            try probability(divide(cc, sum, c), c), try probability(divide(d, sum, c), c))
    }
    private static func validateModel(_ m: Model, _ c: String) throws {
        guard [m.mu0, m.mu1, m.variance0, m.variance1].allSatisfy(\.isFinite),
              m.variance0 > 0, m.variance1 > 0,
              !(m.mu0 == m.mu1 && m.variance0 == m.variance1) else {
            throw BacktestConfigurationError.invalidParameter(c + " Gaussian variance or collapsed pair")
        }
        for p in [m.p00, m.p01, m.p10, m.p11] { _ = try probability(p, c) }
        guard try add(m.p00, m.p01, c) > 0, try add(m.p10, m.p11, c) > 0 else {
            throw BacktestConfigurationError.invalidParameter(c + " empty transition row")
        }
    }
    private static func density(_ r: Double, mean: Double, variance: Double, logTwoPi: Double, context c: String) throws -> Double {
        let diff = try subtract(r, mean, c), square = try multiply(diff, diff, c)
        let scaled = try divide(square, variance, c), logVar = try logarithm(variance, c)
        let first = try add(logTwoPi, logVar, c), combined = try add(first, scaled, c)
        return try multiply(-0.5, combined, c)
    }
    private static func projected(_ alpha: Pair, model m: Model, _ c: String) throws -> Pair {
        let a0 = try multiply(alpha.a, m.p00, c), a1 = try multiply(alpha.b, m.p10, c)
        let q0 = try probability(add(a0, a1, c), c)
        let b0 = try multiply(alpha.a, m.p01, c), b1 = try multiply(alpha.b, m.p11, c)
        let q1 = try probability(add(b0, b1, c), c)
        return Pair(q0, q1)
    }
    private static func advance(_ alpha: Pair, r: Double, model: Model, logTwoPi: Double, context c: String) throws -> (Pair, Pair, Double) {
        let ell = try Pair(density(r, mean: model.mu0, variance: model.variance0, logTwoPi: logTwoPi, context: c),
            density(r, mean: model.mu1, variance: model.variance1, logTwoPi: logTwoPi, context: c))
        let q = try projected(alpha, model: model, c) // No q renormalization.
        let weights = try Pair(logAdd(logProbability(q.a, c), ell.a, c), logAdd(logProbability(q.b, c), ell.b, c))
        let z = try lse2(weights, c)
        return (try normalizedLogs2(weights, normalizer: z, context: c), ell, z)
    }
    private static func forward(_ returns: [Double], model: Model, context c: String) throws -> ForwardPass {
        try validateModel(model, c)
        let twoPi = try multiply(2, 3.141592653589793, c), logTwoPi = try logarithm(twoPi, c)
        var alpha = [Pair](repeating: Pair(0, 0), count: returns.count + 1)
        var ell = [Pair](repeating: Pair(0, 0), count: returns.count), normalizers = [Double](repeating: 0, count: returns.count)
        alpha[0] = Pair(0.5, 0.5)
        var likelihood = 0.0
        for t in returns.indices {
            let step = try advance(alpha[t], r: returns[t], model: model, logTwoPi: logTwoPi, context: c)
            alpha[t + 1] = step.0; ell[t] = step.1; normalizers[t] = step.2
            likelihood = try add(likelihood, step.2, c)
        }
        return .init(alpha: alpha, ell: ell, c: normalizers, likelihood: likelihood)
    }
    private static func maximization(_ returns: [Double], old: Model, pass: ForwardPass, context c: String) throws -> Model {
        let n = returns.count
        var beta = [Pair](repeating: Pair(0, 0), count: n + 1) // log beta_n=0.
        for t in stride(from: n, through: 1, by: -1) {
            var row = Pair(0, 0)
            for i in 0..<2 {
                let first0 = try logAdd(logProbability(old.transition(i, 0), c), pass.ell[t - 1].a, c)
                let first1 = try logAdd(logProbability(old.transition(i, 1), c), pass.ell[t - 1].b, c)
                let a = try logAdd(first0, beta[t].a, c), b = try logAdd(first1, beta[t].b, c)
                let value = try logSubtract(lse2(Pair(a, b), c), pass.c[t - 1], c)
                if i == 0 { row.a = value } else { row.b = value }
            }
            beta[t - 1] = row
        }
        var gamma = [Pair](repeating: Pair(0, 0), count: n)
        var counts = Pair(0, 0), weightedMeans = Pair(0, 0), transitions = Four(0, 0, 0, 0)
        for t in 1...n {
            let ga = try logAdd(logProbability(pass.alpha[t].a, c), beta[t].a, c)
            let gb = try logAdd(logProbability(pass.alpha[t].b, c), beta[t].b, c)
            let g = try normalizedLogs2(Pair(ga, gb), context: c)
            gamma[t - 1] = g
            counts.a = try add(counts.a, g.a, c); counts.b = try add(counts.b, g.b, c)
            let wa = try multiply(g.a, returns[t - 1], c), wb = try multiply(g.b, returns[t - 1], c)
            weightedMeans.a = try add(weightedMeans.a, wa, c); weightedMeans.b = try add(weightedMeans.b, wb, c)
            func xiWeight(_ i: Int, _ j: Int) throws -> Double {
                let first = try logAdd(logProbability(pass.alpha[t - 1][i], c), logProbability(old.transition(i, j), c), c)
                let second = try logAdd(first, pass.ell[t - 1][j], c)
                let third = try logAdd(second, beta[t][j], c)
                return try logSubtract(third, pass.c[t - 1], c)
            }
            let x = try normalizedLogs4(Four(xiWeight(0, 0), xiWeight(0, 1), xiWeight(1, 0), xiWeight(1, 1)), c)
            transitions.a = try add(transitions.a, x.a, c); transitions.b = try add(transitions.b, x.b, c)
            transitions.c = try add(transitions.c, x.c, c); transitions.d = try add(transitions.d, x.d, c)
        }
        guard counts.a > 0, counts.b > 0 else { throw BacktestConfigurationError.invalidParameter(c + " zero component count") }
        let mean0 = try divide(weightedMeans.a, counts.a, c), mean1 = try divide(weightedMeans.b, counts.b, c)
        var squares = Pair(0, 0)
        for t in returns.indices {
            let d0 = try subtract(returns[t], mean0, c), d1 = try subtract(returns[t], mean1, c)
            let s0 = try multiply(d0, d0, c), s1 = try multiply(d1, d1, c)
            let w0 = try multiply(gamma[t].a, s0, c), w1 = try multiply(gamma[t].b, s1, c)
            squares.a = try add(squares.a, w0, c); squares.b = try add(squares.b, w1, c)
        }
        let v0 = try divide(squares.a, counts.a, c), v1 = try divide(squares.b, counts.b, c)
        let den0 = try add(transitions.a, transitions.b, c), den1 = try add(transitions.c, transitions.d, c)
        guard den0 > 0, den1 > 0 else { throw BacktestConfigurationError.invalidParameter(c + " zero transition count") }
        let row0 = try normalized2(Pair(divide(transitions.a, den0, c), divide(transitions.b, den0, c)), c)
        let row1 = try normalized2(Pair(divide(transitions.c, den1, c), divide(transitions.d, den1, c)), c)
        var next = Model(mu0: mean0, mu1: mean1, variance0: v0, variance1: v1,
            p00: row0.a, p01: row0.b, p10: row1.a, p11: row1.b)
        try validateModel(next, c)
        if next.mu0 > next.mu1 || (next.mu0 == next.mu1 && next.variance0 > next.variance1) {
            next = Model(mu0: next.mu1, mu1: next.mu0, variance0: next.variance1, variance1: next.variance0,
                p00: next.p11, p01: next.p10, p10: next.p01, p11: next.p00)
        }
        return next
    }
    private static func fit(_ returns: [Double], firstDate: String, lastDate: String, context c: String) throws -> Fit {
        guard returns.count >= formationReturns, returns.allSatisfy(\.isFinite) else {
            throw BacktestConfigurationError.invalidParameter(c + " fit prefix")
        }
        var sum = 0.0
        for r in returns { sum = try add(sum, r, c) }
        let mean = try divide(sum, Double(returns.count), c)
        var squares = 0.0
        for r in returns {
            let diff = try subtract(r, mean, c), square = try multiply(diff, diff, c)
            squares = try add(squares, square, c)
        }
        let variance = try divide(squares, Double(returns.count), c)
        guard variance > 0 else { throw BacktestConfigurationError.invalidParameter(c + " zero initial variance") }
        let sd = try squareRoot(variance, c)
        let initial = try Model(mu0: subtract(mean, sd, c), mu1: add(mean, sd, c),
            variance0: variance, variance1: variance, p00: 0.95, p01: 0.05, p10: 0.05, p11: 0.95)
        try validateModel(initial, c)
        var model = initial, scores: [Double] = []
        for iteration in 1...emIterations {
            let pass = try forward(returns, model: model, context: c + " E\(iteration)")
            scores.append(pass.likelihood)
            model = try maximization(returns, old: model, pass: pass, context: c + " M\(iteration)")
        }
        // This is final forward evaluation of theta100, not an extra M iteration.
        let final = try forward(returns, model: model, context: c + " final theta100")
        scores.append(final.likelihood)
        let gap = try subtract(scores[100], scores[99], c)
        return .init(model: model, alpha: final.alpha[returns.count],
            record: .init(fitPrefixFirstSourceDate: firstDate, fitPrefixLastSourceDate: lastDate,
                observedReturns: returns.count, initialPrefixMean: mean, initialPrefixVariance: variance,
                initialModel: initial, iterations: emIterations, logLikelihoodByIteration: scores),
            likelihood: final.likelihood, gap: gap)
    }
    private static func model(_ s: States) -> Model {
        .init(mu0: s.mu0, mu1: s.mu1, variance0: s.variance0, variance1: s.variance1,
            p00: s.p00, p01: s.p01, p10: s.p10, p11: s.p11)
    }
    private static func validateState(_ s: States, _ c: String) throws {
        guard [s.previousClose, s.currentReturn, s.mu0, s.mu1, s.variance0, s.variance1,
            s.p00, s.p01, s.p10, s.p11, s.alpha0, s.alpha1, s.next0, s.next1,
            s.predictedMean, s.fitLogLikelihood, s.fitLogLikelihoodGap].allSatisfy(\.isFinite),
              s.periodCount >= 0, s.returnCount >= 0, s.fitCount >= 0, s.lastFitReturnCount >= 0,
              s.periodCount < 9_007_199_254_740_992,
              (s.periodCount == 0 ? s.previousClose == 0 : s.previousClose > 0) else {
            throw BacktestConfigurationError.invalidParameter(c + " serialized state domain")
        }
        if s.fitCount > 0 {
            try validateModel(model(s), c)
            for p in [s.alpha0, s.alpha1, s.next0, s.next1] { _ = try probability(p, c) }
        }
    }
    public static func signals(bars: [Bar], splits: [Date: Double], stateEligibleFrom: Date) throws -> [Signal] {
        guard !bars.isEmpty, stateEligibleFrom.timeIntervalSinceReferenceDate.isFinite,
              zip(bars, bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              splits.allSatisfy({ $0.key.timeIntervalSinceReferenceDate.isFinite && $0.value.isFinite && $0.value > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian ordered bars/splits/funding")
        }
        let splitDates = splits.keys.sorted()
        var splitIndex = 0, priorState = States(), result: [Signal] = [], weight = 0.0
        var returns: [Double] = [], latestFitDate: Date?
        for (ordinal, b) in bars.enumerated() {
            let day = BacktestSeriesAlignment.historicalSeriesDateString(from: b.date)
            let c = "LatentGaussian sourceOrdinal=\(ordinal) date=\(day)"
            guard b.date.timeIntervalSinceReferenceDate.isFinite,
                  [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 }),
                  b.high >= max(b.open, b.close), b.low <= min(b.open, b.close),
                  b.volume.isFinite, b.volume >= 0 else {
                throw BacktestConfigurationError.invalidParameter(c + " original USD OHLCV")
            }
            let beforeSplit = priorState, previousWeight = weight
            var prior = priorState, applied: [Date] = [], splitFactor = 1.0
            while splitIndex < splitDates.count, splitDates[splitIndex] <= b.date {
                let date = splitDates[splitIndex], ratio = splits[date]!
                prior.previousClose = try divide(prior.previousClose, ratio, c + " split previousClose")
                splitFactor = try multiply(splitFactor, ratio, c + " metadata splitFactor")
                applied.append(date); splitIndex += 1
            }
            try validateState(prior, c)
            var state = prior
            state.periodCount = ordinal + 1; state.returnCount = ordinal; state.previousClose = b.close
            if ordinal > 0 {
                let relative = try divide(b.close, prior.previousClose, c + " observed relative")
                state.currentReturn = try subtract(relative, 1, c + " observed simple return")
                returns.append(state.currentReturn)
            } else { state.currentReturn = 0 }
            let hadModel = prior.fitCount > 0
            let newMonth = ordinal > 0 && String(day.prefix(7)) != String(result[ordinal - 1].sourceDate.prefix(7))
            let performFit = returns.count >= formationReturns && (!hadModel || newMonth)
            var record: FitRecord?
            if performFit {
                let fitted = try fit(returns, firstDate: result[1].sourceDate, lastDate: day, context: c)
                state.mu0 = fitted.model.mu0; state.mu1 = fitted.model.mu1
                state.variance0 = fitted.model.variance0; state.variance1 = fitted.model.variance1
                state.p00 = fitted.model.p00; state.p01 = fitted.model.p01
                state.p10 = fitted.model.p10; state.p11 = fitted.model.p11
                state.alpha0 = fitted.alpha.a; state.alpha1 = fitted.alpha.b
                state.fitCount = prior.fitCount + 1; state.lastFitReturnCount = returns.count
                state.fitIterationCount = emIterations
                state.fitLogLikelihood = fitted.likelihood; state.fitLogLikelihoodGap = fitted.gap
                latestFitDate = b.date; record = fitted.record
            } else if hadModel {
                let twoPi = try multiply(2, 3.141592653589793, c), logTwoPi = try logarithm(twoPi, c)
                let step = try advance(Pair(prior.alpha0, prior.alpha1), r: state.currentReturn,
                    model: model(prior), logTwoPi: logTwoPi, context: c)
                state.alpha0 = step.0.a; state.alpha1 = step.0.b
            }
            let available = state.fitCount > 0
            if available {
                let next = try normalized2(projected(Pair(state.alpha0, state.alpha1), model: model(state), c), c)
                state.next0 = next.a; state.next1 = next.b
                let a = try multiply(next.a, state.mu0, c), b = try multiply(next.b, state.mu1, c)
                state.predictedMean = try add(a, b, c)
            }
            try validateState(state, c)
            let eligible = b.date >= stateEligibleFrom, reason: String
            if !eligible { weight = 0; reason = "pre-funding-cash" }
            else if !available { weight = 0; reason = "model-formation-cash" }
            else if state.predictedMean > 0 { weight = 1; reason = "latent-positive-predicted-mean-long" }
            else { weight = 0; reason = "latent-nonpositive-predicted-mean-cash" }
            result.append(.init(date: b.date, sourceDate: day, sourceOrdinal: ordinal, currentBar: ordinal + 1,
                computed: true, comparisonAvailable: available, modelAvailable: available,
                returnAvailable: ordinal > 0, fitPerformed: performFit, warmOverride: false,
                price: b.close, currentUSDBar: b, states: state, priorStates: prior, priorStatesBeforeSplit: beforeSplit,
                appliedSplitDates: applied, splitFactor: splitFactor, fundingEligible: eligible,
                previousWeight: previousWeight, weight: weight, stateReason: reason, stateSourceDate: b.date,
                latestFitDate: latestFitDate, fitPrefixEndDate: latestFitDate, fitRecord: record))
            priorState = state
        }
        return result
    }

    public static func signalData(_ signals: [Signal]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(signals)
    }

    private static let studyPath = "/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/fixed-latent2-gaussian-source-2026-10-10"
    private static let pricesSHA = "94227f568f4e16f99b8774d0a4375bb1c8d5fed64661ecdc27dc501c5e73fdef"
    private static let preSHA = "20e75e2c10ffd7619c071592527dd04eb690be99e008a46f166bdeefd8a8f209"
    private static let inputSHA = "80a14c646dbf47e896a544fcec4cc4c69c5bb8e776f942851fc846b5125b1981"
    private static let interfaceSHA = "5fc40d085069c3cea8d98a0418a0781153224376874189f385da1427558bac3c"

    private static func requireContracts(_ study: URL) throws {
        guard study.path == studyPath else { throw BacktestConfigurationError.invalidParameter("LatentGaussian literal study path") }
        for (name, expected) in [("PRE_SPECIFICATION.json", preSHA), ("INPUT_FREEZE.json", inputSHA), ("SOURCE_INTERFACE.json", interfaceSHA)] {
            guard ResearchRunEvidence.sha256(try Data(contentsOf: study.appendingPathComponent(name))) == expected else {
                throw BacktestConfigurationError.invalidParameter("LatentGaussian frozen contract " + name)
            }
        }
    }
    /// Source-only route. No accounts/history/FX/NAV are read.
    public static func exportSource(pricesPath: String, outputPath: String, sourceCommit: String) throws {
        let study = URL(fileURLWithPath: studyPath)
        try requireContracts(study)
        guard !sourceCommit.isEmpty, pricesPath == study.appendingPathComponent("inputs/prices.json").path,
              outputPath == study.appendingPathComponent("source/signals.json").path else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian literal source entry")
        }
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        guard ResearchRunEvidence.sha256(raw) == pricesSHA else { throw BacktestConfigurationError.invalidParameter("LatentGaussian frozen prices hash") }
        let input = try JSONDecoder().decode(Input.self, from: raw)
        try validateInput(input)
        let bars = try input.bars.map { row -> Bar in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: row.date) else {
                throw BacktestConfigurationError.invalidParameter("LatentGaussian source bar date")
            }
            return Bar(date: date, open: row.open, high: row.high, low: row.low, close: row.close, volume: row.volume)
        }
        let splits = try Dictionary(uniqueKeysWithValues: input.splits.map { row -> (Date, Double) in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: row.date) else {
                throw BacktestConfigurationError.invalidParameter("LatentGaussian source split date")
            }
            return (date, row.ratio)
        })
        let evidence = try signals(bars: bars, splits: splits,
            stateEligibleFrom: BacktestSeriesAlignment.historicalSeriesDate(from: "2000-01-13")!)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try signalData(evidence).write(to: output, options: .withoutOverwriting)
        print("Fixed LatentGaussian source: \(evidence.count) original USD bar signals; no accounts.")
    }
    private static func validateInput(_ input: Input) throws {
        guard input.schema == "fixed-latent2-gaussian-v1", input.symbol == "QQQ", input.currency == "USD",
              input.bars.count == 6937, input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-06",
              input.splits.count == 1, input.splits[0].date == "2000-03-20", input.splits[0].ratio == 2 else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian frozen original USD bars/split")
        }
    }
    private static func jsonObject(_ path: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian metadata object " + path.lastPathComponent)
        }
        return object
    }
    private static func exactInt(_ value: Any?, equals expected: Int) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return n.stringValue == String(expected)
    }
    private static func trueBool(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue
    }
    /// Consume the already exported, independently qualified tape; never fit/filter here.
    private static func qualifiedSource(study: URL, bars: [Bar], splits: [BacktestShareSplit],
        rawPrices: Data, sourceCommit: String) throws -> ([Signal], Data) {
        try requireContracts(study)
        let path = study.appendingPathComponent("source/signals.json")
        let data = try Data(contentsOf: path), dumpSHA = ResearchRunEvidence.sha256(data)
        let referencePath = study.appendingPathComponent("SOURCE_REFERENCE_REVIEW.json")
        let referenceData = try Data(contentsOf: referencePath)
        let reference = try jsonObject(referencePath)
        let receipt = try jsonObject(study.appendingPathComponent("SOURCE_REFERENCE_RECEIPT.json"))
        let source = try jsonObject(study.appendingPathComponent("SOURCE_EXPORT_RECEIPT.json"))
        guard source["stage"] as? String == "source", exactInt(source["exit_code"], equals: 0),
              trueBool(source["bindings_unchanged_after"]), let bindings = source["bindings"] as? [String: Any],
              bindings["app_commit"] as? String == sourceCommit,
              let files = bindings["files"] as? [String: String],
              bindings["binary_sha256"] as? String == ResearchRunEvidence.sha256(try Data(contentsOf:
                URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
              receipt["stage"] as? String == "reference", exactInt(receipt["exit_code"], equals: 0),
              trueBool(receipt["bindings_unchanged_after"]),
              receipt["stdout_sha256"] as? String == ResearchRunEvidence.sha256(referenceData),
              reference["status"] as? String == "PASS_FIXED_LATENT2_GAUSSIAN_INDEPENDENT_SOURCE_REFERENCE",
              reference["source_dump_path"] as? String == path.path,
              reference["source_dump_sha256"] as? String == dumpSHA,
              reference["prices_sha256"] as? String == pricesSHA,
              reference["pre_specification_sha256"] as? String == preSHA,
              reference["input_freeze_sha256"] as? String == inputSHA,
              reference["source_interface_sha256"] as? String == interfaceSHA,
              exactInt(reference["source_signal_count"], equals: 6937),
              exactInt(reference["mismatches"], equals: 0),
              let blockers = reference["blockers"] as? [Any], blockers.isEmpty,
              ResearchRunEvidence.sha256(rawPrices) == pricesSHA else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian mandatory actual source/reference qualification")
        }
        for (name, expected) in [("PRE_SPECIFICATION.json", preSHA), ("INPUT_FREEZE.json", inputSHA),
            ("SOURCE_INTERFACE.json", interfaceSHA), ("inputs/prices.json", pricesSHA)] {
            guard files[study.appendingPathComponent(name).path] == expected else {
                throw BacktestConfigurationError.invalidParameter("LatentGaussian required source binding " + name)
            }
        }
        for (file, expected) in files {
            guard file.hasPrefix("/"), ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: file))) == expected else {
                throw BacktestConfigurationError.invalidParameter("LatentGaussian source binding unchanged " + file)
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let tape = try decoder.decode([Signal].self, from: data)
        guard tape.count == 6937, tape.count == bars.count, try signalData(tape) == data else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian literal complete Codable source tape")
        }
        var fitCount = 0, latestFitDate: Date?, splitIndex = 0
        let splitEvents = splits.sorted { $0.effectiveDate < $1.effectiveDate }
        let funded = BacktestSeriesAlignment.historicalSeriesDate(from: "2000-01-13")!
        for i in tape.indices {
            let s = tape[i], bar = bars[i], prior = i == 0 ? States() : tape[i - 1].states
            let hadModel = i > 0 && tape[i - 1].modelAvailable
            let newMonth = i > 0 && String(s.sourceDate.prefix(7)) != String(tape[i - 1].sourceDate.prefix(7))
            let fitPerformed = i >= formationReturns && (!hadModel || newMonth)
            if fitPerformed { fitCount += 1; latestFitDate = bar.date }
            var transported = prior, applied: [Date] = [], factor = 1.0
            while splitIndex < splitEvents.count, splitEvents[splitIndex].effectiveDate <= bar.date {
                let event = splitEvents[splitIndex]
                transported.previousClose = try divide(transported.previousClose, event.newUnitsPerOldUnit, "LatentGaussian saved prior split")
                factor = try multiply(factor, event.newUnitsPerOldUnit, "LatentGaussian saved split metadata")
                applied.append(event.effectiveDate); splitIndex += 1
            }
            let available = fitCount > 0, eligible = bar.date >= funded
            let expectedWeight: Double = eligible && available && s.states.predictedMean > 0 ? 1 : 0
            let reason = !eligible ? "pre-funding-cash" : !available ? "model-formation-cash"
                : s.states.predictedMean > 0 ? "latent-positive-predicted-mean-long" : "latent-nonpositive-predicted-mean-cash"
            guard s.date == bar.date, s.sourceDate == BacktestSeriesAlignment.historicalSeriesDateString(from: bar.date),
                  s.sourceOrdinal == i, s.currentBar == i + 1, s.currentUSDBar == bar, s.price == bar.close,
                  s.computed, !s.warmOverride, s.modelAvailable == available, s.comparisonAvailable == available,
                  s.returnAvailable == (i > 0), s.fitPerformed == fitPerformed, s.fundingEligible == eligible,
                  s.states.periodCount == i + 1, s.states.returnCount == i, s.states.fitCount == fitCount,
                  s.states.fitIterationCount == (available ? emIterations : 0),
                  s.states.previousClose == bar.close,
                  s.priorStatesBeforeSplit == prior, s.priorStates == transported,
                  s.appliedSplitDates == applied, s.splitFactor == factor,
                  s.latestFitDate == latestFitDate, s.fitPrefixEndDate == latestFitDate,
                  s.stateSourceDate == bar.date, s.previousWeight == (i == 0 ? 0 : tape[i - 1].weight),
                  s.weight == expectedWeight, s.stateReason == reason else {
                throw BacktestConfigurationError.invalidParameter("LatentGaussian saved source date/clock/state/target \(i)")
            }
            try validateState(s.states, "LatentGaussian saved states \(i)")
            if fitPerformed {
                guard let record = s.fitRecord, record.observedReturns == i, record.iterations == emIterations,
                      record.fitPrefixFirstSourceDate == tape[1].sourceDate,
                      record.fitPrefixLastSourceDate == s.sourceDate, s.states.lastFitReturnCount == i,
                      record.logLikelihoodByIteration.count == emIterations + 1,
                      record.logLikelihoodByIteration.allSatisfy(\.isFinite),
                      record.initialPrefixMean.isFinite, record.initialPrefixVariance.isFinite,
                      record.initialPrefixVariance > 0 else {
                    throw BacktestConfigurationError.invalidParameter("LatentGaussian saved complete fitRecord \(i)")
                }
                try validateModel(record.initialModel, "LatentGaussian saved initialModel \(i)")
            } else {
                guard s.fitRecord == nil,
                      s.states.lastFitReturnCount == (i == 0 ? 0 : tape[i - 1].states.lastFitReturnCount) else {
                    throw BacktestConfigurationError.invalidParameter("LatentGaussian saved null/nonrefit record \(i)")
                }
            }
        }
        return (tape, data)
    }
    public static func latestSignal(_ signals: [Signal], before date: Date) -> Signal? {
        var low = 0, high = signals.count
        while low < high {
            let mid = (low + high) / 2
            if signals[mid].date < date { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? signals[low - 1] : nil
    }

    public typealias Role = ChaikinMoneyFlowScreen.Role
    public typealias Decision = ChaikinMoneyFlowScreen.Decision
    public struct NativeRun {
        public let simulation: BacktestDailySimulationResult
        public let decisions: [Decision]
        public let targetMismatchCount: Int
    }
    /// Shared one-asset target delivery: submit the first post-baseline target,
    /// then submit only changes. A split-day open uses the prior completed signal.
    public static func runAccount(preparation: NativePreparation, signals: [Signal], shareSplits: [BacktestShareSplit], role: Role) throws -> NativeRun {
        let frame = preparation.frame
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false,
            buyReason: role == .candidate ? "fixed LatentGaussian research" : "fixed CMF20 research")
        func desired(_ c: StrategyTargetContext) -> Double {
            guard c.index > frame.simulationRange.lowerBound else { return 0 }
            switch role {
            case .cash: return 0
            case .buyHold: return 1
            case .candidate: return latestSignal(signals, before: c.date)?.weight ?? 0
            }
        }
        var submitted: Double?, decisions: [Decision] = []
        guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
            provider: .init { desired($0) == 1 ? ["QQQ": 1] : [:] },
            rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
            contextualRebalanceDecision: { c in
                let w = desired(c), previous = submitted
                let changed = c.index > frame.simulationRange.lowerBound && (submitted == nil || submitted != w)
                if changed { submitted = w }
                decisions.append(.init(index: c.index, date: c.date, signalDate: c.signalDate,
                    latestUSDBarDate: latestSignal(signals, before: c.date)?.date, desired: w,
                    previousSubmitted: previous, submitted: submitted, shouldRebalance: changed, accepted: 0))
                return .init(shouldRebalance: changed, refreshOverlay: false)
            }, executionPricesBySymbol: ["QQQ": preparation.opens], shareSplits: shareSplits) else {
            throw BacktestConfigurationError.computationFailed
        }
        guard run.dailyStates.count == decisions.count,
              run.dailyStates.first?.portfolioValue == 100000, run.dailyStates.first?.cash == 100000,
              run.dailyStates.first?.targetWeights.isEmpty == true,
              !run.trades.contains(where: { $0.date == frame.dates[frame.simulationRange.lowerBound] }) else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian unchanged initial cash baseline")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].accepted = run.dailyStates[i].targetWeights["QQQ"] ?? 0
            if decisions[i].accepted != decisions[i].desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("LatentGaussian prior target delivery") }
        return .init(simulation: run, decisions: decisions, targetMismatchCount: mismatches)
    }

    private struct Input: Decodable {
        let schema: String; let symbol: String; let currency: String; let bars: [InputBar]; let splits: [Split]
        struct InputBar: Decodable {
            let date: String; let open: Double; let high: Double; let low: Double; let close: Double; let volume: Double
        }
        struct Split: Decodable { let date: String; let ratio: Double }
    }
    private struct Sources: Decodable {
        let schema: String; let files: [File]
        struct File: Decodable { let path: String; let sha256: String; let ids: [String] }
    }
    private struct Saved: Decodable { let id: String; let dailyStates: [BacktestDailyState] }
    private struct Account {
        let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade]; let savedObject: [String: Any]?
    }
    private struct CashEvidence: Encodable {
        let startDate: Date?
        let endDate: Date?
        let totalCashInterest: Double
        let averageAnnualRate: Double
        let averageCashRatio: Double
        init(_ summary: CashYieldSummary) {
            startDate = summary.startDate; endDate = summary.endDate; totalCashInterest = summary.totalCashInterest
            averageAnnualRate = summary.averageAnnualRate; averageCashRatio = summary.averageCashRatio
        }
    }
    public static var savedControlIDs: [String] { ChaikinMoneyFlowScreen.savedControlIDs }

    public static func run(pricesPath: String, historyPath: String, accountsPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let savedRaw = try Data(contentsOf: URL(fileURLWithPath: accountsPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        let sources = try JSONDecoder().decode(Sources.self, from: savedRaw)
        guard input.schema == "fixed-latent2-gaussian-v1", input.symbol == "QQQ", input.currency == "USD",
              input.bars.count == 6937, input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-06",
              input.splits.count == 1, input.splits[0].date == "2000-03-20", input.splits[0].ratio == 2,
              sources.schema == "fixed-latent2-gaussian-saved-v1", !sources.files.isEmpty,
              sources.files.flatMap(\.ids) == savedControlIDs, savedControlIDs.count == 31 else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian frozen input and 31 saved-control scope")
        }
        func date(_ day: String) throws -> Date {
            guard let value = BacktestSeriesAlignment.historicalSeriesDate(from: day) else {
                throw BacktestConfigurationError.invalidParameter("LatentGaussian session date")
            }
            return value
        }
        let bars = try input.bars.map { b in Bar(date: try date(b.date), open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume) }
        let splits = try input.splits.map { s in BacktestShareSplit(id: "QQQ:" + s.date, symbol: "QQQ",
            effectiveDate: try date(s.date), newUnitsPerOldUnit: s.ratio) }
        let study = output.deletingLastPathComponent()
        let (signalEvidence, savedSignalBytes) = try qualifiedSource(study: study, bars: bars, splits: splits,
            rawPrices: raw, sourceCommit: sourceCommit)
        let dataset = try PublicBacktestCore.loadDataset(from: history, datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        guard let fx = dataset.seriesBySymbol["usd_per_cny"], fx.dates.first == "2000-01-13" else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian original App FX start; no early extension")
        }
        let native = try ChaikinMoneyFlowScreen.nativePreparation(bars: bars, fxDates: fx.dates, fxPrices: fx.prices, baseline: date("2000-01-13"))
        guard native.frame.dates.last == (try date("2026-10-06")), native.frame.dates.count == 6722,
              native.frame.dates.count == input.bars.filter({ $0.date >= "2000-01-13" }).count else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian every native QQQ session retained")
        }
        var accounts: [Account] = [], decisions: [String: [Decision]] = [:]
        var splitEvidence: [String: [BacktestSplitAdjustment]] = [:], targetAudits: [String: [String: Int]] = [:]
        var cashEvidence: [String: CashEvidence] = [:]
        for (id, role) in [(candidateID, Role.candidate), (buyHoldID, Role.buyHold), (cashID, Role.cash)] {
            let run = try runAccount(preparation: native, signals: signalEvidence, shareSplits: splits, role: role)
            decisions[id] = run.decisions; splitEvidence[id] = run.simulation.splitAdjustments
            cashEvidence[id] = CashEvidence(run.simulation.cashYieldSummary)
            targetAudits[id] = ["desired_accepted_mismatches": run.targetMismatchCount, "state_count": run.simulation.dailyStates.count]
            accounts.append(.init(id: id, states: run.simulation.dailyStates, trades: run.simulation.trades, savedObject: nil))
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var selectedIDs: [String] = []
        for file in sources.files {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
            guard ResearchRunEvidence.sha256(data) == file.sha256,
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw BacktestConfigurationError.invalidParameter("LatentGaussian saved-control file hash/rows")
            }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }),
                      selectedIDs.contains(id) == false else {
                    throw BacktestConfigurationError.invalidParameter("LatentGaussian saved-control identity/state order")
                }
                selectedIDs.append(id)
                accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("LatentGaussian 3 new / 31 saved account budget") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("LatentGaussian mechanical common calendar") }
            let commonSet = Set(common), last = common.last!
            let ten = BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding: .year, value: -10, to: last)!
            let windows = [("full", text(common.first!), text(last)), ("trailing10Y", text(ten), text(last)),
                ("since2020", "2020-01-01", text(last)), ("since2022", "2022-01-01", text(last)),
                ("crisis2008", "2008-01-01", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"),
                ("crisis2022", "2022-01-01", "2022-12-31")]
            return (try selected.map { a in try object(DailyScreenOutput.row(a.id,
                states: a.states.filter { commonSet.contains($0.date) }, trades: a.trades, windows: windows), account: a) }, common)
        }
        let (longRows, longDates) = try comparison(accounts.filter { $0.id != qualID })
        let (allRows, allDates) = try comparison(accounts)
        guard longDates.count == 5595, text(longDates.first!) == "2002-09-18", text(longDates.last!) == "2026-09-30",
              allDates.count == 3086, text(allDates.first!) == "2013-07-18", text(allDates.last!) == "2026-09-30" else {
            throw BacktestConfigurationError.invalidParameter("LatentGaussian frozen mechanical long/all20 calendars")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        let result = try JSONSerialization.data(withJSONObject: longRows, options: [.sortedKeys])
        let nativeBytes = try JSONSerialization.data(withJSONObject: nativeRows, options: [.sortedKeys])
        let allBytes = try JSONSerialization.data(withJSONObject: allRows, options: [.sortedKeys])
        let signalBytes = savedSignalBytes
        let inputObject = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        var nativeQuotes = try JSONSerialization.jsonObject(with: encoder.encode(native.quotes)) as! [[String: Any]]
        for key in ["fxDate", "usdPerCNY", "cnyPerUSD"] { nativeQuotes[0][key] = NSNull() }
        var decisionObjects = try JSONSerialization.jsonObject(with: encoder.encode(decisions)) as! [String: [[String: Any]]]
        for id in decisionObjects.keys {
            for index in decisionObjects[id]!.indices {
                for key in ["latestUSDBarDate", "previousSubmitted", "submitted"] where decisionObjects[id]![index][key] == nil {
                    decisionObjects[id]![index][key] = NSNull()
                }
            }
        }
        let quotesObject: [String: Any] = ["original_usd_bars": inputObject["bars"]!, "native_quotes": nativeQuotes,
            "split_events": inputObject["splits"]!, "input_price_units": "already-restored historical share units; no second adjustment"]
        let frameObject: [String: Any] = ["dates": native.frame.dates.map(text), "prices": native.frame.pricesBySymbol,
            "auction_prices": ["QQQ": native.opens], "observed": native.frame.observedBySymbol,
            "simulation_first": native.frame.simulationRange.lowerBound, "simulation_last": native.frame.simulationRange.upperBound]
        let evidence: [String: Any] = ["completed_at": ISO8601DateFormatter().string(from: Date()),
            "evidence_class": "D0_USER_AUTHORIZED_POST_HOC_RELATED_ROOT_ORIGINAL_LATENT_GAUSSIAN_DIRECTION_FORECAST", "formal_validation": false,
            "recommendation_eligible": false, "source_commit": sourceCommit,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "prices_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "accounts_sha256": ResearchRunEvidence.sha256(savedRaw), "saved_source_files": sources.files.map { ["path": $0.path, "sha256": $0.sha256, "ids": $0.ids] as [String: Any] },
            "result_sha256": ResearchRunEvidence.sha256(result), "native_full_sha256": ResearchRunEvidence.sha256(nativeBytes),
            "all20_sha256": ResearchRunEvidence.sha256(allBytes), "signals_sha256": ResearchRunEvidence.sha256(signalBytes),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "candidate_count": 1, "new_funded_account_count": 3, "saved_control_count": 31, "account_count": 34,
            "parameter_search_budget": 0, "tunable_parameter_count": 0, "estimated_parameter_count": 6,
            "seed_policy": "Root 22 zero states before source0: five exact Int and 17 Double; all source bars computed and currentBar=ordinal+1; 15 zero model placeholders are not estimates; first model after252 observed returns; no funding/slice reset",
            "recurrence_policy": "Two Gaussian states with own mean/variance; expanding known return prefix;100 fixed EM updates; fixed uniform s0; xi includes allN s0-to-s1 transitions; canonical labels permute both P axes; fresh final theta100 forward once and101 likelihood records; no rescue/FMA/reassociation",
            "forecast_policy": "Root one-step pnext from final causal filtered alpha and P, normalized once; predictedMean=next0*mu0+next1*mu1; prefunding/model formation cash, funded available strictpositive forecast fullQQQ elsecash includingzero; no position latch",
            "position_state_eligible_from": "2000-01-13", "source_bar_count": bars.count, "native_state_count": native.frame.dates.count,
            "native_start": text(native.frame.dates.first!), "native_end": text(native.frame.dates.last!),
            "primary_metric": "App native-full daily NAV Sharpe Rf=0; long-common19 is an additional required comparison gate",
            "common_history_is_primary_user_choice": false,
            "primary": ["metric": "App native complete-funded-history raw-return Sharpe Rf0", "threshold": 1.2,
                "require_native_full": true, "require_long_common19_sharpe_at_least_1_2": true,
                "require_beat_strongest19": true, "all20_supplement_only": true, "all20_short_common_supplement_only": true] as [String: Any],
            "strongest19_control_ids": BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs,
            "long_common_dates": longDates.map(text), "all20_common_dates": allDates.map(text),
            "long_comparison_count": longRows.count, "all20_comparison_count": allRows.count,
            "long_excluded_id": qualID, "saved_control_ids": selectedIDs, "target_audits": targetAudits,
            "native_control_inheritance": "QQQ buy-hold and CNY cash retain unchanged CMF native preparation/execution, including original engine buyReason fixed CMF20 research",
            "fee_rate": 0.00025, "slippage_rate": 0, "cash": "CashYieldCNY",
            "fx_policy": "unchanged App FX / strictly prior calendar date / max14 calendar days / same factor OHLC",
            "cash_baseline_policy": "2000-01-13 cash100000; zero unavailable QQQ mark and auction; no target or trade",
            "signal_policy": "Complete original USD Close prefix; latest completed strictly before opening; all source bars compute, monthly refit at first observed civil newmonth; finance consumes only the actual exported independently qualified Codable tape without refit/filter/return reconstruction",
            "price_units": "Input already restores historical OHLC; no second input adjustment; effective splits divide only internal prior previousClose in chronological event order; factor product is metadata only; returns and dimensionless model states are not rescaled; emitted states/weights immutable; original engine handles held units",
            "state_names": ["periodCount", "returnCount", "fitCount", "lastFitReturnCount", "fitIterationCount",
                "previousClose", "currentReturn", "mu0", "mu1", "variance0", "variance1", "p00", "p01", "p10", "p11",
                "alpha0", "alpha1", "next0", "next1", "predictedMean", "fitLogLikelihood", "fitLogLikelihoodGap"],
            "initial_state_count": 22, "max_bars_back": 0, "first_computed_source_ordinal": 0,
            "warm_override": false, "comparison_available_policy": "same as modelAvailable: false before first252-return fit, true afterwards",
            "source_authority": "Hamilton 2005 author manuscript; exact physical authority bindings in frozen PRE",
            "pre_specification_sha256": preSHA,
            "input_freeze_sha256": inputSHA, "source_interface_sha256": interfaceSHA,
            "qualified_source_dump_path": study.appendingPathComponent("source/signals.json").path,
            "source_reference_review_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: study.appendingPathComponent("SOURCE_REFERENCE_REVIEW.json"))),
            "source_reference_receipt_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: study.appendingPathComponent("SOURCE_REFERENCE_RECEIPT.json"))),
            "source_export_receipt_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: study.appendingPathComponent("SOURCE_EXPORT_RECEIPT.json"))),
            "limitations": ["Related D0 Root original latent Gaussian policy. Hamilton supplies latent filtering/likelihood source authority, not this100-update EM,252-return formation, monthly expanding-clock, initialization, split treatment, long/cash policy or default. Related mechanism overlap and missing REGIME original remain UNKNOWN; no independent-alpha, global-MLE, pristine-OOS or formal-validation claim.",
                "No dividends, tax, FX conversion fees or separate USD-wallet certification; historical quotes are not complete quote-vintage certification.",
                "Fixed100 EM may reach a local solution and is not convergence-certified; any invalid variance/count/density/probability closes the candidate without restart, ridge, floors or rescue; all data-source/forecast gaps and transaction costs remain.",
                "Full native history retains initial unavailable-mark cash baseline; comparison calendars are mechanical slices of one native account; saved31 whole rows and limits remain unchanged and QUAL is only shorter all20 supplement."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, data) in [("result.json", result), ("native-full.json", nativeBytes), ("all20.json", allBytes),
            ("signals.json", signalBytes), ("decisions.json", try JSONSerialization.data(withJSONObject: decisionObjects, options: [.sortedKeys])),
            ("splits.json", try encoder.encode(splitEvidence)), ("cash-yield.json", try encoder.encode(cashEvidence)),
            ("quotes.json", try JSONSerialization.data(withJSONObject: quotesObject, options: [.sortedKeys])),
            ("native-frame.json", try JSONSerialization.data(withJSONObject: frameObject, options: [.sortedKeys])),
            ("evidence.json", try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]))] {
            try data.write(to: output.appendingPathComponent(name))
        }
        print("Fixed LatentGaussian: 1 candidate, 3 new accounts, 31 saved controls; native \(native.frame.dates.count)/long \(longDates.count)/all20 \(allDates.count) dates.")
    }
}
