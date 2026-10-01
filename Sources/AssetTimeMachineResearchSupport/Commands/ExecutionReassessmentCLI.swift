import AssetTimeMachineBacktestCore
import Foundation

// Engineering replay of fixed product strategies; no parameter search or promotion.
public enum ExecutionReassessmentCLI {
    public static func run() throws {
        guard CommandLine.arguments.count == 5 else {
            throw NSError(domain: "usage: replay history.json macro.json fee_percent output.json", code: 64)
        }
        let args = CommandLine.arguments
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let dataset = try PublicBacktestCore.loadDataset(from: data, datasetHash: "external-sha256-manifest", dataStale: false)
        let macro = try loadMacro(args[2])
        guard let fee = Double(args[3]) else { throw NSError(domain: "invalid fee", code: 65) }
        let allActive = ProcessInfo.processInfo.environment["ATM_REPLAY_ALL"] == "1"
        let extraModes = (ProcessInfo.processInfo.environment["ATM_REPLAY_MODES"] ?? "")
            .split(separator: ",").compactMap { AdvancedBacktestStrategyMode(rawValue: String($0)) }
        var templates = AdvancedBacktestStrategyTemplate.all
        let represented = Set(templates.map(\.mode))
        templates += extraModes.filter { !represented.contains($0) }.map { mode in
            AdvancedBacktestStrategyTemplate(id: "legacy-mode:\(mode.rawValue)", mode: mode,
                selectedAssetSymbols: nil,
                categoryLocalizationKey: "研究兼容模式", titleLocalizationKey: mode.title,
                annualizedReturn: 0, maxDrawdown: 0, sharpeRatio: 0,
                buyRule: .init(direction: .alwaysBuy, days: 1), sellRule: .init(direction: .neverSell, days: 1),
                tradeAmountRatio: 1, maxPositionRatio: 100, cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0)
        }
        var ids = !extraModes.isEmpty ? templates.map(\.id)
            : (allActive ? templates.filter { $0.mode.isRotation }.map(\.id) : PublicBacktestCore.strategyIDs + ["nfci-dual-core-v11"])
        if let selection = ProcessInfo.processInfo.environment["ATM_REPLAY_STRATEGIES"] {
            let requested = selection.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !requested.isEmpty, Set(requested).count == requested.count,
                  requested.allSatisfy({ ids.contains($0) }) else {
                throw NSError(domain: "invalid explicit replay strategy selection", code: 65)
            }
            // Bound evidence serialization on small Linux validation hosts.
            // Each selected strategy still performs its complete unchanged replay.
            ids = ids.filter { requested.contains($0) }
        }
        let formatter = DateFormatter()
        formatter.calendar = BacktestSeriesAlignment.historicalSeriesCalendar
        formatter.timeZone = BacktestSeriesAlignment.historicalSeriesCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var results: [[String: Any]] = []
        for id in ids {
            guard let template = templates.first(where: { $0.id == id }) else {
                throw NSError(domain: "missing template \(id)", code: 66)
            }
            let inputs = BacktestCoreStrategyDefaults.assetOptions(for: template).map {
                BacktestCoreEngine.advancedAssetInput(for: $0, historyProvider: { dataset.seriesBySymbol[$0] })
            }
            let settings = AdvancedBacktestRiskSettings(feeRate: fee, slippageRate: 0.05,
                maxPositionRatio: template.maxPositionRatio, cooldownDays: template.cooldownDays,
                stopLossRatio: template.stopLossRatio, takeProfitRatio: template.takeProfitRatio)
            let calculated: AdvancedRotationStrategyRun?
            if !extraModes.isEmpty {
                // The inventory audit exercises the public registry/run interface
                // against the original compatibility engine for every definition.
                let definition = try StrategyRegistry.definition(id: id)
                let result = try definition.makeRunner().run(
                    input: .init(seriesBySymbol: dataset.seriesBySymbol, nfciAsOf: macro),
                    configuration: .init(strategy: definition.reference, purpose: .research,
                                         settings: settings))
                calculated = .init(report: result.report, dailyStates: result.dailyStates)
            } else if template.mode.isRotation {
                calculated = BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(assetInputs: inputs,
                    initialCash: 100000, settings: settings, mode: template.mode, nfciAsOf: macro)
            } else {
                let definition = try StrategyRegistry.definition(id: id)
                let result = try definition.makeRunner().run(
                    input: .init(seriesBySymbol: dataset.seriesBySymbol),
                    configuration: .init(strategy: definition.reference, purpose: .research,
                                         settings: settings))
                calculated = .init(report: result.report, dailyStates: result.dailyStates)
            }
            guard let run = calculated else {
                if allActive { results.append(["id": id, "status": "no_report_for_dataset"]); continue }
                throw NSError(domain: "strategy failed \(id)", code: 67)
            }
            let violations = run.dailyStates.filter { state in
                let held = state.holdingsBySymbol.values.reduce(0, +)
                return !state.portfolioValue.isFinite || state.portfolioValue <= 0
                    || abs(held + state.cash - state.portfolioValue) > 0.001
                    || state.targetWeights.values.contains { !$0.isFinite || $0 < 0 }
            }
            let unleveredViolations = run.dailyStates.filter { state in
                state.cash < -0.001 || state.holdingsBySymbol.values.reduce(0, +) > state.portfolioValue + 0.001
                    || state.targetWeights.values.reduce(0, +) > 1.000001
            }
            guard violations.isEmpty && (allActive || unleveredViolations.isEmpty) else {
                throw NSError(domain: "accounting/exposure violation \(id)", code: 68)
            }
            var slices: [String: Any] = [:]
            for (name, start) in [("full", "0001-01-01"), ("since2016", "2016-01-01"), ("since2020", "2020-01-01"), ("since2022", "2022-01-01")] {
                // Full precision daily states, never sampled presentation points.
                let tracePoints = run.dailyStates.isEmpty ? run.report.points : run.dailyStates.enumerated().map {
                    BacktestSeriesPoint(date: $0.element.date, portfolioValue: $0.element.portfolioValue, sequence: $0.offset)
                }
                let points = tracePoints.filter { formatter.string(from: $0.date) >= start }.enumerated().map {
                    BacktestSeriesPoint(date: $0.element.date, portfolioValue: $0.element.portfolioValue, sequence: $0.offset)
                }
                guard let m = BacktestMetricsCalculator.performanceMetrics(from: points) else {
                    throw NSError(domain: "missing metrics \(id) \(name)", code: 69)
                }
                slices[name] = ["start": formatter.string(from: points.first!.date), "end": formatter.string(from: points.last!.date),
                    "annualized_return": m.annualizedReturn as Any? ?? NSNull(), "max_drawdown": m.maxDrawdown,
                    "sharpe_rf0": m.sharpeRatio as Any? ?? NSNull(), "annualized_volatility": m.annualizedVolatility as Any? ?? NSNull(),
                    "point_count": points.count]
            }
            let states: [[String: Any]] = run.dailyStates.map {
                ["date": formatter.string(from: $0.date), "cash": $0.cash, "nav": $0.portfolioValue,
                 "holdings_cny": $0.holdingsBySymbol, "target_weights": $0.targetWeights]
            }
            let trades: [[String: Any]] = run.report.trades.map {
                ["date": formatter.string(from: $0.date), "symbol": $0.assetSymbol, "action": $0.action.rawValue,
                 "price": $0.price, "cash_amount": $0.cashAmount, "units": $0.units, "reason": $0.reason]
            }
            results.append(["id": id, "title": template.title, "slices": slices, "engine_report_full": ["annualized_return": run.report.annualizedReturn as Any? ?? NSNull(), "max_drawdown": run.report.maxDrawdown, "sharpe_rf0": run.report.sharpeRatio as Any? ?? NSNull()], "trade_count": trades.count,
                "daily_states": states, "points": run.report.points.map { ["date": formatter.string(from: $0.date), "nav": $0.portfolioValue] }, "final_cash": run.report.finalCash, "trades": trades, "accounting_violations": violations.count,
                "unlevered_constraint_violations": unleveredViolations.count,
                "final_value": run.report.finalPortfolioValue, "evidence_class": "POST_HOC_CURRENT_REPLAY"])
        }
        let output: [String: Any] = ["engine_version": PublicBacktestCore.engineVersion,
            "generated_at": ISO8601DateFormatter().string(from: Date()), "fee_percent": fee, "slippage_percent": 0.05,
            "initial_cash": 100000, "dataset_cutoff": dataset.dataCutoff,
            "metric_definition": "continuous full-precision daily NAV; fixed retrospective slices; Sharpe Rf=0; legacy financing separately identified",
            "results": results]
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[4]), options: .atomic)
    }
    static func loadMacro(_ path: String) throws -> BacktestNFCIAsOfData {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        guard raw["success"] as? Bool == true, let series = raw["series"] as? [[String: Any]] else {
            throw NSError(domain: "invalid macro envelope", code: 70)
        }
        var points: [String: [BacktestNFCIPoint]] = [:]
        let iso = ISO8601DateFormatter()
        let fraction = ISO8601DateFormatter(); fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for row in series {
            guard let id = row["series_id"] as? String, let entries = row["points"] as? [[String: Any]] else {
                throw NSError(domain: "invalid macro series", code: 70)
            }
            points[id] = try entries.map { p in
                guard let release = p["release_date"] as? String, let reference = p["reference_date"] as? String,
                      let at = p["available_at"] as? String, let date = fraction.date(from: at) ?? iso.date(from: at),
                      date <= Date(), let value = p["value"] as? Double, value.isFinite else {
                    throw NSError(domain: "invalid PIT macro point", code: 70)
                }
                return BacktestNFCIPoint(releaseDate: release, referenceDate: reference, availableAt: date, value: value)
            }
        }
        let result = BacktestNFCIAsOfData(source: raw["source"] as? String ?? "ALFRED", credit: points["NFCICREDIT"] ?? [], leverage: points["NFCILEVERAGE"] ?? [])
        guard result.isReadyForC3L3 else { throw NSError(domain: "macro coverage insufficient", code: 70) }
        return result
    }
}
