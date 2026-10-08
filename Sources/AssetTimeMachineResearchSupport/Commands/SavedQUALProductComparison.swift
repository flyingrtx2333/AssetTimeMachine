import Foundation
import AssetTimeMachineBacktestCore

/// Adds one saved existing QUAL comparator to the immutable 19-comparator
/// calendar. Never constructs targets or trades, and never shrinks that calendar.
public enum SavedQUALProductComparison {
    private struct Bindings: Decodable {
        let schema: String
        let comparatorsSHA256: String
        let sourceCommit: String
        let configurationSHA256: String
    }
    private struct Saved: Decodable {
        let id: String
        let dailyStates: [BacktestDailyState]
    }
    private struct Account: Decodable {
        let dailyStates: [BacktestDailyState]
        enum CodingKeys: String, CodingKey { case dailyStates = "daily_states" }
    }

    public static func run(comparatorsPath: String, qualDirectory: String, bindingsPath: String,
                           outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let comparatorData = try Data(contentsOf: URL(fileURLWithPath: comparatorsPath))
        let bindingData = try Data(contentsOf: URL(fileURLWithPath: bindingsPath))
        let bindings = try JSONDecoder().decode(Bindings.self, from: bindingData)
        guard bindings.schema == "existing-qual-append-fixed-calendar-v1",
              ResearchRunEvidence.sha256(comparatorData) == bindings.comparatorsSHA256 else {
            throw BacktestConfigurationError.invalidParameter("frozen existing comparator binding")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let comparators = try decoder.decode([Saved].self, from: comparatorData)
        let expected = BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs
        guard comparators.map(\.id) == expected, expected.count == 19,
              let first = comparators.first, first.dailyStates.count == 5595 else {
            throw BacktestConfigurationError.invalidParameter("immutable 19-comparator scope")
        }
        let dates = first.dailyStates.map(\.date)
        guard dates == Array(Set(dates)).sorted(),
              comparators.allSatisfy({ $0.dailyStates.map(\.date) == dates }) else {
            throw BacktestConfigurationError.invalidParameter("exact existing common dates")
        }
        let qual = URL(fileURLWithPath: qualDirectory)
        let accountData = try Data(contentsOf: qual.appendingPathComponent("result.json"))
        let evidenceData = try Data(contentsOf: qual.appendingPathComponent("evidence.json"))
        let parametersData = try Data(contentsOf: qual.appendingPathComponent("parameters.json"))
        guard let evidence = try JSONSerialization.jsonObject(with: evidenceData) as? [String: Any],
              let strategy = evidence["strategy"] as? [String: Any],
              strategy["id"] as? String == "nfci-dual-core-v11-qual-role",
              evidence["source_commit"] as? String == bindings.sourceCommit,
              evidence["result_sha256"] as? String == ResearchRunEvidence.sha256(accountData),
              evidence["parameters_sha256"] as? String == ResearchRunEvidence.sha256(parametersData),
              let parameters = try JSONSerialization.jsonObject(with: parametersData) as? [String: Any],
              let run = parameters["run"],
              ResearchRunEvidence.sha256(try JSONSerialization.data(withJSONObject: run, options: [.sortedKeys, .withoutEscapingSlashes])) == bindings.configurationSHA256 else {
            throw BacktestConfigurationError.invalidParameter("saved QUAL provenance")
        }
        let account = try decoder.decode(Account.self, from: accountData)
        guard account.dailyStates.map(\.date) == Array(Set(account.dailyStates.map(\.date))).sorted() else {
            throw BacktestConfigurationError.invalidParameter("saved QUAL date ordering")
        }
        let common = Set(dates)
        let states = account.dailyStates.filter { common.contains($0.date) }
        guard states.map(\.date) == dates else {
            throw BacktestConfigurationError.missingData("QUAL cannot cover all frozen common dates; no shortening allowed")
        }
        func text(_ date: Date) -> String { BacktestSeriesAlignment.historicalSeriesDateString(from: date) }
        let end = dates.last!
        let tenYears = BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding: .year, value: -10, to: end)!
        let windows = [("full",text(dates.first!),text(end)),("trailing10Y",text(tenYears),text(end)),
            ("since2020","2020-01-01",text(end)),("since2022","2022-01-01",text(end)),
            ("crisis2008","2008-01-01","2008-12-31"),("crisis2020","2020-01-01","2020-12-31"),
            ("crisis2022","2022-01-01","2022-12-31")]
        let row = try DailyScreenOutput.row("nfci-dual-core-v11-qual-role", states: states, trades: [], windows: windows)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var objects = try JSONSerialization.jsonObject(with: comparatorData) as! [[String: Any]]
        var newRow = try JSONSerialization.jsonObject(with: encoder.encode(row)) as! [String: Any]
        newRow["trades_retained_in"] = "../qual-run/result.json"
        objects.append(newRow)
        let resultData = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try resultData.write(to: output.appendingPathComponent("result.json"))
        let receipt: [String: Any] = [
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "evidence_class": "POSTHOC_EXISTING_QUAL_COMPARATOR_SAVED_NAV",
            "source_commit": sourceCommit, "bindings_sha256": ResearchRunEvidence.sha256(bindingData),
            "qual_account_sha256": ResearchRunEvidence.sha256(accountData),
            "comparators_sha256": ResearchRunEvidence.sha256(comparatorData),
            "result_sha256": ResearchRunEvidence.sha256(resultData), "common_dates": dates.map(text),
            "existing_19_objects_unchanged": true, "saved_comparator_count": 20,
            "new_capital_replays_in_comparison": 0, "new_candidate_count": 0,
            "calendar_shortened": false, "complete_executable_frontier_certified": false,
            "formal_validation": false, "recommendation_eligible": false,
            "limitations": ["QUAL is the unchanged App hybrid adjusted-close return role, not discrete funded ETF accounting.",
                "Earlier matched-total-return formal FAIL remains unchanged; no quality-alpha promotion.",
                "App hybrid quote calendar and signal/execution fidelity require distinct qualification.",
                "Different snapshot query times are retained; old19 market/macro bytes are unchanged."]
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"))
        print("Saved QUAL appended to 19 unchanged comparators on all 5595 fixed dates; no capital replay in comparison.")
    }
}
