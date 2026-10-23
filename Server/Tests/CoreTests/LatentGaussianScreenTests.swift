import Foundation
import CoreFoundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

/// Frozen retained QQQ engineering checks only; no accounts/NAV/Sharpe or toy model data.
final class LatentGaussianScreenTests: XCTestCase {
    typealias Screen = LatentGaussianScreen
    typealias Bar = Screen.Bar
    private let expectedSHA = "94227f568f4e16f99b8774d0a4375bb1c8d5fed64661ecdc27dc501c5e73fdef"
    private let integerNames: Set<String> = ["periodCount", "returnCount", "fitCount", "lastFitReturnCount", "fitIterationCount"]
    private let doubleNames: Set<String> = ["previousClose", "currentReturn", "mu0", "mu1", "variance0", "variance1",
        "p00", "p01", "p10", "p11", "alpha0", "alpha1", "next0", "next1", "predictedMean", "fitLogLikelihood", "fitLogLikelihoodGap"]
    private struct Input: Decodable {
        let schema: String; let bars: [Row]; let splits: [Split]
        struct Row: Decodable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double; let volume: Double }
        struct Split: Decodable { let date: String; let ratio: Double }
    }
    private func day(_ text: String) throws -> Date {
        try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from: text))
    }
    private func frozenInput() throws -> ([Bar], [Date: Double]) {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ATM_LATENT_GAUSSIAN_PRICES_PATH"],
            "Root must supply the exact frozen retained input")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(ResearchRunEvidence.sha256(data), expectedSHA)
        let input = try JSONDecoder().decode(Input.self, from: data)
        XCTAssertEqual(input.schema, "fixed-latent2-gaussian-v1")
        XCTAssertEqual(input.bars.count, 6937)
        let bars = try input.bars.map { b in Bar(date: try day(b.date), open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume) }
        let splits = try Dictionary(uniqueKeysWithValues: input.splits.map { (try day($0.date), $0.ratio) })
        return (bars, splits)
    }
    private func evidence(_ bars: [Bar], splits: [Date: Double]) throws -> [Screen.Signal] {
        try Screen.signals(bars: bars, splits: splits, stateEligibleFrom: day("2000-01-13"))
    }

    func testRealPrefixFirst252ReturnsHasOneCompleteFitAnd101Scores() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(253)), splits: splits)
        XCTAssertEqual(s.count, 253)
        XCTAssertEqual(s[0].priorStates, Screen.States())
        XCTAssertEqual(s[0].states.previousClose, bars[0].close)
        XCTAssertEqual(s[0].states.currentReturn, 0)
        for i in s.indices {
            XCTAssertEqual(s[i].sourceOrdinal, i)
            XCTAssertEqual(s[i].currentBar, i + 1)
            XCTAssertEqual(s[i].states.periodCount, i + 1)
            XCTAssertEqual(s[i].states.returnCount, i)
            XCTAssertTrue(s[i].computed)
            XCTAssertFalse(s[i].warmOverride)
            XCTAssertEqual(s[i].returnAvailable, i > 0)
            XCTAssertEqual(s[i].modelAvailable, i >= 252)
            XCTAssertEqual(s[i].comparisonAvailable, s[i].modelAvailable)
            XCTAssertEqual(s[i].fitPerformed, i == 252)
            XCTAssertEqual(s[i].stateSourceDate, bars[i].date)
            XCTAssertEqual(s[i].price, bars[i].close)
            if i < 252 {
                XCTAssertEqual(s[i].states.fitCount, 0)
                XCTAssertNil(s[i].fitRecord)
                XCTAssertNil(s[i].latestFitDate)
                XCTAssertNil(s[i].fitPrefixEndDate)
                XCTAssertEqual(s[i].states.variance0, 0)
                XCTAssertEqual(s[i].states.variance1, 0)
                XCTAssertEqual(s[i].states.predictedMean, 0)
                XCTAssertEqual(s[i].weight, 0)
            }
            if !s[i].fundingEligible { XCTAssertEqual(s[i].weight, 0) }
        }
        let final = try XCTUnwrap(s.last), fit = try XCTUnwrap(final.fitRecord)
        XCTAssertEqual(fit.iterations, 100)
        XCTAssertEqual(fit.observedReturns, 252)
        XCTAssertEqual(fit.logLikelihoodByIteration.count, 101)
        XCTAssertTrue(fit.logLikelihoodByIteration.allSatisfy(\.isFinite))
        XCTAssertEqual(fit.fitPrefixFirstSourceDate, s[1].sourceDate)
        XCTAssertEqual(fit.fitPrefixLastSourceDate, final.sourceDate)
        XCTAssertEqual(final.states.fitCount, 1)
        XCTAssertEqual(final.states.lastFitReturnCount, 252)
        XCTAssertEqual(final.states.fitIterationCount, 100)
        XCTAssertEqual(final.states.fitLogLikelihood, fit.logLikelihoodByIteration[100])
        XCTAssertEqual(final.latestFitDate, final.date)
        XCTAssertEqual(final.fitPrefixEndDate, final.date)
        XCTAssertGreaterThan(final.states.variance0, 0)
        XCTAssertGreaterThan(final.states.variance1, 0)
        XCTAssertLessThanOrEqual(final.states.mu0, final.states.mu1)
        XCTAssertEqual(final.weight, final.fundingEligible && final.states.predictedMean > 0 ? 1 : 0)
    }

    func testRealEffectiveSplitAndCivilMonthClockPreservePriorSignals() throws {
        let (bars, splits) = try frozenInput(), splitDate = try day("2000-03-20")
        let index = try XCTUnwrap(bars.firstIndex { $0.date >= splitDate })
        let s = try evidence(Array(bars.prefix(index + 1)), splits: splits)
        let current = s[index], previous = s[index - 1]
        XCTAssertEqual(current.priorStatesBeforeSplit, previous.states)
        var expectedPrior = previous.states
        expectedPrior.previousClose = previous.states.previousClose / 2
        XCTAssertEqual(current.priorStates, expectedPrior)
        XCTAssertEqual(current.splitFactor, 2)
        XCTAssertEqual(current.appliedSplitDates, [splitDate])
        XCTAssertEqual(current.previousWeight, previous.weight)
        XCTAssertEqual(Screen.latestSignal(s, before: splitDate), previous)
        XCTAssertEqual(previous.sourceDate, "2000-03-17")
        for i in s.indices {
            let hadModel = i > 0 && s[i - 1].modelAvailable
            let monthChanged = i > 0 && s[i].sourceDate.prefix(7) != s[i - 1].sourceDate.prefix(7)
            let expectedFit = i >= 252 && (!hadModel || monthChanged)
            XCTAssertEqual(s[i].fitPerformed, expectedFit)
            if !expectedFit { XCTAssertNil(s[i].fitRecord) }
            if i > 0 { XCTAssertEqual(s[i].priorStatesBeforeSplit, s[i - 1].states) }
        }
        XCTAssertNil(Screen.latestSignal(s, before: s[0].date))
        XCTAssertEqual(Screen.latestSignal(s, before: s[1].date), s[0])
        XCTAssertTrue(s.filter { !$0.fundingEligible }.allSatisfy { $0.weight == 0 && $0.previousWeight == 0 })
    }

    func testRealWarmPrefixPlainArrayCodecKeeps22TypedStatesAndMandatoryNulls() throws {
        let (bars, splits) = try frozenInput()
        let s = try evidence(Array(bars.prefix(14)), splits: splits)
        let data = try Screen.signalData(s)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode([Screen.Signal].self, from: data), s)
        XCTAssertEqual(try Screen.signalData(decoder.decode([Screen.Signal].self, from: data)), data)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for row in rows {
            for key in ["states", "priorStates", "priorStatesBeforeSplit"] {
                let states = try XCTUnwrap(row[key] as? [String: Any])
                XCTAssertEqual(Set(states.keys), integerNames.union(doubleNames))
                for key in integerNames {
                    let n = try XCTUnwrap(states[key] as? NSNumber)
                    XCTAssertNotEqual(CFGetTypeID(n), CFBooleanGetTypeID())
                    XCTAssertFalse(n.stringValue.contains("."))
                }
            }
            XCTAssertTrue(row["fitRecord"] is NSNull)
            XCTAssertTrue(row["latestFitDate"] is NSNull)
            XCTAssertTrue(row["fitPrefixEndDate"] is NSNull)
            XCTAssertEqual(row["modelAvailable"] as? Bool, false)
            XCTAssertEqual(row["computed"] as? Bool, true)
            XCTAssertEqual(row["stateSourceDate"] as? String, row["date"] as? String)
        }
        XCTAssertEqual(rows[0]["date"] as? String, "1999-03-09T16:00:00Z")
        XCTAssertEqual(rows[0]["sourceDate"] as? String, "1999-03-10")
    }

    func testActualInputClockRejectsEmptyRepeatedAndReorderedBarsBeforeFit() throws {
        let (bars, splits) = try frozenInput()
        XCTAssertThrowsError(try evidence([], splits: splits))
        XCTAssertThrowsError(try evidence([bars[1], bars[0]], splits: splits))
        XCTAssertThrowsError(try evidence([bars[0], bars[0]], splits: splits))
    }
}
