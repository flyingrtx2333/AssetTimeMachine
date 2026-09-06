import Foundation

nonisolated public enum RSRangeBreadthFreezeCommand {
    private static let fixtureRelativePath = "tools/fixtures/backtest-history/public_history.json"
    private static let sourceManifestRelativePath = "tools/fixtures/backtest-history/choice_gc00y_backfill_audit_2026-09-02.json"
    private static let datasetRelativePath = "tools/research-results/strategy-validation/datasets/ATM-SVP2-RS-RANGE-BREADTH-001.json"
    private static let scheduleRelativePath = "tools/research-results/strategy-validation/preregistrations/RS-RANGE-BREADTH-21-252-001-schedule.json"
    private static let preregRelativePath = "tools/research-results/strategy-validation/preregistrations/ATM-SVP2-RS-RANGE-BREADTH-001.json"
    private static let cutoff = "2026-08-31"
    private static let trialID = "ATM-SVP2-RS-RANGE-BREADTH-001"

    public static func run(arguments: [String]) throws {
        let options = try Options(arguments: arguments)
        let root = URL(fileURLWithPath: options.repoRoot, isDirectory: true).standardizedFileURL
        if options.mode == .formal {
            try requireFormalGitState(root: root, commit: options.gitCommit)
        }

        let paths = OutputPaths(root: root, mode: options.mode, previewDirectory: options.previewDirectory)
        try FileManager.default.createDirectory(at: paths.dataset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.schedule.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.prereg.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fixtureURL = root.appendingPathComponent(fixtureRelativePath)
        let sourceManifestURL = root.appendingPathComponent(sourceManifestRelativePath)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let sourceManifestData = try Data(contentsOf: sourceManifestURL)
        let fixtureSHA = RSRangeBreadthArtifactCodec.sha256(fixtureData)
        let sourceManifestSHA = RSRangeBreadthArtifactCodec.sha256(sourceManifestData)
        try verifySourceManifest(sourceManifestData, root: root, fixtureData: fixtureData, fixtureSHA: fixtureSHA)

        let dataset = try datasetManifest(
            gitCommit: options.gitCommit,
            fixtureBytes: fixtureData.count,
            fixtureSHA: fixtureSHA,
            sourceManifestBytes: sourceManifestData.count,
            sourceManifestSHA: sourceManifestSHA
        )
        let datasetData = try stableJSON(dataset)
        try datasetData.write(to: paths.dataset, options: .atomic)
        let datasetSHA = RSRangeBreadthArtifactCodec.sha256(datasetData)

        let response = try JSONDecoder().decode(PublicHistoryResponse.self, from: fixtureData)
        guard response.success else { throw FreezeError.invalid("fixture success=false") }
        let sourceBySymbol = Dictionary(uniqueKeysWithValues: response.series.map { ($0.symbol, $0) })
        guard let fx = sourceBySymbol["usd_per_cny"] else { throw FreezeError.invalid("missing usd_per_cny") }

        let mapping = [("gold_cny", "gold_cny"), ("nasdaq", "nasdaq_composite"), ("sp500", "sp500")]
        var prepared: [(appSymbol: String, fixtureSymbol: String, series: PublicHistorySeries, value: PreparedAdvancedSeries)] = []
        for (appSymbol, fixtureSymbol) in mapping {
            guard let raw = sourceBySymbol[fixtureSymbol] else { throw FreezeError.invalid("missing \(fixtureSymbol)") }
            let series = clipped(raw, through: cutoff)
            let option = try assetOption(appSymbol)
            guard let value = BacktestAdvancedSeriesPreparer.preparedAdvancedSeries(
                assetSeries: series,
                assetOption: option,
                fxSeries: clipped(fx, through: cutoff),
                movingAverage: { values, _ in Array(repeating: nil, count: values.count) },
                bollingerBands: { values, _, _ in Array(repeating: nil, count: values.count) }
            ) else { throw FreezeError.invalid("preparation failed \(appSymbol)") }
            guard !value.ohlcPoints.isEmpty else { throw FreezeError.invalid("no prepared OHLC \(appSymbol)") }
            prepared.append((appSymbol, fixtureSymbol, series, value))
        }

        // Executability is defined only from canonical prepared price points, further restricted
        // by the preparer's same-session FX observation set for USD assets. OHLC dates never
        // substitute for canonical valuation/execution observations.
        let executableSets: [Set<String>] = prepared.map { item in
            Set(item.value.pricePoints.compactMap { point in
                guard item.value.executionObservationDates.contains(point.date) else { return nil }
                return point.date.recordDateString
            })
        }
        guard let firstExecutable = executableSets.first else { throw FreezeError.invalid("no executable sets") }
        let executableDates = executableSets.dropFirst().reduce(firstExecutable) { $0.intersection($1) }.sorted()
        guard !executableDates.isEmpty else { throw FreezeError.invalid("no joint canonical executable dates") }

        let assets: [RSRangeBreadthAssetInput] = prepared.map { item in
            let sourceID = frozenSourceID(
                appSymbol: item.appSymbol,
                fixtureSymbol: item.fixtureSymbol,
                series: item.series,
                fixtureSHA: fixtureSHA,
                sourceManifestSHA: sourceManifestSHA
            )
            return RSRangeBreadthAssetInput(
                symbol: item.appSymbol,
                sourceID: sourceID,
                currency: "CNY",
                bars: item.value.ohlcPoints.map {
                    RSRangeBreadthSignalBar(
                        date: $0.date.recordDateString,
                        open: $0.open,
                        high: $0.high,
                        low: $0.low,
                        close: $0.close,
                        sourceID: sourceID
                    )
                }
            )
        }

        let anchor = try scheduleAnchor(assets: assets)
        let windows = try actualWindows(executableDates: executableDates, anchor: anchor)
        let config = RSRangeBreadthFreezeConfig(
            gitCommit: options.gitCommit,
            fixturePath: fixtureRelativePath,
            fixtureSHA256: fixtureSHA,
            manifestPath: datasetRelativePath,
            manifestSHA256: datasetSHA,
            runtime: .formal,
            actualWindows: windows,
            executableDates: executableDates
        )
        let artifact = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config)
        guard artifact.anchorDate == anchor else { throw FreezeError.invalid("anchor self-check") }
        let scheduleData = try RSRangeBreadthArtifactCodec.encode(artifact)
        _ = try RSRangeBreadthArtifactLoader.load(data: scheduleData, enforceFormalRuntime: true)
        try scheduleData.write(to: paths.schedule, options: .atomic)
        let scheduleSHA = try fileSHA256(paths.schedule, root: root)

        let prereg = preregistration(
            gitCommit: options.gitCommit,
            datasetPath: paths.logicalDatasetPath,
            datasetSHA: datasetSHA,
            schedulePath: paths.logicalSchedulePath,
            scheduleSHA: scheduleSHA,
            artifact: artifact,
            prepared: prepared,
            fixtureSHA: fixtureSHA,
            sourceManifestSHA: sourceManifestSHA
        )
        let preregData = try stableJSON(prereg)
        try preregData.write(to: paths.prereg, options: .atomic)
        let preregSHA = RSRangeBreadthArtifactCodec.sha256(preregData)

        // Deliberately return only freeze evidence. No simulator or performance API is reachable here.
        print("artifact_path=\(paths.schedule.path)")
        print("dataset_manifest_path=\(paths.dataset.path)")
        print("preregistration_path=\(paths.prereg.path)")
        print("review_count=\(artifact.reviews.count)")
        for window in artifact.actualWindows {
            print("actual_window=\(window.id):\(window.actualStart)..\(window.actualEnd)")
        }
        print("fingerprint_candidate=\(artifact.scheduleFingerprints.candidate)")
        print("fingerprint_natural=\(artifact.scheduleFingerprints.natural)")
        print("fingerprint_placebo=\(artifact.scheduleFingerprints.placebo)")
        print("fingerprint_combined=\(artifact.combinedFingerprint)")
        print("schedule_sha256=\(scheduleSHA)")
        print("dataset_manifest_sha256=\(datasetSHA)")
        print("preregistration_sha256=\(preregSHA)")
    }

    private enum Mode: String { case preview, formal }

    private struct Options {
        let repoRoot: String
        let mode: Mode
        let previewDirectory: String?
        let gitCommit: String

        init(arguments: [String]) throws {
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let key = arguments[index]
                guard key.hasPrefix("--"), index + 1 < arguments.count else { throw FreezeError.usage }
                guard values[key] == nil else { throw FreezeError.invalid("duplicate option \(key)") }
                values[key] = arguments[index + 1]
                index += 2
            }
            let allowed = Set(["--repo-root", "--mode", "--preview-output-dir", "--git-commit"])
            guard Set(values.keys).isSubset(of: allowed), let commit = values["--git-commit"],
                  commit.count == 40, commit.allSatisfy({ $0.isHexDigit }), commit == commit.lowercased(),
                  let modeText = values["--mode"], let parsedMode = Mode(rawValue: modeText) else {
                throw FreezeError.usage
            }
            let preview = values["--preview-output-dir"]
            if parsedMode == .preview && (preview?.isEmpty ?? true) { throw FreezeError.invalid("preview requires --preview-output-dir") }
            if parsedMode == .formal && preview != nil { throw FreezeError.invalid("formal forbids --preview-output-dir") }
            repoRoot = values["--repo-root"] ?? FileManager.default.currentDirectoryPath
            mode = parsedMode
            previewDirectory = preview
            gitCommit = commit
        }
    }

    private struct OutputPaths {
        let dataset: URL
        let schedule: URL
        let prereg: URL
        let logicalDatasetPath: String
        let logicalSchedulePath: String

        init(root: URL, mode: Mode, previewDirectory: String?) {
            if mode == .formal {
                dataset = root.appendingPathComponent(datasetRelativePath)
                schedule = root.appendingPathComponent(scheduleRelativePath)
                prereg = root.appendingPathComponent(preregRelativePath)
                logicalDatasetPath = datasetRelativePath
                logicalSchedulePath = scheduleRelativePath
            } else {
                let directory = URL(fileURLWithPath: previewDirectory!, relativeTo: root).standardizedFileURL
                dataset = directory.appendingPathComponent("ATM-SVP2-RS-RANGE-BREADTH-001-dataset-preview.json")
                schedule = directory.appendingPathComponent("RS-RANGE-BREADTH-21-252-001-schedule-preview.json")
                prereg = directory.appendingPathComponent("ATM-SVP2-RS-RANGE-BREADTH-001-prereg-preview.json")
                logicalDatasetPath = dataset.path
                logicalSchedulePath = schedule.path
            }
        }
    }

    private enum FreezeError: Error, CustomStringConvertible {
        case usage
        case invalid(String)
        var description: String {
            switch self {
            case .usage:
                return "usage: RSRangeBreadthFreeze --mode preview|formal --git-commit <40-lowercase-hex> [--repo-root <path>] [--preview-output-dir <path>]"
            case .invalid(let message): return message
            }
        }
    }

    private static func clipped(_ series: PublicHistorySeries, through cutoff: String) -> PublicHistorySeries {
        let indices = series.dates.indices.filter { series.dates[$0] <= cutoff }
        func values(_ input: [Double?]?) -> [Double?]? { input.map { source in indices.map { source[$0] } } }
        return PublicHistorySeries(
            symbol: series.symbol, category: series.category, label: series.label, currency: series.currency,
            unit: series.unit, source: series.source, dates: indices.map { series.dates[$0] },
            prices: indices.map { series.prices[$0] }, hasOHLC: series.hasOHLC, ohlcSource: series.ohlcSource,
            ohlcCoverageRatio: series.ohlcCoverageRatio, openPrices: values(series.openPrices),
            highPrices: values(series.highPrices), lowPrices: values(series.lowPrices),
            closePrices: values(series.closePrices), volumes: values(series.volumes)
        )
    }

    private static func assetOption(_ symbol: String) throws -> BacktestAssetOption {
        guard let option = BacktestDefaults.dcaAssetOptions.first(where: { $0.symbol == symbol }) else {
            throw FreezeError.invalid("missing App asset option \(symbol)")
        }
        return option
    }

    private static func frozenSourceID(
        appSymbol: String,
        fixtureSymbol: String,
        series: PublicHistorySeries,
        fixtureSHA: String,
        sourceManifestSHA: String
    ) -> String {
        let source = (series.ohlcSource ?? series.source).replacingOccurrences(of: "|", with: "/")
        let audit = appSymbol == "gold_cny" ? ":choice-audit=\(sourceManifestSHA)" : ""
        return "public-history=\(fixtureSHA):cutoff=\(cutoff):app=\(appSymbol):fixture=\(fixtureSymbol):ohlc=\(source)\(audit)"
    }

    private static func scheduleAnchor(assets: [RSRangeBreadthAssetInput]) throws -> String {
        let sets = assets.map { Set($0.bars.map(\.date)) }
        guard let first = sets.first else { throw FreezeError.invalid("no assets") }
        let common = sets.dropFirst().reduce(first) { $0.intersection($1) }.sorted()
        guard let anchor = common.first(where: { date in
            assets.allSatisfy { $0.bars.prefix { $0.date <= date }.count >= RSRangeBreadthStrategy.lookback }
        }) else { throw FreezeError.invalid("no schedule anchor") }
        return anchor
    }

    private static func actualWindows(executableDates: [String], anchor: String) throws -> [RSRangeBreadthWindow] {
        let eligible = executableDates.filter { $0 >= anchor && $0 <= cutoff }
        guard let first = eligible.first, let last = eligible.last else { throw FreezeError.invalid("no executable portfolio window") }
        let definitions: [(String, String?)] = [
            ("full", nil), ("since_2016_08_31", "2016-08-31"),
            ("since_2020_01_01", "2020-01-01"), ("since_2022_01_01", "2022-01-01")
        ]
        return try definitions.map { id, requested in
            let lower = max(first, requested ?? first)
            guard let actual = eligible.first(where: { $0 >= lower }) else { throw FreezeError.invalid("empty window \(id)") }
            return RSRangeBreadthWindow(id: id, requestedStart: requested, actualStart: actual, actualEnd: last)
        }
    }


    private static func verifySourceManifest(_ data: Data, root: URL, fixtureData: Data, fixtureSHA: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fixture = object["asset_time_machine_fixture"] as? [String: Any],
              fixture["path"] as? String == fixtureRelativePath,
              fixture["sha256"] as? String == fixtureSHA,
              (fixture["bytes"] as? NSNumber)?.intValue == fixtureData.count,
              let source = object["source"] as? [String: Any],
              let sourcePath = source["path"] as? String,
              let sourceSHA = source["sha256"] as? String,
              let sourceBytes = (source["bytes"] as? NSNumber)?.intValue else {
            throw FreezeError.invalid("source manifest does not bind fixture/source")
        }
        let sourceData = try Data(contentsOf: root.appendingPathComponent(sourcePath))
        guard sourceData.count == sourceBytes, RSRangeBreadthArtifactCodec.sha256(sourceData) == sourceSHA else {
            throw FreezeError.invalid("source workbook hash mismatch")
        }
    }

    private static func datasetManifest(
        gitCommit: String,
        fixtureBytes: Int,
        fixtureSHA: String,
        sourceManifestBytes: Int,
        sourceManifestSHA: String
    ) throws -> [String: Any] {
        return [
            "trial_id": trialID, "protocol_id": "ATM-SVP-2", "kind": "dataset",
            "implementation_commit": gitCommit, "cutoff": cutoff, "performance_viewed_before_freeze": false,
            "files": [
                ["path": fixtureRelativePath, "format": "json", "bytes": fixtureBytes, "sha256": fixtureSHA],
                ["path": sourceManifestRelativePath, "format": "json", "bytes": sourceManifestBytes, "sha256": sourceManifestSHA]
            ],
            "series_contract": [
                "asset_order": RSRangeBreadthStrategy.assetOrder,
                "fixture_symbol_mapping": ["gold_cny": "gold_cny", "nasdaq": "nasdaq_composite", "sp500": "sp500"],
                "fx_symbol": "usd_per_cny",
                "canonical_price_role": "valuation and executable-date eligibility only",
                "ohlc_role": "signal only; all four same-session fields converted together by BacktestAdvancedSeriesPreparer",
                "source_id_rule": "every frozen bar row carries fixture SHA, cutoff, App/fixture symbol, OHLC source/version; gold rows also carry Choice audit SHA"
            ],
            "runtime": ["swift": RSRangeBreadthRuntime.formal.swiftVersion, "target": RSRangeBreadthRuntime.formal.target,
                        "os": "macOS 26.5.2", "build": "25F84"]
        ]
    }

    private static func preregistration(
        gitCommit: String,
        datasetPath: String,
        datasetSHA: String,
        schedulePath: String,
        scheduleSHA: String,
        artifact: RSRangeBreadthFrozenArtifact,
        prepared: [(appSymbol: String, fixtureSymbol: String, series: PublicHistorySeries, value: PreparedAdvancedSeries)],
        fixtureSHA: String,
        sourceManifestSHA: String
    ) -> [String: Any] {
        let sourceRows: [[String: Any]] = prepared.map {
            ["symbol": $0.appSymbol, "fixture_symbol": $0.fixtureSymbol, "native_currency": $0.series.currency,
             "prepared_currency": "CNY", "canonical_source": $0.series.source,
             "ohlc_source": $0.series.ohlcSource ?? $0.series.source,
             "historical_fx": $0.appSymbol == "gold_cny" ? NSNull() : "usd_per_cny",
             "same_session_ohlc_conversion": true]
        }
        let windows: [[String: Any]] = artifact.actualWindows.map {
            ["id": $0.id, "requested_start": $0.requestedStart ?? NSNull(), "actual_start": $0.actualStart, "actual_end": $0.actualEnd]
        }
        return [
            "trial_id": trialID,
            "protocol_id": "ATM-SVP-2",
            "protocol_component": "ROGERS_SATCHELL_RANGE_BREADTH_21_252",
            "strategy_lineage": "rs-range-breadth-21-252-v1",
            "hypothesis": "Cross-asset contraction in true Rogers-Satchell range risk identifies calmer assets whose equal-weight allocation is more durable than state-independent natural drift; the opposite expanding-state schedule is a directional placebo.",
            "evidence_class": "R1_RETROSPECTIVE",
            "dataset_manifest": datasetPath,
            "allowed_changes": ["none after this freeze", "one exact candidate schedule", "natural and sign-placebo falsification controls only"],
            "candidate_ids": [RSRangeBreadthStrategy.strategyID],
            "candidate_count": 1,
            "selection_metric": "No parameter search and no selection. One candidate, one immutable schedule, one formal run; all four strategy windows and the factor-mechanism gate must pass.",
            "pass_fail_gates": [
                "factorMechanismPass: in every frozen window, at least two of three assets have unrounded median futureRisk(expanding)-median futureRisk(calm)>0, with at least five samples in each state per asset",
                "in each frozen window candidate CAGR>=10%, MDD<=10%, Sharpe>=0.8",
                "in each frozen window candidate Sharpe is strictly greater than natural and placebo",
                "in each frozen window candidate MDD is strictly less than natural",
                "all metrics use BacktestMetricsCalculator without pre-comparison rounding; missing or non-finite values fail",
                "requested and marked-to-market gross exposure<=100%, all weights/holdings/cash nonnegative, no financing, leverage or shorting",
                "shared BacktestDailySimulator trace must show every pending target completed before the next review"
            ],
            "formal_run_budget": 1,
            "follow_up_policy": "If any gate fails or the sole run is invalid, permanently close this exact candidate. No retry, parameter change, threshold, window, asset, source, cost, control, sign, lag or execution rescue is allowed after performance is opened.",
            "swift_engine_entrypoint": "RSRangeBreadthArtifactLoader date lookup only -> shared BacktestDailySimulator; schedule generation is prohibited during formal simulation",
            "expected_outputs": [
                "formal candidate/natural/placebo evidence for exactly four frozen windows",
                "factor-mechanism evidence for exactly four frozen windows",
                "immutable schedule fingerprints and shared-simulator queue trace",
                "constraint checks, run authorization receipt, execution record, stdout/stderr and SHA-256 artifact manifest"
            ],
            "implementation_commit": gitCommit,
            "runtime": ["swift": artifact.runtime.swiftVersion, "target": artifact.runtime.target,
                        "os_product": artifact.runtime.osProduct, "os_version": artifact.runtime.osVersion, "os_build": artifact.runtime.osBuild],
            "fixture": ["path": fixtureRelativePath, "sha256": fixtureSHA, "source_manifest_path": sourceManifestRelativePath,
                        "source_manifest_sha256": sourceManifestSHA, "dataset_manifest_sha256": datasetSHA, "cutoff": cutoff],
            "frozen_schedule": ["path": schedulePath, "sha256": scheduleSHA, "review_count": artifact.reviews.count,
                                "anchor_date": artifact.anchorDate, "actual_windows": windows,
                                "fingerprints": ["candidate": artifact.scheduleFingerprints.candidate,
                                                 "natural": artifact.scheduleFingerprints.natural,
                                                 "placebo": artifact.scheduleFingerprints.placebo,
                                                 "combined": artifact.combinedFingerprint]],
            "assets": sourceRows,
            "algorithm": [
                "asset_order": RSRangeBreadthStrategy.assetOrder, "lookback": 252, "short_lookback": 21, "review_step": 21,
                "daily_q": "log(high/close)*log(high/open)+log(low/close)*log(low/open); exact Swift operation order, micro-negative clamp to +0",
                "state": "longMean=sum(oldest-to-newest 252 q)/252; shortMean=sum(oldest-to-newest final 21 q)/21; x=shortMean/longMean-1; x<=0 calm, x>0 expanding; nonpositive/nonfinite longMean invalid",
                "candidate": "equal weight across valid calm assets; cash if none",
                "natural": "one-third each at anchor, then natural drift; unchanged reviews suppressed",
                "placebo": "equal weight across valid expanding assets; cash if none",
                "clock": "anchor is earliest common valid-OHLC date with 252 own valid bars per asset; review anchor+21*m on common OHLC ordinal",
                "execution": "strictly later joint canonical prepared-price date with same-session USD FX; sell-before-buy, with replacement buy on the next eligible date; zero vector uses the same eligibility rule",
                "fingerprint_grammar": "ATM_RS_RANGE_BREADTH_SCHEDULE_V1 as documented in RSRangeBreadthStrategy.swift; U64 big-endian lengths/counts/integers, IEEE-754 binary64 bits big-endian, explicit bool/enum/optional tags, fixed field and asset order"
            ],
            "cost_model": ["initial_cash_cny": 100000, "fee_rate_percent": BacktestDefaults.advancedFeeRatePercent,
                           "slippage_rate_percent": BacktestDefaults.advancedSlippageRatePercent,
                           "cash_yield": "CashYieldCNY PBOC historical demand-deposit rules",
                           "rebalance_band": 0, "allows_financed_exposure": false, "financing_annual_rate": 0],
            "factor_gate": [
                "sample": "each formal review x asset with valid signal x",
                "future_risk": "mean q over exactly 21 strictly subsequent own valid bars divided by signal-date longMean",
                "tail_rule": "fewer than 21 future valid bars excludes only that sample and is reported; overlapping samples retained",
                "groups": "expanding x>0 versus calm x<=0", "minimum_per_group_per_asset_window": 5,
                "window_pass": "at least two of three assets have unrounded median(expanding futureRisk)-median(calm futureRisk)>0",
                "overall_pass": "all four windows pass; missing/nonfinite evidence fails the candidate"
            ],
            "evaluation_windows": windows,
            "no_search_policy": ["no arguments expose strategy parameters", "unique formal run only", "failure is not rerun", "controls cannot be promoted"],
            "return_blind_freeze": true
        ]
    }

    private static func stableJSON(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        return data
    }

    private static func requireFormalGitState(root: URL, commit: String) throws {
        let head = try process("/usr/bin/git", ["rev-parse", "HEAD"], root: root).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == commit else { throw FreezeError.invalid("formal --git-commit must equal HEAD") }
        let status = try process("/usr/bin/git", ["status", "--porcelain", "--untracked-files=all"], root: root)
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FreezeError.invalid("formal freeze requires a clean implementation commit before artifact generation")
        }
    }

    private static func process(_ executable: String, _ arguments: [String], root: URL) throws -> String {
#if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw FreezeError.invalid("git check failed: \(output)") }
        return output
#else
        throw FreezeError.invalid("freeze CLI process execution is available on macOS only")
#endif
    }

    private static func fileSHA256(_ url: URL, root: URL) throws -> String {
        let output = try process("/usr/bin/shasum", ["-a", "256", url.path], root: root)
        guard let digest = output.split(separator: " ").first.map(String.init),
              digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }) else {
            throw FreezeError.invalid("invalid shasum output for \(url.path)")
        }
        return digest.lowercased()
    }
}
