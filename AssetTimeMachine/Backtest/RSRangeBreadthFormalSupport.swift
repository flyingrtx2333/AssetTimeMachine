import Foundation

nonisolated public enum RSRangeBreadthFormalSupport {
    private static let schedulePath = "tools/research-results/strategy-validation/preregistrations/RS-RANGE-BREADTH-21-252-001-schedule.json"
    private static let fixturePath = "tools/fixtures/backtest-history/public_history.json"

    public static func run(arguments: [String]) throws {
        guard arguments.count == 4, arguments[0] == "--repo-root", arguments[2] == "--output-dir" else {
            throw FormalError("usage: RSRangeBreadthFormal --repo-root <path> --output-dir <path>")
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        let output = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scheduleData = try Data(contentsOf: root.appendingPathComponent(schedulePath))
        let loaded = try RSRangeBreadthArtifactLoader.load(data: scheduleData, enforceFormalRuntime: true)
        let artifact = loaded.artifact
        let fixtureData = try Data(contentsOf: root.appendingPathComponent(fixturePath))
        guard RSRangeBreadthArtifactCodec.sha256(fixtureData) == artifact.fixtureSHA256 else { throw FormalError("fixture hash mismatch") }
        let response = try JSONDecoder().decode(PublicHistoryResponse.self, from: fixtureData)
        guard response.success else { throw FormalError("fixture success=false") }
        let source = Dictionary(uniqueKeysWithValues: response.series.map { ($0.symbol, $0) })
        guard let fx = source["usd_per_cny"], let end = artifact.actualWindows.first?.actualEnd else { throw FormalError("fixture inputs missing") }
        let mapping = [("gold_cny", "gold_cny"), ("nasdaq", "nasdaq_composite"), ("sp500", "sp500")]
        let inputs = try mapping.map { app, fixture -> (PublicHistorySeries?, BacktestAssetOption, PublicHistorySeries?) in
            guard let series = source[fixture], let option = BacktestDefaults.dcaAssetOptions.first(where: { $0.symbol == app }) else {
                throw FormalError("missing asset \(app)")
            }
            return (clipped(series, through: end), option, app == "gold_cny" ? nil : clipped(fx, through: end))
        }
        let config = ResearchTargetStrategyConfig(
            symbol: "rs_range_breadth_21_252_001", title: RSRangeBreadthStrategy.strategyID,
            warmupSessions: 1, rebalanceSessions: 1, rebalanceBand: 0,
            maxGrossExposure: 1, allowsFinancedExposure: false, financingAnnualRate: 0,
            buyReason: "RS frozen schedule target"
        )
        guard let frame = BacktestEngine.researchMarketDataFrame(assetInputs: inputs, config: config) else { throw FormalError("frame preparation failed") }
        let executableSet = Set(artifact.executableDates)
        guard frame.dates.map({ $0.recordDateString }).filter({ executableSet.contains($0) }) == artifact.executableDates else {
            throw FormalError("executable date binding mismatch")
        }
        let execution = BacktestExecutionConfig(
            initialCash: 100_000,
            feeRate: BacktestDefaults.advancedFeeRatePercent / 100,
            slippageRate: BacktestDefaults.advancedSlippageRatePercent / 100,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false,
            buyReason: "RS frozen schedule target"
        )
        var runs: [RSRangeBreadthStrategy.Variant: RSRangeBreadthSimulationValidation] = [:]
        for variant in RSRangeBreadthStrategy.Variant.allCases {
            runs[variant] = try RSRangeBreadthSharedSimulator.run(artifact: artifact, variant: variant, frame: frame, execution: execution)
        }
        guard let candidate = runs[.candidate], let natural = runs[.natural], let placebo = runs[.placebo] else { throw FormalError("missing run") }
        let candidateWindows = windows(candidate.simulation.points, definitions: artifact.actualWindows)
        let naturalWindows = windows(natural.simulation.points, definitions: artifact.actualWindows)
        let placeboWindows = windows(placebo.simulation.points, definitions: artifact.actualWindows)
        let factor = factorEvidence(artifact)
        let constraints = constraintEvidence(candidate.simulation)
        var checks: [String: Bool] = ["factor_mechanism": factor.pass, "constraints": constraints.pass]
        for window in artifact.actualWindows {
            let id = window.id
            guard let c = candidateWindows[id], let n = naturalWindows[id], let p = placeboWindows[id] else {
                checks["\(id)_metrics_available"] = false
                continue
            }
            checks["\(id)_candidate_cagr_ge_10pct"] = c.cagr >= 0.10
            checks["\(id)_candidate_mdd_le_10pct"] = c.mdd <= 0.10
            checks["\(id)_candidate_sharpe_ge_0_8"] = c.sharpe >= 0.8
            checks["\(id)_sharpe_gt_natural"] = c.sharpe > n.sharpe
            checks["\(id)_sharpe_gt_placebo"] = c.sharpe > p.sharpe
            checks["\(id)_mdd_lt_natural"] = c.mdd < n.mdd
        }
        let pass = checks.values.allSatisfy { $0 }
        let result: [String: Any] = [
            "protocol_id": "ATM-SVP-2", "trial_id": "ATM-SVP2-RS-RANGE-BREADTH-001",
            "candidate_id": RSRangeBreadthStrategy.strategyID, "engine_version": BacktestEngine.defaultEngineVersion,
            "schedule_fingerprints": ["candidate": artifact.scheduleFingerprints.candidate, "natural": artifact.scheduleFingerprints.natural, "placebo": artifact.scheduleFingerprints.placebo, "combined": artifact.combinedFingerprint],
            "candidate": encodeWindows(candidateWindows), "natural": encodeWindows(naturalWindows), "placebo": encodeWindows(placeboWindows),
            "factor_mechanism": factor.object, "constraints": constraints.object, "checks": checks,
            "decision": pass ? "PASS" : "REJECTED"
        ]
        let trace: [String: Any] = [
            "candidate": candidate.trace.map { ["review_date": $0.reviewDate, "completion_date": $0.completionDate] },
            "natural": natural.trace.map { ["review_date": $0.reviewDate, "completion_date": $0.completionDate] },
            "placebo": placebo.trace.map { ["review_date": $0.reviewDate, "completion_date": $0.completionDate] }
        ]
        try stableJSON(result).write(to: output.appendingPathComponent("candidate-metrics.json"), options: .atomic)
        try stableJSON(trace).write(to: output.appendingPathComponent("queue-trace.json"), options: .atomic)
        print("RS_RANGE_BREADTH_FORMAL_COMPLETE decision=\(pass ? "PASS" : "REJECTED")")
    }

    private struct Metric { let cagr: Double; let mdd: Double; let sharpe: Double; let totalReturn: Double; let count: Int }
    private static func windows(_ points: [BacktestSeriesPoint], definitions: [RSRangeBreadthWindow]) -> [String: Metric] {
        Dictionary(uniqueKeysWithValues: definitions.compactMap { window in
            let slice = points.filter { let date = $0.date.recordDateString; return date >= window.actualStart && date <= window.actualEnd }
            guard let metric = BacktestMetricsCalculator.performanceMetrics(from: slice),
                  let cagr = metric.annualizedReturn, let sharpe = metric.sharpeRatio,
                  cagr.isFinite, metric.maxDrawdown.isFinite, sharpe.isFinite else { return nil }
            return (window.id, Metric(cagr: cagr, mdd: metric.maxDrawdown, sharpe: sharpe, totalReturn: metric.totalReturn, count: slice.count))
        })
    }
    private static func encodeWindows(_ values: [String: Metric]) -> [String: Any] {
        values.mapValues { ["cagr": $0.cagr, "mdd": $0.mdd, "sharpe": $0.sharpe, "total_return": $0.totalReturn, "observations": $0.count] }
    }

    private static func constraintEvidence(_ run: BacktestDailySimulationResult) -> (pass: Bool, object: [String: Any]) {
        let maxTarget = run.dailyStates.map { $0.targetWeights.values.reduce(0, +) }.max() ?? 0
        let minTarget = run.dailyStates.flatMap { $0.targetWeights.values }.min() ?? 0
        let minCash = run.dailyStates.map(\.cash).min() ?? 0
        let maxGross = run.dailyStates.map { state in state.portfolioValue > 0 ? state.holdingsBySymbol.values.reduce(0, +) / state.portfolioValue : .infinity }.max() ?? 0
        let pass = maxTarget <= 1.000000001 && maxGross <= 1.000000001 && minTarget >= -1e-12 && minCash >= -1e-8
        return (pass, ["max_target_gross": maxTarget, "max_actual_gross": maxGross, "min_target_weight": minTarget, "min_cash": minCash, "pass": pass])
    }

    private static func factorEvidence(_ artifact: RSRangeBreadthFrozenArtifact) -> (pass: Bool, object: [String: Any]) {
        var bars: [String: [String: RSFrozenBar]] = [:]
        for review in artifact.reviews { for asset in review.assets { for bar in asset.bars { bars[asset.symbol, default: [:]][bar.date] = bar } } }
        let ordered = bars.mapValues { $0.values.sorted { $0.date < $1.date } }
        var windowObjects: [String: Any] = [:]
        var allPass = true
        for window in artifact.actualWindows {
            var assetObjects: [String: Any] = [:]
            var positive = 0
            for symbol in artifact.assetOrder {
                var calm: [Double] = []; var expanding: [Double] = []
                for review in artifact.reviews where review.date >= window.actualStart && review.date <= window.actualEnd {
                    guard let state = review.assets.first(where: { $0.symbol == symbol }), state.valid,
                          let x = state.x?.value, let long = state.longMean?.value, long > 0 else { continue }
                    let future = (ordered[symbol] ?? []).filter { $0.date > review.date }.prefix(21)
                    guard future.count == 21 else { continue }
                    let q = future.compactMap { RSRangeBreadthFactor.dailyRS(open: $0.open.value, high: $0.high.value, low: $0.low.value, close: $0.close.value) }
                    guard q.count == 21 else { continue }
                    let risk = q.reduce(0, +) / 21 / long
                    if x > 0 { expanding.append(risk) } else { calm.append(risk) }
                }
                let delta = median(expanding).flatMap { e in median(calm).map { e - $0 } }
                let pass = calm.count >= 5 && expanding.count >= 5 && (delta ?? -.infinity) > 0
                if pass { positive += 1 }
                assetObjects[symbol] = ["calm_count": calm.count, "expanding_count": expanding.count,
                                        "median_delta": delta.map { $0 as Any } ?? NSNull(), "pass": pass]
            }
            let pass = positive >= 2; allPass = allPass && pass
            windowObjects[window.id] = ["assets": assetObjects, "positive_assets": positive, "pass": pass]
        }
        return (allPass, ["windows": windowObjects, "pass": allPass])
    }
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(); let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    private static func clipped(_ series: PublicHistorySeries, through cutoff: String) -> PublicHistorySeries {
        let indices = series.dates.indices.filter { series.dates[$0] <= cutoff }
        func values(_ input: [Double?]?) -> [Double?]? { input.map { source in indices.map { source[$0] } } }
        return .init(symbol: series.symbol, category: series.category, label: series.label, currency: series.currency, unit: series.unit,
                     source: series.source, dates: indices.map { series.dates[$0] }, prices: indices.map { series.prices[$0] },
                     hasOHLC: series.hasOHLC, ohlcSource: series.ohlcSource, ohlcCoverageRatio: series.ohlcCoverageRatio,
                     openPrices: values(series.openPrices), highPrices: values(series.highPrices), lowPrices: values(series.lowPrices),
                     closePrices: values(series.closePrices), volumes: values(series.volumes))
    }
    private static func stableJSON(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]); data.append(0x0a); return data
    }
    private struct FormalError: Error, CustomStringConvertible { let message: String; init(_ message: String) { self.message = message }; var description: String { message } }
}
