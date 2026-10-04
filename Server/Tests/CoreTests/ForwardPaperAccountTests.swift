import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class ForwardPaperAccountTests: XCTestCase {
    private let source = String(repeating: "a", count: 40)
    private let binary = String(repeating: "b", count: 64)
    private func date(_ text: String) -> Date { BacktestSeriesAlignment.historicalSeriesDate(from: text)! }
    private func journal() throws -> ForwardPaperAccount.Journal {
        try ForwardPaperAccount.register(strategyID: "nfci-dual-core-v1", sourceCommit: source,
            binarySHA256: binary, commissionPercent: 0.025, slippagePercent: 0.05,
            now: date("2026-09-01").addingTimeInterval(12 * 3600))
    }
    private func signal(_ day: Int, targets: [String: Double], rebalance: Bool = true) -> ForwardPaperAccount.Signal {
        let time = date("2026-09-01").addingTimeInterval(Double(day) * 86400 + 12 * 3600)
        return .init(recordedAt: time, signalDate: String(format: "2026-09-%02d", day + 1),
            targets: targets, rebalance: rebalance, datasetSHA256: binary, macroSHA256: binary, snapshotSHA256: binary)
    }
    private func frame(end: Int = 8, closed: Set<Int> = []) throws -> MarketDataFrame {
        let days = (0...end).map { date("2026-09-01").addingTimeInterval(Double($0) * 86400) }
        let symbols = try journal().contract.symbols
        let options = Dictionary(uniqueKeysWithValues: BacktestCoreDefaults.strategyAssetOptions.filter { symbols.contains($0.symbol) }.map { ($0.symbol, $0) })
        return MarketDataFrame(dates: days,
            pricesBySymbol: Dictionary(uniqueKeysWithValues: symbols.map { ($0, Array(repeating: 100.0, count: days.count)) }),
            observedBySymbol: Dictionary(uniqueKeysWithValues: symbols.map { ($0, days.indices.map { !closed.contains($0) }) }),
            ohlcBySymbol: [:], tradableSymbols: symbols, optionBySymbol: options, simulationRange: 1...end)
    }
    private func history(end: Int, reviseFX: Bool = false) throws -> Data {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        let dates = (-800...end).map { formatter.string(from: date("2026-09-01").addingTimeInterval(Double($0) * 86400)) }
        let symbols = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite", "usd_per_cny"]
        let series: [[String: Any]] = symbols.map { symbol in
            var prices = Array(repeating: symbol == "usd_per_cny" ? 1.0 : 100.0, count: dates.count)
            // A revision before registration must also be detected, even if it
            // happens not to alter already reported account holdings.
            if reviseFX && symbol == "usd_per_cny" { prices[100] = 1.01 }
            return ["symbol": symbol, "category": symbol == "usd_per_cny" ? "fx" : "index",
                    "label": symbol, "currency": "CNY", "unit": "fixture", "source": "independent-test",
                    "dates": dates, "prices": prices]
        }
        return try JSONSerialization.data(withJSONObject: ["success": true, "series": series], options: .sortedKeys)
    }

    func testNoBackdatedFillsAndSingleSessionBootstrapUsesSharedEngine() throws {
        let recorded = try ForwardPaperAccount.append(journal(), signal: signal(0, targets: ["nasdaq": 1]))
        let run = try ForwardPaperAccount.account(recorded, frame: frame(end: 1), range: 1...1)
        XCTAssertEqual(run.days.count, 1)
        XCTAssertEqual(run.fills.count, 1)
        XCTAssertGreaterThan(run.fills[0].date, recorded.contract.registeredAt)
        XCTAssertEqual(run.fills[0].date, date("2026-09-02"))
        XCTAssertGreaterThan(run.performance!.commissionPaid, 0)
        XCTAssertGreaterThan(run.performance!.maxDrawdownPercent, 0)
        XCTAssertLessThan(run.days[0].state.portfolioValue, 100_000)
    }

    func testIncrementalReplayPreservesCashUnitsFillsAndNav() throws {
        var account = try ForwardPaperAccount.append(journal(), signal: signal(0, targets: ["nasdaq": 1]))
        account = try ForwardPaperAccount.account(account, frame: frame(end: 2), range: 1...2)
        let first = account
        account = try ForwardPaperAccount.append(account, signal: signal(2, targets: ["gold_cny": 1]))
        account = try ForwardPaperAccount.account(account, frame: frame(end: 4), range: 1...4)
        XCTAssertEqual(try ForwardPaperAccount.encoder().encode(Array(account.days.prefix(2))), try ForwardPaperAccount.encoder().encode(first.days))
        let sale = try XCTUnwrap(account.fills.first { $0.actionRawValue == "sell" })
        let buy = try XCTUnwrap(account.fills.first { $0.assetSymbol == "gold_cny" })
        XCTAssertLessThan(sale.date, buy.date)
        for day in account.days {
            XCTAssertEqual(day.state.cash + day.state.holdingsBySymbol.values.reduce(0, +), day.state.portfolioValue, accuracy: 1e-8)
            for (symbol, units) in day.units { XCTAssertEqual(units * 100, day.state.holdingsBySymbol[symbol]!, accuracy: 1e-8) }
        }
    }

    func testLatestSignalWhileMarketClosedReplacesPendingTarget() throws {
        var account = try ForwardPaperAccount.append(journal(), signal: signal(0, targets: ["nasdaq": 1]))
        account = try ForwardPaperAccount.append(account, signal: signal(1, targets: ["gold_cny": 1]))
        account = try ForwardPaperAccount.append(account, signal: signal(2, targets: [:]))
        let result = try ForwardPaperAccount.account(account, frame: frame(closed: [1, 2]), range: 1...8)
        XCTAssertTrue(result.fills.isEmpty)
        XCTAssertTrue(result.days.last!.state.holdingsBySymbol.isEmpty)
    }

    func testUnchangedLastDecisionCannotEraseEarlierRebalanceBeforeReopening() throws {
        var account = try ForwardPaperAccount.append(journal(), signal: signal(0, targets: ["nasdaq": 1]))
        account = try ForwardPaperAccount.append(account, signal: signal(1, targets: ["nasdaq": 1], rebalance: false))
        let result = try ForwardPaperAccount.account(account, frame: frame(closed: [1]), range: 1...8)
        XCTAssertEqual(result.fills.count, 1)
    }

    func testDuplicateUnknownAndLeveragedSignalsFailClosed() throws {
        let registered = try journal()
        let recorded = try ForwardPaperAccount.append(registered, signal: signal(0, targets: [:]))
        XCTAssertThrowsError(try ForwardPaperAccount.append(recorded, signal: signal(0, targets: ["nasdaq": 1])))
        XCTAssertThrowsError(try ForwardPaperAccount.append(registered, signal: signal(0, targets: ["unknown": 1])))
        XCTAssertThrowsError(try ForwardPaperAccount.append(registered, signal: signal(0, targets: ["nasdaq": 0.6, "gold_cny": 0.6])))
        XCTAssertThrowsError(try ForwardPaperAccount.verifyRuntime(registered, sourceCommit: source, binarySHA256: String(repeating: "c", count: 64)))
    }

    func testModifiedPastNavIsRejectedOnContinuation() throws {
        let recorded = try ForwardPaperAccount.append(journal(), signal: signal(0, targets: ["nasdaq": 1]))
        let accounted = try ForwardPaperAccount.account(recorded, frame: frame(end: 2), range: 1...2)
        let old = try frame()
        var prices = old.pricesBySymbol
        prices["nasdaq"]![1] = 99
        let revised = MarketDataFrame(dates: old.dates, pricesBySymbol: prices, observedBySymbol: old.observedBySymbol,
            ohlcBySymbol: old.ohlcBySymbol, tradableSymbols: old.tradableSymbols, optionBySymbol: old.optionBySymbol, simulationRange: 1...8)
        XCTAssertThrowsError(try ForwardPaperAccount.account(accounted, frame: revised, range: 1...8))
    }

    func testJournalRoundTripAndExistingDestinationCannotBeReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paper-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = try ForwardPaperAccount.append(journal(), signal: signal(0, targets: [:]))
        try ForwardPaperAccount.write(account, to: directory)
        let file = directory.appendingPathComponent("account.json")
        let loaded = try ForwardPaperAccount.read(file)
        XCTAssertEqual(try ForwardPaperAccount.digest(account), try ForwardPaperAccount.digest(loaded))
        XCTAssertThrowsError(try ForwardPaperAccount.write(account, to: directory))
        let original = try String(contentsOf: file, encoding: .utf8)
        try original.replacingOccurrences(of: "paper-v4-", with: "tampered-").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ForwardPaperAccount.read(file))
    }

    func testRealHistoryPipelineLocksFXAndRejectsUnfinalizedCrossVenueClose() throws {
        let registered = try ForwardPaperAccount.append(journal(), signal: signal(0, targets: ["nasdaq": 1]))
        let cutoff = date("2026-09-03")
        let firstData = try history(end: 2)
        XCTAssertThrowsError(try ForwardPaperAccount.advance(registered, historyData: firstData, now: cutoff.addingTimeInterval(31 * 3600)))
        let first = try ForwardPaperAccount.advance(registered, historyData: firstData, now: cutoff.addingTimeInterval(32 * 3600))
        let nextData = try history(end: 4)
        let next = try ForwardPaperAccount.advance(first, historyData: nextData, now: date("2026-09-05").addingTimeInterval(32 * 3600))
        XCTAssertEqual(first.days.count, 2)
        // September 5 is Saturday; the shared market alignment excludes it.
        XCTAssertEqual(next.days.count, 3)
        XCTAssertThrowsError(try ForwardPaperAccount.advance(first, historyData: history(end: 4, reviseFX: true), now: date("2026-09-05").addingTimeInterval(32 * 3600)))
    }
}
