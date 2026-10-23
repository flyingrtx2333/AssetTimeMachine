import Foundation
import AssetTimeMachineBacktestCore

/// Frozen whole ANTI1: BAH30 over all29 price-only ANTICOR experts.
/// All actual cash, units, fills and NAV come from one unchanged shared account.
public enum AnticorrelationCoreScreen {
    public static let coreSymbols = RiskParityCoreScreen.coreSymbols
    public static let candidateID = "anticor1-three-core-daily-next-close"
    public static let equalID = "equal-core100-anticor1-daily-close-control"
    public static let cashID = "cny-cash-anticor1-native2001"
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

    public static let windows = Array(2...30)
    private static func invalid(_ reason: String) -> BacktestConfigurationError { .invalidParameter("ANTI1 " + reason) }
    private static func finite(_ value: Double) throws -> Double {
        guard value.isFinite else { throw invalid("nonfinite arithmetic; no fallback") }; return value
    }
    private static func positive(_ value: Double) throws -> Double {
        guard value.isFinite, value > 0 else { throw invalid("positive finite scalar; no floor") }; return value
    }
    static func multiply(_ a: Double, _ b: Double) throws -> Double {
        guard a.isFinite, b.isFinite else { throw invalid("finite product operands") }
        let value = try finite(a * b)
        guard a == 0 || b == 0 || value != 0 else { throw invalid("product underflow; no fallback") }; return value
    }
    static func divide(_ a: Double, _ b: Double) throws -> Double {
        guard a.isFinite, b.isFinite, b != 0 else { throw invalid("finite nonzero divisor") }
        let value = try finite(a / b)
        guard a == 0 || value != 0 else { throw invalid("division underflow; no fallback") }; return value
    }
    static func orderedSum(_ values: [Double]) throws -> Double {
        var sum = 0.0
        for value in values { sum = try finite(sum + finite(value)) }
        return sum
    }
    public struct Normalization: Equatable { public let denominator: Double; public let values: [Double] }
    static func normalize(_ raw: [Double]) throws -> Normalization {
        guard raw.count == 3, raw.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw invalid("nonnegative three-core vector") }
        let denominator = try positive(orderedSum(raw))
        return .init(denominator: denominator, values: try raw.map { try divide($0, denominator) })
    }
    public struct WindowMoments: Encodable, Equatable {
        public let anchors: [Double]
        public let shifts: [Double]
        public let means: [Double]
        public let squareSums: [Double]
        public let variances: [Double]
        public let sigmas: [Double]
    }
    struct CenteredWindow { let moments: WindowMoments; let centeredRows: [[Double]] }
    /// Rows are chronological log price relatives. Anchored moments preserve exact constant columns.
    static func centeredWindow(_ rows: [[Double]]) throws -> CenteredWindow {
        guard rows.count >= 2, rows.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else { throw invalid("finite complete log window") }
        var anchors: [Double] = [], shifts: [Double] = [], means: [Double] = []
        var squares: [Double] = [], variances: [Double] = [], sigmas: [Double] = []
        var centered = Array(repeating: Array(repeating: 0.0, count: 3), count: rows.count)
        for i in 0..<3 {
            let anchor = rows[0][i]
            var deltas: [Double] = []
            for row in rows { deltas.append(try finite(row[i] - anchor)) }
            let shift = try divide(orderedSum(deltas), Double(rows.count)), mean = try finite(anchor + shift)
            var squareSum = 0.0
            for k in rows.indices {
                let c = try finite(deltas[k] - shift); centered[k][i] = c
                squareSum = try finite(squareSum + multiply(c, c))
            }
            let variance = try divide(squareSum, Double(rows.count - 1))
            guard variance >= 0 else { throw invalid("negative variance") }
            let sigma = try finite(sqrt(variance))
            if variance > 0 { _ = try positive(sigma) }
            anchors.append(anchor); shifts.append(shift); means.append(mean); squares.append(squareSum)
            variances.append(variance); sigmas.append(sigma)
        }
        return .init(moments: .init(anchors: anchors, shifts: shifts, means: means, squareSums: squares, variances: variances, sigmas: sigmas), centeredRows: centered)
    }
    public struct Correlation: Equatable {
        public let denominator: Double
        public let zeroVariance: Bool
        public let raw: Double
        public let value: Double
        public let clamped: Bool
    }
    static func correlation(covariance: Double, sigma1: Double, sigma2: Double) throws -> Correlation {
        guard covariance.isFinite, sigma1.isFinite, sigma2.isFinite, sigma1 >= 0, sigma2 >= 0 else { throw invalid("correlation inputs") }
        if sigma1 == 0 || sigma2 == 0 { return .init(denominator: 0, zeroVariance: true, raw: 0, value: 0, clamped: false) }
        let denominator = try positive(multiply(sigma1, sigma2)), raw = try divide(covariance, denominator)
        let value = min(1, max(-1, raw))
        return .init(denominator: denominator, zeroVariance: false, raw: raw, value: value, clamped: value != raw)
    }
    public struct Transfer: Encodable, Equatable {
        public let meanGE: [Bool]
        public let positiveCorrelation: [Bool]
        public let claimMask: [Bool]
        public let claims: [Double]
        public let rowSums: [Double]
        public let fractions: [Double]
        public let retainedMass: [Double]
        public let transfers: [Double]
        public let selfTransfers: [Double]
        public let incomingSums: [Double]
        public let qNextRaw: [Double]
        public let qNextDenominator: Double
        public let qNext: [Double]
    }
    /// Fixed Figure1 >= and all-pair claims; root post-price budgets and nonnegative retained mass.
    static func applyTransfers(bhat: [Double], means2: [Double], correlations: [Double]) throws -> Transfer {
        guard bhat.count == 3, bhat.allSatisfy({ $0.isFinite && $0 >= 0 }), bhat.contains(where: { $0 > 0 }),
              means2.count == 3, means2.allSatisfy(\.isFinite), correlations.count == 9,
              correlations.allSatisfy({ $0.isFinite && $0 >= -1 && $0 <= 1 }) else { throw invalid("immutable transfer inputs") }
        var claims = Array(repeating: 0.0, count: 9), meanGE: [Bool] = [], positiveCorr: [Bool] = [], masks: [Bool] = []
        for i in 0..<3 { for j in 0..<3 {
            let offset = 3 * i + j, ge = means2[i] >= means2[j], pc = correlations[offset] > 0
            meanGE.append(ge); positiveCorr.append(pc); masks.append(ge && pc)
            if ge && pc {
                var claim = correlations[offset]
                if correlations[3 * i + i] < 0 { claim = try finite(claim - correlations[3 * i + i]) }
                if correlations[3 * j + j] < 0 { claim = try finite(claim - correlations[3 * j + j]) }
                claims[offset] = try positive(claim)
            }
        } }
        var rowSums: [Double] = [], retained = Array(repeating: 0.0, count: 3)
        var fractions = Array(repeating: 0.0, count: 9), transfers = Array(repeating: 0.0, count: 9)
        var selfTransfers = Array(repeating: 0.0, count: 3)
        for i in 0..<3 {
            let total = try orderedSum(Array(claims[(3 * i)..<(3 * i + 3)])); rowSums.append(total)
            if total == 0 { retained[i] = bhat[i] }
            else {
                let selfFraction = try divide(claims[3 * i + i], total)
                fractions[3 * i + i] = selfFraction; retained[i] = try multiply(bhat[i], selfFraction)
                selfTransfers[i] = retained[i]; transfers[3 * i + i] = retained[i]
                for j in 0..<3 where j != i {
                    let offset = 3 * i + j, fraction = try divide(claims[offset], total)
                    fractions[offset] = fraction; transfers[offset] = try multiply(bhat[i], fraction)
                }
            }
        }
        var incoming: [Double] = [], raw: [Double] = []
        for i in 0..<3 {
            var sum = 0.0
            for j in 0..<3 where j != i { sum = try finite(sum + transfers[3 * j + i]) }
            incoming.append(sum); raw.append(try finite(retained[i] + sum))
        }
        let n = try normalize(raw)
        return .init(meanGE: meanGE, positiveCorrelation: positiveCorr, claimMask: masks, claims: claims,
            rowSums: rowSums, fractions: fractions, retainedMass: retained, transfers: transfers, selfTransfers: selfTransfers,
            incomingSums: incoming, qNextRaw: raw, qNextDenominator: n.denominator, qNext: n.values)
    }
    public struct Expert: Encodable, Equatable {
        public let expertOrdinal: Int
        public let window: Int
        public let reason: String
        public let ready: Bool
        public let qNext: [Double]
        public let logWealthNext: Double
        public var previousPortfolio: [Double]? = nil
        public var logWealthPrevious: Double? = nil
        public var priceNumerators: [Double]? = nil
        public var growth: Double? = nil
        public var bhatRaw: [Double]? = nil
        public var bhatDenominator: Double? = nil
        public var bhat: [Double]? = nil
        public var logGrowth: Double? = nil
        public var window1Start: Int? = nil
        public var window1End: Int? = nil
        public var window2Start: Int? = nil
        public var window2End: Int? = nil
        public var window1: WindowMoments? = nil
        public var window2: WindowMoments? = nil
        public var covarianceSums: [Double]? = nil
        public var covariance: [Double]? = nil
        public var correlationDenominators: [Double]? = nil
        public var zeroVarianceMask: [Bool]? = nil
        public var rawCorrelations: [Double]? = nil
        public var correlations: [Double]? = nil
        public var correlationClamped: [Bool]? = nil
        public var transfer: Transfer? = nil
    }
    static func updateExpert(window: Int, previousPortfolio: [Double], logWealthPrevious: Double,
                             x: [Double], logRelatives: [[Double]]) throws -> Expert {
        guard windows.contains(window), previousPortfolio.count == 3,
              previousPortfolio.allSatisfy({ $0.isFinite && $0 >= 0 }), previousPortfolio.contains(where: { $0 > 0 }),
              logWealthPrevious.isFinite, x.count == 3, x.allSatisfy({ $0.isFinite && $0 > 0 }),
              !logRelatives.isEmpty else { throw invalid("expert state/funded interval") }
        let numerators = try (0..<3).map { try multiply(previousPortfolio[$0], x[$0]) }
        let growth = try positive(orderedSum(numerators)), raw = try numerators.map { try divide($0, growth) }
        let drift = try normalize(raw), logGrowth = try finite(log(growth)), ell = try finite(logWealthPrevious + logGrowth)
        let s = logRelatives.count, ready = s >= 2 * window
        var first: CenteredWindow?, second: CenteredWindow?, transfer: Transfer?
        var covSums: [Double] = [], cov: [Double] = [], denominators: [Double] = [], zeros: [Bool] = []
        var rawCorr: [Double] = [], corr: [Double] = [], clamped: [Bool] = []
        if ready {
            let one = try centeredWindow(Array(logRelatives[(s - 2 * window)..<(s - window)]))
            let two = try centeredWindow(Array(logRelatives[(s - window)..<s])); first = one; second = two
            for i in 0..<3 { for j in 0..<3 {
                var sum = 0.0
                for k in 0..<window { sum = try finite(sum + multiply(one.centeredRows[k][i], two.centeredRows[k][j])) }
                let covariance = try divide(sum, Double(window - 1))
                let c = try correlation(covariance: covariance, sigma1: one.moments.sigmas[i], sigma2: two.moments.sigmas[j])
                covSums.append(sum); cov.append(covariance); denominators.append(c.denominator); zeros.append(c.zeroVariance)
                rawCorr.append(c.raw); corr.append(c.value); clamped.append(c.clamped)
            } }
            transfer = try applyTransfers(bhat: drift.values, means2: two.moments.means, correlations: corr)
        }
        let next = transfer?.qNext ?? drift.values // Warm exact copy, never a second normalization.
        var result = Expert(expertOrdinal: window - 2, window: window, reason: ready ? "formed-ANTICOR-transfer" : "warm-post-price-drift",
            ready: ready, qNext: next, logWealthNext: ell)
        result.previousPortfolio = previousPortfolio; result.logWealthPrevious = logWealthPrevious
        result.priceNumerators = numerators; result.growth = growth; result.bhatRaw = raw
        result.bhatDenominator = drift.denominator; result.bhat = drift.values; result.logGrowth = logGrowth
        if ready {
            result.window1Start = s - 2 * window + 1; result.window1End = s - window
            result.window2Start = s - window + 1; result.window2End = s
            result.window1 = first!.moments; result.window2 = second!.moments
            result.covarianceSums = covSums; result.covariance = cov; result.correlationDenominators = denominators
            result.zeroVarianceMask = zeros; result.rawCorrelations = rawCorr; result.correlations = corr
            result.correlationClamped = clamped; result.transfer = transfer
        }
        return result
    }
    public struct Mix: Encodable, Equatable {
        public let maxLogWealth: Double
        public let maxOrdinal: Int
        public let scaledWealth: [Double]
        public let scaledDenominator: Double
        public let expertShares: [Double]
        public let mixedRaw: [Double]
        public let mixedDenominator: Double
        public let latentTarget: [Double]
    }
    static func mix(portfolios: [[Double]], logWealth: [Double]) throws -> Mix {
        guard portfolios.count == 29, logWealth.count == 29, logWealth.allSatisfy(\.isFinite),
              portfolios.allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0.isFinite && $0 >= 0 }) && $0.contains(where: { $0 > 0 }) }) else { throw invalid("complete29 expert book") }
        var maximum = logWealth[0], ordinal = 0
        for i in 1..<29 where logWealth[i] > maximum { maximum = logWealth[i]; ordinal = i }
        let scaled = try logWealth.map { try positive(finite(exp(finite($0 - maximum)))) }
        let denominator = try positive(orderedSum(scaled)), shares = try scaled.map { try positive(divide($0, denominator)) }
        var raw: [Double] = []
        for i in 0..<3 {
            var sum = 0.0
            for w in 0..<29 { sum = try finite(sum + multiply(shares[w], portfolios[w][i])) }
            raw.append(sum)
        }
        let n = try normalize(raw)
        return .init(maxLogWealth: maximum, maxOrdinal: ordinal, scaledWealth: scaled, scaledDenominator: denominator,
            expertShares: shares, mixedRaw: raw, mixedDenominator: n.denominator, latentTarget: n.values)
    }
    public struct RoleDiagnostic: Encodable, Equatable {
        public let symbol: String
        public let rawWeight: Double
        public let cleanedWeight: Double
    }
    public struct Signal: Encodable, Equatable {
        public let signalIndex: Int
        public let date: Date
        public let intervalCount: Int
        public let reason: String
        public let x: [Double]?
        public let logX: [Double]?
        public let experts: [Expert]
        public let mix: Mix?
        public let latentTarget: [Double]
        public let roles: [RoleDiagnostic]
        public let rawTarget: [String: Double]
        public let cleanedTarget: [String: Double]
    }
    public static func signals(frame: MarketDataFrame) throws -> [Signal] {
        guard !frame.dates.isEmpty, frame.simulationRange.lowerBound == 0,
              coreSymbols.allSatisfy({ frame.pricesBySymbol[$0]?.count == frame.dates.count && frame.pricesBySymbol[$0]!.allSatisfy({ $0.isFinite && $0 > 0 }) }) else { throw invalid("full positive funded source frame") }
        let initial = Array(repeating: 1.0 / 3, count: 3)
        var portfolios = Array(repeating: initial, count: 29), logWealth = Array(repeating: 0.0, count: 29)
        var logRelatives: [[Double]] = [], result: [Signal] = []
        for s in frame.dates.indices {
            var experts: [Expert] = [], x: [Double]?, logs: [Double]?, m: Mix?
            let latent: [Double]
            if s == 0 {
                experts = windows.enumerated().map { .init(expertOrdinal: $0.offset, window: $0.element,
                    reason: "baseline-explicit-equal-prior", ready: false, qNext: initial, logWealthNext: 0) }
                latent = initial
            } else {
                let factors = try coreSymbols.map { try positive(divide(frame.pricesBySymbol[$0]![s], frame.pricesBySymbol[$0]![s - 1])) }
                let logarithms = try factors.map { try finite(log($0)) }; x = factors; logs = logarithms; logRelatives.append(logarithms)
                for w in windows.indices {
                    let e = try updateExpert(window: windows[w], previousPortfolio: portfolios[w], logWealthPrevious: logWealth[w], x: factors, logRelatives: logRelatives)
                    experts.append(e); portfolios[w] = e.qNext; logWealth[w] = e.logWealthNext
                }
                let combined = try mix(portfolios: portfolios, logWealth: logWealth); m = combined; latent = combined.latentTarget
            }
            let raw = Dictionary(uniqueKeysWithValues: coreSymbols.indices.map { (coreSymbols[$0], latent[$0]) }), clean = providerClean(raw)
            result.append(.init(signalIndex: s, date: frame.dates[s], intervalCount: s,
                reason: s == 0 ? "baseline-explicit-equal-prior" : "sequential-ANTI1-all29-price-only",
                x: x, logX: logs, experts: experts, mix: m, latentTarget: latent,
                roles: coreSymbols.indices.map { .init(symbol: coreSymbols[$0], rawWeight: latent[$0], cleanedWeight: clean[coreSymbols[$0]] ?? 0) }, rawTarget: raw, cleanedTarget: clean))
        }
        return result
    }
    static func signalObjects(_ signals: [Signal], encoder: JSONEncoder) throws -> [[String: Any]] {
        var objects = try JSONSerialization.jsonObject(with: encoder.encode(signals)) as! [[String: Any]]
        let expertNulls = ["previousPortfolio", "logWealthPrevious", "priceNumerators", "growth", "bhatRaw", "bhatDenominator", "bhat", "logGrowth",
            "window1Start", "window1End", "window2Start", "window2End", "window1", "window2", "covarianceSums", "covariance",
            "correlationDenominators", "zeroVarianceMask", "rawCorrelations", "correlations", "correlationClamped", "transfer"]
        for i in objects.indices {
            for key in ["x", "logX", "mix"] where objects[i][key] == nil { objects[i][key] = NSNull() }
            var experts = objects[i]["experts"] as! [[String: Any]]
            for w in experts.indices { for key in expertNulls where experts[w][key] == nil { experts[w][key] = NSNull() } }
            objects[i]["experts"] = experts
        }
        return objects
    }

    public static func runAccount(preparation: NativePreparation, signals: [Signal], role: Role) throws -> NativeRun {
        guard signals.count == preparation.frame.dates.count,
              signals.enumerated().allSatisfy({ $0.offset == $0.element.signalIndex && $0.element.date == preparation.frame.dates[$0.offset] }) else {
            throw BacktestConfigurationError.invalidParameter("ANTI1 exact funded signal alignment")
        }
        return try simulate(preparation: preparation,
            buyReason: role == .candidate ? "fixed ANTI1 core close research" : "fixed ANTI1 daily core close control") { context in
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
        guard frame.simulationRange.lowerBound == 0 else { throw BacktestConfigurationError.invalidParameter("ANTI1 full funded baseline") }
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
            throw BacktestConfigurationError.invalidParameter("ANTI1 unchanged cash baseline/full formation history")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].acceptedAfter = run.dailyStates[i].targetWeights
            let desired = decisions[i].requestedTarget ?? expected[i]
            if decisions[i].acceptedAfter != desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("ANTI1 target adapter delivery") }
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
            throw BacktestConfigurationError.invalidParameter("ANTI1 frozen canonical source and 31 saved controls")
        }
        func date(_ day: String) throws -> Date {
            guard let d = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { throw BacktestConfigurationError.invalidParameter("ANTI1 source session date") }
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
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BacktestConfigurationError.invalidParameter("ANTI1 saved raw hash/rows") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }), !selectedIDs.contains(id) else {
                    throw BacktestConfigurationError.invalidParameter("ANTI1 saved identity/state order")
                }
                selectedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("ANTI1 one candidate / 3 fresh / 31 saved") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("ANTI1 complete mechanical comparison calendar") }
            let commonSet = Set(common), last = common.last!
            let ten = BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding: .year, value: -10, to: last)!
            let windows = [("full", text(common.first!), text(last)), ("trailing10Y", text(ten), text(last)),
                ("since2020", "2020-01-01", text(last)), ("since2022", "2022-01-01", text(last)),
                ("crisis2008", "2008-01-01", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"), ("crisis2022", "2022-01-01", "2022-12-31")]
            return (try selected.map { a in try object(DailyScreenOutput.row(a.id, states: a.states.filter { commonSet.contains($0.date) }, trades: a.trades, windows: windows), account: a) }, common)
        }
        let (longRows, longDates) = try comparison(accounts.filter { $0.id != qualID })
        let (allRows, allDates) = try comparison(accounts)
        guard longDates.map(text) == input.saved_long_comparison_dates, longDates.count == 5595,
              text(longDates.first!) == "2002-09-18", text(longDates.last!) == "2026-09-30",
              allDates.map(text) == input.saved_short_comparison_dates, allDates.count == 3086,
              text(allDates.first!) == "2013-07-18", text(allDates.last!) == "2026-09-30" else {
            throw BacktestConfigurationError.invalidParameter("ANTI1 no comparison-day deletion")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        let signalObjects = try self.signalObjects(signalEvidence, encoder: encoder)
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
            "evidence_class": "POST_HOC_RELATED_D0_ORIGINAL_ANTI1_ALL29_SOURCE_INSPIRED_TRANSFER_AND_NEXT_CLOSE_ADAPTATION", "formal_validation": false, "recommendation_eligible": false,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "pre_specification_sha256": "e08b9d6f8b0a04e0f77e825c0f9aee7d928598b13e3c2cc36c12ce42bafe8345",
            "original_definition": "BorodinElYanivGogan2004_ANTI1_BAH30_root_bhat_budget",
            "primary_original_pdf_sha256": "1bf7530327b32e938b74ab983251e657544237caa4bb6295da0ee342de00d88b",
            "source_proposal_sha256": "82c4e641ec53775f6eeb11503a4ea6cc5b1ec74851bd314c64576cb8b45c3fc5",
            "signal_schema": "fixed-anticor1-core-signal-v1", "window_ordinals": windows, "expert_count": 29,
            "model_policy": "Price-only fullpast all29 BAH30; exactwarm normalizedpostprice bhat; anchoredlogmoments/samplevariance/crosswindowcov; Figure>=/diaginclude/Eq3pairzero/zerorowretain; rootbhatbudget/nonnegative retained+incoming; no actualaccountfeedback",
            "numeric_policy": "Fixedordinal scalar order; corrraw plus mathematicaldomainclamp; incoming from+0 then one retained addition; unconditional core sumdivide bhat/qnext/mixed, warm exactcopy; logwealth/maxexp ordered expertshares; strict nonfinite/nonzero product/division/exp underflow rejection; legalzeros/no tinyfilter/reset/fallback",
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
            "cadence_policy": "initialsentinel Int.min/2; index0actualcash/29equallatentexperts; signal0equalexec1; interval1priceonlymodel1exec2; daily scheduledmaintenance index>=1/latestprior target replacespending; band0/gross1",
            "ideal_book_actual_NAV_identity_claimed": false, "author_numerical_parity_claimed": false, "old_control_parity_claimed": false,
            "dual_clock_limitation": "Original ideal expert BAH wealth and immediate source-price transactions are signal coefficients only; actual one-account nextclose/strictpriorFX/fees/settlement/CNYcash NAV is independently reconstructed. No source Sharpe guarantee.",
            "units_policy": "accounting unitsBySymbol from genuine shared state holding value/canonical mark; ordered actual fills permit independent unit reconstruction",
            "limitations": ["Price proxies; no directly executable security/closing-auction, publication-vintage, futures-roll or total-return certification.",
                "History-exposed related whole ANTI1; explicit Figure/prose comparator, transferoperand and zerovariance authority engineering, anchoredmoments/domainclamp/logwealth/normalization; no authorcode parity, freshalpha, pristineOOS or formal promotion.",
                "No dividends/tax/USDwallet/FXspreads;31oldwhole saved objects and original limitations preserved; shortcalendar supplemental only; all prior closedfamilies unchanged."]]
        outputs["evidence.json"] = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in outputs.keys.sorted() { try outputs[name]!.write(to: output.appendingPathComponent(name)) }
        print("Fixed ANTI1 core: 1 candidate, 3 fresh accounts, 31 saved controls; native6452/long5595/short3086 dates.")
    }
}
