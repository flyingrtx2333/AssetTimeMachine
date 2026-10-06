import Foundation
import AssetTimeMachineBacktestCore

/// Fixed calendar mechanism from Cieslak, Morse and Vissing-Jorgensen (2014).
/// Next-open operational adaptation; no product registration or parameter search.
public enum FOMCCycleScreen {
    public struct Schedule {
        private struct Document: Decodable { let versions: [Version] }
        private struct Version: Decodable {
            let event_id: String
            let date: String
            let available_date: String
            let cancelled: Bool
        }
        private struct Event {
            let id: String
            let date: Date
            let available: Date
            let cancelled: Bool
        }
        private let events: [Event]

        public init(data: Data) throws {
            let versions = try JSONDecoder().decode(Document.self, from: data).versions
            guard !versions.isEmpty else { throw BacktestConfigurationError.missingData("FOMC schedules") }
            var seen = Set<String>()
            events = try versions.map { v in
                guard !v.event_id.isEmpty, seen.insert(v.event_id + "::" + v.available_date).inserted,
                      let date = BacktestSeriesAlignment.historicalSeriesDate(from: v.date),
                      let available = BacktestSeriesAlignment.historicalSeriesDate(from: v.available_date),
                      ![1, 7].contains(BacktestSeriesAlignment.historicalSeriesCalendar.component(.weekday, from: date)) else {
                    throw BacktestConfigurationError.invalidParameter("dated FOMC version")
                }
                return Event(id: v.event_id, date: date, available: available, cancelled: v.cancelled)
            }.sorted { $0.available == $1.available ? $0.id < $1.id : $0.available < $1.available }
        }

        /// Week zero is business-day offsets -1...3; holidays count, weekends do not.
        /// Revisions and cancellations enter only after their recorded availability.
        public func weight(on date: Date, asOf: Date, oddControl: Bool = false) -> Double {
            let calendar = BacktestSeriesAlignment.historicalSeriesCalendar
            guard asOf < date, ![1, 7].contains(calendar.component(.weekday, from: date)) else { return 0 }
            var known: [String: Event] = [:]
            for event in events where event.available <= asOf { known[event.id] = event }
            var nextWeekday = calendar.date(byAdding: .day, value: 1, to: date)!
            while [1, 7].contains(calendar.component(.weekday, from: nextWeekday)) {
                nextWeekday = calendar.date(byAdding: .day, value: 1, to: nextWeekday)!
            }
            guard let meeting = known.values.filter({ !$0.cancelled && $0.date <= nextWeekday })
                .max(by: { $0.date < $1.date }), date.timeIntervalSince(meeting.date) <= 70 * 86400 else { return 0 }
            var offset = -1
            if meeting.date <= date {
                offset = 0
                var cursor = meeting.date
                while cursor < date {
                    cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
                    if ![1, 7].contains(calendar.component(.weekday, from: cursor)) { offset += 1 }
                }
            }
            guard (-1...33).contains(offset) else { return 0 }
            let week = (offset + 1) / 5
            return week % 2 == (oddControl ? 1 : 0) ? 1 : 0
        }
    }

    public static func run(spyPath: String, historyPath: String, calendarPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: spyPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let calendarData = try Data(contentsOf: URL(fileURLWithPath: calendarPath))
        let schedule = try Schedule(data: calendarData)
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2008-01-02")!
        let end = BacktestSeriesAlignment.historicalSeriesDate(from: "2026-08-20")!
        let input = try SPYSessionInput(raw: raw, history: history, start: start, end: end)
        let targetTrace: [[String: Any]] = input.frame.simulationRange.map { index in
            ["date": ISO8601DateFormatter().string(from: input.frame.dates[index]),
             "as_of": ISO8601DateFormatter().string(from: input.frame.dates[index - 1]),
             "even_weight": index == input.first ? 0 : schedule.weight(on: input.frame.dates[index], asOf: input.frame.dates[index - 1]),
             "odd_weight": index == input.first ? 0 : schedule.weight(on: input.frame.dates[index], asOf: input.frame.dates[index - 1], oddControl: true)]
        }
        let traceData = try JSONSerialization.data(withJSONObject: targetTrace, options: [.sortedKeys])
        let execution = BacktestExecutionConfig(initialCash: 100000, feeRate: 0.00025, slippageRate: 0,
            rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false,
            buyReason: "Fixed FOMC calendar phase")
        let windows = [("full", "2008-01-02", "2026-08-20"),
            ("since2020", "2020-01-01", "2026-08-20"), ("since2022", "2022-01-01", "2026-08-20"),
            ("post_publication", "2014-04-24", "2026-08-20"),
            ("crisis2008", "2008-01-02", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"),
            ("crisis2022", "2022-01-01", "2022-12-31")]
        var rows: [DailyScreenOutput.Row] = []
        for id in ["fomc-even-weeks-spy-open-rmb-v1", "fomc-odd-weeks-falsification-control", "spy-buy-hold-open-control"] {
            var submitted: Double?
            func desired(_ c: StrategyTargetContext) -> Double {
                guard c.index > input.first else { return 0 }
                return id == "spy-buy-hold-open-control" ? 1 : schedule.weight(
                    on: input.frame.dates[c.index], asOf: input.frame.dates[c.signalIndex],
                    oddControl: id == "fomc-odd-weeks-falsification-control")
            }
            guard let run = BacktestDailySimulator.run(frame: input.frame, execution: execution,
                provider: .init { desired($0) == 1 ? ["SPY": 1] : [:] },
                rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
                contextualRebalanceDecision: { c in
                    let w = desired(c), changed = submitted == nil || submitted != w
                    if changed { submitted = w }
                    return .init(shouldRebalance: changed, refreshOverlay: false)
                }, executionPricesBySymbol: ["SPY": input.opens]) else {
                throw BacktestConfigurationError.missingData(id)
            }
            rows.append(try DailyScreenOutput.row(id, states: run.dailyStates, trades: run.trades, windows: windows))
        }
        let baseline = try StrategyRegistry.definition(id: "gold-nasdaq-dual-trend-barbell")
        let run = try baseline.run(input: .init(seriesBySymbol: input.dataset.seriesBySymbol,
            datasetHash: input.dataset.datasetHash, sourceCommit: sourceCommit),
            configuration: .init(strategy: baseline.reference, purpose: .research,
                settings: .init(feeRate: 0.025, slippageRate: 0, maxPositionRatio: 100,
                    cooldownDays: 0, stopLossRatio: 0, takeProfitRatio: 0),
                evaluationRange: .init(startDate: start, endDate: end)))
        rows.append(try DailyScreenOutput.row(baseline.reference.id, states: run.dailyStates,
            trades: run.report.trades, windows: windows))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(rows)
        let parameters: [String: Any] = ["candidate_count": 1, "control_count": 3,
            "even_weeks": [0, 2, 4, 6], "week_zero_business_offsets": [-1, 3],
            "max_business_offset": 33, "clock": "next-open; calendar known at prior observed close",
            "start": "2008-01-02", "end": "2026-08-20", "initial_cny": 100000,
            "fee_percent": 0.025, "slippage_percent": 0, "cash": "CashYieldCNY",
            "fx_policy": "strict-prior-calendar-date-for-open-and-close", "fx_max_age_days": 14,
            "dividends": "not_included_price_only"]
        let p = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
        let evidence: [String: Any] = ["evidence_class": "D0_EXPLORATORY_PUBLIC_RULE_ADAPTATION",
            "formal_validation": false, "recommendation_eligible": false,
            "source_commit": sourceCommit, "execution_version": "settlement-v4-with-explicit-session-quotes-v1",
            "spy_sha256": ResearchRunEvidence.sha256(raw), "history_sha256": input.dataset.datasetHash,
            "calendar_sha256": ResearchRunEvidence.sha256(calendarData),
            "target_trace_sha256": ResearchRunEvidence.sha256(traceData),
            "parameters": parameters, "parameters_sha256": ResearchRunEvidence.sha256(p),
            "result_sha256": ResearchRunEvidence.sha256(data),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf:
                URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "limitations": ["Next-open adaptation differs from paper close-to-close index total returns.",
                "No 2007 meeting is supplied; remain in cash until first classified 2008 phase.",
                "Only scheduled meetings and date-stamped changes; emergencies never inserted retrospectively.",
                "Official dated notices are currently hosted, not independently archived first-release vintages.",
                "SPY dividends omitted; prior-day FX is a synthetic CNY wallet without conversion charges.",
                "NYSE holidays count in phase; fills only on observed sessions, never forward-filled quotes.",
                "Single vendor price archive through August 20, not current October performance.",
                "Native gold/Nasdaq index control differs in instruments and execution clock.",
                "Post-publication is retrospective, not pristine holdout or prospective OOS."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        try traceData.write(to: output.appendingPathComponent("calendar-targets.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("FOMC fixed cycle: 1 candidate, 3 controls; immutable outputs saved.")
    }
}
