import Foundation
import XCTest
@testable import AssetTimeMachineBacktestCore

final class IntradayDownsideBreadthFormalSupportTests: XCTestCase {
    private func dates(_ count: Int) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2024-01-01")!
        return (0..<count).map {
            calendar.date(byAdding: .day, value: $0, to: start)!.recordDateString
        }
    }

    /// Constructs the frozen representation directly rather than calling the schedule builder.
    private func artifact(
        count: Int = 315,
        riskByReview: [Bool]? = nil,
        outcomes: [Double]? = nil,
        inconsistentDuplicate: Bool = false
    ) -> IntradayDownsideBreadthFrozenArtifact {
        let allDates = dates(count)
        let ordinals = stride(from: 62, to: count, by: 21).map { $0 }
        let risk = riskByReview ?? ordinals.indices.map { $0 < ordinals.count - 1 && $0.isMultiple(of: 2) }
        let desired = outcomes ?? ordinals.indices.map { index in risk[index] ? -Double(10 + index) : Double(index) }
        var xByDate = Dictionary(uniqueKeysWithValues: allDates.map { ($0, 0.0) })
        for index in ordinals.indices where ordinals[index] + 21 < count {
            for dateIndex in (ordinals[index] + 1)...(ordinals[index] + 21) {
                xByDate[allDates[dateIndex]] = desired[index] / 21.0
            }
        }

        func target(_ values: [Double], event: Bool) -> IDBTargetAudit {
            .init(
                weights: zip(IntradayDownsideBreadthStrategy.assetOrder, values).map {
                    .init(symbol: $0.0, bits: .init($0.1))
                },
                event: event,
                suppressed: !event
            )
        }

        let reviews = ordinals.indices.map { reviewIndex -> IDBReviewAudit in
            let ordinal = ordinals[reviewIndex]
            let assets: [IDBAssetReviewAudit] = IntradayDownsideBreadthStrategy.signalAssetOrder.enumerated().map { assetIndex, symbol in
                let bars = (ordinal - 62...ordinal).map { dateIndex -> IDBFrozenBar in
                    var x = xByDate[allDates[dateIndex]]!
                    if inconsistentDuplicate, reviewIndex == 1, assetIndex == 0, dateIndex == 62 {
                        x = 123.0
                    }
                    return .init(
                        date: allDates[dateIndex],
                        open: .init(100), high: .init(200), low: .init(1),
                        close: .init(100 * Foundation.exp(x)), sourceID: symbol, x: .init(x)
                    )
                }
                let mean = risk[reviewIndex] && assetIndex == 0 ? -1.0 : 1.0
                return IDBAssetReviewAudit(
                    symbol: symbol, sourceID: symbol, currency: "CNY", bars: bars,
                    mean: IDBBitExactDouble(mean)
                )
            }
            let candidateValues = risk[reviewIndex] ? [0.5, 0.25, 0.25] : [0, 0.5, 0.5]
            return .init(
                date: allDates[ordinal], assets: assets,
                candidate: target(candidateValues, event: reviewIndex == 0),
                natural: target(Array(repeating: 1.0 / 3.0, count: 3), event: reviewIndex == 0),
                placebo: target([0, 0.5, 0.5], event: reviewIndex == 0)
            )
        }
        let window = IntradayDownsideBreadthWindow(
            id: "full", requestedStart: nil,
            actualStart: reviews[0].date, actualEnd: allDates.last!
        )
        return .init(
            schemaVersion: 1,
            trialID: IntradayDownsideBreadthStrategy.trialID,
            strategyID: IntradayDownsideBreadthStrategy.strategyID,
            strategyVersion: IntradayDownsideBreadthStrategy.strategyVersion,
            lineage: IntradayDownsideBreadthStrategy.lineage,
            gitCommit: String(repeating: "a", count: 40),
            fixturePath: "synthetic", fixtureSHA256: String(repeating: "1", count: 64),
            provenancePath: "synthetic", provenanceSHA256: String(repeating: "2", count: 64),
            assetOrder: IntradayDownsideBreadthStrategy.assetOrder,
            signalAssetOrder: IntradayDownsideBreadthStrategy.signalAssetOrder,
            lookback: 63, reviewStep: 21,
            anchorDate: reviews[0].date,
            runtime: .formal,
            actualWindows: [window],
            signalCommonDates: allDates,
            executableDates: allDates,
            provenance: [], reviews: reviews,
            fingerprints: .init(header: "", input: "", candidate: "", natural: "", placebo: "", full: "")
        )
    }

    private var windows: [IntradayDownsideBreadthWindow] {
        [
            .init(id: "full", requestedStart: nil, actualStart: "2024-01-01", actualEnd: "2024-12-31"),
            .init(id: "since_2016_08_31", requestedStart: "2016-08-31", actualStart: "2024-01-01", actualEnd: "2024-12-31"),
            .init(id: "since_2020_01_01", requestedStart: "2020-01-01", actualStart: "2024-01-01", actualEnd: "2024-12-31"),
            .init(id: "since_2022_01_01", requestedStart: "2022-01-01", actualStart: "2024-01-01", actualEnd: "2024-12-31")
        ]
    }

    private func evidence(sufficient: Bool = true, direction: Bool = true) -> IntradayDownsideBreadthFactorEvidence {
        .init(windows: windows.map { window in
            .init(
                windowID: window.id,
                riskCount: sufficient ? 5 : 4,
                calmCount: 5,
                riskMedian: -2,
                calmMedian: 1,
                sufficient: sufficient,
                direction: sufficient && direction,
                observations: []
            )
        })
    }

    private func metric(
        cagr: Double? = 0.09,
        sharpe: Double? = 0.80,
        mdd: Double? = 0.10
    ) -> IntradayDownsideBreadthFormalMetrics {
        .init(cagr: cagr, sharpe: sharpe, maxDrawdown: mdd)
    }

    private func metrics(_ value: IntradayDownsideBreadthFormalMetrics) -> [String: IntradayDownsideBreadthFormalMetrics] {
        Dictionary(uniqueKeysWithValues: windows.map { ($0.id, value) })
    }

    func testFactorUsesOldestToNewestOutcomesAndComputesCountsMediansAndDirection() throws {
        let frozen = artifact()
        let result = try IntradayDownsideBreadthFormalFactor.evaluate(artifact: frozen)
        let full = try XCTUnwrap(result.windows.first)
        XCTAssertEqual(full.observations.map(\.reviewDate), Array(frozen.reviews.prefix(12)).map(\.date))
        XCTAssertEqual(full.riskCount, 6)
        XCTAssertEqual(full.calmCount, 6)
        XCTAssertEqual(try XCTUnwrap(full.riskMedian), -15, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(full.calmMedian), 6, accuracy: 1e-12)
        XCTAssertTrue(full.sufficient)
        XCTAssertTrue(full.direction)
        XCTAssertEqual(try XCTUnwrap(full.observations.first?.outcome), -10, accuracy: 1e-12)
    }

    func testFactorRejectsInconsistentDuplicateFrozenX() throws {
        XCTAssertThrowsError(try IntradayDownsideBreadthFormalFactor.evaluate(
            artifact: artifact(inconsistentDuplicate: true)
        )) { error in
            XCTAssertTrue(String(describing: error).contains("inconsistent x"))
        }
    }

    func testInsufficientFactorEvidenceIsInvalidBeforeMetrics() {
        let result = IntradayDownsideBreadthFormalGate.evaluate(
            windows: windows, candidate: [:], natural: [:], placebo: [:], factor: evidence(sufficient: false)
        )
        XCTAssertEqual(result.decision, .invalid)
        XCTAssertTrue(result.checksByWindow.isEmpty)
    }

    func testGateAcceptsInclusiveAbsoluteBoundariesButRejectsStrictControlTies() {
        let candidate = metrics(metric())
        let passing = IntradayDownsideBreadthFormalGate.evaluate(
            windows: windows, candidate: candidate,
            natural: metrics(metric(cagr: 0, sharpe: 0.79, mdd: 0.1000001)),
            placebo: metrics(metric(cagr: 0, sharpe: 0.79, mdd: 1)),
            factor: evidence()
        )
        XCTAssertEqual(passing.decision, .pass)

        let sharpeTie = IntradayDownsideBreadthFormalGate.evaluate(
            windows: windows, candidate: candidate,
            natural: metrics(metric(cagr: 0, sharpe: 0.80, mdd: 0.11)),
            placebo: metrics(metric(cagr: 0, sharpe: 0.79, mdd: 1)), factor: evidence()
        )
        XCTAssertEqual(sharpeTie.decision, .fail)

        let mddTie = IntradayDownsideBreadthFormalGate.evaluate(
            windows: windows, candidate: candidate,
            natural: metrics(metric(cagr: 0, sharpe: 0.79, mdd: 0.10)),
            placebo: metrics(metric(cagr: 0, sharpe: 0.79, mdd: 1)), factor: evidence()
        )
        XCTAssertEqual(mddTie.decision, .fail)

        let placeboTie = IntradayDownsideBreadthFormalGate.evaluate(
            windows: windows, candidate: candidate,
            natural: metrics(metric(cagr: 0, sharpe: 0.79, mdd: 0.11)),
            placebo: metrics(metric(cagr: 0, sharpe: 0.80, mdd: 1)), factor: evidence()
        )
        XCTAssertEqual(placeboTie.decision, .fail)

        let wrongDirection = IntradayDownsideBreadthFormalGate.evaluate(
            windows: windows, candidate: candidate,
            natural: metrics(metric(cagr: 0, sharpe: 0.79, mdd: 0.11)),
            placebo: metrics(metric(cagr: 0, sharpe: 0.79, mdd: 1)),
            factor: evidence(direction: false)
        )
        XCTAssertEqual(wrongDirection.decision, .fail)
    }

    func testMissingAndNonfiniteMetricsFail() {
        let controls = metrics(metric(cagr: 0, sharpe: 0.1, mdd: 0.2))
        let missing = IntradayDownsideBreadthFormalGate.evaluate(
            windows: windows, candidate: [:], natural: controls, placebo: controls, factor: evidence()
        )
        XCTAssertEqual(missing.decision, .fail)

        var renamed = windows
        renamed[0] = .init(
            id: "renamed", requestedStart: nil,
            actualStart: renamed[0].actualStart, actualEnd: renamed[0].actualEnd
        )
        XCTAssertEqual(IntradayDownsideBreadthFormalGate.evaluate(
            windows: renamed, candidate: controls, natural: controls,
            placebo: controls, factor: evidence()
        ).decision, .fail)

        for invalid in [
            metric(cagr: nil),
            metric(sharpe: .nan),
            metric(mdd: .infinity)
        ] {
            let result = IntradayDownsideBreadthFormalGate.evaluate(
                windows: windows, candidate: metrics(invalid),
                natural: controls, placebo: controls, factor: evidence()
            )
            XCTAssertEqual(result.decision, .fail)
        }
    }

    func testVariantMetricsRunThroughSharedSimulator() throws {
        let frozen = artifact(count: 126, riskByReview: [false, false, false, false], outcomes: [1, 1, 1, 1])
        let parsedDates = dates(126).map { BacktestSeriesAlignment.historicalSeriesDate(from: $0)! }
        let symbols = IntradayDownsideBreadthStrategy.assetOrder
        let prices = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { assetIndex, symbol in
            (symbol, (0..<126).map { index in
                100.0 * Foundation.pow(1.0 + 0.0005 * Double(assetIndex + 1), Double(index))
            })
        })
        let observed = Dictionary(uniqueKeysWithValues: symbols.map { ($0, Array(repeating: true, count: 126)) })
        let options = Dictionary(uniqueKeysWithValues: symbols.map {
            ($0, BacktestAssetOption(symbol: $0, title: $0, color: .blue, requiresHistoricalFX: false, historicalFXSymbol: nil))
        })
        let frame = MarketDataFrame(
            dates: parsedDates, pricesBySymbol: prices, observedBySymbol: observed, ohlcBySymbol: [:],
            tradableSymbols: symbols, optionBySymbol: options, simulationRange: 1...125
        )
        let execution = BacktestExecutionConfig(
            initialCash: 100_000, feeRate: 0, slippageRate: 0, rebalanceBand: 0,
            financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "synthetic formal test"
        )
        let metrics = try IntradayDownsideBreadthFormalSimulation.runVariant(
            artifact: frozen, variant: .candidate, frame: frame, execution: execution
        )
        let full = try XCTUnwrap(metrics["full"])
        XCTAssertTrue(full.totalReturn.isFinite)
        XCTAssertTrue(full.maxDrawdown.isFinite)
        XCTAssertNotNil(full.annualizedReturn)
    }

    func testExecutableLaunchMarkerIsPermanentAndNonReplayable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let slot = directory.appendingPathComponent("ATM-SVP2-IDB-63-21-001.json")

        try IntradayDownsideBreadthFormalCommand.consumeLaunchMarker(
            slot: slot, slotSHA256: String(repeating: "1", count: 64),
            executableSHA256: String(repeating: "2", count: 64),
            receiptSHA256: String(repeating: "3", count: 64),
            executionCommit: String(repeating: "4", count: 40),
            runBudgetRecordHash: String(repeating: "5", count: 64),
            output: directory
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("ATM-SVP2-IDB-63-21-001.launched.json").path
        ))
        XCTAssertThrowsError(try IntradayDownsideBreadthFormalCommand.consumeLaunchMarker(
            slot: slot, slotSHA256: String(repeating: "1", count: 64),
            executableSHA256: String(repeating: "2", count: 64),
            receiptSHA256: String(repeating: "3", count: 64),
            executionCommit: String(repeating: "4", count: 40),
            runBudgetRecordHash: String(repeating: "5", count: 64),
            output: directory
        ))
    }
}
