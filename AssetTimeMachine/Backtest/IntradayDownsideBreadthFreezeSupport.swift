import Foundation

/// Return-blind freeze-only CLI for ATM-SVP2-IDB-63-21-001. It prepares immutable inputs,
/// provenance, schedule, and preregistration metadata but has no simulator or metric entrypoint.
nonisolated public enum IntradayDownsideBreadthFreezeCommand {
    private static let fixtureRelativePath = "tools/fixtures/backtest-history/public_history.json"
    private static let provenanceRelativePath = "tools/fixtures/backtest-history/public_history_ohlc_provenance_v1.json"
    private static let datasetRelativePath = "tools/research-results/strategy-validation/datasets/ATM-SVP2-IDB-63-21-001.json"
    private static let scheduleRelativePath = "tools/research-results/strategy-validation/preregistrations/IDB-63-21-schedule.json"
    private static let preregRelativePath = "tools/research-results/strategy-validation/preregistrations/ATM-SVP2-IDB-63-21-001.json"
    private static let ledgerRelativePath = "tools/research-results/strategy-validation/trial-ledger.jsonl"
    private static let goldenTestRelativePath = "Server/Tests/CoreTests/IntradayDownsideBreadthStrategyTests.swift"
    private static let cutoff = "2026-08-31"

    public static func run(arguments: [String]) throws {
        let options = try Options(arguments)
        let root = URL(fileURLWithPath: options.repoRoot, isDirectory: true).standardizedFileURL
        if options.mode == .formal { try requireCleanImplementation(root: root, commit: options.gitCommit) }
        let paths = Paths(root: root, mode: options.mode, preview: options.previewDirectory)
        for path in [paths.dataset, paths.schedule, paths.prereg] {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let fixtureData = try Data(contentsOf: root.appendingPathComponent(fixtureRelativePath))
        let provenanceData = try Data(contentsOf: root.appendingPathComponent(provenanceRelativePath))
        let fixtureSHA = IntradayDownsideBreadthArtifactCodec.sha256(fixtureData)
        let provenanceSHA = IntradayDownsideBreadthArtifactCodec.sha256(provenanceData)
        try verifyOHLCProvenance(provenanceData, root: root, fixtureData: fixtureData, fixtureSHA: fixtureSHA)

        let datasetData = try stableJSON([
            "trial_id": IntradayDownsideBreadthStrategy.trialID,
            "protocol_id": "ATM-SVP-2",
            "kind": "dataset",
            "implementation_commit": options.gitCommit,
            "cutoff": cutoff,
            "return_blind_freeze": true,
            "files": [
                ["path": fixtureRelativePath, "bytes": fixtureData.count, "sha256": fixtureSHA],
                ["path": provenanceRelativePath, "bytes": provenanceData.count, "sha256": provenanceSHA]
            ],
            "data_claim": [
                "gold_cny": "mixed_provenance; only Choice-classified imported rows have production-apply/source/value row proof; native/preexisting rows do not inherit that claim",
                "gold_choice_imported_subset_row_proof": true,
                "gold_asset_wide_row_level_source_proof": false,
                "nasdaq": "provider_label_only",
                "sp500": "provider_label_only",
                "equity_row_level_source_proof": false
            ]
        ])
        try datasetData.write(to: paths.dataset, options: .atomic)
        let datasetSHA = IntradayDownsideBreadthArtifactCodec.sha256(datasetData)

        let response = try JSONDecoder().decode(PublicHistoryResponse.self, from: fixtureData)
        guard response.success else { throw FreezeError.invalid("fixture success=false") }
        let raw = Dictionary(uniqueKeysWithValues: response.series.map { ($0.symbol, $0) })
        guard let fx = raw["usd_per_cny"] else { throw FreezeError.invalid("missing usd_per_cny") }
        let mapping = [("gold_cny", "gold_cny"), ("nasdaq", "nasdaq_composite"), ("sp500", "sp500")]
        var prepared: [(app: String, fixture: String, raw: PublicHistorySeries, value: PreparedAdvancedSeries)] = []
        for (app, fixture) in mapping {
            guard let source = raw[fixture] else { throw FreezeError.invalid("missing \(fixture)") }
            guard let value = BacktestAdvancedSeriesPreparer.preparedAdvancedSeries(
                assetSeries: clipped(source), assetOption: try option(app), fxSeries: clipped(fx),
                movingAverage: { values, _ in Array(repeating: nil, count: values.count) },
                bollingerBands: { values, _, _ in Array(repeating: nil, count: values.count) }
            ), !value.ohlcPoints.isEmpty else { throw FreezeError.invalid("preparation failed \(app)") }
            prepared.append((app, fixture, clipped(source), value))
        }

        let executionSets = prepared.map { item in
            Set(item.value.pricePoints.compactMap {
                item.value.executionObservationDates.contains($0.date) ? $0.date.recordDateString : nil
            })
        }
        guard let first = executionSets.first else { throw FreezeError.invalid("no execution series") }
        let executableDates = executionSets.dropFirst().reduce(first) { $0.intersection($1) }.sorted()
        guard !executableDates.isEmpty else { throw FreezeError.invalid("no joint canonical execution dates") }

        func sourceID(_ item: (app: String, fixture: String, raw: PublicHistorySeries, value: PreparedAdvancedSeries)) -> String {
            let label = (item.raw.ohlcSource ?? item.raw.source).replacingOccurrences(of: "|", with: "/")
            let proof = item.app == "gold_cny" ? ":mixed-provenance=\(provenanceSHA)" : ":provider-label-only"
            return "public-history=\(fixtureSHA):cutoff=\(cutoff):app=\(item.app):fixture=\(item.fixture):ohlc=\(label)\(proof)"
        }
        let sourceIDs = Dictionary(uniqueKeysWithValues: prepared.map { ($0.app, sourceID($0)) })
        let signalAssets = prepared.filter { IntradayDownsideBreadthStrategy.signalAssetOrder.contains($0.app) }.map { item in
            IntradayDownsideBreadthAssetInput(
                symbol: item.app, sourceID: sourceIDs[item.app]!, currency: "CNY",
                bars: item.value.ohlcPoints.map {
                    .init(date: $0.date.recordDateString, open: $0.open, high: $0.high, low: $0.low,
                          close: $0.close, sourceID: sourceIDs[item.app]!)
                }
            )
        }
        let anchor = try anchorDate(assets: signalAssets, executableDates: executableDates)
        let windows = try actualWindows(executableDates: executableDates, anchor: anchor)
        let provenance: [IntradayDownsideBreadthProvenance] = IntradayDownsideBreadthStrategy.assetOrder.map { symbol in
            .init(symbol: symbol, sourceID: sourceIDs[symbol]!,
                  claim: symbol == "gold_cny"
                    ? "mixed_provenance; row proof applies only to Choice-classified imported rows"
                    : "provider_label_only",
                  rowLevelSourceProof: false,
                  provenanceSHA256: symbol == "gold_cny" ? provenanceSHA : nil)
        }
        let artifact = try IntradayDownsideBreadthScheduleBuilder.build(
            assets: signalAssets,
            config: .init(gitCommit: options.gitCommit, fixturePath: fixtureRelativePath, fixtureSHA256: fixtureSHA,
                          provenancePath: provenanceRelativePath, provenanceSHA256: provenanceSHA,
                          runtime: .formal, actualWindows: windows, executableDates: executableDates, provenance: provenance)
        )
        guard artifact.anchorDate == anchor else { throw FreezeError.invalid("anchor self-check") }
        let scheduleData = try IntradayDownsideBreadthArtifactCodec.encode(artifact)
        _ = try IntradayDownsideBreadthArtifactLoader.load(data: scheduleData, enforceFormalRuntime: true)
        try scheduleData.write(to: paths.schedule, options: .atomic)
        let scheduleSHA = IntradayDownsideBreadthArtifactCodec.sha256(scheduleData)
        let goldenData = try Data(contentsOf: root.appendingPathComponent(goldenTestRelativePath))
        let goldenSHA = IntradayDownsideBreadthArtifactCodec.sha256(goldenData)

        let preregData = try stableJSON([
            "trial_id": IntradayDownsideBreadthStrategy.trialID,
            "protocol_id": "ATM-SVP-2",
            "protocol_component": "INTRADAY_DOWNSIDE_BREADTH_GOLD_ROTATION",
            "strategy_lineage": IntradayDownsideBreadthStrategy.lineage,
            "hypothesis": "Persistent negative open-to-close returns across Nasdaq and S&P 500 represent broad informed selling during the US cash session; higher downside breadth should predict weaker next-month intraday equity returns, so gold exposure increases linearly with breadth.",
            "evidence_class": "D0_EXPOSED",
            "candidate_ids": [IntradayDownsideBreadthStrategy.strategyID],
            "candidate_count": 1,
            "implementation_commit": options.gitCommit,
            "dataset_manifest": paths.logicalDataset,
            "dataset_manifest_sha256": datasetSHA,
            "frozen_schedule": ["path": paths.logicalSchedule, "sha256": scheduleSHA,
                                "anchor_date": artifact.anchorDate, "review_count": artifact.reviews.count,
                                "fingerprints": ["header": artifact.fingerprints.header, "input": artifact.fingerprints.input,
                                                 "candidate": artifact.fingerprints.candidate, "natural": artifact.fingerprints.natural,
                                                 "placebo": artifact.fingerprints.placebo, "full": artifact.fingerprints.full]],
            "algorithm": [
                "asset_order": IntradayDownsideBreadthStrategy.assetOrder,
                "signal_assets": IntradayDownsideBreadthStrategy.signalAssetOrder,
                "signal": "x=Foundation.log(close/open), Swift Double division first; exact oldest-to-newest 63-observation mean",
                "clock": "equity signal-common anchor and +21 signal-common ordinal reviews; strict T-1",
                "candidate": "b=count(mean<0); gold=b/2; each equity=(1-b/2)/2; equality uncounted",
                "natural": "exact one-third each",
                "placebo": "b=count(mean>0); same target map; equality uncounted",
                "execution": "joint canonical real observations for all three assets; same-session FX for USD; sell-before-buy; completion before next review"
            ],
            "data_claim": ["gold_cny": "mixed_provenance; row proof applies only to Choice-classified imported rows",
                           "gold_choice_imported_subset_row_proof": true,
                           "gold_asset_wide_row_level_source_proof": false,
                           "nasdaq": "provider_label_only", "sp500": "provider_label_only",
                           "nasdaq_row_level_source_proof": false, "sp500_row_level_source_proof": false],
            "selection_metric": "No candidate selection metric: exactly one return-blind candidate; formal decision requires every frozen factor, absolute product, natural-control, and placebo gate in every window.",
            "evaluation_windows": artifact.actualWindows.map { item -> [String: Any] in
                ["id": item.id, "requested_start": item.requestedStart.map { $0 as Any } ?? NSNull(),
                 "actual_start": item.actualStart, "actual_end": item.actualEnd]
            },
            "cost_model": ["initial_cash_cny": 100_000.0, "transaction_fee_rate": 0.01,
                           "slippage_rate": 0.0005, "financing_annual_rate": 0.0,
                           "allows_financed_exposure": false, "sensitivity_runs_allowed": false],
            "factor_mechanism_gate": [
                "group_risk": "candidate breadth >= 1", "group_calm": "candidate breadth == 0",
                "outcome": "next 21 signal-common observations' equal-weight mean of Nasdaq and S&P 500 cumulative intraday log returns",
                "tail_policy": "exclude reviews without all 21 future signal-common observations",
                "minimum_observations_per_group_per_window": 5,
                "required_direction_per_window": "median(risk) < median(calm)",
                "insufficient_sample_status": "INVALID before portfolio metrics"
            ],
            "pass_fail_gates": [
                "factor mechanism gate passes in every window",
                "candidate CAGR >= 0.09 in every window",
                "candidate Sharpe >= 0.80 in every window",
                "candidate maximum drawdown <= 0.10 in every window",
                "candidate Sharpe strictly exceeds natural control in every window",
                "candidate Sharpe strictly exceeds sign-inverted placebo in every window",
                "candidate maximum drawdown is strictly below natural control in every window",
                "every event completes strictly after review and before the next review on frozen joint canonical execution dates"
            ],
            "formal_run_budget": 1,
            "requires_durable_run_reservation": true,
            "result_manifest_kind": "result",
            "run_budget_authority": [
                "kind": "git-remote-immutable-tag-cas", "remote": "origin", "base_branch": "main",
                "ref": "refs/tags/atm-run-budget/ATM-SVP2-IDB-63-21-001"
            ],
            "factor_evidence_role": "preregistered_falsification_control_not_factor_candidate",
            "follow_up_policy": "PASS records success; any provenance, schedule, fingerprint, shared-engine, T-1, queue, factor-sample, factor-direction, acceptance, process, or archival failure permanently closes this lineage as FAIL/INVALID. No parameter rescue, alternate window, lower fee, replacement candidate, or second formal run.",
            "swift_engine_entrypoint": "IntradayDownsideBreadthSharedSimulator.run via scripts/run_intraday_downside_breadth_formal.py and strategy_validation_formal_run.py",
            "expected_outputs": [
                "RUN_STARTED ledger event", "run-budget-reservation.json",
                "run-authorization.json", "stdout.txt", "stderr.txt", "execution.json",
                "run-slot.json", "launch-marker.json", "factor-evidence.json",
                "candidate-metrics.json", "queue-trace.json", "artifact-manifest.json",
                "strategy-library-import-v2.json",
                "tools/research-results/strategy-validation/results/ATM-SVP2-IDB-63-21-001.json",
                "append-only RESULT in tools/research-results/strategy-validation/trial-ledger.jsonl"
            ],
            "independent_golden": ["path": goldenTestRelativePath, "sha256": goldenSHA],
            "allowed_changes": [
                paths.logicalDataset, paths.logicalSchedule, preregRelativePath, ledgerRelativePath,
                "No strategy, simulator, formal consumer, runner, finalizer, test, cost, runtime, window, provenance, or gate source may change after implementation_commit"
            ],
            "return_blind_freeze": true
        ])
        try preregData.write(to: paths.prereg, options: .atomic)
        print("artifact_path=\(paths.schedule.path)")
        print("dataset_manifest_path=\(paths.dataset.path)")
        print("preregistration_path=\(paths.prereg.path)")
        print("review_count=\(artifact.reviews.count)")
        print("fingerprint_header=\(artifact.fingerprints.header)")
        print("fingerprint_input=\(artifact.fingerprints.input)")
        print("fingerprint_candidate=\(artifact.fingerprints.candidate)")
        print("fingerprint_natural=\(artifact.fingerprints.natural)")
        print("fingerprint_placebo=\(artifact.fingerprints.placebo)")
        print("fingerprint_full=\(artifact.fingerprints.full)")
        print("schedule_sha256=\(scheduleSHA)")
        print("dataset_manifest_sha256=\(datasetSHA)")
        print("independent_golden_sha256=\(goldenSHA)")
        print("preregistration_sha256=\(IntradayDownsideBreadthArtifactCodec.sha256(preregData))")
    }

    private enum Mode: String { case preview, formal }
    private struct Options {
        let repoRoot: String; let mode: Mode; let previewDirectory: String?; let gitCommit: String
        init(_ arguments: [String]) throws {
            var values: [String: String] = [:]; var index = 0
            while index < arguments.count {
                guard arguments[index].hasPrefix("--"), index + 1 < arguments.count,
                      values[arguments[index]] == nil else { throw FreezeError.usage }
                values[arguments[index]] = arguments[index + 1]; index += 2
            }
            let allowed = Set(["--repo-root", "--mode", "--preview-output-dir", "--git-commit"])
            guard Set(values.keys).isSubset(of: allowed), let commit = values["--git-commit"],
                  commit.count == 40, commit == commit.lowercased(), commit.allSatisfy(\.isHexDigit),
                  let modeValue = values["--mode"], let parsed = Mode(rawValue: modeValue) else { throw FreezeError.usage }
            let preview = values["--preview-output-dir"]
            guard (parsed == .preview && preview?.isEmpty == false) || (parsed == .formal && preview == nil) else { throw FreezeError.usage }
            repoRoot = values["--repo-root"] ?? FileManager.default.currentDirectoryPath
            mode = parsed; previewDirectory = preview; gitCommit = commit
        }
    }
    private struct Paths {
        let dataset: URL; let schedule: URL; let prereg: URL; let logicalDataset: String; let logicalSchedule: String
        init(root: URL, mode: Mode, preview: String?) {
            if mode == .formal {
                dataset = root.appendingPathComponent(datasetRelativePath); schedule = root.appendingPathComponent(scheduleRelativePath)
                prereg = root.appendingPathComponent(preregRelativePath); logicalDataset = datasetRelativePath; logicalSchedule = scheduleRelativePath
            } else {
                let base = URL(fileURLWithPath: preview!, relativeTo: root).standardizedFileURL
                dataset = base.appendingPathComponent("ATM-SVP2-IDB-63-21-001-dataset-preview.json")
                schedule = base.appendingPathComponent("IDB-63-21-schedule-preview.json")
                prereg = base.appendingPathComponent("ATM-SVP2-IDB-63-21-001-prereg-preview.json")
                logicalDataset = dataset.path; logicalSchedule = schedule.path
            }
        }
    }
    private enum FreezeError: Error, CustomStringConvertible {
        case usage; case invalid(String)
        var description: String {
            switch self {
            case .usage: return "usage: IntradayDownsideBreadthFreeze --mode preview|formal --git-commit <40-lowercase-hex> [--repo-root <path>] [--preview-output-dir <path>]"
            case .invalid(let value): return value
            }
        }
    }

    private static func clipped(_ series: PublicHistorySeries) -> PublicHistorySeries {
        let indices = series.dates.indices.filter { series.dates[$0] <= cutoff }
        func values(_ source: [Double?]?) -> [Double?]? { source.map { values in indices.map { values[$0] } } }
        return .init(symbol: series.symbol, category: series.category, label: series.label, currency: series.currency,
                     unit: series.unit, source: series.source, dates: indices.map { series.dates[$0] },
                     prices: indices.map { series.prices[$0] }, hasOHLC: series.hasOHLC, ohlcSource: series.ohlcSource,
                     ohlcCoverageRatio: series.ohlcCoverageRatio, openPrices: values(series.openPrices),
                     highPrices: values(series.highPrices), lowPrices: values(series.lowPrices),
                     closePrices: values(series.closePrices), volumes: values(series.volumes))
    }
    private static func option(_ symbol: String) throws -> BacktestAssetOption {
        guard let value = BacktestDefaults.dcaAssetOptions.first(where: { $0.symbol == symbol }) else {
            throw FreezeError.invalid("missing App option \(symbol)")
        }
        return value
    }
    private static func anchorDate(assets: [IntradayDownsideBreadthAssetInput], executableDates: [String]) throws -> String {
        let common = assets.dropFirst().reduce(Set(assets[0].bars.map(\.date))) { $0.intersection(Set($1.bars.map(\.date))) }.sorted()
        guard let ordinal = common.indices.first(where: { ordinal in
            guard ordinal >= 62, common[ordinal] >= executableDates[0], common.indices.contains(ordinal + 21) else { return false }
            return executableDates.contains { $0 > common[ordinal] && $0 < common[ordinal + 21] }
        }) else { throw FreezeError.invalid("no executable anchor") }
        return common[ordinal]
    }
    private static func actualWindows(executableDates: [String], anchor: String) throws -> [IntradayDownsideBreadthWindow] {
        let eligible = executableDates.filter { $0 > anchor && $0 <= cutoff }
        guard let first = eligible.first, let last = eligible.last else { throw FreezeError.invalid("no portfolio window") }
        return try [("full", nil), ("since_2016_08_31", "2016-08-31"), ("since_2020_01_01", "2020-01-01"), ("since_2022_01_01", "2022-01-01")].map { id, requested in
            guard let actual = eligible.first(where: { $0 >= max(first, requested ?? first) }) else { throw FreezeError.invalid("empty window \(id)") }
            return .init(id: id, requestedStart: requested, actualStart: actual, actualEnd: last)
        }
    }
    private static func verifyOHLCProvenance(_ data: Data, root: URL, fixtureData: Data, fixtureSHA: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema_version"] as? String == "public-history-ohlc-provenance-v1",
              let semantics = object["artifact_semantics"] as? [String: Any],
              semantics["immutable_for_input_hashes"] as? Bool == true,
              semantics["contains_wall_clock_time"] as? Bool == false,
              semantics["reads_strategy_performance"] as? Bool == false,
              semantics["mutates_public_history_fixture"] as? Bool == false,
              let inputs = object["inputs"] as? [String: Any],
              let fixture = inputs["public_history_fixture"] as? [String: Any],
              fixture["path"] as? String == fixtureRelativePath,
              fixture["sha256"] as? String == fixtureSHA,
              (fixture["bytes"] as? NSNumber)?.intValue == fixtureData.count,
              let assets = object["assets"] as? [String: Any],
              let gold = assets["gold_cny"] as? [String: Any],
              gold["choice_source_row_proof"] as? Bool == true,
              (gold["complete_ohlc_rows"] as? NSNumber)?.intValue ?? 0 > 0,
              let nasdaq = assets["nasdaq_composite"] as? [String: Any],
              nasdaq["provider_label_only"] as? Bool == true,
              nasdaq["row_level_source_proof"] as? Bool == false,
              let sp500 = assets["sp500"] as? [String: Any],
              sp500["provider_label_only"] as? Bool == true,
              sp500["row_level_source_proof"] as? Bool == false else {
            throw FreezeError.invalid("OHLC provenance contract mismatch")
        }
        var boundFiles: [[String: Any]] = []
        if let generator = object["generator"] as? [String: Any] { boundFiles.append(generator) }
        for key in ["choice_gc00y_source", "production_apply_report"] {
            guard let item = inputs[key] as? [String: Any] else {
                throw FreezeError.invalid("OHLC provenance missing input \(key)")
            }
            boundFiles.append(item)
        }
        for item in boundFiles {
            guard let path = item["path"] as? String,
                  let sha = item["sha256"] as? String,
                  let bytes = (item["bytes"] as? NSNumber)?.intValue else {
                throw FreezeError.invalid("OHLC provenance file identity")
            }
            let sourceData = try Data(contentsOf: root.appendingPathComponent(path))
            guard sourceData.count == bytes, IntradayDownsideBreadthArtifactCodec.sha256(sourceData) == sha else {
                throw FreezeError.invalid("OHLC provenance source hash mismatch: \(path)")
            }
        }
    }
    private static func stableJSON(_ value: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]); data.append(0x0a); return data
    }
    private static func requireCleanImplementation(root: URL, commit: String) throws {
        let head = try process("/usr/bin/git", ["rev-parse", "HEAD"], root).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == commit else { throw FreezeError.invalid("formal commit must equal HEAD") }
        guard try process("/usr/bin/git", ["status", "--porcelain", "--untracked-files=all"], root).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FreezeError.invalid("formal freeze requires clean implementation commit")
        }
    }
    private static func process(_ executable: String, _ arguments: [String], _ root: URL) throws -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments; task.currentDirectoryURL = root
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe; try task.run(); task.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard task.terminationStatus == 0 else { throw FreezeError.invalid(output) }; return output
    }
}
