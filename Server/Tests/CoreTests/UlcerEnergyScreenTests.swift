import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

/// Frozen real-input source engineering checks only; no accounts, NAV or return metrics.
final class UlcerEnergyScreenTests: XCTestCase {
    typealias Screen = UlcerEnergyScreen
    typealias Bar = Screen.Bar
    private let expectedSHA = "97a4d5281abdd6864ac1f962b5e50172df66ff6f583c67ab2db1f780a986f317"
    private let names: Set<String> = ["maxValue", "sumSq", "periodCount", "meanSq", "ulcerIndex", "drawdownPercent"]
    private struct Input: Decodable {
        let schema: String; let bars: [Row]; let splits: [Split]
        struct Row: Decodable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double; let volume: Double }
        struct Split: Decodable { let date: String; let ratio: Double }
    }
    private func day(_ text: String) throws -> Date {
        try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: text))
    }
    private func frozenInput() throws -> ([Bar], [Date: Double]) {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ATM_ULCER_PRICES_PATH"], "Root must supply the frozen real-input path")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(ResearchRunEvidence.sha256(data), expectedSHA)
        let input = try JSONDecoder().decode(Input.self, from: data)
        XCTAssertEqual(input.schema, "fixed-ulcer-energy-v1")
        let bars = try input.bars.map { row in
            Bar(date: try day(row.date), open: row.open, high: row.high, low: row.low, close: row.close, volume: row.volume)
        }
        let splits = try Dictionary(uniqueKeysWithValues: input.splits.map { (try day($0.date), $0.ratio) })
        return (bars, splits)
    }
    private func evidence(_ bars: [Bar], splits: [Date: Double]) throws -> [Screen.Signal] {
        try Screen.signals(bars: bars, splits: splits, stateEligibleFrom: day("2000-01-13"))
    }

    func testRealPrefixSeedExactCountAndStrictPriorClock() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(14)), splits: splits)
        XCTAssertEqual(s.count, 14)
        XCTAssertEqual(s[0].priorStates, Screen.States())
        XCTAssertEqual(s[0].states.maxValue, bars[0].close)
        XCTAssertEqual(s[0].states.sumSq, 0)
        XCTAssertEqual(s[0].states.meanSq, 0)
        XCTAssertEqual(s[0].states.ulcerIndex, 0)
        XCTAssertEqual(s[0].states.drawdownPercent, 0)
        XCTAssertEqual(s[0].states.periodCount, 1)
        for i in s.indices {
            XCTAssertEqual(s[i].sourceOrdinal, i)
            XCTAssertEqual(s[i].currentBar, i + 1)
            XCTAssertEqual(s[i].states.periodCount, i + 1)
            XCTAssertEqual(s[i].priorStates.periodCount, i)
            XCTAssertTrue(s[i].computed)
            XCTAssertEqual(s[i].comparisonAvailable, i > 0)
            XCTAssertFalse(s[i].warmOverride)
            XCTAssertEqual(s[i].stateSourceDate, s[i].date)
            XCTAssertEqual(s[i].price, bars[i].close)
            XCTAssertTrue([s[i].states.maxValue, s[i].states.sumSq, s[i].states.meanSq,
                s[i].states.ulcerIndex, s[i].states.drawdownPercent].allSatisfy(\.isFinite))
            if i > 0 { XCTAssertEqual(s[i].priorStates, s[i - 1].states) }
            if bars[i].close > s[i].priorStates.maxValue {
                XCTAssertEqual(s[i].states.sumSq, s[i].priorStates.sumSq)
                XCTAssertEqual(s[i].states.drawdownPercent, 0)
            }
        }
        XCTAssertTrue(s.allSatisfy { !$0.fundingEligible && $0.weight == 0 && $0.previousWeight == 0 && $0.stateReason == "pre-funding-cash" })
        XCTAssertNil(Screen.latestSignal(s, before: s[0].date))
        XCTAssertEqual(Screen.latestSignal(s, before: s[1].date), s[0])
        XCTAssertEqual(Screen.latestSignal(s, before: s[1].date.addingTimeInterval(1)), s[1])
        XCTAssertEqual(ISO8601DateFormatter().string(from: s[0].date), "1999-03-09T16:00:00Z")
        XCTAssertEqual(s[0].sourceDate, "1999-03-10")
    }

    func testRealSplitTransportsOnlyHighAndKeepsEntireSourcePrefix() throws {
        let (bars, splits) = try frozenInput(), splitDate = try day("2000-03-20")
        let index = try XCTUnwrap(bars.firstIndex { $0.date >= splitDate })
        let before = try evidence(Array(bars.prefix(index)), splits: splits)
        let through = try evidence(Array(bars.prefix(index + 1)), splits: splits)
        XCTAssertEqual(Array(through.prefix(index)), before)
        let current = through[index], previous = try XCTUnwrap(before.last)
        XCTAssertEqual(current.priorStatesBeforeSplit, previous.states)
        XCTAssertEqual(current.appliedSplitDates, [splitDate])
        XCTAssertEqual(current.splitFactor, 2)
        XCTAssertEqual(current.previousWeight, previous.weight)
        XCTAssertEqual(current.priorStates.maxValue, previous.states.maxValue / 2)
        XCTAssertEqual(current.priorStates.sumSq, previous.states.sumSq)
        XCTAssertEqual(current.priorStates.periodCount, previous.states.periodCount)
        XCTAssertEqual(current.priorStates.meanSq, previous.states.meanSq)
        XCTAssertEqual(current.priorStates.ulcerIndex, previous.states.ulcerIndex)
        XCTAssertEqual(current.priorStates.drawdownPercent, previous.states.drawdownPercent)
        XCTAssertEqual(current.states.periodCount, index + 1)
        XCTAssertEqual(Screen.latestSignal(through, before: splitDate), previous)
        XCTAssertEqual(BacktestSeriesAlignment.historicalSeriesDateString(from: previous.date), "2000-03-17")
        XCTAssertTrue(current.comparisonAvailable)
        XCTAssertEqual(current.price, current.currentUSDBar.close)
        let fundingDate = try day("2000-01-13")
        let firstEligible = try XCTUnwrap(through.first { $0.date >= fundingDate })
        XCTAssertEqual(firstEligible.previousWeight, 0)
        XCTAssertTrue(through.filter { $0.date < fundingDate }.allSatisfy { $0.previousWeight == 0 && $0.weight == 0 })
        for row in through where row.fundingEligible {
            XCTAssertEqual(row.weight, row.states.meanSq > row.priorStatesBeforeSplit.meanSq ? 0 : 1)
        }
    }

    func testRealPrefixPlainArrayCodecHasSixTypedStatesAndAvailableComparator() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(14)), splits: splits)
        let encoded = try Screen.signalData(s)
        XCTAssertEqual(encoded, try Screen.signalData(s))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertEqual(objects.count, 14)
        for (i, row) in objects.enumerated() {
            for key in ["states", "priorStates", "priorStatesBeforeSplit"] {
                let states = try XCTUnwrap(row[key] as? [String: Any])
                XCTAssertEqual(Set(states.keys), names)
                let count = try XCTUnwrap(states["periodCount"] as? NSNumber)
                XCTAssertEqual(count.doubleValue, key == "states" ? Double(i + 1) : Double(i))
            }
            XCTAssertNil(row["previousStates"])
            XCTAssertNil(row["previousStatesBeforeSplit"])
            XCTAssertEqual(row["comparisonAvailable"] as? Bool, i > 0)
            XCTAssertEqual(row["computed"] as? Bool, true)
            XCTAssertEqual(row["warmOverride"] as? Bool, false)
            XCTAssertEqual(row["stateSourceDate"] as? String, row["date"] as? String)
            XCTAssertNotNil(row["currentUSDBar"])
        }
        XCTAssertEqual(objects[0]["date"] as? String, "1999-03-09T16:00:00Z")
    }

    func testActualInputClockRejectsEmptyReorderedAndRepeatedRealBars() throws {
        let (bars, splits) = try frozenInput()
        XCTAssertThrowsError(try evidence([], splits: splits))
        XCTAssertThrowsError(try evidence([bars[1], bars[0]], splits: splits))
        XCTAssertThrowsError(try evidence([bars[0], bars[0]], splits: splits))
    }
}
