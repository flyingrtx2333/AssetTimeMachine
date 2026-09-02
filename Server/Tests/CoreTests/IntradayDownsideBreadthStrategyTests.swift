import Foundation
import XCTest
@testable import AssetTimeMachineBacktestCore

final class IntradayDownsideBreadthStrategyTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let sha1 = String(repeating: "1", count: 64)
    private let sha2 = String(repeating: "2", count: 64)

    private func dates(_ count: Int) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2021-10-01")!
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)!.recordDateString }
    }

    private func bars(_ count: Int, source: String, close: (Int) -> Double) -> [IntradayDownsideBreadthSignalBar] {
        dates(count).enumerated().map { index, date in
            .init(date: date, open: 100, high: 120, low: 80, close: close(index), sourceID: source)
        }
    }

    private func config(_ count: Int, executableDates: [String]? = nil) -> IntradayDownsideBreadthFreezeConfig {
        let all = dates(count)
        return .init(
            gitCommit: commit,
            fixturePath: "fixture.json",
            fixtureSHA256: sha1,
            provenancePath: "provenance.json",
            provenanceSHA256: sha2,
            runtime: .formal,
            actualWindows: [
                .init(id: "full", requestedStart: nil, actualStart: all[63], actualEnd: all.last!),
                .init(id: "since_2016_08_31", requestedStart: "2016-08-31", actualStart: all[63], actualEnd: all.last!),
                .init(id: "since_2020_01_01", requestedStart: "2020-01-01", actualStart: all[63], actualEnd: all.last!),
                .init(id: "since_2022_01_01", requestedStart: "2022-01-01", actualStart: all.first(where: { $0 >= "2022-01-01" })!, actualEnd: all.last!)
            ],
            executableDates: executableDates ?? all,
            provenance: [
                .init(symbol: "gold_cny", sourceID: "gold", claim: "mixed; Choice subset row proof", rowLevelSourceProof: false, provenanceSHA256: sha2),
                .init(symbol: "nasdaq", sourceID: "n", claim: "provider_label_only", rowLevelSourceProof: false, provenanceSHA256: nil),
                .init(symbol: "sp500", sourceID: "s", claim: "provider_label_only", rowLevelSourceProof: false, provenanceSHA256: nil)
            ]
        )
    }

    private func build(
        count: Int = 126,
        nasdaqClose: @escaping (Int) -> Double,
        sp500Close: @escaping (Int) -> Double,
        executableDates: [String]? = nil
    ) throws -> IntradayDownsideBreadthFrozenArtifact {
        try IntradayDownsideBreadthScheduleBuilder.build(
            assets: [
                .init(symbol: "nasdaq", sourceID: "n", currency: "CNY", bars: bars(count, source: "n", close: nasdaqClose)),
                .init(symbol: "sp500", sourceID: "s", currency: "CNY", bars: bars(count, source: "s", close: sp500Close))
            ],
            config: config(count, executableDates: executableDates)
        )
    }

    private func options() -> [String: BacktestAssetOption] {
        Dictionary(uniqueKeysWithValues: IntradayDownsideBreadthStrategy.assetOrder.map {
            ($0, BacktestAssetOption(symbol: $0, title: $0, color: .blue, requiresHistoricalFX: false, historicalFXSymbol: nil))
        })
    }

    private func frame(_ count: Int, observed: [String: [Bool]]? = nil) -> MarketDataFrame {
        let parsed = dates(count).map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        return .init(
            dates: parsed,
            pricesBySymbol: Dictionary(uniqueKeysWithValues: IntradayDownsideBreadthStrategy.assetOrder.map { ($0, Array(repeating: 100.0, count: count)) }),
            observedBySymbol: observed ?? Dictionary(uniqueKeysWithValues: IntradayDownsideBreadthStrategy.assetOrder.map { ($0, Array(repeating: true, count: count)) }),
            ohlcBySymbol: [:],
            tradableSymbols: IntradayDownsideBreadthStrategy.assetOrder,
            optionBySymbol: options(),
            simulationRange: 1...(count - 1)
        )
    }

    private let execution = BacktestExecutionConfig(
        initialCash: 100_000,
        feeRate: 0.01,
        slippageRate: 0.0005,
        rebalanceBand: 0,
        financingAnnualRate: 0,
        allowsFinancedExposure: false,
        buyReason: "IDB contract test"
    )

    func testIntradayFormulaGeometryAndIndependentMeanGolden() throws {
        let x = try XCTUnwrap(IntradayDownsideBreadthFactor.intradayLogReturn(open: 100, high: 120, low: 80, close: 99))
        XCTAssertEqual(x.bitPattern, Foundation.log(99.0 / 100.0).bitPattern)
        let expected = (0..<63).reduce(0.0) { value, _ in value + Foundation.log(0.99) } / 63.0
        XCTAssertEqual(try XCTUnwrap(IntradayDownsideBreadthFactor.mean(Array(repeating: x, count: 63))).bitPattern, expected.bitPattern)
        XCTAssertNil(IntradayDownsideBreadthFactor.mean(Array(repeating: x, count: 62)))
        XCTAssertNil(IntradayDownsideBreadthFactor.intradayLogReturn(open: 100, high: 98, low: 80, close: 99))
        XCTAssertNil(IntradayDownsideBreadthFactor.intradayLogReturn(open: 0, high: 1, low: 0, close: 1))
    }

    func testFrozenWeightsZeroSemanticsAndSuppression() throws {
        let bothPositive = try build(nasdaqClose: { _ in 101 }, sp500Close: { _ in 101 })
        XCTAssertEqual(bothPositive.anchorDate, dates(126)[62])
        XCTAssertEqual(bothPositive.reviews.map(\.date), [62, 83, 104, 125].map { dates(126)[$0] })
        XCTAssertEqual(bothPositive.reviews[0].candidate.weights.map(\.value), [0, 0.5, 0.5])
        XCTAssertEqual(bothPositive.reviews[0].placebo.weights.map(\.value), [1, 0, 0])
        XCTAssertEqual(bothPositive.reviews[0].natural.weights.map(\.value), Array(repeating: 1.0 / 3.0, count: 3))
        XCTAssertTrue(bothPositive.reviews[0].candidate.event)
        XCTAssertTrue(bothPositive.reviews[1].candidate.suppressed)

        let mixed = try build(nasdaqClose: { _ in 99 }, sp500Close: { _ in 101 })
        XCTAssertEqual(mixed.reviews[0].candidate.weights.map(\.value), [0.5, 0.25, 0.25])
        XCTAssertEqual(mixed.reviews[0].placebo.weights.map(\.value), [0.5, 0.25, 0.25])

        let bothNegative = try build(nasdaqClose: { _ in 99 }, sp500Close: { _ in 99 })
        XCTAssertEqual(bothNegative.reviews[0].candidate.weights.map(\.value), [1, 0, 0])
        XCTAssertEqual(bothNegative.reviews[0].placebo.weights.map(\.value), [0, 0.5, 0.5])

        let exactZero = try build(nasdaqClose: { _ in 100 }, sp500Close: { _ in 100 })
        XCTAssertEqual(exactZero.reviews[0].candidate.weights.map(\.value), [0, 0.5, 0.5])
        XCTAssertEqual(exactZero.reviews[0].placebo.weights.map(\.value), [0, 0.5, 0.5])
    }

    func testSignalCommonClockAndFuturePrefixInvariance() throws {
        var n = bars(126, source: "n", close: { _ in 101 })
        n.remove(at: 70)
        let s = bars(126, source: "s", close: { _ in 101 })
        let full = try IntradayDownsideBreadthScheduleBuilder.build(
            assets: [.init(symbol: "nasdaq", sourceID: "n", currency: "CNY", bars: n), .init(symbol: "sp500", sourceID: "s", currency: "CNY", bars: s)],
            config: config(126)
        )
        XCTAssertFalse(full.signalCommonDates.contains(dates(126)[70]))
        XCTAssertEqual(full.reviews[1].date, full.signalCommonDates[83])
        XCTAssertEqual(full.reviews[1].assets[0].bars.count, 63)

        let short = try build(count: 105, nasdaqClose: { _ in 101 }, sp500Close: { _ in 99 })
        let long = try build(count: 126, nasdaqClose: { _ in 101 }, sp500Close: { _ in 99 })
        XCTAssertEqual(Array(long.reviews.prefix(short.reviews.count)), short.reviews)
    }

    func testFingerprintGoldenDeterminismAndTamperRejection() throws {
        let artifact = try build(nasdaqClose: { _ in 101 }, sp500Close: { _ in 99 })
        let again = try build(nasdaqClose: { _ in 101 }, sp500Close: { _ in 99 })
        XCTAssertEqual(artifact.fingerprints, again.fingerprints)
        XCTAssertEqual(artifact.fingerprints.full, "177a5b97d73b9b18fc7c90212431308afed42dcd037bb107f6c6a5599ac6bc10")
        let data = try IntradayDownsideBreadthArtifactCodec.encode(artifact)
        XCTAssertNoThrow(try IntradayDownsideBreadthArtifactLoader.load(data: data, enforceFormalRuntime: true))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var windows = try XCTUnwrap(object["actualWindows"] as? [[String: Any]])
        windows.removeLast()
        object["actualWindows"] = windows
        XCTAssertThrowsError(try IntradayDownsideBreadthArtifactLoader.load(
            data: try JSONSerialization.data(withJSONObject: object), enforceFormalRuntime: true
        )) { error in
            XCTAssertTrue(String(describing: error).contains("four-window"))
        }

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var provenance = try XCTUnwrap(object["provenance"] as? [[String: Any]])
        provenance[1]["claim"] = "row proof invented"
        object["provenance"] = provenance
        XCTAssertThrowsError(try IntradayDownsideBreadthArtifactLoader.load(
            data: try JSONSerialization.data(withJSONObject: object), enforceFormalRuntime: true
        ))
    }

    func testLoaderRejectsEquityProvenanceOverclaimAndHeaderMutation() throws {
        let artifact = try build(nasdaqClose: { _ in 101 }, sp500Close: { _ in 99 })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: IntradayDownsideBreadthArtifactCodec.encode(artifact)) as? [String: Any])
        object["lookback"] = 64
        XCTAssertThrowsError(try IntradayDownsideBreadthArtifactLoader.load(
            data: try JSONSerialization.data(withJSONObject: object), enforceFormalRuntime: false
        ))
        XCTAssertThrowsError(try IntradayDownsideBreadthScheduleBuilder.build(
            assets: [
                .init(symbol: "nasdaq", sourceID: "n", currency: "CNY", bars: bars(126, source: "n", close: { _ in 101 })),
                .init(symbol: "sp500", sourceID: "s", currency: "CNY", bars: bars(126, source: "s", close: { _ in 99 }))
            ],
            config: .init(
                gitCommit: commit, fixturePath: "fixture", fixtureSHA256: sha1,
                provenancePath: "provenance", provenanceSHA256: sha2, runtime: .formal,
                actualWindows: [], executableDates: dates(126),
                provenance: [
                    .init(symbol: "gold_cny", sourceID: "g", claim: "proof", rowLevelSourceProof: true, provenanceSHA256: sha2),
                    .init(symbol: "nasdaq", sourceID: "n", claim: "invented", rowLevelSourceProof: true, provenanceSHA256: sha2),
                    .init(symbol: "sp500", sourceID: "s", claim: "label", rowLevelSourceProof: false, provenanceSHA256: nil)
                ]
            )
        ))
    }

    func testSharedSimulatorStrictTMinusOneAndSellBeforeBuyCompletion() throws {
        let artifact = try build(
            nasdaqClose: { $0 < 63 ? 100.1 : 90 },
            sp500Close: { $0 < 63 ? 100.1 : 90 }
        )
        let validated = try IntradayDownsideBreadthSharedSimulator.run(
            artifact: artifact, variant: .candidate, frame: frame(126), execution: execution
        )
        XCTAssertEqual(validated.trace.map(\.reviewDate), artifact.reviews.filter { $0.candidate.event }.map(\.date))
        for item in validated.trace { XCTAssertGreaterThan(item.completionDate, item.reviewDate) }
        let second = try XCTUnwrap(validated.trace.dropFirst().first)
        let reviewIndex = try XCTUnwrap(dates(126).firstIndex(of: second.reviewDate))
        XCTAssertEqual(second.completionDate, dates(126)[reviewIndex + 2])
        XCTAssertLessThan(second.completionDate, artifact.reviews[2].date)
    }

    func testFreezeRejectsOneDayCapacityForSellThenBuyTransition() throws {
        let all = dates(126)
        let executable = all.filter { date in
            guard date > all[83] && date < all[104] else { return true }
            return date == all[84]
        }
        XCTAssertThrowsError(try build(
            nasdaqClose: { $0 < 63 ? 100.1 : 90 },
            sp500Close: { $0 < 63 ? 100.1 : 90 },
            executableDates: executable
        )) { error in
            XCTAssertTrue(String(describing: error).contains("capacity 1 < required 2"))
        }
    }

    func testSharedSimulatorDefersToFrozenJointObservationAndRejectsPendingPastReview() throws {
        let all = dates(126)
        let baseline = try build(nasdaqClose: { _ in 101 }, sp500Close: { _ in 101 })
        let firstReview = baseline.reviews[0].date
        let firstIndex = try XCTUnwrap(all.firstIndex(of: firstReview))
        let frozen = all.filter { $0 != all[firstIndex + 1] }
        let deferred = try build(nasdaqClose: { _ in 101 }, sp500Close: { _ in 101 }, executableDates: frozen)
        let validation = try IntradayDownsideBreadthSharedSimulator.run(
            artifact: deferred, variant: .candidate, frame: frame(126), execution: execution
        )
        XCTAssertEqual(validation.trace.first?.completionDate, all[firstIndex + 2])

        var observed = Dictionary(uniqueKeysWithValues: IntradayDownsideBreadthStrategy.assetOrder.map { ($0, Array(repeating: true, count: 126)) })
        for index in (firstIndex + 1)...83 { observed["sp500"]![index] = false }
        XCTAssertThrowsError(try IntradayDownsideBreadthSharedSimulator.run(
            artifact: baseline, variant: .candidate, frame: frame(126, observed: observed), execution: execution
        ))
    }

    func testSharedSimulatorRejectsMalformedFrame() throws {
        let artifact = try build(nasdaqClose: { _ in 101 }, sp500Close: { _ in 101 })
        let base = frame(126)
        let malformed = MarketDataFrame(
            dates: base.dates,
            pricesBySymbol: base.pricesBySymbol,
            observedBySymbol: base.observedBySymbol,
            ohlcBySymbol: base.ohlcBySymbol,
            tradableSymbols: base.tradableSymbols + ["gold_cny"],
            optionBySymbol: base.optionBySymbol,
            simulationRange: base.simulationRange
        )
        XCTAssertThrowsError(try IntradayDownsideBreadthSharedSimulator.run(
            artifact: artifact, variant: .candidate, frame: malformed, execution: execution
        ))
    }
}
