import Foundation
import AssetTimeMachineBacktestCore

/// A new, prospectively recorded signal-following paper account. It is not the
/// historical model portfolio, a broker account, or certification of G6.
public enum ForwardPaperAccount {
    public static let schema = "forward-paper-account-v1"

    public struct Contract: Codable {
        public let accountID: String
        public let registeredAt: Date
        public let strategy: StrategyReference
        public let sourceCommit: String
        public let binarySHA256: String
        public let executionVersion: String
        public let frozenParametersJSON: String
        public let parametersSHA256: String
        public let symbols: [String]
        public let initialCash: Double
        /// Percent per fill; divided by 100 exactly once at execution.
        public let commissionPercent: Double
        public let slippagePercent: Double
        public let rebalanceBand: Double
        public let signalPolicy: String
        public let valuationBasis: String
    }

    struct Signal: Codable {
        let recordedAt: Date
        let signalDate: String
        let targets: [String: Double]
        let rebalance: Bool
        let datasetSHA256: String
        let macroSHA256: String
        let snapshotSHA256: String
    }

    struct MarketLock: Codable {
        let dates: [Date]
        let prices: [String: [Double]]
        let observed: [String: [Bool]]
    }

    public struct Day: Codable {
        public let state: BacktestDailyState
        public let units: [String: Double]
        public let fullyObserved: Bool
    }

    public struct Performance: Codable {
        public let pricedSessions: Int
        public let totalReturnPercent: Double
        public let maxDrawdownPercent: Double
        public let commissionPaid: Double
        public let evidenceClass: String
    }

    public struct Journal: Codable {
        public let schemaVersion: String
        public let contract: Contract
        public let revision: Int
        public let previousSHA256: String?
        let signals: [Signal]
        let market: MarketLock?
        public let days: [Day]
        public let fills: [BacktestRecordAdvancedTradePayload]
        public let performance: Performance?
    }

    private struct Envelope: Codable { let payload: Journal; let sha256: String }
    private static func fail(_ text: String) -> BacktestConfigurationError { .invalidParameter("paper account: \(text)") }
    private static func isHash(_ text: String, count: Int = 64) -> Bool {
        text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return value
    }
    public static func digest(_ journal: Journal) throws -> String { ResearchRunEvidence.sha256(try encoder().encode(journal)) }

    public static func register(strategyID: String, sourceCommit: String, binarySHA256: String,
                                commissionPercent: Double, slippagePercent: Double,
                                now: Date = Date()) throws -> Journal {
        guard PublicBacktestCore.forwardStrategyIDs.contains(strategyID),
              isHash(sourceCommit, count: 40), isHash(binarySHA256),
              commissionPercent.isFinite, (0...100).contains(commissionPercent),
              slippagePercent.isFinite, (0..<100).contains(slippagePercent) else { throw fail("registration or costs") }
        let definition = try StrategyRegistry.definition(id: strategyID)
        let parameters = try definition.frozenParametersJSON
        let contract = Contract(accountID: "paper-v4-\(UUID().uuidString.lowercased())",
            registeredAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)), strategy: definition.reference,
            sourceCommit: sourceCommit, binarySHA256: binarySHA256,
            executionVersion: BacktestExecutionVersion.defaultEngineVersion,
            frozenParametersJSON: String(decoding: parameters, as: UTF8.self),
            parametersSHA256: ResearchRunEvidence.sha256(parameters),
            symbols: BacktestCoreStrategyDefaults.assetOptions(for: definition.template).map(\.symbol).sorted(),
            initialCash: 100_000, commissionPercent: commissionPercent, slippagePercent: slippagePercent,
            rebalanceBand: NFCIFrozenParameters.frozenV1.finalRebalanceBand,
            signalPolicy: "prospective-model-signals-next-China-calendar-date-real-quotes",
            valuationBasis: "CNY-price-index-paper-account-cash-yield-core")
        return Journal(schemaVersion: schema, contract: contract, revision: 0, previousSHA256: nil,
            signals: [], market: nil, days: [], fills: [], performance: nil)
    }

    /// Every continuation binds both the actual executable and declared source.
    public static func verifyRuntime(_ journal: Journal, sourceCommit: String, binarySHA256: String) throws {
        let definition = try StrategyRegistry.definition(reference: journal.contract.strategy)
        guard journal.schemaVersion == schema, journal.contract.sourceCommit == sourceCommit,
              journal.contract.binarySHA256 == binarySHA256,
              journal.contract.executionVersion == BacktestExecutionVersion.defaultEngineVersion,
              ResearchRunEvidence.sha256(try definition.frozenParametersJSON) == journal.contract.parametersSHA256,
              ResearchRunEvidence.sha256(Data(journal.contract.frozenParametersJSON.utf8)) == journal.contract.parametersSHA256 else {
            throw fail("runtime/rules changed; register a separate account")
        }
    }

    public static func record(_ journal: Journal, historyData: Data, macroData: Data,
                              now: Date = Date()) throws -> Journal {
        let recordedAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        let dataset = try PublicBacktestCore.loadDataset(from: historyData,
            datasetHash: ResearchRunEvidence.sha256(historyData), loadedAt: recordedAt)
        guard !dataset.dataStale else { throw fail("stale signal data") }
        // Reuse the shared strategy implementation; never copy the historical
        // model's executed holdings/cash into this fresh account.
        let snapshot = try PublicBacktestCore.forwardSnapshot(strategyID: journal.contract.strategy.id,
            dataset: dataset, nfciData: macroData, decisionAt: recordedAt)
        guard snapshot.strategyVersion == journal.contract.strategy.version,
              snapshot.dataStale == false else { throw fail("snapshot identity") }
        let changed = journal.signals.last?.targets != snapshot.desiredTargetWeights
        let signal = Signal(recordedAt: recordedAt, signalDate: snapshot.signalDate,
            targets: snapshot.desiredTargetWeights,
            rebalance: journal.signals.isEmpty || changed || snapshot.rebalanceRecommended,
            datasetSHA256: ResearchRunEvidence.sha256(historyData),
            macroSHA256: ResearchRunEvidence.sha256(macroData),
            snapshotSHA256: ResearchRunEvidence.sha256(try encoder().encode(snapshot)))
        return try append(journal, signal: signal)
    }

    static func append(_ journal: Journal, signal: Signal) throws -> Journal {
        guard signal.recordedAt >= journal.contract.registeredAt,
              journal.signals.last.map({ signal.recordedAt > $0.recordedAt && signal.signalDate > $0.signalDate }) ?? true,
              journal.days.last.map({ signal.recordedAt > $0.state.date }) ?? true,
              let cutoff = BacktestSeriesAlignment.historicalSeriesDate(from: signal.signalDate),
              cutoff < signal.recordedAt,
              Set(signal.targets.keys).isSubset(of: Set(journal.contract.symbols)),
              signal.targets.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              signal.targets.values.reduce(0, +) <= 1 + 1e-12,
              [signal.datasetSHA256, signal.macroSHA256, signal.snapshotSHA256].allSatisfy({ isHash($0) }) else {
            throw fail("backdated/duplicate signal, unknown asset or exposure")
        }
        return Journal(schemaVersion: schema, contract: journal.contract, revision: journal.revision + 1,
            previousSHA256: try digest(journal), signals: journal.signals + [signal], market: journal.market,
            days: journal.days, fills: journal.fills, performance: journal.performance)
    }

    public static func advance(_ journal: Journal, historyData: Data, now: Date = Date()) throws -> Journal {
        let dataset = try PublicBacktestCore.loadDataset(from: historyData,
            datasetHash: ResearchRunEvidence.sha256(historyData), loadedAt: now)
        let options = BacktestCoreStrategyDefaults.assetOptions(for: try StrategyRegistry.definition(reference: journal.contract.strategy).template)
        let inputs = options.map { option in MarketInputPreparation.advancedAssetInput(for: option, historyProvider: { dataset.seriesBySymbol[$0] }) }
        let config = ResearchTargetStrategyConfig(symbol: "paper", title: "Forward paper account",
            warmupSessions: 0, rebalanceSessions: 1, rebalanceBand: journal.contract.rebalanceBand,
            buyReason: "prospectively recorded paper signal")
        guard let frame = TargetProviderBacktest.researchMarketDataFrame(assetInputs: inputs, config: config),
              let cutoff = BacktestSeriesAlignment.historicalSeriesDate(from: dataset.dataCutoff) else { throw fail("missing market frame") }
        // Date-only cross-venue closes are final no earlier than next China day
        // 08:00. Never account unfinalized future bars.
        let availability = cutoff.addingTimeInterval(32 * 3600)
        guard availability <= now else { throw fail("market cutoff not yet available") }
        guard let end = frame.dates.lastIndex(where: { $0 <= cutoff }) else { throw fail("empty finalized market prefix") }
        let lock = MarketLock(dates: Array(frame.dates.prefix(end + 1)),
            prices: frame.pricesBySymbol.mapValues { Array($0.prefix(end + 1)) },
            observed: frame.observedBySymbol.mapValues { Array($0.prefix(end + 1)) })
        if let old = journal.market {
            guard lock.dates.count >= old.dates.count, Array(lock.dates.prefix(old.dates.count)) == old.dates,
                  old.prices.allSatisfy({ key, prices in lock.prices[key].map { Array($0.prefix(prices.count)) == prices } ?? false }),
                  old.observed.allSatisfy({ key, observed in lock.observed[key].map { Array($0.prefix(observed.count)) == observed } ?? false }) else {
                throw fail("historical market prefix changed; preserve the old account and investigate")
            }
        }
        guard let start = frame.dates.firstIndex(where: { $0 > journal.contract.registeredAt }),
              start <= end else { throw fail("no finalized post-registration session") }
        return try account(journal, frame: frame, range: start...end, lock: lock)
    }

    static func account(_ journal: Journal, frame: MarketDataFrame, range: ClosedRange<Int>, lock: MarketLock? = nil) throws -> Journal {
        guard range.lowerBound > 0, range.upperBound < frame.dates.count,
              frame.dates[range.lowerBound] > journal.contract.registeredAt else { throw fail("account range") }
        // Eligibility uses actual recording time, not a historical execution hint.
        // Multiple decisions before a market reopening collapse to the last one.
        var events: [Int: Signal] = [:]
        var rebalanceIndices: Set<Int> = []
        for signal in journal.signals {
            if let index = range.first(where: { frame.dates[$0] > signal.recordedAt }) {
                events[index] = signal
                if signal.rebalance { rebalanceIndices.insert(index) }
            }
        }
        let execution = BacktestExecutionConfig(initialCash: journal.contract.initialCash,
            feeRate: journal.contract.commissionPercent / 100, slippageRate: journal.contract.slippagePercent / 100,
            rebalanceBand: journal.contract.rebalanceBand, financingAnnualRate: 0,
            allowsFinancedExposure: false, buyReason: "prospectively recorded paper signal")
        let scoped = MarketDataFrame(dates: frame.dates, pricesBySymbol: frame.pricesBySymbol,
            observedBySymbol: frame.observedBySymbol, ohlcBySymbol: frame.ohlcBySymbol,
            tradableSymbols: frame.tradableSymbols, optionBySymbol: frame.optionBySymbol, simulationRange: range)
        guard let result = BacktestDailySimulator.run(frame: scoped, execution: execution,
            provider: StrategyTargetProvider { events[$0.index]?.targets ?? [:] },
            rebalanceDecision: { index, _ in .init(shouldRebalance: rebalanceIndices.contains(index), refreshOverlay: false) }) else { throw fail("cancelled or failed accounting") }
        var peak = journal.contract.initialCash
        var drawdown = 0.0
        let indexByDate = Dictionary(uniqueKeysWithValues: frame.dates.enumerated().map { ($0.element, $0.offset) })
        let days = try result.dailyStates.map { state -> Day in
            let total = state.cash + state.holdingsBySymbol.values.reduce(0, +)
            guard state.portfolioValue.isFinite, state.portfolioValue > 0, state.cash >= -1e-8,
                  abs(total - state.portfolioValue) <= max(1e-8, abs(total) * 1e-12),
                  state.targetWeights.values.reduce(0, +) <= 1 + 1e-12 else { throw fail("accounting identity") }
            peak = max(peak, state.portfolioValue)
            drawdown = max(drawdown, (peak - state.portfolioValue) / peak)
            let index = indexByDate[state.date]!
            var units: [String: Double] = [:]
            for (symbol, value) in state.holdingsBySymbol {
                guard let price = frame.pricesBySymbol[symbol]?[index], price > 0 else { throw fail("unpriced holding") }
                units[symbol] = value / price
            }
            return Day(state: state, units: units,
                fullyObserved: journal.contract.symbols.allSatisfy { frame.observedBySymbol[$0]?[index] == true })
        }
        let fills = result.trades.enumerated().map { BacktestRecordAdvancedTradePayload(trade: $0.element, sequence: $0.offset) }
        guard days.count >= journal.days.count,
              try encoder().encode(Array(days.prefix(journal.days.count))) == encoder().encode(journal.days),
              fills.count >= journal.fills.count,
              try encoder().encode(Array(fills.prefix(journal.fills.count))) == encoder().encode(journal.fills) else {
            throw fail("previous NAV/fills changed")
        }
        for trade in result.trades {
            guard let index = indexByDate[trade.date], frame.observedBySymbol[trade.assetSymbol]?[index] == true else { throw fail("fill without a real quote") }
        }
        let fees = result.trades.reduce(0) { $0 + abs($1.cashAmount - $1.units * $1.price) }
        let performance = Performance(pricedSessions: days.filter(\.fullyObserved).count,
            totalReturnPercent: ((days.last!.state.portfolioValue / journal.contract.initialCash) - 1) * 100,
            maxDrawdownPercent: drawdown * 100, commissionPaid: fees, evidenceClass: "ENGINEERING_PAPER_FORWARD")
        return Journal(schemaVersion: schema, contract: journal.contract, revision: journal.revision + 1,
            previousSHA256: try digest(journal), signals: journal.signals, market: lock ?? journal.market,
            days: days, fills: fills, performance: performance)
    }

    public static func read(_ url: URL) throws -> Journal {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.payload.schemaVersion == schema, try digest(envelope.payload) == envelope.sha256 else { throw fail("journal digest mismatch") }
        return envelope.payload
    }

    public static func write(_ journal: Journal, to directory: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".paper-\(UUID().uuidString)")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let envelope = Envelope(payload: journal, sha256: try digest(journal))
        try encoder().encode(envelope).write(to: temporary.appendingPathComponent("account.json"), options: .withoutOverwriting)
        try manager.moveItem(at: temporary, to: directory)
    }
}
