import Foundation
import AssetTimeMachineBacktestCore

/// Compare immutable, already-funded saved NAVs. Never constructs targets,
/// simulates a strategy, chooses parameters, or resets an account's holdings.
public enum SavedTechnicalIndicatorComparison {
    private struct Input: Decodable {
        let schema: String
        let files: [File]
        struct File: Decodable {
            let path: String
            let sha256: String
            let ids: [String]
        }
    }
    private struct Saved: Decodable {
        let id: String
        let dailyStates: [BacktestDailyState]
    }
    private struct Compared: Encodable {
        let id: String
        let sourceSHA256: String
        let nativeStateCount: Int
        let dailyStates: [BacktestDailyState]
        let slices: [String: DailyScreenOutput.Metric]
        let meanExposure: Double
        let nativeFull: [String: DailyScreenOutput.Metric]
    }
    public static func run(accountsPath: String, outputPath: String, sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let data = try Data(contentsOf: URL(fileURLWithPath: accountsPath))
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.schema == "catalogue20-technical8-saved-nav-v1", input.files.count == 4 else {
            throw BacktestConfigurationError.invalidParameter("saved comparison frozen sources")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var accounts: [(Saved, String)] = []
        for file in input.files {
            let raw = try Data(contentsOf: URL(fileURLWithPath: file.path))
            guard ResearchRunEvidence.sha256(raw) == file.sha256 else {
                throw BacktestConfigurationError.invalidParameter("saved account source hash")
            }
            let rows = try decoder.decode([Saved].self, from: raw)
            for id in file.ids {
                let matching = rows.filter { $0.id == id }
                guard matching.count == 1, !matching[0].dailyStates.isEmpty,
                      zip(matching[0].dailyStates, matching[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }) else {
                    throw BacktestConfigurationError.invalidParameter("saved account uniqueness/date order")
                }
                accounts.append((matching[0], file.sha256))
            }
        }
        let technicalIDs = ["gold_cny:lower-downcross", "gold_cny:lower-reentry", "gold_cny:upper-breakout",
            "nasdaq:lower-downcross", "nasdaq:lower-reentry", "nasdaq:upper-breakout", "QQQ:rsi3:open", "QQQ:ibs02:open"]
        let expected = BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs
            + ["nfci-dual-core-v11-qual-role"] + technicalIDs
        guard accounts.map({ $0.0.id }) == expected, accounts.count == 28, Set(accounts.map { $0.0.id }).count == 28 else {
            throw BacktestConfigurationError.invalidParameter("catalogue20 plus fixed technical8 saved scope")
        }
        let common = accounts.reduce(Set(accounts[0].0.dailyStates.map(\.date))) {
            $0.intersection(Set($1.0.dailyStates.map(\.date)))
        }.sorted()
        guard let first = common.first, let last = common.last, common.count > 252 else {
            throw BacktestConfigurationError.missingData("full common saved NAV calendar")
        }
        let commonSet = Set(common)
        func dateText(_ date: Date) -> String { BacktestSeriesAlignment.historicalSeriesDateString(from: date) }
        let windows = [("full",dateText(first),dateText(last)),("since2020","2020-01-01",dateText(last)),
            ("since2022","2022-01-01",dateText(last)),("crisis2008","2008-01-01","2008-12-31"),
            ("crisis2020","2020-01-01","2020-12-31"),("crisis2022","2022-01-01","2022-12-31")]
        let compared = try accounts.map { account, sha -> Compared in
            let states = account.dailyStates.filter { commonSet.contains($0.date) }
            let row = try DailyScreenOutput.row(account.id, states: states, trades: [], windows: windows)
            let native = try DailyScreenOutput.row(account.id, states: account.dailyStates, trades: [],
                windows: [("native_full",dateText(account.dailyStates.first!.date),dateText(account.dailyStates.last!.date))])
            return .init(id: account.id, sourceSHA256: sha, nativeStateCount: account.dailyStates.count,
                         dailyStates: states, slices: row.slices, meanExposure: row.meanExposure, nativeFull: native.slices)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = try encoder.encode(compared)
        let evidence: [String: Any] = ["completed_at": ISO8601DateFormatter().string(from: Date()),
            "evidence_class": "POSTHOC_TECHNICAL8_CATALOGUE20_SAVED_NAV_SUPPLEMENT", "formal_validation": false,
            "strategy_replayed": false, "original_long_comparison_failure_preserved": true, "objective_complete": false, "common_history_is_primary_user_choice": false, "parameter_search_count": 0, "source_commit": sourceCommit,
            "input_sha256": ResearchRunEvidence.sha256(data), "result_sha256": ResearchRunEvidence.sha256(result),
            "binary_sha256": ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())),
            "primary_metric": "App full common saved NAV Sharpe Rf=0", "account_count": 28,
            "common_dates": common.map(dateText), "common_start": dateText(first), "common_end": dateText(last),
            "limitations": ["No new funded replay or independent source/total-return certification.",
                "Existing account vintages and opening/closing execution conventions remain distinct.",
                "Historical candidate was already viewed; new comparison is post-hoc, not OOS or a new alpha trial.",
                "Eight known technical indicator accounts,all retained;not a new strategy or parameter search."]]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.write(to: output.appendingPathComponent("result.json"))
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys,.prettyPrinted])
            .write(to: output.appendingPathComponent("evidence.json"))
        print("Saved-account audit: 28 accounts on \(common.count) identical dates; no strategy simulation.")
    }
}
