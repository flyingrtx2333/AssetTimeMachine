import Foundation
import AssetTimeMachineBacktestCore

/// Frozen deterministic CWMR-Stdev price-only learned confidence.
/// All actual cash, units, fills and NAV come from one unchanged shared account.
public enum ConfidenceWeightedMeanReversionCoreScreen {
    public static let coreSymbols = RiskParityCoreScreen.coreSymbols
    public static let candidateID = "cwmr-stdev-three-core-daily-next-close"
    public static let equalID = "equal-core100-cwmr-daily-close-control"
    public static let cashID = "cny-cash-cwmr-native2001"
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

    public static let phi = 2.0
    public static let epsilon = -0.5
    private static func invalid(_ reason: String) -> BacktestConfigurationError { .invalidParameter("CWMR-Stdev " + reason) }
    private static func finite(_ x: Double) throws -> Double {
        guard x.isFinite else { throw invalid("nonfinite arithmetic; no fallback") }; return x
    }
    static func multiply(_ a: Double, _ b: Double) throws -> Double {
        let value = try finite(a * b)
        guard a.isFinite, b.isFinite, a == 0 || b == 0 || value != 0 else { throw invalid("product underflow; no fallback") }
        return value
    }
    static func divide(_ a: Double, _ b: Double) throws -> Double {
        guard a.isFinite, b.isFinite, b != 0 else { throw invalid("finite nonzero divisor") }
        let value = try finite(a / b)
        guard a == 0 || value != 0 else { throw invalid("division underflow; no fallback") }; return value
    }
    private static func positive(_ x: Double) throws -> Double {
        guard x.isFinite, x > 0 else { throw invalid("positive finite state; no floor/reset") }; return x
    }
    public struct RootSolution: Encodable, Equatable {
        public let branch: String
        public let q: Double?
        public let roots: [Double]
        public let lambda: Double
    }
    /// Pure polynomial branches permit isolated synthetic boundary checks only.
    /// Production coefficients are the one frozen AppendixB expansion below.
    public static func solveMultiplier(a: Double, b: Double, c: Double, discriminant: Double) throws -> RootSolution {
        guard [a, b, c, discriminant].allSatisfy(\.isFinite), a >= 0 else { throw invalid("illegal polynomial") }
        var branch: String, roots: [Double]
        var q: Double? = nil
        if a > 0 {
            guard discriminant >= 0 else { throw invalid("negative discriminant; no rounding repair") }
            if discriminant > 0 {
                branch = "quadratic-stable-q"
                let value = try multiply(-0.5, finite(b + copysign(sqrt(discriminant), b)))
                guard value != 0 else { throw invalid("zero stable q") }; q = value
                roots = [try divide(value, a), try divide(c, value)]
            } else {
                branch = "quadratic-repeated-root"
                roots = [try divide(-b, multiply(2, a))]
            }
        } else if b != 0 {
            branch = "linear"; roots = [try divide(-c, b)]
        } else if c == 0 {
            branch = "all-zero-polynomial"; roots = []
        } else { throw invalid("inconsistent constant polynomial; no fallback") }
        var lambda = 0.0
        for root in roots where root > lambda { lambda = root }
        return .init(branch: branch, q: q, roots: roots, lambda: lambda)
    }
    public struct Projection: Encodable, Equatable {
        public let sortedOrdinals: [Int]
        public let sortedValues: [Double]
        public let prefixSums: [Double]
        public let thresholdCandidates: [Double]
        public let activeTests: [Double]
        public let rho: Int
        public let theta: Double
        public let projected: [Double]
        public let projectedDenominator: Double
        public let muNext: [Double]
    }
    public static func project(_ muRaw: [Double]) throws -> Projection {
        guard muRaw.count == 3, muRaw.allSatisfy(\.isFinite) else { throw invalid("finite three-core projection") }
        let sorted = muRaw.indices.sorted { muRaw[$0] == muRaw[$1] ? $0 < $1 : muRaw[$0] > muRaw[$1] }
        let values = sorted.map { muRaw[$0] }
        var sum = 0.0, prefixes: [Double] = [], thresholds: [Double] = [], tests: [Double] = [], rho = 0
        for offset in values.indices {
            sum = try finite(sum + values[offset]); prefixes.append(sum)
            let tau = try divide(finite(sum - 1), Double(offset + 1))
            let test = try finite(values[offset] - tau); thresholds.append(tau); tests.append(test)
            if test > 0 { rho = offset + 1 }
        }
        guard rho > 0 else { throw invalid("empty simplex active set; no fallback") }
        let theta = try divide(finite(prefixes[rho - 1] - 1), Double(rho))
        let projected = try muRaw.map { max(try finite($0 - theta), 0) }
        var denominator = 0.0
        for p in projected { denominator = try finite(denominator + p) }
        _ = try positive(denominator)
        let next = try projected.map { try divide($0, denominator) }
        return .init(sortedOrdinals: sorted, sortedValues: values, prefixSums: prefixes, thresholdCandidates: thresholds,
            activeTests: tests, rho: rho, theta: theta, projected: projected, projectedDenominator: denominator, muNext: next)
    }
    public struct ModelUpdate: Encodable, Equatable {
        public let incomingMu: [Double]
        public let incomingD: [Double]
        public let x: [Double]
        public let xSquared: [Double]
        public let M: Double
        public let S0: Double
        public let Sx: Double
        public let V: Double
        public let xbar: Double
        public let M2: Double
        public let diffs: [Double]
        public let diffSquared: [Double]
        public let D: Double
        public let K: Double
        public let delta: Double
        public let phiSquared: Double
        public let B: Double
        public let a: Double
        public let b: Double
        public let c: Double
        public let discriminant: Double
        public let branch: String
        public let q: Double?
        public let roots: [Double]
        public let lambda: Double
        public let T: Double
        public let sqrtU: Double
        public let coef: Double
        public let meanSteps: [Double]
        public let muRaw: [Double]
        public let shrink: [Double]
        public let dRaw: [Double]
        public let sortedOrdinals: [Int]
        public let sortedValues: [Double]
        public let prefixSums: [Double]
        public let thresholdCandidates: [Double]
        public let activeTests: [Double]
        public let rho: Int
        public let theta: Double
        public let projected: [Double]
        public let projectedDenominator: Double
        public let muNext: [Double]
        public let traceRaw: Double
        public let traceDenominator: Double
        public let dNext: [Double]
    }
    public static func update(mu: [Double], d: [Double], x: [Double]) throws -> ModelUpdate {
        guard mu.count == 3, d.count == 3, x.count == 3,
              mu.allSatisfy({ $0.isFinite && $0 >= 0 }), mu.contains(where: { $0 > 0 }),
              d.allSatisfy({ $0.isFinite && $0 > 0 }), x.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw invalid("incoming three-core model state") }
        var M = 0.0, S0 = 0.0, Sx = 0.0, V = 0.0, xSquared: [Double] = []
        for i in 0..<3 {
            let square = try multiply(x[i], x[i]); xSquared.append(square)
            M = try finite(M + multiply(mu[i], x[i])); S0 = try finite(S0 + d[i])
            Sx = try finite(Sx + multiply(d[i], x[i])); V = try finite(V + multiply(d[i], square))
        }
        _ = try positive(M); _ = try positive(S0); _ = try positive(Sx); _ = try positive(V)
        let xbar = try positive(divide(Sx, S0)), M2 = try positive(multiply(M, M))
        var diffs: [Double] = [], diffSquared: [Double] = [], D = 0.0
        for i in 0..<3 {
            let diff = try finite(x[i] - xbar), square = try multiply(diff, diff)
            diffs.append(diff); diffSquared.append(square); D = try finite(D + multiply(d[i], square))
        }
        let K = try divide(D, M2), phiSquared = try multiply(phi, phi)
        let delta = try finite(epsilon - log(M)), deltaSquared = try multiply(delta, delta)
        let vPhi = try multiply(V, phiSquared), B = try divide(vPhi, 2)
        let a = try finite(multiply(K, K) + multiply(vPhi, K))
        let b = try multiply(multiply(2, delta), finite(K + B))
        let c = try finite(deltaSquared - vPhi)
        let discriminant = try finite(multiply(multiply(4, deltaSquared), multiply(B, B)) + multiply(multiply(4, a), vPhi))
        let root = try solveMultiplier(a: a, b: b, c: c, discriminant: discriminant)
        let T = try multiply(multiply(root.lambda, phi), V)
        let radical = sqrt(try positive(finite(multiply(T, T) + multiply(4, V))))
        let sqrtU = try positive(divide(multiply(2, V), positive(finite(radical + T))))
        let coef = try divide(multiply(phi, root.lambda), sqrtU)
        var steps: [Double] = [], rawMu: [Double] = [], shrinks: [Double] = [], rawD: [Double] = []
        for i in 0..<3 {
            let step = try divide(multiply(multiply(root.lambda, d[i]), diffs[i]), M)
            let shrink = try multiply(multiply(d[i], coef), xSquared[i])
            steps.append(step); rawMu.append(try finite(mu[i] - step)); shrinks.append(shrink)
            rawD.append(try positive(divide(d[i], positive(finite(1 + shrink)))))
        }
        let p = try project(rawMu)
        var trace = 0.0
        for value in rawD { trace = try finite(trace + value) }
        let traceDenominator = try positive(multiply(9, positive(trace)))
        let nextD = try rawD.map { try positive(divide($0, traceDenominator)) }
        return .init(incomingMu: mu, incomingD: d, x: x, xSquared: xSquared, M: M, S0: S0, Sx: Sx, V: V,
            xbar: xbar, M2: M2, diffs: diffs, diffSquared: diffSquared, D: D, K: K, delta: delta,
            phiSquared: phiSquared, B: B, a: a, b: b, c: c, discriminant: discriminant,
            branch: root.branch, q: root.q, roots: root.roots, lambda: root.lambda, T: T, sqrtU: sqrtU, coef: coef,
            meanSteps: steps, muRaw: rawMu, shrink: shrinks, dRaw: rawD,
            sortedOrdinals: p.sortedOrdinals, sortedValues: p.sortedValues, prefixSums: p.prefixSums,
            thresholdCandidates: p.thresholdCandidates, activeTests: p.activeTests, rho: p.rho, theta: p.theta,
            projected: p.projected, projectedDenominator: p.projectedDenominator, muNext: p.muNext,
            traceRaw: trace, traceDenominator: traceDenominator, dNext: nextD)
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
        public let update: ModelUpdate?
        public let muNext: [Double]
        public let dNext: [Double]
        public let roles: [RoleDiagnostic]
        public let rawTarget: [String: Double]
        public let cleanedTarget: [String: Double]
    }
    public static func signals(frame: MarketDataFrame) throws -> [Signal] {
        guard !frame.dates.isEmpty, coreSymbols.allSatisfy({ symbol in
            guard let prices = frame.pricesBySymbol[symbol], prices.count == frame.dates.count else { return false }
            return prices.allSatisfy { $0.isFinite && $0 > 0 }
        }) else { throw invalid("positive aligned canonical CNY frame") }
        var mu = Array(repeating: 1.0 / 3, count: 3), d = Array(repeating: 1.0 / 9, count: 3)
        return try frame.dates.indices.map { s in
            var model: ModelUpdate?
            if s >= 1 {
                let x = try coreSymbols.map { try positive(divide(frame.pricesBySymbol[$0]![s], frame.pricesBySymbol[$0]![s - 1])) }
                model = try update(mu: mu, d: d, x: x); mu = model!.muNext; d = model!.dNext
            }
            let raw = Dictionary(uniqueKeysWithValues: coreSymbols.indices.map { (coreSymbols[$0], mu[$0]) })
            let clean = providerClean(raw)
            let roles = coreSymbols.indices.map { RoleDiagnostic(symbol: coreSymbols[$0], rawWeight: mu[$0], cleanedWeight: clean[coreSymbols[$0]] ?? 0) }
            return .init(signalIndex: s, date: frame.dates[s], intervalCount: s,
                reason: s == 0 ? "baseline-explicit-equal-prior" : "sequential-CWMR-Stdev-trace",
                update: model, muNext: mu, dNext: d, roles: roles, rawTarget: raw, cleanedTarget: clean)
        }
    }
    public static func runAccount(preparation: NativePreparation, signals: [Signal], role: Role) throws -> NativeRun {
        guard signals.count == preparation.frame.dates.count,
              signals.enumerated().allSatisfy({ $0.offset == $0.element.signalIndex && $0.element.date == preparation.frame.dates[$0.offset] }) else {
            throw BacktestConfigurationError.invalidParameter("CWMR-Stdev exact funded signal alignment")
        }
        return try simulate(preparation: preparation,
            buyReason: role == .candidate ? "fixed CWMR-Stdev core close research" : "fixed CWMR daily core close control") { context in
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
        guard frame.simulationRange.lowerBound == 0 else { throw BacktestConfigurationError.invalidParameter("CWMR-Stdev full funded baseline") }
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
            throw BacktestConfigurationError.invalidParameter("CWMR-Stdev unchanged cash baseline/full formation history")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].acceptedAfter = run.dailyStates[i].targetWeights
            let desired = decisions[i].requestedTarget ?? expected[i]
            if decisions[i].acceptedAfter != desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("CWMR-Stdev target adapter delivery") }
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
            throw BacktestConfigurationError.invalidParameter("CWMR-Stdev frozen canonical source and 31 saved controls")
        }
        func date(_ day: String) throws -> Date {
            guard let d = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { throw BacktestConfigurationError.invalidParameter("CWMR-Stdev source session date") }
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
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BacktestConfigurationError.invalidParameter("CWMR-Stdev saved raw hash/rows") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }), !selectedIDs.contains(id) else {
                    throw BacktestConfigurationError.invalidParameter("CWMR-Stdev saved identity/state order")
                }
                selectedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("CWMR-Stdev one candidate / 3 fresh / 31 saved") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("CWMR-Stdev complete mechanical comparison calendar") }
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
            throw BacktestConfigurationError.invalidParameter("CWMR-Stdev no comparison-day deletion")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        var signalObjects = try JSONSerialization.jsonObject(with: encoder.encode(signalEvidence)) as! [[String: Any]]
        for i in signalObjects.indices {
            if let model = signalObjects[i].removeValue(forKey: "update") as? [String: Any] {
                for (key, value) in model { signalObjects[i][key] = value }
            }
            for key in ["incomingMu", "incomingD", "x", "xSquared", "M", "S0", "Sx", "V", "xbar", "M2", "diffs", "diffSquared", "D", "K", "delta", "phiSquared", "B", "a", "b", "c", "discriminant", "branch", "q", "roots", "lambda", "T", "sqrtU", "coef", "meanSteps", "muRaw", "shrink", "dRaw", "sortedOrdinals", "sortedValues", "prefixSums", "thresholdCandidates", "activeTests", "rho", "theta", "projected", "projectedDenominator", "traceRaw", "traceDenominator"] where signalObjects[i][key] == nil { signalObjects[i][key] = NSNull() }
        }
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
            "evidence_class": "POST_HOC_RELATED_D0_DETERMINISTIC_CWMR_STDEV_TRACE_THREE_CORE_NUMERICAL_AND_NEXT_CLOSE_EXECUTION_ADAPTATION", "formal_validation": false, "recommendation_eligible": false,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "pre_specification_sha256": "6831b2ebca7bbf1b8128201722e2298e2f37b317d6d72ca0b01a58d6c07fb32d",
            "original_definition": "LiHoi2011_deterministic_CWMR_Stdev_Algorithm1_trace",
            "primary_original_pdf_sha256": "4eeb62839dd942f2a675868def56d78b918d8b1b5b4cbce8e39103a837b865d5",
            "source_proposal_sha256": "25e023cbe9e368ed4ecbafb36be71db92d0c922681227b9468e1849240d7d981",
            "signal_schema": "fixed-cwmr-stdev-core-signal-v1", "phi": phi, "epsilon": epsilon,
            "model_policy": "Price-only sequential mu/strictly positive diagonal confidence; factors not returns; delta=-0.5-logM; phi2; centeredD/stableexpandedAppendixB; deterministic simplex projection and unconditional trace; no state reset/account feedback",
            "solver_policy": "Exact frozen scalar order; stableq roots/linear/allzero/constant rejection; positive support/product/division underflow fail; ordinal stable descending projection/rho>0; zeroslegal/no tinyfilter; fixedordinal postprojection sum normalize",
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
            "dual_clock_limitation": "Paper immediate-period ideal wealth differs from root nofinancing single-account canonical next-close/strictpriorFX/cost/settlement. Raw price-only confidence model is separate from genuine actual NAV. No source Sharpe guarantee.",
            "units_policy": "accounting unitsBySymbol derived from genuine shared state holding value divided by canonical mark; ordered fills allow independent units reconstruction",
            "limitations": ["Price proxies; no directly executable securities/closing-auction, publication-vintage, futures-roll or total-return certification.",
                "Root deterministic CWMR-Stdev trace/scalar/degenerate/projection and three-coreCNY daily next-close adaptation; related OLMAR exposure/census UNKNOWN; no author code/empirical parity, exact nonlinear optimizer, pristine OOS or formal promotion.",
                "No dividends/tax/USD wallet/FX spreads; 31 prior native whole objects preserved with original limitations; short calendar supplemental only."]]
        outputs["evidence.json"] = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in outputs.keys.sorted() { try outputs[name]!.write(to: output.appendingPathComponent(name)) }
        print("Fixed CWMR-Stdev core: 1 candidate, 3 fresh accounts, 31 saved controls; native6452/long5595/short3086 dates.")
    }
}
