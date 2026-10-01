import Foundation

public struct StrategyReference: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

public struct StrategyDataRequirements: Codable, Equatable, Sendable {
    public let priceSymbols: [String]
    public let fxSymbols: [String]
    public let requiresNFCIAsOf: Bool
}

/// Catalog entry containing no UI, storage, network client, or mutable strategy state.
public struct StrategyDefinition: Sendable {
    public let reference: StrategyReference
    public let template: AdvancedBacktestStrategyTemplate
    public let dataRequirements: StrategyDataRequirements

    public var frozenParametersJSON: Data {
        get throws { try StrategyRegistry.parameterSnapshots[reference]!.get() }
    }

    fileprivate func encodeFrozenParameters() throws -> Data {
        try BacktestRunScope.$parameters.withValue(.frozen) {
            try BacktestText.$context.withValue(.init()) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let rotation = RotationParameters.advancedRotationConfig(for: template.mode)
                let snapshot = FrozenParameterSnapshot(
                    reference: reference,
                    researchDefaults: BacktestResearchParameterDefaults.frozenV1,
                    components: AdvancedBacktestStrategyMode.allCases.reduce(into: [String: RotationParameters.AdvancedRotationConfig]()) { result, mode in
                        result[mode.rawValue] = RotationParameters.advancedRotationConfig(for: mode)
                    },
                    mode: template.mode,
                    selectedAssetSymbols: template.selectedAssetSymbols,
                    buyRule: template.buyRule, sellRule: template.sellRule,
                    tradeAmountRatio: template.tradeAmountRatio,
                    settings: defaultSettings,
                    rotation: rotation,
                    barbell: template.mode == .goldNasdaqDualTrendBarbell ? .frozenV1 : nil,
                    nfci: template.mode.requiresNFCIAsOf ? .frozenV1 : nil,
                    reallocation: ["stable": .stable, "growth": .growth,
                                   "recoveryStable": .recoveryStable, "recoveryGrowth": .recoveryGrowth],
                    recoveryQuality: .cashConfidenceAdaptive,
                    cashConfidence: [.riskContributionCashConfidenceLowNoise,
                                     .riskContributionCashConfidenceRouter, .nfciDualCoreV1,
                                     .nfciDualCoreSimplifiedV11, .nfciDualCoreSimplifiedV11QualRole]
                        .contains(template.mode) ? .frozenV1 : nil)
                // Sets encode in arbitrary order. Canonicalize only their named fields;
                // ordered asset arrays keep the original execution ordering.
                let object = try JSONSerialization.jsonObject(with: encoder.encode(snapshot))
                return try JSONSerialization.data(withJSONObject: canonicalSets(object), options: [.sortedKeys, .withoutEscapingSlashes])
            }
        }
    }

    public var defaultSettings: AdvancedBacktestRiskSettings {
        .init(feeRate: template.mode.defaultFeeRatePercent,
              slippageRate: template.mode.defaultSlippageRatePercent,
              maxPositionRatio: template.maxPositionRatio, cooldownDays: template.cooldownDays,
              stopLossRatio: template.stopLossRatio, takeProfitRatio: template.takeProfitRatio)
    }

    /// Creates a runner with no shared holdings, targets, online calibration, or macro store.
    public func makeRunner() -> BacktestStrategyRunner { .init(definition: self) }

    public func run(input: BacktestRunInput, configuration: BacktestRunConfiguration) throws -> BacktestRunResult {
        guard configuration.strategy == reference else {
            throw BacktestConfigurationError.unknownVersion(configuration.strategy.version)
        }
        try configuration.parameters.validate()
        if configuration.purpose == .product && configuration.parameters.hasOverrides {
            throw BacktestConfigurationError.researchOverrideOnProduct
        }
        guard configuration.initialCash.isFinite, configuration.initialCash > 0,
              configuration.settings.feeRate.isFinite, configuration.settings.feeRate >= 0,
              configuration.settings.slippageRate.isFinite, configuration.settings.slippageRate >= 0 else {
            throw BacktestConfigurationError.invalidParameter("cash or execution costs")
        }
        let risk = configuration.settings
        // Existing leveraged catalog entries freeze ratios above 100. The new
        // configuration boundary must permit their unchanged default settings.
        let maximumPositionRatio = max(100, template.maxPositionRatio)
        guard risk.maxPositionRatio.isFinite, risk.maxPositionRatio > 0, risk.maxPositionRatio <= maximumPositionRatio,
              risk.stopLossRatio.isFinite, risk.stopLossRatio >= 0,
              risk.takeProfitRatio.isFinite, risk.takeProfitRatio >= 0, risk.cooldownDays >= 0 else {
            throw BacktestConfigurationError.invalidParameter("risk settings")
        }
        for symbol in dataRequirements.priceSymbols + dataRequirements.fxSymbols {
            guard let series = input.seriesBySymbol[symbol], !series.dates.isEmpty else {
                throw BacktestConfigurationError.missingData(symbol)
            }
        }
        if dataRequirements.requiresNFCIAsOf && input.nfciAsOf == nil {
            throw BacktestConfigurationError.missingData("NFCI as-of snapshot")
        }
        if let range = configuration.evaluationRange, range.startDate > range.endDate {
            throw BacktestConfigurationError.invalidParameter("evaluationRange")
        }
        let parameters = configuration.purpose == .product ? .frozen : configuration.parameters
        let observedSeries = try input.observedSeries()
        return try BacktestRunScope.$parameters.withValue(parameters) {
            if Task.isCancelled { throw CancellationError() }
            let options = BacktestCoreStrategyDefaults.assetOptions(for: template)
            let inputs = options.map { MarketInputPreparation.advancedAssetInput(for: $0) { observedSeries[$0] } }
            // Replay from the earliest available row. A range ending before the
            // first row is an input error, never a reversed ClosedRange trap.
            let simulationBounds: ClosedRange<Date>?
            if let range = configuration.evaluationRange {
                let start = MarketInputPreparation.availableDateBounds(for: inputs.flatMap {
                    [$0.assetSeries, $0.fxSeries].compactMap { $0 }
                })?.lowerBound ?? range.startDate
                guard start <= range.endDate else { throw BacktestConfigurationError.missingData("evaluationRange") }
                simulationBounds = start...range.endDate
            } else { simulationBounds = nil }
            let report: AdvancedBacktestReport
            let states: [BacktestDailyState]
            if template.mode.isRotation {
                guard let run = StrategyRuntimeRegistry.run(mode: template.mode, input: .init(
                    assetInputs: inputs, initialCash: configuration.initialCash,
                    settings: configuration.settings, nfciAsOf: input.nfciAsOf,
                    dateBounds: simulationBounds)) else {
                    if Task.isCancelled { throw CancellationError() }
                    throw BacktestConfigurationError.computationFailed
                }
                if let range = configuration.evaluationRange {
                    guard let sliced = BacktestReportBuilder.statefulAdvancedReport(from: run.report,
                        dailyStates: run.dailyStates, within: range.startDate...range.endDate,
                        rebasedTo: configuration.initialCash) else { throw BacktestConfigurationError.computationFailed }
                    report = sliced
                    guard let first = run.report.points.first(where: { $0.date >= range.startDate && $0.date <= range.endDate }),
                          first.portfolioValue > 0 else { throw BacktestConfigurationError.computationFailed }
                    let scale = configuration.initialCash / first.portfolioValue
                    states = run.dailyStates.filter { $0.date >= range.startDate && $0.date <= range.endDate }.map {
                        BacktestDailyState(date: $0.date, targetWeights: $0.targetWeights,
                            cash: $0.cash * scale, holdingsBySymbol: $0.holdingsBySymbol.mapValues { $0 * scale },
                            portfolioValue: $0.portfolioValue * scale)
                    }
                } else {
                    report = run.report
                    states = run.dailyStates
                }
            } else {
                var trace: [BacktestDailyState] = []
                let boundedInputs = simulationBounds.map {
                    MarketInputPreparation.filteredAdvancedAssetInputs(inputs, within: $0)
                } ?? inputs
                guard let result = RuleBasedStrategy.runAdvancedStrategies(assetInputs: boundedInputs,
                    initialCash: configuration.initialCash,
                    tradeAmount: configuration.initialCash * template.tradeAmountRatio,
                    buyRule: template.buyRule, sellRule: template.sellRule,
                    settings: configuration.settings, onDailyState: { trace.append($0) }) else {
                    if Task.isCancelled { throw CancellationError() }
                    throw BacktestConfigurationError.computationFailed
                }
                if let range = configuration.evaluationRange {
                    guard let sliced = BacktestReportBuilder.statefulAdvancedReport(from: result,
                        dailyStates: trace, within: range.startDate...range.endDate,
                        rebasedTo: configuration.initialCash),
                        let first = trace.first(where: { $0.date >= range.startDate && $0.date <= range.endDate }),
                        first.portfolioValue > 0 else { throw BacktestConfigurationError.computationFailed }
                    let scale = configuration.initialCash / first.portfolioValue
                    report = sliced
                    states = trace.filter { $0.date >= range.startDate && $0.date <= range.endDate }.map {
                        .init(date: $0.date, targetWeights: $0.targetWeights, cash: $0.cash * scale,
                              holdingsBySymbol: $0.holdingsBySymbol.mapValues { $0 * scale },
                              portfolioValue: $0.portfolioValue * scale)
                    }
                } else { report = result; states = trace }
            }
            if Task.isCancelled { throw CancellationError() }
            return BacktestRunResult(report: report, dailyStates: states,
                provenance: .init(strategy: reference, executionVersion: BacktestExecutionVersion.defaultEngineVersion,
                    sourceCommit: input.sourceCommit ?? "unknown", datasetHash: input.datasetHash ?? "unknown",
                    macroHash: input.macroHash, configuration: configuration,
                    frozenParametersJSON: try frozenParametersJSON))
        }
    }
}

public struct BacktestStrategyRunner: Sendable {
    private let definition: StrategyDefinition
    fileprivate init(definition: StrategyDefinition) { self.definition = definition }
    public func run(input: BacktestRunInput, configuration: BacktestRunConfiguration) throws -> BacktestRunResult {
        try definition.run(input: input, configuration: configuration)
    }
}

public enum StrategyRegistry {
    /// Unnamed implementations receive a source snapshot version, not a validation claim.
    public static let legacyRulesVersion = "rules-d801a9bb"
    public static let definitions: [StrategyDefinition] = {
        let catalog = AdvancedBacktestStrategyTemplate.all
        let represented = Set(catalog.map(\.mode))
        let internalModes = AdvancedBacktestStrategyMode.allCases.filter { !represented.contains($0) }.map { mode in
            AdvancedBacktestStrategyTemplate(id: "legacy-mode:\(mode.rawValue)", mode: mode,
                selectedAssetSymbols: nil,
                categoryLocalizationKey: "研究兼容模式", titleLocalizationKey: mode.title,
                annualizedReturn: 0, maxDrawdown: 0, sharpeRatio: 0,
                buyRule: .init(direction: .alwaysBuy, days: 1), sellRule: .init(direction: .neverSell, days: 1),
                tradeAmountRatio: 1, maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)
        }
        return (catalog + internalModes).map { template in
        let version: String
        switch template.id {
        case "nfci-dual-core-v1": version = "dualcore-v1-2026-08-14"
        case "nfci-dual-core-v11": version = "dualcore-v11-2026-08-15"
        default: version = legacyRulesVersion
        }
        let options = BacktestCoreStrategyDefaults.assetOptions(for: template)
        return .init(reference: .init(id: template.id, version: version), template: template,
            dataRequirements: .init(priceSymbols: options.map(\.symbol).filter { $0 != "usd_cash" },
                fxSymbols: Array(Set(options.compactMap(\.historicalFXSymbol) + (options.contains { $0.symbol == "usd_cash" } ? ["usd_per_cny"] : []))).sorted(),
                requiresNFCIAsOf: template.mode.requiresNFCIAsOf))
        }
    }()

    // Immutable snapshots are encoded once. Repeated advice and cache lookups
    // cannot rebuild every component's configuration on the UI/background path.
    fileprivate static let parameterSnapshots: [StrategyReference: Result<Data, Error>] =
        Dictionary(uniqueKeysWithValues: definitions.map { definition in
            (definition.reference, Result { try definition.encodeFrozenParameters() })
        })

    public static func definition(id: String) throws -> StrategyDefinition {
        guard let definition = definitions.first(where: { $0.reference.id == id }) else {
            throw BacktestConfigurationError.unknownStrategy(id)
        }
        return definition
    }

    public static func definition(reference: StrategyReference) throws -> StrategyDefinition {
        let definition = try definition(id: reference.id)
        guard definition.reference.version == reference.version else {
            throw BacktestConfigurationError.unknownVersion(reference.version)
        }
        return definition
    }
}

public struct BacktestRunRange: Codable, Equatable, Sendable {
    public let startDate: Date
    public let endDate: Date
    public init(startDate: Date, endDate: Date) { self.startDate = startDate; self.endDate = endDate }
}

public struct BacktestRunConfiguration: Codable, Sendable {
    public enum Purpose: String, Codable, Sendable { case product, research }
    public let strategy: StrategyReference
    public let purpose: Purpose
    public let initialCash: Double
    public let settings: AdvancedBacktestRiskSettings
    public let evaluationRange: BacktestRunRange?
    public let parameters: BacktestResearchParameters

    public init(strategy: StrategyReference, purpose: Purpose = .product, initialCash: Double = 100_000,
                settings: AdvancedBacktestRiskSettings, evaluationRange: BacktestRunRange? = nil,
                parameters: BacktestResearchParameters = .frozen) {
        self.strategy = strategy; self.purpose = purpose; self.initialCash = initialCash
        self.settings = settings; self.evaluationRange = evaluationRange; self.parameters = parameters
    }
}

/// Raw rows include real observation dates; alignment creates valuation fills separately.
/// No process-wide market store is consulted by a run.
public struct BacktestRunInput: Sendable {
    public let seriesBySymbol: [String: PublicHistorySeries]
    /// Parallel row masks: false means a valuation fill, never an executable quote.
    public let realObservationsBySymbol: [String: [Bool]]
    public let nfciAsOf: BacktestNFCIAsOfData?
    public let datasetHash: String?
    public let macroHash: String?
    public let sourceCommit: String?
    public init(seriesBySymbol: [String: PublicHistorySeries], realObservationsBySymbol: [String: [Bool]] = [:], nfciAsOf: BacktestNFCIAsOfData? = nil,
                datasetHash: String? = nil, macroHash: String? = nil, sourceCommit: String? = nil) {
        self.seriesBySymbol = seriesBySymbol; self.realObservationsBySymbol = realObservationsBySymbol; self.nfciAsOf = nfciAsOf
        self.datasetHash = datasetHash; self.macroHash = macroHash; self.sourceCommit = sourceCommit
    }

    fileprivate func observedSeries() throws -> [String: PublicHistorySeries] {
        var output = seriesBySymbol
        for (symbol, source) in seriesBySymbol {
            guard source.dates.count == source.prices.count,
                  source.prices.allSatisfy({ $0.isFinite && $0 > 0 }),
                  zip(source.dates, source.dates.dropFirst()).allSatisfy({ $0 < $1 }) else {
                throw BacktestConfigurationError.invalidParameter("price rows: \(symbol)")
            }
        }
        for (symbol, mask) in realObservationsBySymbol {
            guard let source = seriesBySymbol[symbol], mask.count == source.dates.count,
                  source.prices.count == source.dates.count else {
                throw BacktestConfigurationError.invalidParameter("real observations: \(symbol)")
            }
            let indices = mask.indices.filter { mask[$0] }
            guard !indices.isEmpty else { throw BacktestConfigurationError.missingData("real quotes: \(symbol)") }
            func filtered(_ values: [Double?]?) throws -> [Double?]? {
                guard let values else { return nil }
                guard values.count == mask.count else { throw BacktestConfigurationError.invalidParameter("OHLC: \(symbol)") }
                return indices.map { values[$0] }
            }
            output[symbol] = try PublicHistorySeries(symbol: source.symbol, category: source.category,
                label: source.label, currency: source.currency, unit: source.unit, source: source.source,
                dates: indices.map { source.dates[$0] }, prices: indices.map { source.prices[$0] },
                hasOHLC: source.hasOHLC, ohlcSource: source.ohlcSource, ohlcCoverageRatio: source.ohlcCoverageRatio,
                openPrices: filtered(source.openPrices), highPrices: filtered(source.highPrices),
                lowPrices: filtered(source.lowPrices), closePrices: filtered(source.closePrices), volumes: filtered(source.volumes))
        }
        return output
    }
}

public struct BacktestRunProvenance: Codable, Sendable {
    public let strategy: StrategyReference
    public let executionVersion: String
    public let sourceCommit: String
    public let datasetHash: String
    public let macroHash: String?
    public let configuration: BacktestRunConfiguration
    public let frozenParametersJSON: Data
}

public struct BacktestRunResult {
    public let report: AdvancedBacktestReport
    public let dailyStates: [BacktestDailyState]
    public let provenance: BacktestRunProvenance
}

private struct FrozenParameterSnapshot: Encodable {
    let reference: StrategyReference
    let researchDefaults: BacktestResearchParameters
    let components: [String: RotationParameters.AdvancedRotationConfig]
    let mode: AdvancedBacktestStrategyMode
    let selectedAssetSymbols: [String]?
    let buyRule: AdvancedBacktestRule
    let sellRule: AdvancedBacktestRule
    let tradeAmountRatio: Double
    let settings: AdvancedBacktestRiskSettings
    let rotation: RotationParameters.AdvancedRotationConfig?
    let barbell: GoldNasdaqBarbellParameters?
    let nfci: NFCIFrozenParameters?
    let reallocation: [String: RiskContributionStrategy.RiskContributionReallocationParameters]
    let recoveryQuality: RiskContributionStrategy.RecoverySleeveQualityConfig
    let cashConfidence: CashConfidenceFrozenParameters?
}

private func canonicalSets(_ value: Any, key: String? = nil) -> Any {
    if let dictionary = value as? [String: Any] {
        return dictionary.mapValues { $0 }.reduce(into: [String: Any]()) { result, entry in
            result[entry.key] = canonicalSets(entry.value, key: entry.key)
        }
    }
    if let array = value as? [Any] {
        if let key, ["baseRotationSymbols", "zeroFillBeforeFirstSymbols", "signalOnlySymbols", "chinaExtraSymbols"].contains(key),
           let symbols = array as? [String] { return symbols.sorted() }
        if let key, ["months", "weakMonths"].contains(key), let months = array as? [Int] { return months.sorted() }
        return array.map { canonicalSets($0) }
    }
    return value
}
