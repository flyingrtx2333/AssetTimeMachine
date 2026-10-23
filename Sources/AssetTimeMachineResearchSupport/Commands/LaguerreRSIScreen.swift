import Foundation
import AssetTimeMachineBacktestCore

/// Frozen Figure 9 Laguerre RSI and Root long/cash crossing adaptation; related D0 only.
public enum LaguerreRSIScreen {
    public typealias Bar = ChaikinMoneyFlowScreen.Bar
    public typealias NativePreparation = ChaikinMoneyFlowScreen.NativePreparation
    public static let candidateID = "laguerre05-qqq-long-cash"
    public static let buyHoldID = ChaikinMoneyFlowScreen.buyHoldID
    public static let cashID = ChaikinMoneyFlowScreen.cashID
    public static let qualID = ChaikinMoneyFlowScreen.qualID

    public struct States: Encodable, Equatable {
        public var l0 = 0.0, l1 = 0.0, l2 = 0.0, l3 = 0.0, cu = 0.0, cd = 0.0, rsi = 0.0
        public init() {}
    }
    public struct Signal: Encodable, Equatable {
        public let date: Date
        public let sourceDate: String
        public let sourceOrdinal: Int
        public let currentBar: Int
        public let computed: Bool
        public let warmOverride: Bool
        public let price: Double
        public let currentUSDBar: Bar
        public let states: States
        /// Internal prior after this bar's effective split-unit transport.
        public let previousStates: States
        public let previousStatesBeforeSplit: States
        public let appliedSplitDates: [Date]
        public let splitFactor: Double
        public let fundingEligible: Bool
        public let previousWeight: Double
        public let weight: Double
        public let stateReason: String
        public let stateSourceDate: Date?

        enum CodingKeys: String, CodingKey {
            case date, sourceDate, sourceOrdinal, currentBar, computed, warmOverride, price, currentUSDBar
            case states, previousStates, previousStatesBeforeSplit, appliedSplitDates, splitFactor
            case fundingEligible, previousWeight, weight, stateReason, stateSourceDate
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date); try c.encode(sourceDate, forKey: .sourceDate)
            try c.encode(sourceOrdinal, forKey: .sourceOrdinal); try c.encode(currentBar, forKey: .currentBar)
            try c.encode(computed, forKey: .computed); try c.encode(warmOverride, forKey: .warmOverride)
            try c.encode(price, forKey: .price); try c.encode(currentUSDBar, forKey: .currentUSDBar)
            try c.encode(states, forKey: .states); try c.encode(previousStates, forKey: .previousStates)
            try c.encode(previousStatesBeforeSplit, forKey: .previousStatesBeforeSplit)
            try c.encode(appliedSplitDates, forKey: .appliedSplitDates); try c.encode(splitFactor, forKey: .splitFactor)
            try c.encode(fundingEligible, forKey: .fundingEligible); try c.encode(previousWeight, forKey: .previousWeight)
            try c.encode(weight, forKey: .weight); try c.encode(stateReason, forKey: .stateReason)
            try c.encode(stateSourceDate, forKey: .stateSourceDate)
        }
    }

    // Individual finite-checked operations preserve the printed left folds.
    @inline(never) private static func finite(_ value: Double, _ context: String) throws -> Double {
        guard value.isFinite else { throw BacktestConfigurationError.invalidParameter(context + " nonfinite") }
        return value
    }
    @inline(never) private static func add(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a + b, c) }
    @inline(never) private static func subtract(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a - b, c) }
    @inline(never) private static func multiply(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a * b, c) }
    @inline(never) private static func divide(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a / b, c) }

    private static func validateState(_ state: States, context: String) throws {
        guard [state.l0, state.l1, state.l2, state.l3, state.cu, state.cd, state.rsi].allSatisfy(\.isFinite) else {
            throw BacktestConfigurationError.invalidParameter(context + " invalid prior/transformed state")
        }
    }
    private static func transport(_ state: inout States, ratio: Double, context: String) throws {
        state.l0 = try divide(state.l0, ratio, context + " split l0")
        state.l1 = try divide(state.l1, ratio, context + " split l1")
        state.l2 = try divide(state.l2, ratio, context + " split l2")
        state.l3 = try divide(state.l3, ratio, context + " split l3")
        state.cu = try divide(state.cu, ratio, context + " split cu")
        state.cd = try divide(state.cd, ratio, context + " split cd")
        // RSI is dimensionless. Earlier emitted snapshots and weights are not changed.
        try validateState(state, context: context)
    }

    public static func signals(bars: [Bar], splits: [Date: Double], stateEligibleFrom: Date) throws -> [Signal] {
        guard !bars.isEmpty, stateEligibleFrom.timeIntervalSinceReferenceDate.isFinite,
              zip(bars, bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              splits.allSatisfy({ $0.key.timeIntervalSinceReferenceDate.isFinite && $0.value.isFinite && $0.value > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("Laguerre05 ordered USD bars / effective splits / funding date")
        }
        let splitDates = splits.keys.sorted()
        var nextSplit = 0, priorState = States(), result: [Signal] = [], weight = 0.0
        for (ordinal, b) in bars.enumerated() {
            guard b.date.timeIntervalSinceReferenceDate.isFinite else {
                throw BacktestConfigurationError.invalidParameter("Laguerre05 sourceOrdinal=\(ordinal) invalid source date")
            }
            let day = BacktestSeriesAlignment.historicalSeriesDateString(from: b.date)
            let context = "Laguerre05 sourceOrdinal=\(ordinal) date=\(day)"
            guard [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 }),
                  b.high >= b.low, b.high >= max(b.open, b.close), b.low <= min(b.open, b.close),
                  b.volume.isFinite, b.volume >= 0 else {
                throw BacktestConfigurationError.invalidParameter(context + " invalid complete USD OHLCV")
            }
            let previousWeight = weight, previousBeforeSplit = priorState
            try validateState(previousBeforeSplit, context: context)
            var applied: [Date] = [], splitFactor = 1.0
            while nextSplit < splitDates.count && splitDates[nextSplit] <= b.date {
                let splitDate = splitDates[nextSplit], ratio = splits[splitDate]!
                try transport(&priorState, ratio: ratio, context: context)
                splitFactor = try multiply(splitFactor, ratio, context + " split factor")
                applied.append(splitDate); nextSplit += 1
            }
            let prior = priorState, currentBar = ordinal, computed = ordinal > 0, price = b.close
            try validateState(prior, context: context)
            var state = States()
            if computed {
                let gamma = 0.5
                let beta = try subtract(1, gamma, context + " beta")
                let current0 = try multiply(beta, price, context + " l0 current")
                let tail0 = try multiply(gamma, prior.l0, context + " l0 prior")
                state.l0 = try add(current0, tail0, context + " l0")
                let negGamma = try finite(-gamma, context + " negative gamma")
                let current1 = try multiply(negGamma, state.l0, context + " l1 current")
                let partial1 = try add(current1, prior.l0, context + " l1 partial")
                let tail1 = try multiply(gamma, prior.l1, context + " l1 prior")
                state.l1 = try add(partial1, tail1, context + " l1")
                let current2 = try multiply(negGamma, state.l1, context + " l2 current")
                let partial2 = try add(current2, prior.l1, context + " l2 partial")
                let tail2 = try multiply(gamma, prior.l2, context + " l2 prior")
                state.l2 = try add(partial2, tail2, context + " l2")
                let current3 = try multiply(negGamma, state.l2, context + " l3 current")
                let partial3 = try add(current3, prior.l2, context + " l3 partial")
                let tail3 = try multiply(gamma, prior.l3, context + " l3 prior")
                state.l3 = try add(partial3, tail3, context + " l3")
                // CU/CD begin at the seven-state initializer's exact zeros each bar.
                if state.l0 >= state.l1 { state.cu = try subtract(state.l0, state.l1, context + " first cu") }
                else { state.cd = try subtract(state.l1, state.l0, context + " first cd") }
                if state.l1 >= state.l2 {
                    let sum = try add(state.cu, state.l1, context + " second cu sum")
                    state.cu = try subtract(sum, state.l2, context + " second cu")
                } else {
                    let sum = try add(state.cd, state.l2, context + " second cd sum")
                    state.cd = try subtract(sum, state.l1, context + " second cd")
                }
                if state.l2 >= state.l3 {
                    let sum = try add(state.cu, state.l2, context + " third cu sum")
                    state.cu = try subtract(sum, state.l3, context + " third cu")
                } else {
                    let sum = try add(state.cd, state.l3, context + " third cd sum")
                    state.cd = try subtract(sum, state.l2, context + " third cd")
                }
                let denominator = try add(state.cu, state.cd, context + " rsi denominator")
                state.rsi = prior.rsi
                if denominator != 0 { state.rsi = try divide(state.cu, denominator, context + " rsi ratio") }
            }
            try validateState(state, context: context)
            let eligible = b.date >= stateEligibleFrom, reason: String
            if !eligible { weight = 0; reason = "pre-funding-cash" }
            else if !computed { weight = 0; reason = "warmup-cash" }
            else if prior.rsi >= 0.8 && state.rsi < 0.8 { weight = 0; reason = "rsi-cross-down-exit-cash" }
            else if prior.rsi <= 0.2 && state.rsi > 0.2 { weight = 1; reason = "rsi-cross-up-entry-long" }
            else { reason = weight == 1 ? "latch-long" : "latch-cash" }
            result.append(.init(date: b.date, sourceDate: day, sourceOrdinal: ordinal, currentBar: currentBar,
                computed: computed, warmOverride: false, price: price, currentUSDBar: b,
                states: state, previousStates: prior, previousStatesBeforeSplit: previousBeforeSplit,
                appliedSplitDates: applied, splitFactor: splitFactor, fundingEligible: eligible,
                previousWeight: previousWeight, weight: weight, stateReason: reason,
                stateSourceDate: computed ? b.date : nil))
            priorState = state
        }
        return result
    }

    public static func signalData(_ signals: [Signal]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(signals)
    }

    /// Reads only the frozen USD bars and writes the same signal bytes as finance.
    public static func exportSource(pricesPath: String, outputPath: String, sourceCommit: String) throws {
        guard !sourceCommit.isEmpty else { throw BacktestConfigurationError.invalidParameter("Laguerre05 source commit") }
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        try validateInput(input)
        let b = try input.bars.map { row -> Bar in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: row.date) else {
                throw BacktestConfigurationError.invalidParameter("Laguerre05 source bar date")
            }
            return Bar(date: date, open: row.open, high: row.high, low: row.low, close: row.close, volume: row.volume)
        }
        let splits = try Dictionary(uniqueKeysWithValues: input.splits.map { row -> (Date, Double) in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: row.date) else {
                throw BacktestConfigurationError.invalidParameter("Laguerre05 source split date")
            }
            return (date, row.ratio)
        })
        let evidence = try signals(bars: b, splits: splits, stateEligibleFrom: BacktestSeriesAlignment.historicalSeriesDate(from: "2000-01-13")!)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try signalData(evidence).write(to: output, options: .withoutOverwriting)
        print("Fixed Laguerre05 source: \(evidence.count) original USD bar signals; no accounts.")
    }

    private static func validateInput(_ input: Input) throws {
        guard input.schema == "fixed-laguerre05-v1", input.symbol == "QQQ", input.currency == "USD",
              input.bars.count == 6937, input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-06",
              input.splits.count == 1, input.splits[0].date == "2000-03-20", input.splits[0].ratio == 2 else {
            throw BacktestConfigurationError.invalidParameter("Laguerre05 frozen original USD bars / effective split")
        }
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
            buyReason: role == .candidate ? "fixed Laguerre05 research" : "fixed CMF20 research")
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
            throw BacktestConfigurationError.invalidParameter("Laguerre05 unchanged initial cash baseline")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].accepted = run.dailyStates[i].targetWeights["QQQ"] ?? 0
            if decisions[i].accepted != decisions[i].desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("Laguerre05 prior target delivery") }
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
        guard input.schema == "fixed-laguerre05-v1", input.symbol == "QQQ", input.currency == "USD",
              input.bars.count == 6937, input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-06",
              input.splits.count == 1, input.splits[0].date == "2000-03-20", input.splits[0].ratio == 2,
              sources.schema == "fixed-laguerre05-saved-v1", !sources.files.isEmpty,
              sources.files.flatMap(\.ids) == savedControlIDs, savedControlIDs.count == 31 else {
            throw BacktestConfigurationError.invalidParameter("Laguerre05 frozen input and 31 saved-control scope")
        }
        func date(_ day: String) throws -> Date {
            guard let value = BacktestSeriesAlignment.historicalSeriesDate(from: day) else {
                throw BacktestConfigurationError.invalidParameter("Laguerre05 session date")
            }
            return value
        }
        let bars = try input.bars.map { b in Bar(date: try date(b.date), open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume) }
        let splits = try input.splits.map { s in BacktestShareSplit(id: "QQQ:" + s.date, symbol: "QQQ",
            effectiveDate: try date(s.date), newUnitsPerOldUnit: s.ratio) }
        let signalEvidence = try signals(bars: bars, splits: Dictionary(uniqueKeysWithValues: splits.map { ($0.effectiveDate, $0.newUnitsPerOldUnit) }), stateEligibleFrom: date("2000-01-13"))
        let dataset = try PublicBacktestCore.loadDataset(from: history, datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        guard let fx = dataset.seriesBySymbol["usd_per_cny"], fx.dates.first == "2000-01-13" else {
            throw BacktestConfigurationError.invalidParameter("Laguerre05 original App FX start; no early extension")
        }
        let native = try ChaikinMoneyFlowScreen.nativePreparation(bars: bars, fxDates: fx.dates, fxPrices: fx.prices, baseline: date("2000-01-13"))
        guard native.frame.dates.last == (try date("2026-10-06")), native.frame.dates.count == 6722,
              native.frame.dates.count == input.bars.filter({ $0.date >= "2000-01-13" }).count else {
            throw BacktestConfigurationError.invalidParameter("Laguerre05 every native QQQ session retained")
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
                throw BacktestConfigurationError.invalidParameter("Laguerre05 saved-control file hash/rows")
            }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }),
                      selectedIDs.contains(id) == false else {
                    throw BacktestConfigurationError.invalidParameter("Laguerre05 saved-control identity/state order")
                }
                selectedIDs.append(id)
                accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("Laguerre05 3 new / 31 saved account budget") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("Laguerre05 mechanical common calendar") }
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
            throw BacktestConfigurationError.invalidParameter("Laguerre05 frozen mechanical long/all20 calendars")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        let result = try JSONSerialization.data(withJSONObject: longRows, options: [.sortedKeys])
        let nativeBytes = try JSONSerialization.data(withJSONObject: nativeRows, options: [.sortedKeys])
        let allBytes = try JSONSerialization.data(withJSONObject: allRows, options: [.sortedKeys])
        let signalBytes = try signalData(signalEvidence)
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
            "evidence_class": "D0_USER_AUTHORIZED_POST_HOC_RELATED_LAGUERRE_STAGE_REVERSAL", "formal_validation": false,
            "recommendation_eligible": false, "source_commit": sourceCommit,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "prices_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "accounts_sha256": ResearchRunEvidence.sha256(savedRaw), "saved_source_files": sources.files.map { ["path": $0.path, "sha256": $0.sha256, "ids": $0.ids] as [String: Any] },
            "result_sha256": ResearchRunEvidence.sha256(result), "native_full_sha256": ResearchRunEvidence.sha256(nativeBytes),
            "all20_sha256": ResearchRunEvidence.sha256(allBytes), "signals_sha256": ResearchRunEvidence.sha256(signalBytes),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "candidate_count": 1, "new_funded_account_count": 3, "saved_control_count": 31, "account_count": 34,
            "parameter_search_budget": 0, "gamma": 0.5, "entry_threshold": 0.2, "exit_threshold": 0.8,
            "seed_policy": "Seven printed zero states; Root MBB1/CurrentBar=sourceOrdinal; source0 inactive; source1 first computation; no warm override or platform startup parity claim",
            "recurrence_policy": "Frozen Figure9 Binary64 Close EMA then three current/prior all-pass stages; CU/CD reset0 and three >= comparisons with printed left-fold add then subtract; finite den!=0 ratio else priorRSI carry; no clamp/epsilon",
            "crossover_policy": "Root RSI-line interpretation of price exit prose; postfunding priorRSI>=.8/current<.8 exit priority, else prior<=.2/current>.2 entry, else prior emitted weight latch; threshold touch no trade; prefunding cash no latent position",
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
            "signal_policy": "all original USD Close bars; latest completed strictly before opening; prefunding emittedcash/no latent position; afterfunding only real eligible .2up/.8down crossings change latched target; no split reset or cash veto",
            "price_units": "Input already restores historical OHLC; no second input adjustment; effective split divides internal prior l0/l1/l2/l3/cu/cd byratio, dimensionless rsi unchanged; previous emitted signals and weights immutable; original engine handles held units",
            "state_names": ["l0", "l1", "l2", "l3", "cu", "cd", "rsi"],
            "initial_state_count": 7, "max_bars_back": 1, "first_computed_source_ordinal": 1,
            "warm_override": false,
            "source_pdf_sha256": "fb82cdff5082b43a11d79b8f7156781ceffbcfdfe818d656067c093062f38398",
            "pre_specification_sha256": "3c71ed19cec9d4230207fa2b9dbd03988512ca2e0268569f6eeea5df05a584d5",
            "limitations": ["Related D0 Laguerre stage-reversal long/cash adaptation; seven zero seeds and Figure9 indicator literal, while RSI-line interpretation of price exit prose, MBB/clock, latch/funding, split transport and orders are frozen Root conventions. No exact platform-bitwise replication, independent alpha, pristine OOS or formal certification.",
                "No dividends, tax, FX conversion fees or separate USD-wallet certification; historical quotes are not complete quote-vintage certification.",
                "Full native history retains the initial unavailable-mark cash baseline; common-calendar comparisons are mechanical slices of the one native account.",
                "Saved controls preserve their original full rows and limitations; QUAL remains only in the separate shorter all20 supplement."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, data) in [("result.json", result), ("native-full.json", nativeBytes), ("all20.json", allBytes),
            ("signals.json", signalBytes), ("decisions.json", try JSONSerialization.data(withJSONObject: decisionObjects, options: [.sortedKeys])),
            ("splits.json", try encoder.encode(splitEvidence)), ("cash-yield.json", try encoder.encode(cashEvidence)),
            ("quotes.json", try JSONSerialization.data(withJSONObject: quotesObject, options: [.sortedKeys])),
            ("native-frame.json", try JSONSerialization.data(withJSONObject: frameObject, options: [.sortedKeys])),
            ("evidence.json", try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]))] {
            try data.write(to: output.appendingPathComponent(name))
        }
        print("Fixed Laguerre05: 1 candidate, 3 new accounts, 31 saved controls; native \(native.frame.dates.count)/long \(longDates.count)/all20 \(allDates.count) dates.")
    }
}
