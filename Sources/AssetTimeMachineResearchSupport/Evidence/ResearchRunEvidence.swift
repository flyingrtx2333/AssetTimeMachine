import Foundation
import Crypto
import AssetTimeMachineBacktestCore

public enum ResearchRunEvidence {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// File paths and transport envelopes stay outside the calculation core.
    public static func run(configurationData: Data, historyData: Data, macroData: Data? = nil,
                           observationsData: Data? = nil,
                           sourceCommit: String = "unknown") throws -> BacktestRunResult {
        let configuration = try ResearchConfiguration.decode(configurationData)
        let definition = try StrategyRegistry.definition(reference: configuration.run.strategy)
        let observations = try observationsData.map { try JSONDecoder().decode([String: [Bool]].self, from: $0) } ?? [:]
        let hash = observationsData.map { sha256(Data((sha256(historyData) + "|" + sha256($0)).utf8)) } ?? sha256(historyData)
        let dataset = try PublicBacktestCore.loadDataset(from: historyData,
            datasetHash: hash, dataStale: false)
        let macro = try macroData.map { try macroSnapshot(from: $0) }
        return try definition.run(input: BacktestRunInput(seriesBySymbol: dataset.seriesBySymbol,
            realObservationsBySymbol: observations,
            nfciAsOf: macro, datasetHash: dataset.datasetHash, macroHash: macroData.map(sha256),
            sourceCommit: sourceCommit), configuration: configuration.run)
    }

    /// As-of metadata is required, never replaced by the latest revised macro series.
    public static func macroSnapshot(from data: Data) throws -> BacktestNFCIAsOfData {
        struct Point: Decodable {
            let releaseDate: String
            let referenceDate: String
            let availableAt: String
            let value: Double
            enum CodingKeys: String, CodingKey {
                case releaseDate = "release_date", referenceDate = "reference_date", availableAt = "available_at", value
            }
        }
        struct Series: Decodable {
            let seriesID: String
            let points: [Point]
            enum CodingKeys: String, CodingKey { case seriesID = "series_id", points }
        }
        struct Envelope: Decodable {
            let success: Bool
            let source: String
            let series: [Series]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.success else { throw BacktestConfigurationError.missingData("macro response") }
        let iso = ISO8601DateFormatter()
        let fractions = ISO8601DateFormatter()
        fractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func points(_ id: String) throws -> [BacktestNFCIPoint] {
            guard let series = envelope.series.first(where: { $0.seriesID == id }) else {
                throw BacktestConfigurationError.missingData(id)
            }
            return try series.points.map { point in
                guard let at = fractions.date(from: point.availableAt) ?? iso.date(from: point.availableAt),
                      at <= Date(), point.value.isFinite,
                      BacktestSeriesAlignment.historicalSeriesDate(from: point.releaseDate) != nil,
                      BacktestSeriesAlignment.historicalSeriesDate(from: point.referenceDate) != nil else {
                    throw BacktestConfigurationError.invalidParameter("macro observation")
                }
                return .init(releaseDate: point.releaseDate, referenceDate: point.referenceDate,
                             availableAt: at, value: point.value)
            }
        }
        let snapshot = try BacktestNFCIAsOfData(source: envelope.source,
            credit: points("NFCICREDIT"), leverage: points("NFCILEVERAGE"))
        guard snapshot.isReadyForC3L3 else { throw BacktestConfigurationError.missingData("macro coverage") }
        return snapshot
    }

    /// Never replaces an existing evidence directory or a historical study.
    public static func write(_ result: BacktestRunResult, to directory: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: directory.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".research-\(UUID().uuidString)")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let configuration = try encoder.encode(result.provenance.configuration)
        let frozen = result.provenance.frozenParametersJSON
        let parametersObject: [String: Any] = [
            "frozen": try JSONSerialization.jsonObject(with: frozen),
            "run": try JSONSerialization.jsonObject(with: configuration)
        ]
        let parameters = try JSONSerialization.data(withJSONObject: parametersObject,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let mode = try StrategyRegistry.definition(reference: result.provenance.strategy).template.mode
        let hasDecisionShadow = [.riskContributionCashConfidenceLowNoise,
            .riskContributionCashConfidenceRouter, .nfciDualCoreV1,
            .nfciDualCoreSimplifiedV11, .nfciDualCoreSimplifiedV11QualRole].contains(mode)
        let internalCosts: Any = hasDecisionShadow
            ? ["fee_percent": CashConfidenceFrozenParameters.frozenV1.frozenDecisionFeeRatePercent,
               "slippage_percent": CashConfidenceFrozenParameters.frozenV1.frozenDecisionSlippageRatePercent]
            : NSNull()
        let evidence: [String: Any] = [
            "schema_version": 1,
            "evidence_class": "ENGINEERING_REPLAY",
            "strategy": ["id": result.provenance.strategy.id, "version": result.provenance.strategy.version],
            "execution_version": result.provenance.executionVersion,
            "source_commit": result.provenance.sourceCommit,
            "dataset_sha256": result.provenance.datasetHash,
            "macro_sha256": result.provenance.macroHash as Any? ?? "unknown",
            "parameters_sha256": sha256(parameters),
            "parameters": parametersObject,
            "execution_cost_units": "percent",
            "execution_costs": ["fee_percent": result.provenance.configuration.settings.feeRate,
                                "slippage_percent": result.provenance.configuration.settings.slippageRate],
            "internal_decision_costs": internalCosts,
            "internal_decision_cost_scope": hasDecisionShadow ? "cash-confidence shadow simulations" : "not applicable",
            "interval": ["start": result.report.points.first.map { isoDate($0.date) } ?? "unknown",
                         "end": result.report.points.last.map { isoDate($0.date) } ?? "unknown"]
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: temporary.appendingPathComponent("evidence.json"))
        try parameters.write(to: temporary.appendingPathComponent("parameters.json"))
        let report = result.report
        let reportObject: [String: Any] = [
            "ending_value": report.finalPortfolioValue, "ending_cash": report.finalCash,
            "annualized_return": report.annualizedReturn as Any? ?? NSNull(),
            "max_drawdown": report.maxDrawdown, "sharpe_rf0": report.sharpeRatio as Any? ?? NSNull(),
            "annualized_volatility": report.annualizedVolatility as Any? ?? NSNull(),
            "points": report.points.map { ["date": isoDate($0.date), "value": $0.portfolioValue] },
            "trades": try JSONSerialization.jsonObject(with: encoder.encode(report.trades.enumerated().map {
                BacktestRecordAdvancedTradePayload(trade: $0.element, sequence: $0.offset)
            })),
            "daily_states": try JSONSerialization.jsonObject(with: encoder.encode(result.dailyStates))
        ]
        try JSONSerialization.data(withJSONObject: reportObject, options: [.sortedKeys])
            .write(to: temporary.appendingPathComponent("result.json"))
        try manager.moveItem(at: temporary, to: directory)
    }

    private static func isoDate(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
