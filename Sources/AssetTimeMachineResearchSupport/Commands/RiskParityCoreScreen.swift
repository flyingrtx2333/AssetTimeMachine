import Foundation
import AssetTimeMachineBacktestCore

/// Frozen related D0 three-core inverse-volatility rule. Canonical source-close
/// prices drive signals, execution and valuation; independent OHLC is not used.
public enum RiskParityCoreScreen {
    public static let coreSymbols = ["gold_cny", "nasdaq", "sp500"]
    public static let candidateID = "rp63-three-core-close"
    public static let equalID = "equal-core95-close-control"
    public static let cashID = "cny-cash-rp63-native2001"
    public static let qualID = ChaikinMoneyFlowScreen.qualID
    public static var savedControlIDs: [String] { ChaikinMoneyFlowScreen.savedControlIDs }

    public struct PriceBar: Equatable {
        public let date: Date
        public let price: Double
        public init(date: Date, price: Double) { self.date = date; self.price = price }
    }
    public struct FXPoint: Equatable {
        public let date: Date
        public let usdPerCNY: Double
        public init(date: Date, usdPerCNY: Double) { self.date = date; self.usdPerCNY = usdPerCNY }
    }
    public struct Quote: Encodable, Equatable {
        public let symbol: String
        public let index: Int
        public let date: Date
        public let sourceDate: Date
        public let quoteToday: Bool
        public let originalCanonicalPrice: Double
        public let fxDate: Date?
        public let usdPerCNY: Double?
        public let cnyPerUSD: Double?
        public let fxAgeDays: Int?
        public let cnyClose: Double
        public let executionPrice: Double
        public let quoteAgeDays: Int
    }
    public struct NativePreparation {
        public let frame: MarketDataFrame
        public let executionPrices: [String: [Double]]
        public let quotes: [Quote]
    }

    /// Conversion is performed once on the actual quote date. A carried CNY mark
    /// never picks a newer FX fixing and is never an executable observation.
    public static func nativePreparation(barsBySymbol: [String: [PriceBar]], fxPoints: [FXPoint], fundedDates: [Date]) throws -> NativePreparation {
        func ordered(_ dates: [Date]) -> Bool {
            !dates.isEmpty && dates.allSatisfy { $0.timeIntervalSinceReferenceDate.isFinite }
                && zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 }
        }
        guard ordered(fundedDates), ordered(fxPoints.map(\.date)),
              fxPoints.allSatisfy({ $0.usdPerCNY.isFinite && $0.usdPerCNY > 0 }),
              coreSymbols.allSatisfy({ symbol in
                  guard let bars = barsBySymbol[symbol] else { return false }
                  return ordered(bars.map(\.date)) && bars.allSatisfy { $0.price.isFinite && $0.price > 0 }
              }) else { throw BacktestConfigurationError.invalidParameter("RP63 ordered positive canonical source/FX/funded calendar") }
        var prices: [String: [Double]] = [:], observed: [String: [Bool]] = [:]
        var executionPrices: [String: [Double]] = [:], quotes: [Quote] = []
        let calendar = BacktestSeriesAlignment.historicalSeriesCalendar
        for symbol in coreSymbols {
            let bars = barsBySymbol[symbol]!
            var next = 0, priorSource: Date?, close = 0.0
            var fixing: FXPoint?, fixingAge: Int?
            var marks: [Double] = [], executable: [Double] = [], observations: [Bool] = []
            for (index, date) in fundedDates.enumerated() {
                while next < bars.count && bars[next].date <= date { next += 1 }
                guard next > 0 else { throw BacktestConfigurationError.missingData("RP63 no pre-source synthetic holding: \(symbol)") }
                let bar = bars[next - 1]
                if priorSource != bar.date {
                    fixing = nil; fixingAge = nil
                    if symbol == "gold_cny" { close = bar.price }
                    else {
                        var low = 0, high = fxPoints.count
                        while low < high {
                            let mid = (low + high) / 2
                            if fxPoints[mid].date < bar.date { low = mid + 1 } else { high = mid }
                        }
                        guard low > 0 else { throw BacktestConfigurationError.missingData("RP63 strictly prior quote-date FX") }
                        let fx = fxPoints[low - 1]
                        let age = calendar.dateComponents([.day], from: fx.date, to: bar.date).day ?? Int.max
                        guard age > 0, age <= 14 else { throw BacktestConfigurationError.missingData("RP63 strictly prior FX within14 calendar days") }
                        fixing = fx; fixingAge = age
                        close = bar.price / fx.usdPerCNY
                    }
                    guard close.isFinite, close > 0 else { throw BacktestConfigurationError.invalidParameter("RP63 finite CNY canonical close") }
                    priorSource = bar.date
                }
                let today = bar.date == date, auction = today ? close : 0
                marks.append(close); executable.append(auction); observations.append(today)
                quotes.append(.init(symbol: symbol, index: index, date: date, sourceDate: bar.date,
                    quoteToday: today, originalCanonicalPrice: bar.price, fxDate: fixing?.date,
                    usdPerCNY: fixing?.usdPerCNY, cnyPerUSD: fixing.map { 1 / $0.usdPerCNY },
                    fxAgeDays: fixingAge, cnyClose: close, executionPrice: auction,
                    quoteAgeDays: calendar.dateComponents([.day], from: bar.date, to: date).day ?? 0))
            }
            prices[symbol] = marks; observed[symbol] = observations; executionPrices[symbol] = executable
        }
        let options = Dictionary(uniqueKeysWithValues: coreSymbols.map {
            ($0, BacktestInstrument(symbol: $0, title: $0, requiresHistoricalFX: false,
                historicalFXSymbol: nil, currency: "CNY", unit: $0 == "gold_cny" ? "gram" : "index-point"))
        })
        let frame = MarketDataFrame(dates: fundedDates, pricesBySymbol: prices, observedBySymbol: observed,
            ohlcBySymbol: [:], tradableSymbols: coreSymbols, optionBySymbol: options,
            simulationRange: 0...(fundedDates.count - 1))
        return .init(frame: frame, executionPrices: executionPrices, quotes: quotes)
    }

    public struct RoleDiagnostic: Encodable, Equatable {
        public let symbol: String
        public let returnCount: Int
        public let mean: Double?
        public let sumSquares: Double?
        public let sampleVariance: Double?
        public let annualVol: Double?
        public let score: Double?
        public var rawWeight: Double?
        public var cleanedWeight: Double
        public let reason: String
    }
    public struct Signal: Encodable, Equatable {
        public let signalIndex: Int
        public let date: Date
        public let priceStartIndex: Int?
        public let returnStartIndex: Int?
        public let windowEndIndex: Int?
        public let denominator: Double
        public let roles: [RoleDiagnostic]
        public let rawTarget: [String: Double]
        public let cappedTarget: [String: Double]
        public let cleanedTarget: [String: Double]
    }
    /// Original zoo's >1e-6 filter and cap; provider cleaning follows separately.
    public static func capped(_ weights: [String: Double]) -> [String: Double] {
        var kept = weights.filter { $0.value > 1e-6 }
        let sum = kept.keys.sorted().reduce(0.0) { $0 + kept[$1]! }
        if sum > 1 { kept = kept.mapValues { $0 / sum } }
        return kept
    }
    /// Equivalent to shared generic target-provider finite-positive/allowed clean.
    public static func providerClean(_ weights: [String: Double]) -> [String: Double] {
        let allowed = Set(coreSymbols)
        var clean: [String: Double] = [:]
        for symbol in weights.keys.sorted() where allowed.contains(symbol) {
            let weight = weights[symbol]!
            if weight.isFinite && weight > 0 { clean[symbol, default: 0] += weight }
        }
        let gross = clean.keys.sorted().reduce(0.0) { $0 + max(clean[$1]!, 0) }
        guard gross > 0 else { return [:] }
        if gross > 1 { return clean.mapValues { $0 * 1 / gross } }
        return clean
    }
    public static func signals(frame: MarketDataFrame) throws -> [Signal] {
        guard coreSymbols.allSatisfy({ symbol in
            guard let p = frame.pricesBySymbol[symbol], p.count == frame.dates.count else { return false }
            return p.allSatisfy { $0.isFinite && $0 > 0 }
        }) else { throw BacktestConfigurationError.invalidParameter("RP63 positive aligned canonical CNY frame") }
        return try frame.dates.indices.map { s in
            var roles: [RoleDiagnostic] = []
            for symbol in coreSymbols {
                guard s >= 20, s >= 63 else {
                    roles.append(.init(symbol: symbol, returnCount: 0, mean: nil, sumSquares: nil,
                        sampleVariance: nil, annualVol: nil, score: nil, rawWeight: nil,
                        cleanedWeight: 0, reason: s < 20 ? "early-guard-cash" : "undefined63-returns"))
                    continue
                }
                let p = frame.pricesBySymbol[symbol]!
                let returns = ((s - 63 + 1)...s).map { p[$0] / p[$0 - 1] - 1 }
                let mean = returns.reduce(0, +) / 63
                let ss = returns.reduce(0.0) { $0 + pow($1 - mean, 2) }
                let variance = ss / (63 - 1), vol = sqrt(max(variance, 0)) * sqrt(252)
                guard returns.allSatisfy(\.isFinite), mean.isFinite, ss.isFinite, vol.isFinite else {
                    throw BacktestConfigurationError.invalidParameter("RP63 finite simple-return sample volatility")
                }
                let score = vol > 0 ? 1 / max(vol, 0.04) : nil
                roles.append(.init(symbol: symbol, returnCount: 63, mean: mean, sumSquares: ss,
                    sampleVariance: variance, annualVol: vol, score: score, rawWeight: nil,
                    cleanedWeight: 0, reason: vol > 0 ? "positive-vol-score" : "zero-vol-omitted-before-floor"))
            }
            // Frozen score and denominator arithmetic is in the original core order.
            let denominator = roles.reduce(0.0) { $0 + ($1.score ?? 0) }
            var raw: [String: Double] = [:]
            if denominator > 0 {
                for i in roles.indices {
                    if let score = roles[i].score {
                        let weight = 0.95 * score / denominator
                        roles[i].rawWeight = weight; raw[roles[i].symbol] = weight
                    }
                }
            }
            let cap = capped(raw), clean = providerClean(cap)
            for i in roles.indices { roles[i].cleanedWeight = clean[roles[i].symbol] ?? 0 }
            return .init(signalIndex: s, date: frame.dates[s], priceStartIndex: s >= 63 ? s - 63 : nil,
                returnStartIndex: s >= 63 ? s - 62 : nil, windowEndIndex: s >= 63 ? s : nil,
                denominator: denominator, roles: roles, rawTarget: raw, cappedTarget: cap, cleanedTarget: clean)
        }
    }

    public enum Role { case candidate, equal, cash }
    public struct Decision: Encodable, Equatable {
        public let index: Int
        public let date: Date
        public let signalIndex: Int
        public let signalDate: Date
        public let shouldRebalance: Bool
        public var providerCalled: Bool
        public let lastDidExecuteBefore: Int
        public var lastDidExecuteAfter: Int
        public let reviewAgeBefore: Int
        public let retainedTargetBefore: [String: Double]
        public var requestedTarget: [String: Double]?
        public var acceptedAfter: [String: Double]
        public let pendingBefore: [String: Double]?
        public var pendingAfter: [String: Double]?
        public var completedToday: Bool
    }
    public struct Completion: Encodable, Equatable {
        public let index: Int
        public let date: Date
        public let target: [String: Double]
    }
    public struct NativeRun {
        public let simulation: BacktestDailySimulationResult
        public let decisions: [Decision]
        public let completions: [Completion]
        public let targetMismatchCount: Int
    }
    public static func runAccount(preparation: NativePreparation, signals: [Signal], role: Role) throws -> NativeRun {
        guard signals.count == preparation.frame.dates.count,
              signals.enumerated().allSatisfy({ $0.offset == $0.element.signalIndex && $0.element.date == preparation.frame.dates[$0.offset] }) else {
            throw BacktestConfigurationError.invalidParameter("RP63 exact funded signal alignment")
        }
        return try simulate(preparation: preparation, buyReason: role == .candidate ? "fixed RP63 core close research" : "fixed RP63 core close control") { context in
            switch role {
            case .candidate: return signals[context.signalIndex].cleanedTarget
            case .equal: return Dictionary(uniqueKeysWithValues: coreSymbols.map { ($0, 0.95 / 3) })
            case .cash: return [:]
            }
        }
    }
    /// This internal adapter is also exercised with synthetic target fixtures.
    /// Production callers use only the fixed role switch above.
    static func simulate(preparation: NativePreparation, buyReason: String,
                         target: @escaping (StrategyTargetContext) -> [String: Double]) throws -> NativeRun {
        let frame = preparation.frame
        guard frame.simulationRange.lowerBound == 0 else { throw BacktestConfigurationError.invalidParameter("RP63 full funded baseline") }
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0.04, tradeToBandBoundary: false, financingAnnualRate: 0,
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
                let due = c.index >= 21 && age >= 21
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
            throw BacktestConfigurationError.invalidParameter("RP63 unchanged cash baseline/full formation history")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].acceptedAfter = run.dailyStates[i].targetWeights
            let desired = decisions[i].requestedTarget ?? expected[i]
            if decisions[i].acceptedAfter != desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("RP63 target adapter delivery") }
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
              input.schema == "fixed-rp63-core-source-primitives-v1", input.cutoff == "2026-10-06", input.baseline == "2001-06-25",
              input.role_to_source_symbol == ["gold_cny": "gold_cny", "nasdaq": "nasdaq_composite", "sp500": "sp500"],
              input.source_history_sha256 == "86c62407994fdc49ec41ba891a44373201335a4ff0670310a6098c2b1de2dedb",
              coreSymbols.map({ input.series[$0]?.count ?? 0 }) == [6423, 6732, 6743],
              input.funded_union_calendar.count == 6452, input.funded_union_calendar.first == "2001-06-25", input.funded_union_calendar.last == "2026-10-06",
              sources.schema == "fixed-rp63-core-saved-v1", !sources.files.isEmpty,
              sources.files.flatMap(\.ids) == savedControlIDs, savedControlIDs.count == 31,
              sources.files.allSatisfy({ $0.sha256 == "2555a5234bc949de465e00781b39a05871edf9ef28a1bc03002ce4551f15d2ce" }) else {
            throw BacktestConfigurationError.invalidParameter("RP63 frozen canonical source and 31 saved controls")
        }
        func date(_ day: String) throws -> Date {
            guard let d = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { throw BacktestConfigurationError.invalidParameter("RP63 source session date") }
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
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BacktestConfigurationError.invalidParameter("RP63 saved raw hash/rows") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }), !selectedIDs.contains(id) else {
                    throw BacktestConfigurationError.invalidParameter("RP63 saved identity/state order")
                }
                selectedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("RP63 one candidate / 3 fresh / 31 saved") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("RP63 complete mechanical comparison calendar") }
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
            throw BacktestConfigurationError.invalidParameter("RP63 no comparison-day deletion")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        var signalObjects = try JSONSerialization.jsonObject(with: encoder.encode(signalEvidence)) as! [[String: Any]]
        for i in signalObjects.indices {
            for key in ["priceStartIndex", "returnStartIndex", "windowEndIndex"] where signalObjects[i][key] == nil { signalObjects[i][key] = NSNull() }
            var roles = signalObjects[i]["roles"] as! [[String: Any]]
            for j in roles.indices { for key in ["mean", "sumSquares", "sampleVariance", "annualVol", "score", "rawWeight"] where roles[j][key] == nil { roles[j][key] = NSNull() } }
            signalObjects[i]["roles"] = roles
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
            "evidence_class": "POST_HOC_RELATED_D0_CORE_ONLY_INPUT_AND_FX_CLOCK_ADAPTATION; original mathematical target definition retained, original zoo numeric/all-object parity not claimed.", "formal_validation": false, "recommendation_eligible": false,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
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
            "cadence_policy": "initial sentinel Int.min/2; first execution review21; subsequent completion+21; overdue daily prior-signal replacement; empty/no-fill completion; no completion on quote/settlement wait",
            "units_policy": "accounting unitsBySymbol derived from genuine shared state holding value divided by canonical mark; ordered fills allow independent units reconstruction",
            "limitations": ["Price proxies; no directly executable securities/closing-auction, publication-vintage, futures-roll or total-return certification.",
                "Related D0 exposed history; no original zoo numerical parity, pristine OOS, parameter rescue or formal promotion.",
                "No dividends/tax/USD wallet/FX spreads; 31 prior native whole objects preserved with original limitations; short calendar supplemental only."]]
        outputs["evidence.json"] = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in outputs.keys.sorted() { try outputs[name]!.write(to: output.appendingPathComponent(name)) }
        print("Fixed RP63 core: 1 candidate, 3 fresh accounts, 31 saved controls; native6452/long5595/short3086 dates.")
    }
}
