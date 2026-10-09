import Foundation
import AssetTimeMachineBacktestCore

/// Frozen finite Cover expert signal. Virtual expert coefficients are price-only
/// signals; all cash, fills, units and NAV come from one genuine shared account.
public enum CoverUniversalCoreScreen {
    public static let coreSymbols = RiskParityCoreScreen.coreSymbols
    public static let candidateID = "cover-q20-three-core-close"
    public static let equalID = "equal-core100-cover-daily-close-control"
    public static let cashID = "cny-cash-cover-native2001"
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

    public struct Expert: Encodable, Equatable {
        public let ordinal: Int
        public let gi: Int
        public let ni: Int
        public let si: Int
        public let weights: [Double]
    }
    public static let experts: [Expert] = {
        var grid: [Expert] = []
        for gi in 0...20 {
            for ni in 0...(20 - gi) {
                let si = 20 - gi - ni
                grid.append(.init(ordinal: grid.count, gi: gi, ni: ni, si: si,
                    weights: [Double(gi) / 20, Double(ni) / 20, Double(si) / 20]))
            }
        }
        return grid
    }()
    public struct BookUpdate: Equatable {
        public let grossFactors: [Double]
        public let expertWealth: [Double]
        public let denominator: Double
        public let numerators: [Double]
        public let weights: [Double]
    }
    /// Pure finite-book arithmetic also permits the paper's original two-stock
    /// synthetic example. Production always supplies the one frozen 231 grid.
    public static func updateBook(expertWeights: [[Double]], previousWealth: [Double], relatives: [Double]) throws -> BookUpdate {
        guard !relatives.isEmpty, relatives.allSatisfy({ $0.isFinite && $0 > 0 }),
              !expertWeights.isEmpty, expertWeights.count == previousWealth.count,
              previousWealth.allSatisfy({ $0.isFinite && $0 > 0 }),
              expertWeights.allSatisfy({ $0.count == relatives.count && $0.allSatisfy({ $0.isFinite && $0 >= 0 }) }) else {
            throw BacktestConfigurationError.invalidParameter("Cover finite positive raw book inputs")
        }
        var factors: [Double] = [], wealth: [Double] = []
        for ordinal in expertWeights.indices {
            var factor = 0.0
            for leg in relatives.indices { factor += expertWeights[ordinal][leg] * relatives[leg] }
            let value = previousWealth[ordinal] * factor
            guard factor.isFinite, factor > 0, value.isFinite, value > 0 else {
                throw BacktestConfigurationError.invalidParameter("Cover raw product overflow/underflow; no fallback")
            }
            factors.append(factor); wealth.append(value)
        }
        var denominator = 0.0
        for value in wealth { denominator += value }
        guard denominator.isFinite, denominator > 0 else {
            throw BacktestConfigurationError.invalidParameter("Cover raw ordinal denominator; no rescaling")
        }
        var numerators: [Double] = [], weights: [Double] = []
        for leg in relatives.indices {
            var numerator = 0.0
            for ordinal in expertWeights.indices { numerator += expertWeights[ordinal][leg] * wealth[ordinal] }
            let weight = numerator / denominator
            guard numerator.isFinite, numerator > 0, weight.isFinite, weight > 0 else {
                throw BacktestConfigurationError.invalidParameter("Cover raw ordinal numerator")
            }
            numerators.append(numerator); weights.append(weight)
        }
        return .init(grossFactors: factors, expertWealth: wealth, denominator: denominator, numerators: numerators, weights: weights)
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
        public let relatives: [Double]?
        public let expertWealthBefore: [Double]
        public let grossFactors: [Double]
        public let expertWealth: [Double]
        public let denominator: Double
        public let numerators: [Double]?
        public let roles: [RoleDiagnostic]
        public let rawTarget: [String: Double]
        public let cleanedTarget: [String: Double]
    }
    public static func signals(frame: MarketDataFrame) throws -> [Signal] {
        guard !frame.dates.isEmpty, coreSymbols.allSatisfy({ symbol in
            guard let p = frame.pricesBySymbol[symbol], p.count == frame.dates.count else { return false }
            return p.allSatisfy { $0.isFinite && $0 > 0 }
        }) else { throw BacktestConfigurationError.invalidParameter("Cover positive aligned canonical CNY frame") }
        var wealth = Array(repeating: 1.0, count: experts.count)
        let expertWeights = experts.map(\.weights)
        return try frame.dates.indices.map { s in
            let before = s == 0 ? [] : wealth
            let relatives: [Double]? = s == 0 ? nil : coreSymbols.map { frame.pricesBySymbol[$0]![s] / frame.pricesBySymbol[$0]![s - 1] }
            var factors: [Double] = [], denominator = 231.0
            var numerators: [Double]?
            var weights = Array(repeating: 1.0 / 3, count: 3)
            if let relatives {
                let update = try updateBook(expertWeights: expertWeights, previousWealth: wealth, relatives: relatives)
                wealth = update.expertWealth; factors = update.grossFactors
                denominator = update.denominator; numerators = update.numerators; weights = update.weights
            }
            let raw = Dictionary(uniqueKeysWithValues: coreSymbols.indices.map { (coreSymbols[$0], weights[$0]) })
            let clean = providerClean(raw)
            let roles = coreSymbols.indices.map { RoleDiagnostic(symbol: coreSymbols[$0], rawWeight: weights[$0], cleanedWeight: clean[coreSymbols[$0]] ?? 0) }
            return .init(signalIndex: s, date: frame.dates[s], intervalCount: s,
                reason: s == 0 ? "baseline-explicit-equal-prior" : "full-past-raw-finite-expert-posterior",
                relatives: relatives, expertWealthBefore: before, grossFactors: factors, expertWealth: wealth,
                denominator: denominator, numerators: numerators, roles: roles, rawTarget: raw, cleanedTarget: clean)
        }
    }
    public static func runAccount(preparation: NativePreparation, signals: [Signal], role: Role) throws -> NativeRun {
        guard signals.count == preparation.frame.dates.count,
              signals.enumerated().allSatisfy({ $0.offset == $0.element.signalIndex && $0.element.date == preparation.frame.dates[$0.offset] }) else {
            throw BacktestConfigurationError.invalidParameter("Cover exact funded signal alignment")
        }
        return try simulate(preparation: preparation,
            buyReason: role == .candidate ? "fixed Cover q20 core close research" : "fixed Cover daily core close control") { context in
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
        guard frame.simulationRange.lowerBound == 0 else { throw BacktestConfigurationError.invalidParameter("Cover full funded baseline") }
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
            throw BacktestConfigurationError.invalidParameter("Cover unchanged cash baseline/full formation history")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].acceptedAfter = run.dailyStates[i].targetWeights
            let desired = decisions[i].requestedTarget ?? expected[i]
            if decisions[i].acceptedAfter != desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("Cover target adapter delivery") }
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
            throw BacktestConfigurationError.invalidParameter("Cover q20 frozen canonical source and 31 saved controls")
        }
        func date(_ day: String) throws -> Date {
            guard let d = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { throw BacktestConfigurationError.invalidParameter("Cover q20 source session date") }
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
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BacktestConfigurationError.invalidParameter("Cover q20 saved raw hash/rows") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }), !selectedIDs.contains(id) else {
                    throw BacktestConfigurationError.invalidParameter("Cover q20 saved identity/state order")
                }
                selectedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("Cover q20 one candidate / 3 fresh / 31 saved") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("Cover q20 complete mechanical comparison calendar") }
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
            throw BacktestConfigurationError.invalidParameter("Cover q20 no comparison-day deletion")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        var signalObjects = try JSONSerialization.jsonObject(with: encoder.encode(signalEvidence)) as! [[String: Any]]
        for i in signalObjects.indices {
            for key in ["relatives", "numerators"] where signalObjects[i][key] == nil { signalObjects[i][key] = NSNull() }
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
            "evidence_class": "POST_HOC_RELATED_D0_SOURCE_QUANTIZATION_DIMENSION_INPUT_FX_AND_EXECUTION_ADAPTATION", "formal_validation": false, "recommendation_eligible": false,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "pre_specification_sha256": "1f2ace3fe498736a3fcf80f78ebb163a15c3d162a5301fbf87dc088eb6be7415",
            "original_definition": "Cover1991_Eq8.1_8.2_finite_uniform_CRP_next_target",
            "primary_original_pdf_sha256": "dfb8d3c33beeb3fef6faa906bf3bc0cc0c916be3ccce85d52d3aa194fcca1c12",
            "source_proposal_sha256": "bf1b2a006139c30333fc12c2f733b6865cf714511b467cddc4052e8dba0b6a62",
            "signal_schema": "fixed-cover-q20-core-signal-v1", "expert_count": 231,
            "expert_grid": try JSONSerialization.jsonObject(with: encoder.encode(experts)),
            "expert_book_policy": "S0=1 uniform; signal0 explicit equal thirds; full funded past simple gross relatives; ordinal gold/nasdaq/sp500 dot then raw chronological S multiplication; positive finite or fail; no log/scaling/reset",
            "target_policy": "each leg ordinal sum b*S / ordinal sum S; finite-positive allowed-symbol maxGross1 provider cleaning only; no tiny cutoff; virtual S never actual NAV",
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
            "cadence_policy": "initial sentinel Int.min/2; baseline0 cash; every index>=1 latest signalIndex=index-1 replaces pending; band0/gross1; completion diagnostic only; no completion on quote/settlement wait",
            "ideal_book_actual_NAV_identity_claimed": false, "old_RP_GMV_control_parity_claimed": false,
            "dual_clock_limitation": "Ideal next-period-start coefficients differ from actual next-close fills; first funded interval is actual cash. Costs, quote waits, settlement and cash interest further separate actual NAV from ideal expert-book mean.",
            "units_policy": "accounting unitsBySymbol derived from genuine shared state holding value divided by canonical mark; ordered fills allow independent units reconstruction",
            "limitations": ["Price proxies; no directly executable securities/closing-auction, publication-vintage, futures-roll or total-return certification.",
                "Finite three-core adaptation; source/history exposed and census UNKNOWN; no continuum error bound, original empirical parity, pristine OOS, parameter rescue or formal promotion.",
                "No dividends/tax/USD wallet/FX spreads; 31 prior native whole objects preserved with original limitations; short calendar supplemental only."]]
        outputs["evidence.json"] = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in outputs.keys.sorted() { try outputs[name]!.write(to: output.appendingPathComponent(name)) }
        print("Fixed Cover q20 core: 1 candidate, 3 fresh accounts, 31 saved controls; native6452/long5595/short3086 dates.")
    }
}
