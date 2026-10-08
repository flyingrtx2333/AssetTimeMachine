import Foundation
import AssetTimeMachineBacktestCore

/// A census of existing App defaults, followed by one diagnostic replay per ready
/// comparator. Does not define, optimize, or select a new trading strategy.
public enum ProductBenchmarkScopeReplay {
    private static let cashFundStrategies: Set<String> = [
        "recent-volatility-managed-idle-cash", "recent-pair-spread-z252-shift25",
        "recent-gold-equity-relative-z252-shift25"
    ]
    private static let endText = "2026-10-06"

    public static func run(mode: String, historyPath: String, macroPath: String,
                           outputPath: String, preparedPath: String, sourceCommit: String) throws {
        guard ["prepare", "run"].contains(mode) else {
            throw BacktestConfigurationError.invalidParameter("scope replay mode")
        }
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let macroData = try Data(contentsOf: URL(fileURLWithPath: macroPath))
        let dataset = try PublicBacktestCore.loadDataset(from: history,
            datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        let macro = try ResearchRunEvidence.macroSnapshot(from: macroData)
        let ids = BacktestProductStrategyCatalog.templateIDs
        guard ids.count == 23, BacktestProductStrategyCatalog.curatedTemplateIDs.count == 6,
              BacktestProductStrategyCatalog.experimentalTemplateIDs.count == 4,
              BacktestProductStrategyCatalog.basicTemplateIDs.count == 13,
              BacktestProductStrategyCatalog.validationIssues().isEmpty else {
            throw BacktestConfigurationError.invalidParameter("frozen 23-entry catalogue")
        }
        let settings = AdvancedBacktestRiskSettings(feeRate: 0.025, slippageRate: 0,
            maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)
        var census: [[String: Any]] = []
        var ready: [String] = []
        for id in ids {
            let definition = try StrategyRegistry.definition(id: id)
            let needed = definition.dataRequirements.priceSymbols + definition.dataRequirements.fxSymbols
            let missing = needed.filter { dataset.seriesBySymbol[$0]?.dates.isEmpty != false }
            let status: String
            if cashFundStrategies.contains(id) { status = "EXCLUDED_USER_DEMAND_DEPOSIT_CONSTRAINT" }
            else if !missing.isEmpty { status = "PENDING_INPUT_NO_INFERIORITY_CLAIM" }
            else { status = "READY_EXISTING_COMPARATOR"; ready.append(id) }
            let tier = BacktestProductStrategyCatalog.isCuratedTemplateID(id) ? "curated"
                : BacktestProductStrategyCatalog.isExperimentalTemplateID(id) ? "experimental" : "basic"
            census.append([
                "id": id, "tier": tier, "mode": definition.template.mode.rawValue,
                "title_key": definition.template.titleLocalizationKey,
                "version": definition.reference.version, "status": status,
                "missing_symbols": missing, "required_symbols": needed,
                "requires_nfci_asof": definition.dataRequirements.requiresNFCIAsOf,
                "frozen_parameters": try JSONSerialization.jsonObject(with: definition.frozenParametersJSON),
                "frozen_parameters_sha256": ResearchRunEvidence.sha256(try definition.frozenParametersJSON),
                "is_new_candidate": false
            ])
        }
        guard ready.count == 19,
              census.filter({ $0["status"] as? String == "PENDING_INPUT_NO_INFERIORITY_CLAIM" })
                .compactMap({ $0["id"] as? String }) == ["nfci-dual-core-v11-qual-role"] else {
            throw BacktestConfigurationError.invalidParameter("frozen 19 ready + 1 QUAL pending + 3 excluded")
        }
        let contract: [String: Any] = [
            "schema": "product-benchmark-scope-v1", "catalogue_ids": ids,
            "ready_ids": ready, "catalogue": census,
            "history_sha256": ResearchRunEvidence.sha256(history),
            "macro_sha256": ResearchRunEvidence.sha256(macroData),
            "end": endText, "fee_percent": 0.025, "slippage_percent": 0,
            "cash": "CashYieldCNY demand deposits", "parameter_search_budget": 0,
            "new_candidate_count": 0, "funded_replay_budget": 19,
            "purpose": "POSTHOC_EXISTING_APP_BENCHMARK_SCOPE_NOT_FORMAL",
            "primary_metric": "App Rf=0 full common saved NAV; dates intersected mechanically",
            "qual_rule": "Missing QUAL remains pending. Do not replace with SPY or remove to certify full frontier."
        ]
        let contractData = try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys, .withoutEscapingSlashes])
        if mode == "prepare" {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try contractData.write(to: output.appendingPathComponent("contract.json"))
            print("Prepared 23 existing App entries: 19 ready, 1 QUAL pending, 3 violate cash constraint; no capital replay.")
            return
        }
        let frozen = try Data(contentsOf: URL(fileURLWithPath: preparedPath))
        guard frozen == contractData else { throw BacktestConfigurationError.invalidParameter("prepared scope changed") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try frozen.write(to: output.appendingPathComponent("contract.json"))
        let input = BacktestRunInput(seriesBySymbol: dataset.seriesBySymbol, nfciAsOf: macro,
            datasetHash: ResearchRunEvidence.sha256(history), macroHash: ResearchRunEvidence.sha256(macroData),
            sourceCommit: sourceCommit)
        let range = BacktestRunRange(
            startDate: BacktestSeriesAlignment.historicalSeriesDate(from: "1900-01-01")!,
            endDate: BacktestSeriesAlignment.historicalSeriesDate(from: endText)!)
        let binaryHash = ResearchRunEvidence.sha256(try Data(contentsOf:
            URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()))
        var accounts: [BacktestRunResult] = []
        for id in ready {
            let definition = try StrategyRegistry.definition(id: id)
            let configuration = BacktestRunConfiguration(strategy: definition.reference, purpose: .research,
                initialCash: 100000, settings: settings, evaluationRange: range)
            let result = try definition.makeRunner().run(input: input, configuration: configuration)
            try ResearchRunEvidence.write(result, to: output.appendingPathComponent("accounts/" + id),
                executableSHA256: binaryHash)
            accounts.append(result)
            print("Existing comparator saved: \(id)")
        }
        let common = accounts.reduce(Set(accounts[0].dailyStates.map(\.date))) {
            $0.intersection(Set($1.dailyStates.map(\.date)))
        }.sorted()
        guard let first = common.first, let last = common.last, common.count > 252 else {
            throw BacktestConfigurationError.missingData("full common catalogue NAV")
        }
        func text(_ date: Date) -> String { BacktestSeriesAlignment.historicalSeriesDateString(from: date) }
        let tenYears = BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding: .year, value: -10, to: last)!
        let windows = [("full", text(first), text(last)), ("trailing10Y", text(tenYears), text(last)),
            ("since2020", "2020-01-01", text(last)), ("since2022", "2022-01-01", text(last)),
            ("crisis2008", "2008-01-01", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"),
            ("crisis2022", "2022-01-01", "2022-12-31")]
        let commonSet = Set(common)
        let rows = try accounts.map {
            try DailyScreenOutput.row($0.provenance.strategy.id,
                states: $0.dailyStates.filter { commonSet.contains($0.date) }, trades: $0.report.trades, windows: windows)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let resultData = try encoder.encode(rows)
        try resultData.write(to: output.appendingPathComponent("result.json"))
        let evidence: [String: Any] = [
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "evidence_class": "POSTHOC_EXISTING_APP_BENCHMARK_SCOPE_NOT_FORMAL",
            "source_commit": sourceCommit, "binary_sha256": binaryHash,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "contract_sha256": ResearchRunEvidence.sha256(frozen),
            "result_sha256": ResearchRunEvidence.sha256(resultData), "common_dates": common.map(text),
            "common_start": text(first), "common_end": text(last), "comparator_count": 19,
            "candidate_count": 0, "parameter_search_budget": 0, "formal_validation": false,
            "complete_frontier_certified": false, "recommendation_eligible": false,
            "limitations": [
                "QUAL experimental comparator remains pending; no complete usable-App frontier claim.",
                "Source is the retained 2026-10-08 public response; this is not a new online snapshot.",
                "Native App gold/index price proxies, no independently funded tradable total-return certification.",
                "Continuous accounts start at natural warmup dates; common window is a stateful saved-NAV slice.",
                "Existing parameters preserved; no new alpha, untouched holdout or G0-G6 certification."
            ]
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"))
        print("Existing catalogue comparison: 19 comparators on \(common.count) exact common dates; QUAL still pending.")
    }
}
