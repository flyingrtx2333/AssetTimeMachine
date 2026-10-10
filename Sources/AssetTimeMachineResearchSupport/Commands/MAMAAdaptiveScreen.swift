import Foundation
import AssetTimeMachineBacktestCore

/// The frozen .5/.05 MAMA/FAMA crossover; related D0 research only.
public enum MAMAAdaptiveScreen {
    public typealias Bar = ChaikinMoneyFlowScreen.Bar
    public typealias NativePreparation = ChaikinMoneyFlowScreen.NativePreparation
    public static let candidateID = "mama05-005-qqq-long-cash"
    public static let buyHoldID = ChaikinMoneyFlowScreen.buyHoldID
    public static let cashID = ChaikinMoneyFlowScreen.cashID
    public static let qualID = ChaikinMoneyFlowScreen.qualID

    public struct States: Encodable, Equatable {
        public var smooth = 0.0, detrender = 0.0, i1 = 0.0, q1 = 0.0
        public var jI = 0.0, jQ = 0.0, i2 = 0.0, q2 = 0.0, re = 0.0, im = 0.0
        public var period = 0.0, smoothPeriod = 0.0, phase = 0.0, deltaPhase = 0.0
        public var alpha = 0.0, mama = 0.0, fama = 0.0
        public init() {}
    }
    public struct Signal: Encodable, Equatable {
        public let date: Date
        public let sourceDate: String
        public let sourceOrdinal: Int
        public let currentBar: Int
        public let computed: Bool
        public let price: Double
        public let currentUSDBar: Bar
        public let states: States
        /// Internal prior states after this bar's effective split transport.
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
            case date, sourceDate, sourceOrdinal, currentBar, computed, price, currentUSDBar
            case states, previousStates, previousStatesBeforeSplit, appliedSplitDates, splitFactor
            case fundingEligible, previousWeight, weight, stateReason, stateSourceDate
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date); try c.encode(sourceDate, forKey: .sourceDate)
            try c.encode(sourceOrdinal, forKey: .sourceOrdinal); try c.encode(currentBar, forKey: .currentBar)
            try c.encode(computed, forKey: .computed); try c.encode(price, forKey: .price)
            try c.encode(currentUSDBar, forKey: .currentUSDBar); try c.encode(states, forKey: .states)
            try c.encode(previousStates, forKey: .previousStates)
            try c.encode(previousStatesBeforeSplit, forKey: .previousStatesBeforeSplit)
            try c.encode(appliedSplitDates, forKey: .appliedSplitDates); try c.encode(splitFactor, forKey: .splitFactor)
            try c.encode(fundingEligible, forKey: .fundingEligible); try c.encode(previousWeight, forKey: .previousWeight)
            try c.encode(weight, forKey: .weight); try c.encode(stateReason, forKey: .stateReason)
            try c.encode(stateSourceDate, forKey: .stateSourceDate)
        }
    }

    // Separate scalar calls retain each declared Binary64 operation and its
    // finite check; no multiply/add contraction or alternative atan convention.
    @inline(never) private static func finite(_ value: Double, _ context: String) throws -> Double {
        guard value.isFinite else { throw BacktestConfigurationError.invalidParameter(context + " nonfinite") }
        return value
    }
    @inline(never) private static func add(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a + b, c) }
    @inline(never) private static func subtract(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a - b, c) }
    @inline(never) private static func multiply(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a * b, c) }
    @inline(never) private static func divide(_ a: Double, _ b: Double, _ c: String) throws -> Double { try finite(a / b, c) }

    private static func transport(_ state: inout States, ratio: Double, square: Double, context: String) throws {
        let linear: [WritableKeyPath<States, Double>] = [\.smooth, \.detrender, \.i1, \.q1, \.jI, \.jQ, \.i2, \.q2, \.mama, \.fama]
        for key in linear { state[keyPath: key] = try divide(state[keyPath: key], ratio, context + " split linear") }
        state.re = try divide(state.re, square, context + " split re")
        state.im = try divide(state.im, square, context + " split im")
    }

    public static func signals(bars: [Bar], splits: [Date: Double], stateEligibleFrom: Date) throws -> [Signal] {
        guard !bars.isEmpty, stateEligibleFrom.timeIntervalSinceReferenceDate.isFinite,
              zip(bars, bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              splits.allSatisfy({ $0.key.timeIntervalSinceReferenceDate.isFinite && $0.value.isFinite && $0.value > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("MAMA ordered USD bars / effective splits / funding date")
        }
        let splitDates = splits.keys.sorted()
        var nextSplit = 0, priceHistory: [Double] = [], stateHistory: [States] = [], result: [Signal] = []
        var weight = 0.0
        for (ordinal, b) in bars.enumerated() {
            guard b.date.timeIntervalSinceReferenceDate.isFinite else {
                throw BacktestConfigurationError.invalidParameter("MAMA sourceOrdinal=\(ordinal) invalid source date")
            }
            let day = BacktestSeriesAlignment.historicalSeriesDateString(from: b.date)
            let context = "MAMA sourceOrdinal=\(ordinal) date=\(day)"
            guard b.date.timeIntervalSinceReferenceDate.isFinite,
                  [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 }),
                  b.high >= max(b.open, b.close), b.low <= min(b.open, b.close),
                  b.volume.isFinite, b.volume >= 0 else {
                throw BacktestConfigurationError.invalidParameter(context + " invalid complete USD OHLCV")
            }
            let previousWeight = weight, previousBeforeSplit = stateHistory.last ?? States()
            var applied: [Date] = [], splitFactor = 1.0
            while nextSplit < splitDates.count && splitDates[nextSplit] <= b.date {
                let splitDate = splitDates[nextSplit], ratio = splits[splitDate]!
                let square = try multiply(ratio, ratio, context + " split ratio squared")
                for i in priceHistory.indices { priceHistory[i] = try divide(priceHistory[i], ratio, context + " split price lag") }
                for i in stateHistory.indices { try transport(&stateHistory[i], ratio: ratio, square: square, context: context) }
                splitFactor = try multiply(splitFactor, ratio, context + " split factor")
                applied.append(splitDate); nextSplit += 1
            }
            let prior = stateHistory.last ?? States(), currentBar = ordinal - 5, computed = currentBar > 5
            let price = try divide(add(b.high, b.low, context + " midpoint sum"), 2, context + " midpoint")
            priceHistory.append(price)
            var state = States()
            if computed {
                func lag(_ key: KeyPath<States, Double>, _ amount: Int) -> Double { stateHistory[ordinal - amount][keyPath: key] }
                let smooth01 = try add(multiply(4, price, context + " smooth0"), multiply(3, priceHistory[ordinal - 1], context + " smooth1"), context + " smooth01")
                let smooth012 = try add(smooth01, multiply(2, priceHistory[ordinal - 2], context + " smooth2"), context + " smooth012")
                state.smooth = try divide(add(smooth012, priceHistory[ordinal - 3], context + " smooth0123"), 10, context + " smooth")
                let factor = try add(multiply(0.075, prior.period, context + " Hilbert period"), 0.54, context + " Hilbert factor")
                func hilbert(_ current: Double, _ key: KeyPath<States, Double>, _ label: String) throws -> Double {
                    let a = try add(multiply(0.0962, current, context + label), multiply(0.5769, lag(key, 2), context + label), context + label)
                    let b = try subtract(a, multiply(0.5769, lag(key, 4), context + label), context + label)
                    let c = try subtract(b, multiply(0.0962, lag(key, 6), context + label), context + label)
                    return try multiply(c, factor, context + label)
                }
                state.detrender = try hilbert(state.smooth, \.smooth, " detrender")
                state.q1 = try hilbert(state.detrender, \.detrender, " q1")
                state.i1 = lag(\.detrender, 3)
                state.jI = try hilbert(state.i1, \.i1, " jI")
                state.jQ = try hilbert(state.q1, \.q1, " jQ")
                state.i2 = try add(multiply(0.2, subtract(state.i1, state.jQ, context + " i2 difference"), context + " i2 current"), multiply(0.8, prior.i2, context + " i2 prior"), context + " i2")
                state.q2 = try add(multiply(0.2, add(state.q1, state.jI, context + " q2 sum"), context + " q2 current"), multiply(0.8, prior.q2, context + " q2 prior"), context + " q2")
                let rawRe = try add(multiply(state.i2, prior.i2, context + " re i2"), multiply(state.q2, prior.q2, context + " re q2"), context + " re raw")
                let rawIm = try subtract(multiply(state.i2, prior.q2, context + " im i2q2"), multiply(state.q2, prior.i2, context + " im q2i2"), context + " im raw")
                state.re = try add(multiply(0.2, rawRe, context + " re current"), multiply(0.8, prior.re, context + " re prior"), context + " re")
                state.im = try add(multiply(0.2, rawIm, context + " im current"), multiply(0.8, prior.im, context + " im prior"), context + " im")
                state.period = prior.period
                if state.im != 0 && state.re != 0 {
                    let ratio = try divide(state.im, state.re, context + " period ratio")
                    let angle = try divide(multiply(finite(atan(ratio), context + " period atan"), 180, context + " period degree product"), Double.pi, context + " period degrees")
                    state.period = try divide(360, angle, context + " period atan denominator")
                }
                let upper = try multiply(1.5, prior.period, context + " period prior cap")
                let lower = try multiply(0.67, prior.period, context + " period prior floor")
                if state.period > upper { state.period = upper }
                if state.period < lower { state.period = lower }
                if state.period < 6 { state.period = 6 }
                if state.period > 50 { state.period = 50 }
                state.period = try add(multiply(0.2, state.period, context + " period current"), multiply(0.8, prior.period, context + " period prior"), context + " period")
                state.smoothPeriod = try add(multiply(0.33, state.period, context + " smoothPeriod current"), multiply(0.67, prior.smoothPeriod, context + " smoothPeriod prior"), context + " smoothPeriod")
                state.phase = prior.phase
                if state.i1 != 0 {
                    let ratio = try divide(state.q1, state.i1, context + " phase ratio")
                    state.phase = try divide(multiply(finite(atan(ratio), context + " phase atan"), 180, context + " phase degree product"), Double.pi, context + " phase degrees")
                }
                state.deltaPhase = try subtract(prior.phase, state.phase, context + " deltaPhase")
                if state.deltaPhase < 1 { state.deltaPhase = 1 }
                state.alpha = try divide(0.5, state.deltaPhase, context + " alpha")
                if state.alpha < 0.05 { state.alpha = 0.05 }
                state.mama = try add(multiply(state.alpha, price, context + " mama current"), multiply(subtract(1, state.alpha, context + " mama beta"), prior.mama, context + " mama prior"), context + " mama")
                let halfAlpha = try multiply(0.5, state.alpha, context + " fama alpha")
                state.fama = try add(multiply(halfAlpha, state.mama, context + " fama current"), multiply(subtract(1, halfAlpha, context + " fama beta"), prior.fama, context + " fama prior"), context + " fama")
            }
            let eligible = b.date >= stateEligibleFrom, reason: String
            if !eligible { weight = 0; reason = "pre-funding-cash" }
            else if !computed { weight = 0; reason = "warmup-cash" }
            else if state.mama > state.fama { weight = 1; reason = "mama-above-fama-long" }
            else { weight = 0; reason = "mama-not-above-fama-cash" }
            // Result values are snapshots; split transport only touches the
            // separate internal histories, never an earlier emitted signal.
            result.append(.init(date: b.date, sourceDate: day, sourceOrdinal: ordinal, currentBar: currentBar,
                computed: computed, price: price, currentUSDBar: b, states: state,
                previousStates: prior, previousStatesBeforeSplit: previousBeforeSplit,
                appliedSplitDates: applied, splitFactor: splitFactor, fundingEligible: eligible,
                previousWeight: previousWeight, weight: weight, stateReason: reason,
                stateSourceDate: computed ? b.date : nil))
            stateHistory.append(state)
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
        guard !sourceCommit.isEmpty else { throw BacktestConfigurationError.invalidParameter("MAMA source commit") }
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        try validateInput(input)
        let b = try input.bars.map { row -> Bar in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: row.date) else {
                throw BacktestConfigurationError.invalidParameter("MAMA source bar date")
            }
            return Bar(date: date, open: row.open, high: row.high, low: row.low, close: row.close, volume: row.volume)
        }
        let splits = try Dictionary(uniqueKeysWithValues: input.splits.map { row -> (Date, Double) in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: row.date) else {
                throw BacktestConfigurationError.invalidParameter("MAMA source split date")
            }
            return (date, row.ratio)
        })
        let evidence = try signals(bars: b, splits: splits, stateEligibleFrom: BacktestSeriesAlignment.historicalSeriesDate(from: "2000-01-13")!)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try signalData(evidence).write(to: output, options: .withoutOverwriting)
        print("Fixed MAMA .5/.05 source: \(evidence.count) original USD bar signals; no accounts.")
    }

    private static func validateInput(_ input: Input) throws {
        guard input.schema == "fixed-mama05-005-v1", input.symbol == "QQQ", input.currency == "USD",
              input.bars.count == 6937, input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-06",
              input.splits.count == 1, input.splits[0].date == "2000-03-20", input.splits[0].ratio == 2 else {
            throw BacktestConfigurationError.invalidParameter("MAMA frozen original USD bars / effective split")
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
            buyReason: role == .candidate ? "fixed MAMA .5/.05 research" : "fixed CMF20 research")
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
            throw BacktestConfigurationError.invalidParameter("MAMA .5/.05 unchanged initial cash baseline")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].accepted = run.dailyStates[i].targetWeights["QQQ"] ?? 0
            if decisions[i].accepted != decisions[i].desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("MAMA .5/.05 prior target delivery") }
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
        guard input.schema == "fixed-mama05-005-v1", input.symbol == "QQQ", input.currency == "USD",
              input.bars.count == 6937, input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-06",
              input.splits.count == 1, input.splits[0].date == "2000-03-20", input.splits[0].ratio == 2,
              sources.schema == "fixed-mama05-005-saved-v1", !sources.files.isEmpty,
              sources.files.flatMap(\.ids) == savedControlIDs, savedControlIDs.count == 31 else {
            throw BacktestConfigurationError.invalidParameter("MAMA .5/.05 frozen input and 31 saved-control scope")
        }
        func date(_ day: String) throws -> Date {
            guard let value = BacktestSeriesAlignment.historicalSeriesDate(from: day) else {
                throw BacktestConfigurationError.invalidParameter("MAMA .5/.05 session date")
            }
            return value
        }
        let bars = try input.bars.map { b in Bar(date: try date(b.date), open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume) }
        let splits = try input.splits.map { s in BacktestShareSplit(id: "QQQ:" + s.date, symbol: "QQQ",
            effectiveDate: try date(s.date), newUnitsPerOldUnit: s.ratio) }
        let signalEvidence = try signals(bars: bars, splits: Dictionary(uniqueKeysWithValues: splits.map { ($0.effectiveDate, $0.newUnitsPerOldUnit) }), stateEligibleFrom: date("2000-01-13"))
        let dataset = try PublicBacktestCore.loadDataset(from: history, datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        guard let fx = dataset.seriesBySymbol["usd_per_cny"], fx.dates.first == "2000-01-13" else {
            throw BacktestConfigurationError.invalidParameter("MAMA .5/.05 original App FX start; no early extension")
        }
        let native = try ChaikinMoneyFlowScreen.nativePreparation(bars: bars, fxDates: fx.dates, fxPrices: fx.prices, baseline: date("2000-01-13"))
        guard native.frame.dates.last == (try date("2026-10-06")), native.frame.dates.count == 6722,
              native.frame.dates.count == input.bars.filter({ $0.date >= "2000-01-13" }).count else {
            throw BacktestConfigurationError.invalidParameter("MAMA .5/.05 every native QQQ session retained")
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
                throw BacktestConfigurationError.invalidParameter("MAMA .5/.05 saved-control file hash/rows")
            }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }),
                      selectedIDs.contains(id) == false else {
                    throw BacktestConfigurationError.invalidParameter("MAMA .5/.05 saved-control identity/state order")
                }
                selectedIDs.append(id)
                accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("MAMA .5/.05 3 new / 31 saved account budget") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("MAMA .5/.05 mechanical common calendar") }
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
            throw BacktestConfigurationError.invalidParameter("MAMA .5/.05 frozen mechanical long/all20 calendars")
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
            "evidence_class": "D0_USER_AUTHORIZED_POST_HOC_RELATED_MAMA_PHASE_CROSSOVER", "formal_validation": false,
            "recommendation_eligible": false, "source_commit": sourceCommit,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "prices_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "accounts_sha256": ResearchRunEvidence.sha256(savedRaw), "saved_source_files": sources.files.map { ["path": $0.path, "sha256": $0.sha256, "ids": $0.ids] as [String: Any] },
            "result_sha256": ResearchRunEvidence.sha256(result), "native_full_sha256": ResearchRunEvidence.sha256(nativeBytes),
            "all20_sha256": ResearchRunEvidence.sha256(allBytes), "signals_sha256": ResearchRunEvidence.sha256(signalBytes),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "candidate_count": 1, "new_funded_account_count": 3, "saved_control_count": 31, "account_count": 34,
            "parameter_search_budget": 0, "fast_limit": 0.5, "slow_limit": 0.05,
            "seed_policy": "Root MBB6/17 zero states; CurrentBar=sourceOrdinal-5; first computation source11; actual midpoint lag history retained; not platform-bitwise initialization",
            "recurrence_policy": "Frozen source-order Binary64 MAMA/FAMA; one-argument atan converted to degrees; source zero guards and sequential period limits",
            "crossover_policy": "funding-eligible computed MAMA>FAMA long; equality and below cash; no latch/epsilon",
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
            "signal_policy": "all original USD bars; latest completed strictly before opening; pre-funding cash; .5/.05 MAMA>FAMA long, equality/below cash; no reset at effective split",
            "price_units": "Input already restores historical OHLC by known split denomination; no second input adjustment; effective split transports internal price/linear-state buffers by ratio and re/im by ratio squared; previous emitted signals immutable; held units use unchanged engine split handling",
            "state_names": ["smooth", "detrender", "i1", "q1", "jI", "jQ", "i2", "q2", "re", "im", "period", "smoothPeriod", "phase", "deltaPhase", "alpha", "mama", "fama"],
            "initial_state_count": 17, "max_bars_back": 6, "first_computed_source_ordinal": 11,
            "source_pdf_sha256": "5a49f03fd2410a364a60075f11e621dbbb4984cb579242f1b7cf6ee96e842a0c",
            "pre_specification_sha256": "a15bf32092fae6c6bf1806d6e6299240acf3ced0c6424fb4eb4aec5a224c3970",
            "limitations": ["Related D0 standalone long/cash engineering adaptation of Ehlers MAMA crossover prose; appendix plots, Root initialization and split transport are disclosed; not a platform-bitwise replica, independent alpha, pristine OOS or formal certification.",
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
        print("Fixed MAMA .5/.05: 1 candidate, 3 new accounts, 31 saved controls; native \(native.frame.dates.count)/long \(longDates.count)/all20 \(allDates.count) dates.")
    }
}
