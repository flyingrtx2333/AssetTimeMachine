import Foundation
import AssetTimeMachineBacktestCore

/// One frozen CMF20 > 0 QQQ long/cash rule. Research only; no parameter search.
public enum ChaikinMoneyFlowScreen {
    public static let candidateID = "cmf20-qqq-long-cash"
    public static let buyHoldID = "QQQ:buy-hold-native2000"
    public static let cashID = "cny-cash-qqq-native2000"
    public static let qualID = "nfci-dual-core-v11-qual-role"

    /// OHLC is already in the historical share denomination. Volume is unchanged
    /// from the vendor input; this command never applies a second price adjustment.
    public struct Bar: Codable, Equatable {
        public let date: Date
        public let open: Double
        public let high: Double
        public let low: Double
        public let close: Double
        public let volume: Double
        public init(date: Date, open: Double, high: Double, low: Double, close: Double, volume: Double) {
            self.date = date; self.open = open; self.high = high; self.low = low
            self.close = close; self.volume = volume
        }
    }
    public struct Signal: Encodable, Equatable {
        public let date: Date
        public let open: Double
        public let high: Double
        public let low: Double
        public let close: Double
        public let volume: Double
        public let moneyFlowMultiplier: Double
        public let moneyFlowVolume: Double
        public let windowCount: Int
        public let epoch: Int
        public let epochStartDate: Date
        public let windowStartDate: Date?
        public let splitReset: Bool
        public let appliedSplitDates: [Date]
        public let sumMoneyFlowVolume: Double
        public let sumVolume: Double
        public let cmf20: Double?
        public let weight: Double

        enum CodingKeys: String, CodingKey {
            case date, open, high, low, close, volume, moneyFlowMultiplier, moneyFlowVolume
            case windowCount, epoch, epochStartDate, windowStartDate, splitReset, appliedSplitDates
            case sumMoneyFlowVolume, sumVolume, cmf20, weight
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date); try c.encode(open, forKey: .open)
            try c.encode(high, forKey: .high); try c.encode(low, forKey: .low)
            try c.encode(close, forKey: .close); try c.encode(volume, forKey: .volume)
            try c.encode(moneyFlowMultiplier, forKey: .moneyFlowMultiplier)
            try c.encode(moneyFlowVolume, forKey: .moneyFlowVolume)
            try c.encode(windowCount, forKey: .windowCount); try c.encode(epoch, forKey: .epoch)
            try c.encode(epochStartDate, forKey: .epochStartDate)
            try c.encode(windowStartDate, forKey: .windowStartDate)
            try c.encode(splitReset, forKey: .splitReset); try c.encode(appliedSplitDates, forKey: .appliedSplitDates)
            try c.encode(sumMoneyFlowVolume, forKey: .sumMoneyFlowVolume)
            try c.encode(sumVolume, forKey: .sumVolume); try c.encode(cmf20, forKey: .cmf20)
            try c.encode(weight, forKey: .weight)
        }
    }

    private static func validate(_ bars: [Bar]) throws {
        guard !bars.isEmpty, zip(bars, bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              bars.allSatisfy({ b in
                  b.date.timeIntervalSinceReferenceDate.isFinite
                      && [b.open, b.high, b.low, b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                      && b.high >= max(b.open, b.close) && b.low <= min(b.open, b.close)
                      && b.volume.isFinite && b.volume >= 0
              }) else { throw BacktestConfigurationError.invalidParameter("CMF20 complete ordered USD OHLCV") }
    }

    /// Splits reset the window only after they are effective. Every defined window
    /// contains twenty completed bars from one split epoch, so an unknown positive
    /// constant volume adjustment within that epoch cancels in the ratio.
    public static func signals(bars: [Bar], splits: [Date: Double]) throws -> [Signal] {
        try validate(bars)
        guard splits.allSatisfy({ $0.key.timeIntervalSinceReferenceDate.isFinite && $0.value.isFinite && $0.value > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("CMF20 effective split events")
        }
        let splitDates = splits.keys.sorted()
        var nextSplit = 0, epoch = 0, epochStart = bars[0].date
        var window: [(date: Date, flow: Double, volume: Double)] = []
        var result: [Signal] = []
        for b in bars {
            var applied: [Date] = []
            while nextSplit < splitDates.count && splitDates[nextSplit] <= b.date {
                applied.append(splitDates[nextSplit]); nextSplit += 1
            }
            if !applied.isEmpty { window.removeAll(keepingCapacity: true); epoch += applied.count; epochStart = b.date }
            let multiplier = b.high == b.low ? 0 : (2 * b.close - b.high - b.low) / (b.high - b.low)
            let flow = multiplier * b.volume
            window.append((b.date, flow, b.volume))
            if window.count > 20 { window.removeFirst() }
            // Sum the bounded window directly: no cancellation residue from rolling subtraction.
            let sumFlow = window.reduce(0) { $0 + $1.flow }, sumVolume = window.reduce(0) { $0 + $1.volume }
            guard multiplier.isFinite, flow.isFinite, sumFlow.isFinite, sumVolume.isFinite else {
                throw BacktestConfigurationError.invalidParameter("CMF20 finite sums")
            }
            let cmf = window.count == 20 && sumVolume > 0 ? sumFlow / sumVolume : nil
            result.append(.init(date: b.date, open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume,
                moneyFlowMultiplier: multiplier, moneyFlowVolume: flow, windowCount: window.count,
                epoch: epoch, epochStartDate: epochStart, windowStartDate: window.first?.date,
                splitReset: !applied.isEmpty, appliedSplitDates: applied, sumMoneyFlowVolume: sumFlow,
                sumVolume: sumVolume, cmf20: cmf, weight: cmf.map { $0 > 0 ? 1 : 0 } ?? 0))
        }
        return result
    }

    /// USD observations are not sliced to the CNY funding calendar; same-day bars
    /// are excluded even if a preceding completed USD bar was not executable in CNY.
    public static func latestSignal(_ signals: [Signal], before date: Date) -> Signal? {
        var low = 0, high = signals.count
        while low < high {
            let mid = (low + high) / 2
            if signals[mid].date < date { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? signals[low - 1] : nil
    }

    public struct FXObservation: Equatable {
        public let date: Date
        public let usdPerCNY: Double
    }
    private static func validateFX(dates: [String], prices: [Double]) throws {
        guard !dates.isEmpty, dates.count == prices.count,
              zip(dates, dates.dropFirst()).allSatisfy({ $0 < $1 }),
              dates.allSatisfy({ BacktestSeriesAlignment.historicalSeriesDate(from: $0) != nil }),
              prices.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("CMF20 original FX observations")
        }
    }
    private static func strictPriorFX(dates: [String], prices: [Double], asOf: Date) throws -> FXObservation {
        let day = BacktestSeriesAlignment.historicalSeriesDateString(from: asOf)
        var low = 0, high = dates.count
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < day { low = mid + 1 } else { high = mid }
        }
        guard low > 0, let prior = BacktestSeriesAlignment.historicalSeriesDate(from: dates[low - 1]),
              asOf > prior, asOf.timeIntervalSince(prior) <= 14 * 86400 else {
            throw BacktestConfigurationError.missingData("CMF20 strictly prior FX " + day)
        }
        return .init(date: prior, usdPerCNY: prices[low - 1])
    }
    public static func priorFX(dates: [String], prices: [Double], asOf: Date) throws -> FXObservation {
        try validateFX(dates: dates, prices: prices)
        return try strictPriorFX(dates: dates, prices: prices, asOf: asOf)
    }

    public struct Quote: Encodable {
        public let date: Date
        public let sourceUSDDate: Date
        public let fxDate: Date?
        public let usdPerCNY: Double?
        public let cnyPerUSD: Double?
        public let openUSD: Double
        public let highUSD: Double
        public let lowUSD: Double
        public let closeUSD: Double
        public let openCNY: Double
        public let highCNY: Double
        public let lowCNY: Double
        public let closeCNY: Double
        public let observed: Bool
    }
    public struct NativePreparation {
        public let frame: MarketDataFrame
        public let opens: [Double]
        public let quotes: [Quote]
    }
    /// Retain the original first App FX date as the cash baseline. Its unavailable
    /// mark/auction is zero; every subsequent QQQ session must have strict-prior FX.
    public static func nativePreparation(bars: [Bar], fxDates: [String], fxPrices: [Double], baseline: Date) throws -> NativePreparation {
        try validate(bars); try validateFX(dates: fxDates, prices: fxPrices)
        let nativeBars = bars.filter { $0.date >= baseline }
        guard nativeBars.first?.date == baseline else { throw BacktestConfigurationError.missingData("CMF20 cash baseline QQQ session") }
        let quotes = try nativeBars.enumerated().map { index, b -> Quote in
            let fx = index == 0 ? nil : try strictPriorFX(dates: fxDates, prices: fxPrices, asOf: b.date)
            let factor = fx.map { 1 / $0.usdPerCNY } ?? 0
            return .init(date: b.date, sourceUSDDate: b.date, fxDate: fx?.date, usdPerCNY: fx?.usdPerCNY,
                cnyPerUSD: fx.map { 1 / $0.usdPerCNY }, openUSD: b.open, highUSD: b.high, lowUSD: b.low,
                closeUSD: b.close, openCNY: b.open * factor, highCNY: b.high * factor,
                lowCNY: b.low * factor, closeCNY: b.close * factor, observed: index > 0)
        }
        let option = BacktestInstrument(symbol: "QQQ", title: "QQQ fixed CMF20 price-only research", requiresHistoricalFX: false, historicalFXSymbol: nil)
        let frame = MarketDataFrame(dates: quotes.map(\.date), pricesBySymbol: ["QQQ": quotes.map(\.closeCNY)],
            observedBySymbol: ["QQQ": quotes.map(\.observed)], ohlcBySymbol: [:], tradableSymbols: ["QQQ"],
            optionBySymbol: ["QQQ": option], simulationRange: 0...(quotes.count - 1))
        return .init(frame: frame, opens: quotes.map(\.openCNY), quotes: quotes)
    }

    public enum Role: String { case candidate, buyHold, cash }
    public struct Decision: Encodable {
        public let index: Int
        public let date: Date
        public let signalDate: Date
        public let latestUSDBarDate: Date?
        public let desired: Double
        public let previousSubmitted: Double?
        public let submitted: Double?
        public let shouldRebalance: Bool
        public internal(set) var accepted: Double
    }
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
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "fixed CMF20 research")
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
            throw BacktestConfigurationError.invalidParameter("CMF20 unchanged initial cash baseline")
        }
        var mismatches = 0
        for i in decisions.indices {
            decisions[i].accepted = run.dailyStates[i].targetWeights["QQQ"] ?? 0
            if decisions[i].accepted != decisions[i].desired { mismatches += 1 }
        }
        guard mismatches == 0 else { throw BacktestConfigurationError.invalidParameter("CMF20 prior target delivery") }
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
    public static var savedControlIDs: [String] {
        ["nasdaq:buy-hold-native2000", "cny-cash-native2000"]
            + ["gold_cny", "nasdaq"].flatMap { symbol in
                (CloseIndicatorScreen.Rule.allCases.map(\.rawValue) + ["buy-hold"]).map { symbol + ":" + $0 }
            } + ["cny-cash-diagnostic"]
            + BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs + [qualID]
    }

    public static func run(pricesPath: String, historyPath: String, accountsPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let savedRaw = try Data(contentsOf: URL(fileURLWithPath: accountsPath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        let sources = try JSONDecoder().decode(Sources.self, from: savedRaw)
        guard input.schema == "fixed-cmf20-v1", input.symbol == "QQQ", input.currency == "USD",
              input.bars.count == 6937, input.bars.first?.date == "1999-03-10", input.bars.last?.date == "2026-10-06",
              input.splits.count == 1, input.splits[0].date == "2000-03-20", input.splits[0].ratio == 2,
              sources.schema == "fixed-cmf20-saved-v1", !sources.files.isEmpty,
              sources.files.flatMap(\.ids) == savedControlIDs, savedControlIDs.count == 31 else {
            throw BacktestConfigurationError.invalidParameter("CMF20 frozen input and 31 saved-control scope")
        }
        func date(_ day: String) throws -> Date {
            guard let value = BacktestSeriesAlignment.historicalSeriesDate(from: day) else {
                throw BacktestConfigurationError.invalidParameter("CMF20 session date")
            }
            return value
        }
        let bars = try input.bars.map { b in Bar(date: try date(b.date), open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume) }
        let splits = try input.splits.map { s in BacktestShareSplit(id: "QQQ:" + s.date, symbol: "QQQ",
            effectiveDate: try date(s.date), newUnitsPerOldUnit: s.ratio) }
        let signalEvidence = try signals(bars: bars, splits: Dictionary(uniqueKeysWithValues: splits.map { ($0.effectiveDate, $0.newUnitsPerOldUnit) }))
        let dataset = try PublicBacktestCore.loadDataset(from: history, datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        guard let fx = dataset.seriesBySymbol["usd_per_cny"], fx.dates.first == "2000-01-13" else {
            throw BacktestConfigurationError.invalidParameter("CMF20 original App FX start; no early extension")
        }
        let native = try nativePreparation(bars: bars, fxDates: fx.dates, fxPrices: fx.prices, baseline: date("2000-01-13"))
        guard native.frame.dates.last == (try date("2026-10-06")), native.frame.dates.count == 6722,
              native.frame.dates.count == input.bars.filter({ $0.date >= "2000-01-13" }).count else {
            throw BacktestConfigurationError.invalidParameter("CMF20 every native QQQ session retained")
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
                throw BacktestConfigurationError.invalidParameter("CMF20 saved-control file hash/rows")
            }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }),
                      selectedIDs.contains(id) == false else {
                    throw BacktestConfigurationError.invalidParameter("CMF20 saved-control identity/state order")
                }
                selectedIDs.append(id)
                accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("CMF20 3 new / 31 saved account budget") }
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
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("CMF20 mechanical common calendar") }
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
            throw BacktestConfigurationError.invalidParameter("CMF20 frozen mechanical long/all20 calendars")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(DailyScreenOutput.row(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        let result = try JSONSerialization.data(withJSONObject: longRows, options: [.sortedKeys])
        let nativeBytes = try JSONSerialization.data(withJSONObject: nativeRows, options: [.sortedKeys])
        let allBytes = try JSONSerialization.data(withJSONObject: allRows, options: [.sortedKeys])
        let signalBytes = try encoder.encode(signalEvidence)
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
            "evidence_class": "D0_USER_AUTHORIZED_POST_HOC_RELATED_CMF20_SPLIT_EPOCH_GUARD", "formal_validation": false,
            "recommendation_eligible": false, "source_commit": sourceCommit,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "prices_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": ResearchRunEvidence.sha256(history),
            "accounts_sha256": ResearchRunEvidence.sha256(savedRaw), "saved_source_files": sources.files.map { ["path": $0.path, "sha256": $0.sha256, "ids": $0.ids] as [String: Any] },
            "result_sha256": ResearchRunEvidence.sha256(result), "native_full_sha256": ResearchRunEvidence.sha256(nativeBytes),
            "all20_sha256": ResearchRunEvidence.sha256(allBytes), "signals_sha256": ResearchRunEvidence.sha256(signalBytes),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "candidate_count": 1, "new_funded_account_count": 3, "saved_control_count": 31, "account_count": 34,
            "parameter_search_budget": 0, "source_bar_count": bars.count, "native_state_count": native.frame.dates.count,
            "native_start": text(native.frame.dates.first!), "native_end": text(native.frame.dates.last!),
            "primary_metric": "App native-full daily NAV Sharpe Rf=0; long-common19 is an additional required comparison gate",
            "common_history_is_primary_user_choice": false,
            "primary": ["metric": "App full-history raw-return Sharpe Rf0", "threshold": 1.2,
                "require_native_full": true, "require_long_common19_sharpe_at_least_1_2": true,
                "require_beat_strongest19": true, "all20_supplement_only": true] as [String: Any],
            "strongest19_control_ids": BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs,
            "long_common_dates": longDates.map(text), "all20_common_dates": allDates.map(text),
            "long_comparison_count": longRows.count, "all20_comparison_count": allRows.count,
            "long_excluded_id": qualID, "saved_control_ids": selectedIDs, "target_audits": targetAudits,
            "fee_rate": 0.00025, "slippage_rate": 0, "cash": "CashYieldCNY",
            "fx_policy": "unchanged App FX / strictly prior calendar date / max14 calendar days / same factor OHLC",
            "cash_baseline_policy": "2000-01-13 cash100000; zero unavailable QQQ mark and auction; no target or trade",
            "signal_policy": "all original USD bars; latest strictly before execution; CMF20>0; split-epoch restart before effective bar;19 cash warmup bars",
            "price_units": "Input already restores historical OHLC by known split denomination; command does not adjust prices again; shared engine adjusts held units on effective split date",
            "volume_policy": "original source volume; raw versus split-adjusted convention unknown; positive epoch constants cancel after mandatory restart",
            "limitations": ["Price-only D0 related mechanism screen, not independent alpha, pristine OOS or formal G0-G6 certification.",
                "No dividends, tax, FX conversion fees or separate USD-wallet certification; historical quotes are not complete quote-vintage certification.",
                "Full native history retains the initial unavailable-mark cash baseline; common-calendar comparisons are mechanical supplements.",
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
        print("Fixed CMF20: 1 candidate, 3 new accounts, 31 saved controls; native \(native.frame.dates.count)/long \(longDates.count)/all20 \(allDates.count) dates.")
    }
}
