import Foundation
import AssetTimeMachineBacktestCore

/// Root-frozen, source-inspired long-only MDP. Monthly price-only covariance
/// targets feed a single unchanged shared account; no synthetic asset financing.
public enum MaximumDiversificationCoreScreen {
    public static let coreSymbols = RiskParityCoreScreen.coreSymbols
    public static let candidateID = "mdp250-three-core-monthend-close"
    public static let equalID = "equal-core100-mdp-monthend-close-control"
    public static let cashID = "cny-cash-mdp-native2001"
    public static let qualID = ChaikinMoneyFlowScreen.qualID
    public static var savedControlIDs: [String] { ChaikinMoneyFlowScreen.savedControlIDs }
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
    private static func invalid(_ reason: String) -> BacktestConfigurationError { .invalidParameter("MDP250 " + reason) }
    private static func divide(_ numerator: Double, _ denominator: Double) throws -> Double {
        guard numerator.isFinite, denominator.isFinite, denominator > 0 else { throw invalid("finite positive divisor") }
        let result = numerator / denominator
        guard result.isFinite, numerator == 0 || result != 0 else { throw invalid("division nonfinite/underflow; no fallback") }
        return result
    }
    /// Generic dimensions1...3 only permit independent paper toy tests; the one
    /// production rule always uses all three fixed core assets.
    public static func cholesky(_ matrix: [[Double]]) throws -> [[Double]] {
        let n = matrix.count
        guard (1...3).contains(n), matrix.allSatisfy({ $0.count == n && $0.allSatisfy(\.isFinite) }),
              (0..<n).allSatisfy({ i in (0..<n).allSatisfy { matrix[i][$0] == matrix[$0][i] } }) else { throw invalid("finite symmetric matrix") }
        var lower = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var residual = matrix[i][j]
                for k in 0..<j { residual -= lower[i][k] * lower[j][k] }
                guard residual.isFinite else { throw invalid("finite Cholesky residual") }
                if i == j {
                    guard residual > 0 else { throw invalid("strict SPD; no ridge/floor") }
                    lower[i][j] = sqrt(residual)
                    guard lower[i][j].isFinite, lower[i][j] > 0 else { throw invalid("positive finite Cholesky diagonal") }
                } else { lower[i][j] = try divide(residual, lower[j][j]) }
            }
        }
        return lower
    }
    public struct Face: Encodable, Equatable {
        public let mask: Int
        public let activeIndices: [Int]
        public let cholesky: [[Double]]
        public let forward: [Double]
        public let z: [Double]
        public let sumZ: Double
        public let feasible: Bool
        public let status: String
        public let s: [Double]?
        public let q: Double?
    }
    public struct Optimization: Equatable {
        public let covarianceCholesky: [[Double]]
        public let sigma: [Double]
        public let correlation: [[Double]]
        public let correlationCholesky: [[Double]]
        public let faces: [Face]
        public let winningMask: Int
        public let winningS: [Double]
        public let winningQ: Double
        public let inverseVolMapped: [Double]
        public let weightDenominator: Double
        public let weights: [Double]
    }
    public static func optimize(covariance: [[Double]]) throws -> Optimization {
        let vLower = try cholesky(covariance), n = covariance.count
        let sigma = (0..<n).map { sqrt(covariance[$0][$0]) }
        guard sigma.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw invalid("positive finite asset volatility") }
        var correlation = covariance
        for i in 0..<n { for j in 0..<n { correlation[i][j] = try divide(covariance[i][j], sigma[i] * sigma[j]) } }
        let cLower = try cholesky(correlation)
        var faces: [Face] = [], bestQ = Double.infinity, bestMask = 0, bestS: [Double] = []
        for mask in 1..<(1 << n) {
            let active = (0..<n).filter { mask & (1 << $0) != 0 }
            let block = active.map { i in active.map { correlation[i][$0] } }
            let lower = try cholesky(block), count = active.count
            var y = Array(repeating: 0.0, count: count), z = y
            for i in 0..<count {
                var residual = 1.0
                for j in 0..<i { residual -= lower[i][j] * y[j] }
                y[i] = try divide(residual, lower[i][i])
            }
            for i in stride(from: count - 1, through: 0, by: -1) {
                var residual = y[i]
                if i + 1 < count { for j in (i + 1)..<count { residual -= lower[j][i] * z[j] } }
                z[i] = try divide(residual, lower[i][i])
            }
            let sumZ = z.reduce(0.0, +)
            guard sumZ.isFinite, sumZ > 0 else { throw invalid("positive finite stationary sum") }
            guard !z.contains(where: { $0 < 0 }) else {
                faces.append(.init(mask: mask, activeIndices: active, cholesky: lower, forward: y, z: z, sumZ: sumZ,
                    feasible: false, status: "negative-stationary-face-skipped", s: nil, q: nil))
                continue
            }
            var s = Array(repeating: 0.0, count: n)
            for i in active.indices { s[active[i]] = try divide(z[i], sumZ) }
            var q = 0.0
            for i in 0..<n { for j in 0..<n { q += s[i] * s[j] * correlation[i][j] } }
            guard q.isFinite, q > 0 else { throw invalid("positive finite face risk") }
            faces.append(.init(mask: mask, activeIndices: active, cholesky: lower, forward: y, z: z, sumZ: sumZ,
                feasible: true, status: "feasible-stationary-face", s: s, q: q))
            if q < bestQ { bestQ = q; bestMask = mask; bestS = s }
        }
        guard bestMask > 0 else { throw invalid("no feasible face; no fallback") }
        let u = try (0..<n).map { try divide(bestS[$0], sigma[$0]) }
        let denominator = u.reduce(0.0, +)
        let weights = try u.map { try divide($0, denominator) }
        return .init(covarianceCholesky: vLower, sigma: sigma, correlation: correlation, correlationCholesky: cLower,
            faces: faces, winningMask: bestMask, winningS: bestS, winningQ: bestQ,
            inverseVolMapped: u, weightDenominator: denominator, weights: weights)
    }
    public static func monthChanged(_ previous: Date, _ current: Date) -> Bool {
        let calendar = BacktestSeriesAlignment.historicalSeriesCalendar
        let a = calendar.dateComponents([.year, .month], from: previous)
        let b = calendar.dateComponents([.year, .month], from: current)
        return a.year != b.year || a.month != b.month
    }
    public struct Signal: Encodable, Equatable {
        public let signalIndex: Int
        public let date: Date
        public let isMonthlyReview: Bool
        public let evaluationIndex: Int?
        public let evaluationDate: Date?
        public let reason: String
        public let priceStartIndex: Int?
        public let returnStartIndex: Int?
        public let returns: [[Double]]
        public let means: [Double]?
        public let covarianceSums: [[Double]]?
        public let covariance: [[Double]]?
        public let covarianceCholesky: [[Double]]?
        public let sigma: [Double]?
        public let correlation: [[Double]]?
        public let correlationCholesky: [[Double]]?
        public let faces: [Face]
        public let winningMask: Int?
        public let winningS: [Double]?
        public let winningQ: Double?
        public let inverseVolMapped: [Double]?
        public let weightDenominator: Double?
        public let rawTarget: [String: Double]
        public let cleanedTarget: [String: Double]
    }
    public static func signals(frame: MarketDataFrame) throws -> [Signal] {
        guard !frame.dates.isEmpty, coreSymbols.allSatisfy({ symbol in
            guard let p = frame.pricesBySymbol[symbol], p.count == frame.dates.count else { return false }
            return p.allSatisfy { $0.isFinite && $0 > 0 }
        }) else { throw invalid("positive aligned canonical CNY prices") }
        return try frame.dates.indices.map { s in
            let review = s + 1 < frame.dates.count && monthChanged(frame.dates[s], frame.dates[s + 1])
            guard review, s >= 250 else {
                return .init(signalIndex: s, date: frame.dates[s], isMonthlyReview: review,
                    evaluationIndex: review ? s + 1 : nil, evaluationDate: review ? frame.dates[s + 1] : nil,
                    reason: review ? "formation-cash" : "not-month-end-review", priceStartIndex: nil, returnStartIndex: nil,
                    returns: [], means: nil, covarianceSums: nil, covariance: nil, covarianceCholesky: nil,
                    sigma: nil, correlation: nil, correlationCholesky: nil, faces: [], winningMask: nil,
                    winningS: nil, winningQ: nil, inverseVolMapped: nil, weightDenominator: nil, rawTarget: [:], cleanedTarget: [:])
            }
            let returns = coreSymbols.map { symbol in ((s - 249)...s).map { frame.pricesBySymbol[symbol]![$0] / frame.pricesBySymbol[symbol]![$0 - 1] - 1 } }
            guard returns.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { throw invalid("finite simple250 returns") }
            let means = try returns.map { try divide($0.reduce(0.0, +), 250) }
            var sums = Array(repeating: Array(repeating: 0.0, count: 3), count: 3), covariance = sums
            for i in 0..<3 { for j in 0..<3 {
                var sum = 0.0
                for cursor in 0..<250 { sum += (returns[i][cursor] - means[i]) * (returns[j][cursor] - means[j]) }
                guard sum.isFinite else { throw invalid("finite centered covariance sum") }
                sums[i][j] = sum; covariance[i][j] = try divide(sum, 249)
            } }
            let o = try optimize(covariance: covariance)
            let raw = Dictionary(uniqueKeysWithValues: coreSymbols.indices.map { (coreSymbols[$0], o.weights[$0]) })
            return .init(signalIndex: s, date: frame.dates[s], isMonthlyReview: true, evaluationIndex: s + 1,
                evaluationDate: frame.dates[s + 1], reason: "formed250-strictSPD-MDP", priceStartIndex: s - 250,
                returnStartIndex: s - 249, returns: returns, means: means, covarianceSums: sums, covariance: covariance,
                covarianceCholesky: o.covarianceCholesky, sigma: o.sigma, correlation: o.correlation,
                correlationCholesky: o.correlationCholesky, faces: o.faces, winningMask: o.winningMask,
                winningS: o.winningS, winningQ: o.winningQ, inverseVolMapped: o.inverseVolMapped,
                weightDenominator: o.weightDenominator, rawTarget: raw, cleanedTarget: providerClean(raw))
        }
    }
    public struct Decision: Encodable, Equatable {
        public let index: Int
        public let date: Date
        public let signalIndex: Int
        public let signalDate: Date
        public let scheduledReview: Bool
        public let transportOnly: Bool
        public let shouldRebalance: Bool
        public var providerCalled: Bool
        public let lastDidExecuteBefore: Int
        public var lastDidExecuteAfter: Int
        public let reviewAgeBefore: Int
        public let latestMonthlySignalIndexBefore: Int?
        public let latestMonthlySignalIndexAfter: Int?
        public let deliverySignalIndex: Int?
        public let deliverySignalDate: Date?
        public let retainedTargetBefore: [String: Double]
        public var requestedTarget: [String: Double]?
        public var acceptedAfter: [String: Double]
        public let pendingBefore: [String: Double]?
        public var pendingAfter: [String: Double]?
        public var completedToday: Bool
    }
    public struct NativeRun {
        public let simulation: BacktestDailySimulationResult
        public let decisions: [Decision]
        public let completions: [Completion]
        public let targetMismatchCount: Int
    }
    public static func runAccount(preparation: NativePreparation, signals: [Signal], role: Role) throws -> NativeRun {
        guard signals.count == preparation.frame.dates.count,
              signals.enumerated().allSatisfy({ $0.offset == $0.element.signalIndex && $0.element.date == preparation.frame.dates[$0.offset] }) else { throw invalid("funded signal alignment") }
        return try simulate(preparation: preparation, buyReason: role == .candidate ? "fixed MDP250 core close research" : "fixed MDP monthend core close control") { signal in
            switch role {
            case .candidate: return signals[signal].cleanedTarget
            case .equal: return signal >= 250 ? Dictionary(uniqueKeysWithValues: coreSymbols.map { ($0, 1.0 / 3) }) : [:]
            case .cash: return [:]
            }
        }
    }
    /// This internal adapter is also exercised with synthetic target fixtures.
    /// Production callers use only the fixed role switch above.
    static func simulate(preparation: NativePreparation, buyReason: String,
                         target: @escaping (Int) -> [String: Double]) throws -> NativeRun {
        let frame = preparation.frame
        guard frame.simulationRange.lowerBound == 0 else { throw BacktestConfigurationError.invalidParameter("MDP250 full funded baseline") }
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, tradeToBandBoundary: false, financingAnnualRate: 0,
            allowsFinancedExposure: false, buyReason: buyReason)
        var latestMonthlySignal: Int?
        var lastDidExecute = Int.min / 2, retained: [String: Double] = [:], pending: [String: Double]?
        var decisions: [Decision] = [], completions: [Completion] = [], expected: [[String: Double]] = []
        guard let run = BacktestDailySimulator.run(frame: frame, execution: execution,
            provider: .init { context in
                let weights = providerClean(target(latestMonthlySignal!))
                retained = weights; pending = weights
                decisions[decisions.count - 1].providerCalled = true
                decisions[decisions.count - 1].requestedTarget = weights
                decisions[decisions.count - 1].pendingAfter = weights
                return weights
            }, rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
            contextualRebalanceDecision: { c in
                let age = c.index - lastDidExecute
                let before = latestMonthlySignal
                let scheduled = c.index >= 1 && monthChanged(frame.dates[c.index - 1], c.date)
                if scheduled { latestMonthlySignal = c.signalIndex }
                let transport = !scheduled && pending != nil
                let due = scheduled || transport
                decisions.append(.init(index: c.index, date: c.date, signalIndex: c.signalIndex, signalDate: c.signalDate,
                    scheduledReview: scheduled, transportOnly: transport, shouldRebalance: due, providerCalled: false, lastDidExecuteBefore: lastDidExecute,
                    lastDidExecuteAfter: lastDidExecute, reviewAgeBefore: age, latestMonthlySignalIndexBefore: before, latestMonthlySignalIndexAfter: latestMonthlySignal,
                    deliverySignalIndex: due ? latestMonthlySignal : nil, deliverySignalDate: due ? latestMonthlySignal.map { frame.dates[$0] } : nil, retainedTargetBefore: retained,
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
            throw BacktestConfigurationError.invalidParameter("MDP250 unchanged cash baseline/full formation history")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].acceptedAfter = run.dailyStates[i].targetWeights
            let desired = decisions[i].requestedTarget ?? expected[i]
            if decisions[i].acceptedAfter != desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("MDP250 target adapter delivery") }
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
            throw BacktestConfigurationError.invalidParameter("MDP250 frozen canonical source and 31 saved controls")
        }
        func date(_ day: String) throws -> Date {
            guard let d = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { throw BacktestConfigurationError.invalidParameter("MDP250 source session date") }
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
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BacktestConfigurationError.invalidParameter("MDP250 saved raw hash/rows") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }), !selectedIDs.contains(id) else {
                    throw BacktestConfigurationError.invalidParameter("MDP250 saved identity/state order")
                }
                selectedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("MDP250 one candidate / 3 fresh / 31 saved") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("MDP250 complete mechanical comparison calendar") }
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
            throw BacktestConfigurationError.invalidParameter("MDP250 no comparison-day deletion")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        var signalObjects = try JSONSerialization.jsonObject(with: encoder.encode(signalEvidence)) as! [[String: Any]]
        for i in signalObjects.indices {
            for key in ["evaluationIndex", "evaluationDate", "priceStartIndex", "returnStartIndex", "means", "covarianceSums", "covariance", "covarianceCholesky", "sigma", "correlation", "correlationCholesky", "winningMask", "winningS", "winningQ", "inverseVolMapped", "weightDenominator"] where signalObjects[i][key] == nil { signalObjects[i][key] = NSNull() }
            var faces = signalObjects[i]["faces"] as! [[String: Any]]
            for j in faces.indices { for key in ["s", "q"] where faces[j][key] == nil { faces[j][key] = NSNull() } }
            signalObjects[i]["faces"] = faces
        }
        var quoteObjects = try JSONSerialization.jsonObject(with: encoder.encode(preparation.quotes)) as! [[String: Any]]
        for i in quoteObjects.indices { for key in ["fxDate", "usdPerCNY", "cnyPerUSD", "fxAgeDays"] where quoteObjects[i][key] == nil { quoteObjects[i][key] = NSNull() } }
        var decisionObjects = try JSONSerialization.jsonObject(with: encoder.encode(decisions)) as! [String: [[String: Any]]]
        for id in decisionObjects.keys { for i in decisionObjects[id]!.indices {
            for key in ["requestedTarget", "pendingBefore", "pendingAfter", "latestMonthlySignalIndexBefore", "latestMonthlySignalIndexAfter", "deliverySignalIndex", "deliverySignalDate"] where decisionObjects[id]![i][key] == nil { decisionObjects[id]![i][key] = NSNull() }
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
            "evidence_class": "POST_HOC_RELATED_D0_THEORETICAL_LONG_ONLY_MDP_DOMAIN_ESTIMATOR_SOLVER_AND_EXECUTION_ADAPTATION", "formal_validation": false, "recommendation_eligible": false,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "pre_specification_sha256": "1f24ce0ef527cf4c681253e36833a745909a1c5148397c081dcfd06055788c71",
            "original_definition": "ChoueifatyCoignard2008_theoretical_diversification_ratio_root_simplex",
            "primary_original_pdf_sha256": "1fe630990608fa02cdadfdb9080e5889ede62fdec1a50b5cd2d509d5c02aa528",
            "source_proposal_sha256": "5171efe58d3dec552396f375400f7e8af78b4ef8056ab38b64edcf2de9e1baf4",
            "signal_schema": "fixed-mdp250-core-signal-v1", "face_count": 7,
            "covariance_policy": "Monthly review only;250 chronological simple funded returns/mean250/sample249; V and C strict no-pivot SPD; no log/annualization/ridge/floor",
            "solver_policy": "Masks1...7 bit0gold/bit1Nas/bit2SP; fixedcore Cholesky forward/back; negative stationary face skip; nine ordered q terms; strict<firstfloat tie; support-preserving inversevol map; nonfinite/underflow fail",
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
            "cadence_policy": "initial sentinel Int.min/2; monthchange scheduledmaintenance latest completed prior-month signal;250 cashformation; daily onlypending transports same latestmonthlytarget; completed intra-month no maintenance; partialcutoff notmonthend; band0/gross1",
            "ideal_book_actual_NAV_identity_claimed": false, "old_RP_GMV_Cover_control_parity_claimed": false,
            "dual_clock_limitation": "Paper theoretical diversification criterion is a price-only target; original empirical stock restrictions/returns/execution differ from root nofinancing single-account canonical next-close/strictpriorFX/cost/settlement. No source Sharpe guarantee.",
            "units_policy": "accounting unitsBySymbol derived from genuine shared state holding value divided by canonical mark; ordered fills allow independent units reconstruction",
            "limitations": ["Price proxies; no directly executable securities/closing-auction, publication-vintage, futures-roll or total-return certification.",
                "Root theoretical long-only domain/estimator/solver/month-end adaptation; source/history exposed, census UNKNOWN; no author implementation or stock empirical parity, finite precision global certificate, pristine OOS or formal promotion.",
                "No dividends/tax/USD wallet/FX spreads; 31 prior native whole objects preserved with original limitations; short calendar supplemental only."]]
        outputs["evidence.json"] = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in outputs.keys.sorted() { try outputs[name]!.write(to: output.appendingPathComponent(name)) }
        print("Fixed MDP250 core: 1 candidate, 3 fresh accounts, 31 saved controls; native6452/long5595/short3086 dates.")
    }
}
