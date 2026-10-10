import Foundation
import CoreFoundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

/// Real retained QQQ prefixes: warmup, split transport, causal lookup and JSON evidence.
final class VortexDirectionScreenTests: XCTestCase {
    typealias Screen = VortexDirectionScreen
    private struct Input: Decodable {
        let schema: String
        let bars: [Row]
        let splits: [Split]
        struct Row: Decodable { let date: String; let open, high, low, close, volume: Double }
        struct Split: Decodable { let date: String; let ratio: Double }
    }
    private func day(_ value: String) throws -> Date {
        try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: value))
    }
    private func input() throws -> ([Screen.Bar], [Date: Double]) {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ATM_VORTEX14_PRICES_PATH"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(ResearchRunEvidence.sha256(data), "1b0cf5cf1d642c7cec280e11e08e461c23948978ecf31645bc4cd2f18c73313c")
        let input = try JSONDecoder().decode(Input.self, from: data)
        XCTAssertEqual(input.schema, "fixed-vortex14-v1")
        XCTAssertEqual(input.bars.count, 6937)
        return (try input.bars.map { b in
            Screen.Bar(date: try day(b.date), open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume)
        }, try Dictionary(uniqueKeysWithValues: input.splits.map { (try day($0.date), $0.ratio) }))
    }
    private func signals(_ bars: [Screen.Bar], _ splits: [Date: Double]) throws -> [Screen.Signal] {
        try Screen.signals(bars: bars, splits: splits, stateEligibleFrom: day("2000-01-13"))
    }
    func testRealWarmupHas14MovementsAndFutureBarsCannotChangePrefix() throws {
        let (bars, splits) = try input()
        let early = try signals(Array(bars.prefix(15)), splits)
        let later = try signals(Array(bars.prefix(18)), splits)
        XCTAssertEqual(early, Array(later.prefix(15)))
        XCTAssertNil(early[0].previousSourceDate)
        XCTAssertNil(early[0].TR)
        XCTAssertEqual(early[0].window, [])
        for i in early.indices {
            XCTAssertEqual(early[i].sourceOrdinal, i)
            XCTAssertEqual(early[i].windowCount, i)
            XCTAssertEqual(early[i].hasMovement, i > 0)
            XCTAssertEqual(early[i].available, i == 14)
            XCTAssertEqual(early[i].weight, 0) // Real prefix precedes funding.
            if i < 14 { XCTAssertNil(early[i].VIplus); XCTAssertNil(early[i].VIminus) }
        }
        XCTAssertNotNil(early[14].VIplus)
        XCTAssertNil(Screen.latestSignal(early, before: early[0].date))
        XCTAssertEqual(Screen.latestSignal(early, before: early[1].date), early[0])
    }
    func testActualSplitTransportsPriorOHLCAndEveryRetainedMovement() throws {
        let (bars, splits) = try input(), date = try day("2000-03-20")
        let index = try XCTUnwrap(bars.firstIndex { $0.date >= date })
        let prefix = try signals(Array(bars.prefix(index)), splits)
        let extended = try signals(Array(bars.prefix(index + 1)), splits)
        XCTAssertEqual(prefix, Array(extended.prefix(index)))
        let prior = try XCTUnwrap(prefix.last), current = extended[index]
        XCTAssertEqual(current.appliedSplitDates, [date])
        XCTAssertEqual(current.splitFactor, 2)
        XCTAssertEqual(current.previousHighBeforeSplit, bars[index - 1].high)
        XCTAssertEqual(current.previousHigh, bars[index - 1].high / 2)
        XCTAssertEqual(current.previousLow, bars[index - 1].low / 2)
        XCTAssertEqual(current.previousClose, bars[index - 1].close / 2)
        XCTAssertEqual(current.previousWeight, prior.weight)
        XCTAssertEqual(current.windowCount, 14)
        for (old, transported) in zip(prior.window.dropFirst(), current.window.dropLast()) {
            XCTAssertEqual(transported.sourceDate, old.sourceDate)
            XCTAssertEqual(transported.VMplus, old.VMplus / 2)
            XCTAssertEqual(transported.VMminus, old.VMminus / 2)
            XCTAssertEqual(transported.TR, old.TR / 2)
        }
        XCTAssertEqual(Screen.latestSignal(extended, before: date), prior)
    }
    func testRealCodecPreservesExplicitNullsTypedCountsAndCivilDates() throws {
        let (bars, splits) = try input()
        let sample = try signals(Array(bars.prefix(15)), splits)
        let data = try Screen.signalData(sample)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode([Screen.Signal].self, from: data), sample)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for key in ["previousSourceDate", "previousHighBeforeSplit", "previousLowBeforeSplit", "previousCloseBeforeSplit", "previousHigh", "previousLow", "previousClose", "VMplus", "VMminus", "TR", "VIplus", "VIminus"] {
            XCTAssertTrue(rows[0][key] is NSNull, key)
        }
        XCTAssertEqual(rows[0]["date"] as? String, "1999-03-09T16:00:00Z")
        XCTAssertEqual(rows[0]["sourceDate"] as? String, "1999-03-10")
        for row in rows {
            XCTAssertEqual(row.count, 28)
            for key in ["sourceOrdinal", "windowCount"] {
                let number = try XCTUnwrap(row[key] as? NSNumber)
                XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID())
                XCTAssertFalse(number.stringValue.contains("."))
            }
        }
        XCTAssertThrowsError(try signals([], splits))
        XCTAssertThrowsError(try signals([bars[1], bars[0]], splits))
        XCTAssertThrowsError(try signals([bars[0], bars[0]], splits))
    }
}
