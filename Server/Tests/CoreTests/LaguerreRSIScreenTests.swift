import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

/// Frozen actual-input engineering checks only: no accounts or return metrics.
final class LaguerreRSIScreenTests: XCTestCase {
    typealias Screen = LaguerreRSIScreen
    typealias Bar = Screen.Bar
    private let expectedSHA = "3b40a90250f0620658c6727e4381902fc0667170fd88ff297a194546f03f921e"
    private let names: Set<String> = ["l0", "l1", "l2", "l3", "cu", "cd", "rsi"]
    private struct Input: Decodable {
        let schema: String; let bars: [Row]; let splits: [Split]
        struct Row: Decodable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double; let volume: Double }
        struct Split: Decodable { let date: String; let ratio: Double }
    }
    private func day(_ text: String) throws -> Date {
        try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: text))
    }
    private func frozenInput() throws -> ([Bar], [Date: Double]) {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ATM_LAGUERRE_PRICES_PATH"], "Root must supply the frozen real-input path")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(ResearchRunEvidence.sha256(data), expectedSHA)
        let input = try JSONDecoder().decode(Input.self, from: data)
        XCTAssertEqual(input.schema, "fixed-laguerre05-v1")
        let bars = try input.bars.map { row in
            Bar(date: try day(row.date), open: row.open, high: row.high, low: row.low, close: row.close, volume: row.volume)
        }
        let splits = try Dictionary(uniqueKeysWithValues: input.splits.map { (try day($0.date), $0.ratio) })
        return (bars, splits)
    }
    private func evidence(_ bars: [Bar], splits: [Date: Double]) throws -> [Screen.Signal] {
        try Screen.signals(bars: bars, splits: splits, stateEligibleFrom: day("2000-01-13"))
    }

    func testRealPrefixMBBSeedAndStrictPriorClock() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(14)), splits: splits)
        XCTAssertEqual(s.count, 14)
        XCTAssertEqual(s[0].sourceOrdinal, 0)
        XCTAssertEqual(s[0].currentBar, 0)
        XCTAssertFalse(s[0].computed)
        XCTAssertEqual(s[0].states, Screen.States())
        XCTAssertEqual(s[0].previousStates, Screen.States())
        XCTAssertNil(s[0].stateSourceDate)
        XCTAssertEqual(s[1].currentBar, 1)
        XCTAssertEqual(s[1].previousStates, Screen.States())
        for i in 1...13 {
            XCTAssertEqual(s[i].sourceOrdinal, i)
            XCTAssertEqual(s[i].currentBar, i)
            XCTAssertTrue(s[i].computed)
            XCTAssertEqual(s[i].price, bars[i].close)
            XCTAssertEqual(s[i].stateSourceDate, s[i].date)
            XCTAssertEqual(s[i].previousStates, s[i - 1].states)
            XCTAssertTrue([s[i].states.l0, s[i].states.l1, s[i].states.l2, s[i].states.l3,
                s[i].states.cu, s[i].states.cd, s[i].states.rsi].allSatisfy(\.isFinite))
        }
        XCTAssertTrue(s.allSatisfy { !$0.warmOverride })
        XCTAssertTrue(s.allSatisfy { !$0.fundingEligible && $0.weight == 0 && $0.previousWeight == 0 && $0.stateReason == "pre-funding-cash" })
        XCTAssertNil(Screen.latestSignal(s, before: s[0].date))
        XCTAssertEqual(Screen.latestSignal(s, before: s[1].date), s[0])
        XCTAssertEqual(Screen.latestSignal(s, before: s[1].date.addingTimeInterval(1)), s[1])
        XCTAssertEqual(ISO8601DateFormatter().string(from: s[0].date), "1999-03-09T16:00:00Z")
        XCTAssertEqual(s[0].sourceDate, "1999-03-10")
    }

    func testRealEffectiveSplitTransportKeepsRSIAndEmittedHistory() throws {
        let (bars, splits) = try frozenInput(), splitDate = try day("2000-03-20")
        let index = try XCTUnwrap(bars.firstIndex { $0.date >= splitDate })
        let before = try evidence(Array(bars.prefix(index)), splits: splits)
        let through = try evidence(Array(bars.prefix(index + 1)), splits: splits)
        XCTAssertEqual(Array(through.prefix(index)), before)
        let current = through[index], previous = try XCTUnwrap(before.last)
        XCTAssertEqual(current.previousStatesBeforeSplit, previous.states)
        XCTAssertEqual(current.appliedSplitDates, [splitDate])
        XCTAssertEqual(current.splitFactor, 2)
        XCTAssertEqual(current.previousWeight, previous.weight)
        XCTAssertEqual(current.previousStates.l0, previous.states.l0 / 2)
        XCTAssertEqual(current.previousStates.l1, previous.states.l1 / 2)
        XCTAssertEqual(current.previousStates.l2, previous.states.l2 / 2)
        XCTAssertEqual(current.previousStates.l3, previous.states.l3 / 2)
        XCTAssertEqual(current.previousStates.cu, previous.states.cu / 2)
        XCTAssertEqual(current.previousStates.cd, previous.states.cd / 2)
        XCTAssertEqual(current.previousStates.rsi, previous.states.rsi)
        XCTAssertEqual(Screen.latestSignal(through, before: splitDate), previous)
        XCTAssertEqual(BacktestSeriesAlignment.historicalSeriesDateString(from: previous.date), "2000-03-17")
        XCTAssertEqual(ISO8601DateFormatter().string(from: splitDate), "2000-03-19T16:00:00Z")
        XCTAssertTrue(current.computed)
        XCTAssertFalse(current.warmOverride)
        XCTAssertEqual(current.price, current.currentUSDBar.close)
        let fundingDate = try day("2000-01-13")
        let firstEligible = try XCTUnwrap(through.first { $0.date >= fundingDate })
        XCTAssertEqual(firstEligible.previousWeight, 0)
        XCTAssertTrue(through.filter { $0.date < fundingDate }.allSatisfy { $0.previousWeight == 0 && $0.weight == 0 })
    }

    func testRealPrefixArrayCodecAllSevenStatesAndExplicitNull() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(14)), splits: splits)
        let encoded = try Screen.signalData(s)
        XCTAssertEqual(encoded, try Screen.signalData(s))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertEqual(objects.count, 14)
        for row in objects {
            for key in ["states", "previousStates", "previousStatesBeforeSplit"] {
                XCTAssertEqual(Set(try XCTUnwrap(row[key] as? [String: Any]).keys), names)
            }
            XCTAssertNotNil(row["currentUSDBar"])
            XCTAssertEqual(row["warmOverride"] as? Bool, false)
        }
        XCTAssertTrue(objects[0]["stateSourceDate"] is NSNull)
        XCTAssertEqual(objects[1]["stateSourceDate"] as? String, objects[1]["date"] as? String)
        XCTAssertEqual(objects[0]["date"] as? String, "1999-03-09T16:00:00Z")
    }

    func testActualInputClockRejectsEmptyReorderedAndRepeatedRealBars() throws {
        let (bars, splits) = try frozenInput()
        XCTAssertThrowsError(try evidence([], splits: splits))
        XCTAssertThrowsError(try evidence([bars[1], bars[0]], splits: splits))
        XCTAssertThrowsError(try evidence([bars[0], bars[0]], splits: splits))
    }
}
