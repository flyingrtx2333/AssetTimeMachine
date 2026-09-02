import Foundation

nonisolated struct IntradayDownsideBreadthFactorObservation: Equatable {
    let reviewDate: String
    let breadth: Int
    let outcome: Double
}

nonisolated struct IntradayDownsideBreadthFactorWindowEvidence: Equatable {
    let windowID: String
    let riskCount: Int
    let calmCount: Int
    let riskMedian: Double?
    let calmMedian: Double?
    let sufficient: Bool
    let direction: Bool
    let observations: [IntradayDownsideBreadthFactorObservation]
}

nonisolated struct IntradayDownsideBreadthFactorEvidence: Equatable {
    let windows: [IntradayDownsideBreadthFactorWindowEvidence]

    var sufficient: Bool { !windows.isEmpty && windows.allSatisfy(\.sufficient) }
    var direction: Bool { !windows.isEmpty && windows.allSatisfy(\.direction) }
}

nonisolated enum IntradayDownsideBreadthFormalFactor {
    /// Reconstructs the factor series solely from exact x values embedded in the frozen schedule.
    /// Repeated overlapping bars must agree bit-for-bit.
    static func evaluate(
        artifact: IntradayDownsideBreadthFrozenArtifact
    ) throws -> IntradayDownsideBreadthFactorEvidence {
        guard artifact.signalCommonDates == Array(Set(artifact.signalCommonDates)).sorted(),
              artifact.reviews.map(\.date) == artifact.reviews.map(\.date).sorted(),
              artifact.actualWindows.map(\.id).allUnique else {
            throw IntradayDownsideBreadthError.invalidInput("formal factor date/window identity")
        }

        var xBySymbolAndDate: [String: [String: Double]] = [:]
        for review in artifact.reviews {
            guard review.assets.map(\.symbol) == artifact.signalAssetOrder else {
                throw IntradayDownsideBreadthError.invalidInput("formal factor signal assets")
            }
            for asset in review.assets {
                for bar in asset.bars {
                    guard bar.x.value.isFinite else {
                        throw IntradayDownsideBreadthError.invalidInput("formal factor nonfinite x")
                    }
                    if let existing = xBySymbolAndDate[asset.symbol]?[bar.date],
                       existing.bitPattern != bar.x.value.bitPattern {
                        throw IntradayDownsideBreadthError.invalidInput(
                            "formal factor inconsistent x \(asset.symbol) \(bar.date)"
                        )
                    }
                    xBySymbolAndDate[asset.symbol, default: [:]][bar.date] = bar.x.value
                }
            }
        }

        var eligible: [IntradayDownsideBreadthFactorObservation] = []
        for review in artifact.reviews {
            guard let ordinal = artifact.signalCommonDates.firstIndex(of: review.date) else {
                throw IntradayDownsideBreadthError.invalidInput("formal factor review date coverage")
            }
            let end = ordinal + IntradayDownsideBreadthStrategy.reviewStep
            guard artifact.signalCommonDates.indices.contains(end) else { continue }
            let futureDates = artifact.signalCommonDates[(ordinal + 1)...end]
            var sums: [Double] = []
            for symbol in IntradayDownsideBreadthStrategy.signalAssetOrder {
                var sum = 0.0
                for date in futureDates {
                    guard let x = xBySymbolAndDate[symbol]?[date], x.isFinite else {
                        throw IntradayDownsideBreadthError.invalidInput(
                            "formal factor insufficient date coverage \(symbol) \(date)"
                        )
                    }
                    sum += x
                }
                guard sum.isFinite else {
                    throw IntradayDownsideBreadthError.invalidInput("formal factor nonfinite sum")
                }
                sums.append(sum)
            }
            guard sums.count == 2 else {
                throw IntradayDownsideBreadthError.invalidInput("formal factor outcome assets")
            }
            let outcome = 0.5 * (sums[0] + sums[1])
            let breadth = review.assets.reduce(0) { $0 + ($1.mean.value < 0 ? 1 : 0) }
            guard outcome.isFinite, (0...2).contains(breadth) else {
                throw IntradayDownsideBreadthError.invalidInput("formal factor observation")
            }
            eligible.append(.init(reviewDate: review.date, breadth: breadth, outcome: outcome))
        }

        let windows = try artifact.actualWindows.map { window in
            guard window.actualStart <= window.actualEnd else {
                throw IntradayDownsideBreadthError.invalidInput("formal factor window \(window.id)")
            }
            let observations = eligible.filter {
                $0.reviewDate >= window.actualStart && $0.reviewDate <= window.actualEnd
            }
            let risk = observations.filter { $0.breadth >= 1 }.map(\.outcome)
            let calm = observations.filter { $0.breadth == 0 }.map(\.outcome)
            let riskMedian = median(risk)
            let calmMedian = median(calm)
            let sufficient = risk.count >= 5 && calm.count >= 5
            let direction = sufficient
                && riskMedian.map { riskValue in calmMedian.map { riskValue < $0 } ?? false } ?? false
            return IntradayDownsideBreadthFactorWindowEvidence(
                windowID: window.id,
                riskCount: risk.count,
                calmCount: calm.count,
                riskMedian: riskMedian,
                calmMedian: calmMedian,
                sufficient: sufficient,
                direction: direction,
                observations: observations
            )
        }
        return .init(windows: windows)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

nonisolated struct IntradayDownsideBreadthFormalMetrics: Equatable {
    let cagr: Double?
    let sharpe: Double?
    let maxDrawdown: Double?

    init(cagr: Double?, sharpe: Double?, maxDrawdown: Double?) {
        self.cagr = cagr
        self.sharpe = sharpe
        self.maxDrawdown = maxDrawdown
    }

    init(_ metrics: BacktestPerformanceMetrics) {
        self.init(
            cagr: metrics.annualizedReturn,
            sharpe: metrics.sharpeRatio,
            maxDrawdown: metrics.maxDrawdown
        )
    }

    var isCompleteAndFinite: Bool {
        guard let cagr, let sharpe, let maxDrawdown else { return false }
        return cagr.isFinite && sharpe.isFinite && maxDrawdown.isFinite
    }
}

nonisolated enum IntradayDownsideBreadthFormalDecision: String, Equatable {
    case invalid = "INVALID"
    case pass = "PASS"
    case fail = "FAIL"
}

nonisolated struct IntradayDownsideBreadthFormalGateResult: Equatable {
    let decision: IntradayDownsideBreadthFormalDecision
    let checksByWindow: [String: Bool]
}

nonisolated enum IntradayDownsideBreadthFormalGate {
    static func evaluate(
        windows: [IntradayDownsideBreadthWindow],
        candidate: [String: IntradayDownsideBreadthFormalMetrics],
        natural: [String: IntradayDownsideBreadthFormalMetrics],
        placebo: [String: IntradayDownsideBreadthFormalMetrics],
        factor: IntradayDownsideBreadthFactorEvidence
    ) -> IntradayDownsideBreadthFormalGateResult {
        let requiredWindowIdentity: [(String, String?)] = [
            ("full", nil),
            ("since_2016_08_31", "2016-08-31"),
            ("since_2020_01_01", "2020-01-01"),
            ("since_2022_01_01", "2022-01-01")
        ]
        guard windows.count == requiredWindowIdentity.count,
              zip(windows, requiredWindowIdentity).allSatisfy({ window, expected in
                  window.id == expected.0 && window.requestedStart == expected.1
              }) else {
            return .init(decision: .fail, checksByWindow: [:])
        }
        let groupedFactor = Dictionary(grouping: factor.windows, by: \.windowID)
        if windows.isEmpty || windows.contains(where: { groupedFactor[$0.id]?.first?.sufficient != true }) {
            return .init(decision: .invalid, checksByWindow: [:])
        }
        guard windows.map(\.id).allUnique,
              windows.allSatisfy({ groupedFactor[$0.id]?.count == 1 }) else {
            return .init(decision: .fail, checksByWindow: [:])
        }
        let factorByWindow = groupedFactor.mapValues { $0[0] }

        var checks: [String: Bool] = [:]
        for window in windows {
            let id = window.id
            guard let c = candidate[id], let n = natural[id], let p = placebo[id],
                  c.isCompleteAndFinite, n.isCompleteAndFinite, p.isCompleteAndFinite,
                  let cagr = c.cagr, let cSharpe = c.sharpe, let cMDD = c.maxDrawdown,
                  let nSharpe = n.sharpe, let nMDD = n.maxDrawdown,
                  let pSharpe = p.sharpe else {
                checks[id] = false
                continue
            }
            checks[id] = cagr >= 0.09
                && cSharpe >= 0.80
                && cMDD <= 0.10
                && cSharpe > nSharpe
                && cSharpe > pSharpe
                && cMDD < nMDD
                && factorByWindow[id]?.direction == true
        }
        let pass = checks.count == windows.count && checks.values.allSatisfy { $0 }
        return .init(decision: pass ? .pass : .fail, checksByWindow: checks)
    }
}

nonisolated enum IntradayDownsideBreadthFormalSimulation {
    /// Executes exactly one frozen variant through the shared production simulator and computes
    /// each frozen window with the production metrics calculator.
    static func runVariant(
        artifact: IntradayDownsideBreadthFrozenArtifact,
        variant: IntradayDownsideBreadthStrategy.Variant,
        frame: MarketDataFrame,
        execution: BacktestExecutionConfig
    ) throws -> [String: BacktestPerformanceMetrics] {
        let validation = try IntradayDownsideBreadthSharedSimulator.run(
            artifact: artifact,
            variant: variant,
            frame: frame,
            execution: execution
        )
        var result: [String: BacktestPerformanceMetrics] = [:]
        for window in artifact.actualWindows {
            let points = validation.simulation.points.filter {
                let date = $0.date.recordDateString
                return date >= window.actualStart && date <= window.actualEnd
            }
            guard let metrics = BacktestMetricsCalculator.performanceMetrics(from: points) else {
                throw IntradayDownsideBreadthError.invalidInput("formal metrics unavailable \(window.id)")
            }
            result[window.id] = metrics
        }
        return result
    }
}

private extension Array where Element: Hashable {
    var allUnique: Bool { Set(self).count == count }
}

/// One-shot formal consumer. It loads only the frozen schedule and the fixture bound into that
/// schedule; strategy parameters and schedule generation are deliberately not exposed as options.
nonisolated public enum IntradayDownsideBreadthFormalCommand {
    private static let schedulePath = "tools/research-results/strategy-validation/preregistrations/IDB-63-21-schedule.json"
    private static let preregistrationPath = "tools/research-results/strategy-validation/preregistrations/ATM-SVP2-IDB-63-21-001.json"
    private static let datasetPath = "tools/research-results/strategy-validation/datasets/ATM-SVP2-IDB-63-21-001.json"
    private static let ledgerPath = "tools/research-results/strategy-validation/trial-ledger.jsonl"

    public static func run(arguments: [String]) throws {
        guard arguments.count == 4,
              arguments[0] == "--repo-root",
              arguments[2] == "--output-dir" else {
            throw CommandError("usage: IntradayDownsideBreadthFormal --repo-root <path> --output-dir <path>")
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        let output = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
        let preregistration = try validateFormalGuardAndInputs(root: root, output: output)

        let scheduleData = try Data(contentsOf: root.appendingPathComponent(schedulePath))
        let artifact = try IntradayDownsideBreadthArtifactLoader.load(
            data: scheduleData,
            enforceFormalRuntime: true
        ).artifact
        guard artifact.gitCommit == preregistration["implementation_commit"] as? String else {
            throw CommandError("implementation commit binding mismatch")
        }
        let fixtureData = try boundData(
            root: root,
            relativePath: artifact.fixturePath,
            expectedSHA256: artifact.fixtureSHA256,
            label: "fixture"
        )
        _ = try boundData(
            root: root,
            relativePath: artifact.provenancePath,
            expectedSHA256: artifact.provenanceSHA256,
            label: "provenance"
        )

        // The factor gate is intentionally opened before any portfolio performance. An
        // insufficient sample makes the run INVALID without executing a simulator variant.
        let factor = try IntradayDownsideBreadthFormalFactor.evaluate(artifact: artifact)
        guard factor.sufficient else {
            let result: [String: Any] = [
                "protocol_id": "ATM-SVP-2",
                "trial_id": IntradayDownsideBreadthStrategy.trialID,
                "candidate_id": IntradayDownsideBreadthStrategy.strategyID,
                "schedule_fingerprints": fingerprintObject(artifact),
                "factor_mechanism": factorObject(factor),
                "candidate": [:], "natural": [:], "placebo": [:],
                "checks": [:], "decision": IntradayDownsideBreadthFormalDecision.invalid.rawValue
            ]
            try stableJSON(result).write(to: output.appendingPathComponent("candidate-metrics.json"), options: .atomic)
            try stableJSON(["candidate": [], "natural": [], "placebo": []]).write(
                to: output.appendingPathComponent("queue-trace.json"), options: .atomic
            )
            print("INTRADAY_DOWNSIDE_BREADTH_FORMAL_COMPLETE decision=INVALID")
            return
        }

        let response = try JSONDecoder().decode(PublicHistoryResponse.self, from: fixtureData)
        guard response.success else { throw CommandError("fixture success=false") }
        let source = Dictionary(uniqueKeysWithValues: response.series.map { ($0.symbol, $0) })
        guard let fx = source["usd_per_cny"],
              let cutoff = artifact.actualWindows.map(\.actualEnd).max() else {
            throw CommandError("fixture inputs missing")
        }
        let mapping = [("gold_cny", "gold_cny"), ("nasdaq", "nasdaq_composite"), ("sp500", "sp500")]
        let inputs = try mapping.map { app, fixture -> (PublicHistorySeries?, BacktestAssetOption, PublicHistorySeries?) in
            guard let series = source[fixture],
                  let option = BacktestDefaults.dcaAssetOptions.first(where: { $0.symbol == app }) else {
                throw CommandError("missing asset \(app)")
            }
            return (clipped(series, through: cutoff), option, app == "gold_cny" ? nil : clipped(fx, through: cutoff))
        }
        let config = ResearchTargetStrategyConfig(
            symbol: "idb_63_21", title: IntradayDownsideBreadthStrategy.strategyID,
            warmupSessions: 1, rebalanceSessions: 1, rebalanceBand: 0,
            maxGrossExposure: 1, allowsFinancedExposure: false, financingAnnualRate: 0,
            buyReason: "IDB frozen schedule target"
        )
        guard let frame = BacktestEngine.researchMarketDataFrame(assetInputs: inputs, config: config) else {
            throw CommandError("frame preparation failed")
        }
        let executableSet = Set(artifact.executableDates)
        guard frame.dates.map({ $0.recordDateString }).filter({ executableSet.contains($0) }) == artifact.executableDates else {
            throw CommandError("executable date binding mismatch")
        }
        let execution = BacktestExecutionConfig(
            initialCash: 100_000,
            feeRate: 0.01,
            slippageRate: 0.0005,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false,
            buyReason: "IDB frozen schedule target"
        )

        var metrics: [IntradayDownsideBreadthStrategy.Variant: [String: IntradayDownsideBreadthFormalMetrics]] = [:]
        var traces: [IntradayDownsideBreadthStrategy.Variant: [IntradayDownsideBreadthExecutionTrace]] = [:]
        for variant in IntradayDownsideBreadthStrategy.Variant.allCases {
            let validation = try IntradayDownsideBreadthSharedSimulator.run(
                artifact: artifact, variant: variant, frame: frame, execution: execution
            )
            metrics[variant] = try windowMetrics(
                points: validation.simulation.points,
                windows: artifact.actualWindows
            )
            traces[variant] = validation.trace
        }
        guard let candidate = metrics[.candidate],
              let natural = metrics[.natural],
              let placebo = metrics[.placebo] else {
            throw CommandError("missing formal variant")
        }
        let gate = IntradayDownsideBreadthFormalGate.evaluate(
            windows: artifact.actualWindows,
            candidate: candidate, natural: natural, placebo: placebo, factor: factor
        )
        let result: [String: Any] = [
            "protocol_id": "ATM-SVP-2",
            "trial_id": IntradayDownsideBreadthStrategy.trialID,
            "candidate_id": IntradayDownsideBreadthStrategy.strategyID,
            "engine_version": BacktestEngine.defaultEngineVersion,
            "schedule_fingerprints": fingerprintObject(artifact),
            "candidate": metricsObject(candidate),
            "natural": metricsObject(natural),
            "placebo": metricsObject(placebo),
            "factor_mechanism": factorObject(factor),
            "checks": gate.checksByWindow,
            "decision": gate.decision.rawValue
        ]
        let trace: [String: Any] = Dictionary(uniqueKeysWithValues: IntradayDownsideBreadthStrategy.Variant.allCases.map { variant in
            (variantName(variant), (traces[variant] ?? []).map {
                ["review_date": $0.reviewDate, "completion_date": $0.completionDate]
            })
        })
        try stableJSON(result).write(to: output.appendingPathComponent("candidate-metrics.json"), options: .atomic)
        try stableJSON(trace).write(to: output.appendingPathComponent("queue-trace.json"), options: .atomic)
        print("INTRADAY_DOWNSIDE_BREADTH_FORMAL_COMPLETE decision=\(gate.decision.rawValue)")
    }

    private static func validateFormalGuardAndInputs(root: URL, output: URL) throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let required = [
            "ATM_SVP_PROTOCOL_ID", "ATM_SVP_TRIAL_ID", "ATM_SVP_PREREGISTRATION_RECORD_HASH",
            "ATM_SVP_EXECUTION_GIT_COMMIT", "ATM_SVP_RUN_GUARD_RECEIPT",
            "ATM_SVP_RUN_BUDGET_RECORD_HASH", "ATM_SVP_RUN_SLOT", "ATM_SVP_RUN_SLOT_SHA256",
            "ATM_SVP_EXECUTABLE_SHA256"
        ]
        guard required.allSatisfy({ environment[$0]?.isEmpty == false }),
              environment["ATM_SVP_PROTOCOL_ID"] == "ATM-SVP-2",
              environment["ATM_SVP_TRIAL_ID"] == IntradayDownsideBreadthStrategy.trialID else {
            throw CommandError("formal guard environment missing or mismatched")
        }
        let fixedOutput = root.appendingPathComponent(
            "tools/research-results/strategy-validation/runs/\(IntradayDownsideBreadthStrategy.trialID)",
            isDirectory: true
        ).standardizedFileURL
        guard output == fixedOutput, FileManager.default.fileExists(atPath: output.path) else {
            throw CommandError("formal output directory missing or not the fixed trial slot")
        }
        let receipt = URL(fileURLWithPath: environment["ATM_SVP_RUN_GUARD_RECEIPT"]!).standardizedFileURL
        let receiptNames = Set(["run-authorization.json", "run-guard-receipt.json"])
        guard receipt.deletingLastPathComponent() == output,
              receiptNames.contains(receipt.lastPathComponent) else {
            throw CommandError("formal guard receipt path mismatch")
        }
        let existing = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        let existingNames = Set(existing.map(\.lastPathComponent))
        let standardWrapperFiles = Set([
            "run-authorization.json", "stdout.txt", "stderr.txt",
            "run-budget-reservation.json", "run-slot.json"
        ])
        guard existingNames == ["run-guard-receipt.json"] || existingNames == standardWrapperFiles else {
            throw CommandError("formal output directory is not guard-clean")
        }
        let receiptData = try Data(contentsOf: receipt)
        let receiptObject = try object(receiptData, label: "formal guard receipt")
        let recordHash = environment["ATM_SVP_PREREGISTRATION_RECORD_HASH"]!
        let runBudgetRecordHash = environment["ATM_SVP_RUN_BUDGET_RECORD_HASH"]!
        let executionCommit = environment["ATM_SVP_EXECUTION_GIT_COMMIT"]!
        guard receiptObject["trial_id"] as? String == IntradayDownsideBreadthStrategy.trialID,
              receiptObject["preregistration_record_hash"] as? String == recordHash,
              receiptObject["execution_git_commit"] as? String == executionCommit,
              receiptObject["run_budget_record_hash"] as? String == runBudgetRecordHash,
              (receiptObject["formal_run_budget"] as? NSNumber)?.intValue == 1,
              (receiptObject["candidate_count"] as? NSNumber)?.intValue == 1,
              try gitHead(root: root) == executionCommit else {
            throw CommandError("formal guard receipt mismatch")
        }
        try validateRuntime()
        try validateCleanCommittedSource(root: root, receipt: receipt)

        let gitDirectoryValue = try processOutput("/usr/bin/git", ["rev-parse", "--git-dir"], root: root)
        let gitDirectory = URL(fileURLWithPath: gitDirectoryValue, relativeTo: root).standardizedFileURL
        let slot = URL(fileURLWithPath: environment["ATM_SVP_RUN_SLOT"]!).standardizedFileURL
        let expectedSlot = gitDirectory.appendingPathComponent(
            "atm-svp-run-slots/\(IntradayDownsideBreadthStrategy.trialID).json"
        ).standardizedFileURL
        let slotData = try Data(contentsOf: slot)
        guard slot == expectedSlot,
              IntradayDownsideBreadthArtifactCodec.sha256(slotData) == environment["ATM_SVP_RUN_SLOT_SHA256"],
              let executable = Bundle.main.executableURL,
              IntradayDownsideBreadthArtifactCodec.sha256(try Data(contentsOf: executable)) == environment["ATM_SVP_EXECUTABLE_SHA256"] else {
            throw CommandError("formal one-shot slot or executable binding mismatch")
        }
        let slotObject = try object(slotData, label: "formal one-shot slot")
        let expectedRuntime: [String: Any] = [
            "swift_version": IntradayDownsideBreadthRuntime.formal.swiftVersion,
            "target": IntradayDownsideBreadthRuntime.formal.target,
            "os_product": IntradayDownsideBreadthRuntime.formal.osProduct,
            "os_version": IntradayDownsideBreadthRuntime.formal.osVersion,
            "os_build": IntradayDownsideBreadthRuntime.formal.osBuild
        ]
        guard (slotObject["schema_version"] as? NSNumber)?.intValue == 1,
              slotObject["trial_id"] as? String == IntradayDownsideBreadthStrategy.trialID,
              slotObject["protocol_id"] as? String == "ATM-SVP-2",
              slotObject["execution_git_commit"] as? String == executionCommit,
              slotObject["preregistration_record_hash"] as? String == recordHash,
              slotObject["run_budget_record_hash"] as? String == runBudgetRecordHash,
              slotObject["output_directory"] as? String == output.path.replacingOccurrences(of: root.path + "/", with: ""),
              slotObject["guard_receipt_sha256"] as? String == IntradayDownsideBreadthArtifactCodec.sha256(receiptData),
              slotObject["executable_sha256"] as? String == environment["ATM_SVP_EXECUTABLE_SHA256"],
              let slotRuntime = slotObject["runtime"] as? [String: Any],
              NSDictionary(dictionary: slotRuntime).isEqual(to: expectedRuntime),
              (slotObject["nonce"] as? String)?.count == 64 else {
            throw CommandError("formal one-shot slot payload mismatch")
        }

        let preregistrationData = try Data(contentsOf: root.appendingPathComponent(preregistrationPath))
        let preregistration = try object(preregistrationData, label: "preregistration")
        guard preregistration["trial_id"] as? String == IntradayDownsideBreadthStrategy.trialID,
              preregistration["protocol_id"] as? String == "ATM-SVP-2",
              preregistration["protocol_component"] as? String == "INTRADAY_DOWNSIDE_BREADTH_GOLD_ROTATION",
              preregistration["candidate_ids"] as? [String] == [IntradayDownsideBreadthStrategy.strategyID],
              preregistration["dataset_manifest"] as? String == datasetPath,
              preregistration["requires_durable_run_reservation"] as? Bool == true,
              let authority = preregistration["run_budget_authority"] as? [String: Any],
              authority["kind"] as? String == "git-remote-immutable-tag-cas",
              authority["remote"] as? String == "origin",
              authority["base_branch"] as? String == "main",
              authority["ref"] as? String == "refs/tags/atm-run-budget/ATM-SVP2-IDB-63-21-001",
              preregistration["dataset_manifest_sha256"] as? String == IntradayDownsideBreadthArtifactCodec.sha256(
                try Data(contentsOf: root.appendingPathComponent(datasetPath))
              ) else {
            throw CommandError("preregistration identity or dataset binding mismatch")
        }
        guard let cost = preregistration["cost_model"] as? [String: Any],
              (cost["initial_cash_cny"] as? NSNumber)?.doubleValue == 100_000,
              (cost["transaction_fee_rate"] as? NSNumber)?.doubleValue == 0.01,
              (cost["slippage_rate"] as? NSNumber)?.doubleValue == 0.0005,
              (cost["financing_annual_rate"] as? NSNumber)?.doubleValue == 0,
              cost["allows_financed_exposure"] as? Bool == false,
              cost["sensitivity_runs_allowed"] as? Bool == false,
              let implementationCommit = preregistration["implementation_commit"] as? String,
              implementationCommit.count == 40 else {
            throw CommandError("formal cost or implementation contract mismatch")
        }
        try validatePostImplementationChanges(
            root: root, implementationCommit: implementationCommit, executionCommit: executionCommit
        )
        guard let frozen = preregistration["frozen_schedule"] as? [String: Any],
              frozen["path"] as? String == schedulePath,
              frozen["sha256"] as? String == IntradayDownsideBreadthArtifactCodec.sha256(
                try Data(contentsOf: root.appendingPathComponent(schedulePath))
              ) else {
            throw CommandError("preregistration schedule binding mismatch")
        }

        let ledgerData = try String(contentsOf: root.appendingPathComponent(ledgerPath), encoding: .utf8)
        var matchedLedgerPayload = false
        var matchedRunBudget = false
        for line in ledgerData.split(whereSeparator: \.isNewline) {
            let record = try object(Data(line.utf8), label: "ledger record")
            if record["event"] as? String == "RESULT",
               let payload = record["payload"] as? [String: Any],
               payload["trial_id"] as? String == IntradayDownsideBreadthStrategy.trialID {
                throw CommandError("formal RESULT already exists")
            }
            guard record["record_hash"] as? String == recordHash,
                  record["event"] as? String == "PREREGISTER",
                  let payload = record["payload"] as? [String: Any] else { continue }
            matchedLedgerPayload = NSDictionary(dictionary: payload).isEqual(to: preregistration)
        }
        for line in ledgerData.split(whereSeparator: \.isNewline) {
            let record = try object(Data(line.utf8), label: "ledger record")
            guard record["record_hash"] as? String == runBudgetRecordHash,
                  record["event"] as? String == "RUN_STARTED",
                  let payload = record["payload"] as? [String: Any] else { continue }
            matchedRunBudget = payload["trial_id"] as? String == IntradayDownsideBreadthStrategy.trialID
                && payload["preregistration_record_hash"] as? String == recordHash
                && payload["permanent"] as? Bool == true
                && payload["authority_remote"] as? String == "origin"
                && payload["authority_ref"] as? String == "refs/tags/atm-run-budget/ATM-SVP2-IDB-63-21-001"
                && (payload["authority_base_commit"] as? String)?.count == 40
        }
        guard matchedLedgerPayload, matchedRunBudget else {
            throw CommandError("preregistration or durable run-budget ledger binding mismatch")
        }

        let dataset = try object(
            try Data(contentsOf: root.appendingPathComponent(datasetPath)), label: "dataset manifest"
        )
        guard dataset["trial_id"] as? String == IntradayDownsideBreadthStrategy.trialID,
              dataset["return_blind_freeze"] as? Bool == true,
              let files = dataset["files"] as? [[String: Any]] else {
            throw CommandError("dataset manifest malformed")
        }
        for file in files {
            guard let path = file["path"] as? String,
                  let digest = file["sha256"] as? String,
                  let byteCount = (file["bytes"] as? NSNumber)?.intValue,
                  !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw CommandError("dataset file entry malformed")
            }
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            guard data.count == byteCount,
                  IntradayDownsideBreadthArtifactCodec.sha256(data) == digest else {
                throw CommandError("dataset file mismatch: \(path)")
            }
        }
        try consumeLaunchMarker(
            slot: slot,
            slotSHA256: environment["ATM_SVP_RUN_SLOT_SHA256"]!,
            executableSHA256: environment["ATM_SVP_EXECUTABLE_SHA256"]!,
            receiptSHA256: IntradayDownsideBreadthArtifactCodec.sha256(receiptData),
            executionCommit: executionCommit,
            runBudgetRecordHash: runBudgetRecordHash,
            output: output
        )
        return preregistration
    }

    static func consumeLaunchMarker(
        slot: URL,
        slotSHA256: String,
        executableSHA256: String,
        receiptSHA256: String,
        executionCommit: String,
        runBudgetRecordHash: String,
        output: URL
    ) throws {
        let marker = slot.deletingPathExtension().appendingPathExtension("launched.json")
        let payload: [String: Any] = [
            "schema_version": 1,
            "trial_id": IntradayDownsideBreadthStrategy.trialID,
            "slot_sha256": slotSHA256,
            "executable_sha256": executableSHA256,
            "guard_receipt_sha256": receiptSHA256,
            "execution_git_commit": executionCommit,
            "run_budget_record_hash": runBudgetRecordHash,
            "state": "LAUNCHED_PERMANENT_NO_RETRY"
        ]
        do {
            let data = try stableJSON(payload)
            try data.write(to: marker, options: .withoutOverwriting)
            try data.write(to: output.appendingPathComponent("launch-marker.json"), options: .withoutOverwriting)
        } catch {
            throw CommandError("formal launch marker already exists or cannot be consumed")
        }
    }

    private static func object(_ data: Data, label: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandError("\(label) is not an object")
        }
        return value
    }

    private static func gitHead(root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "HEAD"]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            throw CommandError("cannot resolve execution Git commit")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func processOutput(_ executable: String, _ arguments: [String], root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw CommandError(output) }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validateRuntime() throws {
        let root = URL(fileURLWithPath: "/")
        let swift = try processOutput("/usr/bin/xcrun", ["swift", "--version"], root: root)
            .split(whereSeparator: \.isNewline).map(String.init)
        guard swift.first == IntradayDownsideBreadthRuntime.formal.swiftVersion,
              swift.dropFirst().first == "Target: \(IntradayDownsideBreadthRuntime.formal.target)",
              try processOutput("/usr/bin/sw_vers", ["-productName"], root: root) == IntradayDownsideBreadthRuntime.formal.osProduct,
              try processOutput("/usr/bin/sw_vers", ["-productVersion"], root: root) == IntradayDownsideBreadthRuntime.formal.osVersion,
              try processOutput("/usr/bin/sw_vers", ["-buildVersion"], root: root) == IntradayDownsideBreadthRuntime.formal.osBuild else {
            throw CommandError("actual formal runtime mismatch")
        }
    }

    private static func validateCleanCommittedSource(root: URL, receipt: URL) throws {
        _ = try processOutput("/usr/bin/git", ["diff", "--quiet"], root: root)
        _ = try processOutput("/usr/bin/git", ["diff", "--cached", "--quiet"], root: root)
        let untracked = Set(try processOutput(
            "/usr/bin/git", ["ls-files", "--others", "--exclude-standard"], root: root
        ).split(whereSeparator: \.isNewline).map(String.init))
        let expectedReceipt = receipt.path.replacingOccurrences(of: root.path + "/", with: "")
        let output = receipt.deletingLastPathComponent()
        let standardWrapperFiles = Set([
            receipt.lastPathComponent,
            "stdout.txt",
            "stderr.txt",
            "run-budget-reservation.json",
            "run-slot.json"
        ].map { output.appendingPathComponent($0).path.replacingOccurrences(of: root.path + "/", with: "") })
        guard untracked == [expectedReceipt] || untracked == standardWrapperFiles else {
            throw CommandError("formal execution has unexpected untracked files")
        }
    }

    private static func validatePostImplementationChanges(
        root: URL, implementationCommit: String, executionCommit: String
    ) throws {
        let changed = Set(try processOutput(
            "/usr/bin/git", ["diff", "--name-only", "\(implementationCommit)..\(executionCommit)"], root: root
        ).split(whereSeparator: \.isNewline).map(String.init))
        let allowed: Set<String> = [preregistrationPath, schedulePath, datasetPath, ledgerPath]
        guard changed.isSubset(of: allowed) else {
            throw CommandError("formal source changed after implementation freeze")
        }
    }

    private static func boundData(
        root: URL,
        relativePath: String,
        expectedSHA256: String,
        label: String
    ) throws -> Data {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw CommandError("invalid \(label) path")
        }
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        guard IntradayDownsideBreadthArtifactCodec.sha256(data) == expectedSHA256 else {
            throw CommandError("\(label) hash mismatch")
        }
        return data
    }

    private static func windowMetrics(
        points: [BacktestSeriesPoint],
        windows: [IntradayDownsideBreadthWindow]
    ) throws -> [String: IntradayDownsideBreadthFormalMetrics] {
        var result: [String: IntradayDownsideBreadthFormalMetrics] = [:]
        for window in windows {
            let slice = points.filter {
                let date = $0.date.recordDateString
                return date >= window.actualStart && date <= window.actualEnd
            }
            guard let value = BacktestMetricsCalculator.performanceMetrics(from: slice) else {
                throw CommandError("formal metrics unavailable \(window.id)")
            }
            result[window.id] = .init(value)
        }
        return result
    }

    private static func metricsObject(
        _ values: [String: IntradayDownsideBreadthFormalMetrics]
    ) -> [String: Any] {
        values.mapValues { value in
            [
                "cagr": value.cagr.map { $0 as Any } ?? NSNull(),
                "sharpe": value.sharpe.map { $0 as Any } ?? NSNull(),
                "mdd": value.maxDrawdown.map { $0 as Any } ?? NSNull()
            ]
        }
    }

    private static func factorObject(_ factor: IntradayDownsideBreadthFactorEvidence) -> [String: Any] {
        [
            "sufficient": factor.sufficient,
            "direction": factor.direction,
            "windows": Dictionary(uniqueKeysWithValues: factor.windows.map { window in
                (window.windowID, [
                    "risk_count": window.riskCount,
                    "calm_count": window.calmCount,
                    "risk_median": window.riskMedian.map { $0 as Any } ?? NSNull(),
                    "calm_median": window.calmMedian.map { $0 as Any } ?? NSNull(),
                    "sufficient": window.sufficient,
                    "direction": window.direction
                ] as [String: Any])
            })
        ]
    }

    private static func fingerprintObject(_ artifact: IntradayDownsideBreadthFrozenArtifact) -> [String: String] {
        ["header": artifact.fingerprints.header, "input": artifact.fingerprints.input,
         "candidate": artifact.fingerprints.candidate, "natural": artifact.fingerprints.natural,
         "placebo": artifact.fingerprints.placebo, "full": artifact.fingerprints.full]
    }

    private static func variantName(_ variant: IntradayDownsideBreadthStrategy.Variant) -> String {
        switch variant { case .candidate: return "candidate"; case .natural: return "natural"; case .placebo: return "placebo" }
    }

    private static func clipped(_ series: PublicHistorySeries, through cutoff: String) -> PublicHistorySeries {
        let indices = series.dates.indices.filter { series.dates[$0] <= cutoff }
        func values(_ input: [Double?]?) -> [Double?]? { input.map { source in indices.map { source[$0] } } }
        return .init(
            symbol: series.symbol, category: series.category, label: series.label,
            currency: series.currency, unit: series.unit, source: series.source,
            dates: indices.map { series.dates[$0] }, prices: indices.map { series.prices[$0] },
            hasOHLC: series.hasOHLC, ohlcSource: series.ohlcSource,
            ohlcCoverageRatio: series.ohlcCoverageRatio,
            openPrices: values(series.openPrices), highPrices: values(series.highPrices),
            lowPrices: values(series.lowPrices), closePrices: values(series.closePrices),
            volumes: values(series.volumes)
        )
    }

    private static func stableJSON(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        return data
    }

    private struct CommandError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }
}
