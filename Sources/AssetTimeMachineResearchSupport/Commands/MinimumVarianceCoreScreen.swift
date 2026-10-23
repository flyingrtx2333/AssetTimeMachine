import Foundation
import AssetTimeMachineBacktestCore

/// Frozen original GMV63 grid with related D0 canonical-close input/FX adaptation.
/// Preparation and genuine multiasset execution use the unchanged RP63 adapter.
public enum MinimumVarianceCoreScreen {
    public static let coreSymbols = RiskParityCoreScreen.coreSymbols
    public static let candidateID = "gmv63-three-core-close"
    public static let equalID = "equal-core95-gmv63-close-control"
    public static let cashID = "cny-cash-gmv63-native2001"
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
    public static func capped(_ weights: [String: Double]) -> [String: Double] { RiskParityCoreScreen.capped(weights) }
    public static func providerClean(_ weights: [String: Double]) -> [String: Double] { RiskParityCoreScreen.providerClean(weights) }

    public struct RoleDiagnostic: Encodable, Equatable {
        public let symbol: String
        public let returnCount: Int
        public let returns: [Double]
        public let mean: Double?
        public let rawWeight: Double?
        public let cleanedWeight: Double
    }
    public struct GridEvaluation: Equatable {
        /// Ordinal is the array index in the original gi-outer / ni-inner order.
        public let gridVariances: [Double]
        public let winningOrdinal: Int
        public let winningGI: Int
        public let winningNI: Int
        public let winningSI: Int
        public let winningWeights: [Double]
        public let winningVariance: Double
        /// Exact floating-point equal minima, diagnostic only; never a tie override.
        public let minimumTieOrdinals: [Int]
    }
    public struct Signal: Encodable, Equatable {
        public let signalIndex: Int
        public let date: Date
        public let priceStartIndex: Int?
        public let returnStartIndex: Int?
        public let windowEndIndex: Int?
        public let reason: String
        public let roles: [RoleDiagnostic]
        public let covarianceSums: [[Double]]?
        public let covariance: [[Double]]?
        public let gridVariances: [Double]
        public let winningOrdinal: Int?
        public let winningGI: Int?
        public let winningNI: Int?
        public let winningSI: Int?
        public let winningWeights: [Double]?
        public let winningVariance: Double?
        public let minimumTieOrdinals: [Int]
        public let rawTarget: [String: Double]
        public let cappedTarget: [String: Double]
        public let cleanedTarget: [String: Double]
    }

    /// Exact original fixed grid. No clamp, annualization, floor, ridge or optimizer.
    public static func gridEvaluation(covariance: [[Double]]) throws -> GridEvaluation {
        guard covariance.count == 3, covariance.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else {
            throw BacktestConfigurationError.invalidParameter("GMV63 finite full 3x3 covariance")
        }
        var bestVariance = Double.infinity
        var best = (0.0, 0.0, 0.0)
        var winningOrdinal = 0, winningGI = 0, winningNI = 0, winningSI = 20
        var risks: [Double] = []; risks.reserveCapacity(231)
        for gi in 0...20 {
            for ni in 0...(20 - gi) {
                let si = 20 - gi - ni
                let w = [Double(gi) / 20, Double(ni) / 20, Double(si) / 20]
                var variance = 0.0
                for i in 0..<3 {
                    for j in 0..<3 {
                        variance += w[i] * w[j] * covariance[i][j]
                    }
                }
                guard variance.isFinite else { throw BacktestConfigurationError.invalidParameter("GMV63 finite ordered grid risk") }
                risks.append(variance)
                if variance < bestVariance {
                    bestVariance = variance
                    best = (w[0], w[1], w[2])
                    winningOrdinal = risks.count - 1; winningGI = gi; winningNI = ni; winningSI = si
                }
            }
        }
        return .init(gridVariances: risks, winningOrdinal: winningOrdinal, winningGI: winningGI,
            winningNI: winningNI, winningSI: winningSI, winningWeights: [best.0, best.1, best.2],
            winningVariance: bestVariance, minimumTieOrdinals: risks.indices.filter { risks[$0] == bestVariance })
    }

    public static func signals(frame: MarketDataFrame) throws -> [Signal] {
        guard coreSymbols.allSatisfy({ symbol in
            guard let p = frame.pricesBySymbol[symbol], p.count == frame.dates.count else { return false }
            return p.allSatisfy { $0.isFinite && $0 > 0 }
        }) else { throw BacktestConfigurationError.invalidParameter("GMV63 positive aligned canonical CNY frame") }
        return try frame.dates.indices.map { s in
            guard s >= 20, s >= 63 else {
                let roles = coreSymbols.map { RoleDiagnostic(symbol: $0, returnCount: 0, returns: [], mean: nil, rawWeight: nil, cleanedWeight: 0) }
                return .init(signalIndex: s, date: frame.dates[s], priceStartIndex: nil, returnStartIndex: nil, windowEndIndex: nil,
                    reason: s < 20 ? "early-guard-cash" : "undefined63-returns", roles: roles, covarianceSums: nil, covariance: nil,
                    gridVariances: [], winningOrdinal: nil, winningGI: nil, winningNI: nil, winningSI: nil, winningWeights: nil,
                    winningVariance: nil, minimumTieOrdinals: [], rawTarget: [:], cappedTarget: [:], cleanedTarget: [:])
            }
            let series = coreSymbols.map { symbol -> [Double] in
                let p = frame.pricesBySymbol[symbol]!
                return ((s - 63 + 1)...s).map { p[$0] / p[$0 - 1] - 1 }
            }
            let means = series.map { $0.reduce(0, +) / Double($0.count) }
            guard series.allSatisfy({ $0.allSatisfy(\.isFinite) }), means.allSatisfy(\.isFinite) else {
                throw BacktestConfigurationError.invalidParameter("GMV63 finite simple returns/means")
            }
            var sums = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
            var covariance = sums
            for i in 0..<3 {
                for j in 0..<3 {
                    var value = 0.0
                    for cursor in series[i].indices {
                        value += (series[i][cursor] - means[i]) * (series[j][cursor] - means[j])
                    }
                    sums[i][j] = value
                    covariance[i][j] = value / Double(series[i].count - 1)
                }
            }
            let grid = try gridEvaluation(covariance: covariance)
            var raw: [String: Double] = [:]
            for i in coreSymbols.indices { raw[coreSymbols[i]] = grid.winningWeights[i] * 0.95 }
            let cap = capped(raw), clean = providerClean(cap)
            let roles = coreSymbols.indices.map { i in RoleDiagnostic(symbol: coreSymbols[i], returnCount: 63,
                returns: series[i], mean: means[i], rawWeight: raw[coreSymbols[i]], cleanedWeight: clean[coreSymbols[i]] ?? 0) }
            return .init(signalIndex: s, date: frame.dates[s], priceStartIndex: s - 63, returnStartIndex: s - 62, windowEndIndex: s,
                reason: "defined63-full-covariance-grid", roles: roles, covarianceSums: sums, covariance: covariance,
                gridVariances: grid.gridVariances, winningOrdinal: grid.winningOrdinal, winningGI: grid.winningGI,
                winningNI: grid.winningNI, winningSI: grid.winningSI, winningWeights: grid.winningWeights,
                winningVariance: grid.winningVariance, minimumTieOrdinals: grid.minimumTieOrdinals,
                rawTarget: raw, cappedTarget: cap, cleanedTarget: clean)
        }
    }
    public static func runAccount(preparation: NativePreparation, signals: [Signal], role: Role) throws -> NativeRun {
        guard signals.count == preparation.frame.dates.count,
              signals.enumerated().allSatisfy({ $0.offset == $0.element.signalIndex && $0.element.date == preparation.frame.dates[$0.offset] }) else {
            throw BacktestConfigurationError.invalidParameter("GMV63 exact funded signal alignment")
        }
        return try RiskParityCoreScreen.simulate(preparation: preparation,
            buyReason: role == .candidate ? "fixed GMV63 core close research" : "fixed RP63 core close control") { context in
            switch role {
            case .candidate: return signals[context.signalIndex].cleanedTarget
            case .equal: return Dictionary(uniqueKeysWithValues: coreSymbols.map { ($0, 0.95 / 3) })
            case .cash: return [:]
            }
        }
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
            throw BacktestConfigurationError.invalidParameter("GMV63 frozen canonical source and 31 saved controls")
        }
        func date(_ day: String) throws -> Date {
            guard let d = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { throw BacktestConfigurationError.invalidParameter("GMV63 source session date") }
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
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BacktestConfigurationError.invalidParameter("GMV63 saved raw hash/rows") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }), !selectedIDs.contains(id) else {
                    throw BacktestConfigurationError.invalidParameter("GMV63 saved identity/state order")
                }
                selectedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("GMV63 one candidate / 3 fresh / 31 saved") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("GMV63 complete mechanical comparison calendar") }
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
            throw BacktestConfigurationError.invalidParameter("GMV63 no comparison-day deletion")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        var signalObjects = try JSONSerialization.jsonObject(with: encoder.encode(signalEvidence)) as! [[String: Any]]
        for i in signalObjects.indices {
            for key in ["priceStartIndex", "returnStartIndex", "windowEndIndex", "covarianceSums", "covariance",
                "winningOrdinal", "winningGI", "winningNI", "winningSI", "winningWeights", "winningVariance"] where signalObjects[i][key] == nil { signalObjects[i][key] = NSNull() }
            var roles = signalObjects[i]["roles"] as! [[String: Any]]
            for j in roles.indices { for key in ["mean", "rawWeight"] where roles[j][key] == nil { roles[j][key] = NSNull() } }
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
            "pre_specification_sha256": "16a5c71617e67cd22538fb8ef4dea2f01d4b333f39cbf600ec4605b835998eeb",
            "original_definition": "gmv_63", "original_zoo_source_sha256": "e80f27d2ec54c3bdefd0734f1ee7894f3f0ecb2a4817955b225bf8aa4503e063",
            "signal_schema": "fixed-gmv63-core-signal-v1", "grid_state_count": 231,
            "covariance_policy": "63 simple frame returns; chronological mean/63; i,j,cursor centered cross sum/62; all9 entries; no annualization/floor/clamp/ridge",
            "grid_policy": "ordinal=array index; gi0...20 outer, ni0...(20-gi) inner, si=20-gi-ni; weights integer/20; nine variance terms i outer j inner; strict<first tie; zero covariance SP50095",
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
        print("Fixed GMV63 core: 1 candidate, 3 fresh accounts, 31 saved controls; native6452/long5595/short3086 dates.")
    }
}
