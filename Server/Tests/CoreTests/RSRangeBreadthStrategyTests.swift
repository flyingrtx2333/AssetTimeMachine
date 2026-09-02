import XCTest
@testable import AssetTimeMachineBacktestCore

final class RSRangeBreadthStrategyTests: XCTestCase {
    private func bits(_ value: Double) -> String {
        String(format: "%016llx", value.bitPattern)
    }

    private func bar(
        _ day: Int,
        open: Double = 100,
        high: Double = 110,
        low: Double = 90,
        close: Double = 100,
        source: String = "synthetic"
    ) -> RSRangeBreadthSignalBar {
        RSRangeBreadthSignalBar(
            date: String(format: "2020-01-%02d", day),
            open: open,
            high: high,
            low: low,
            close: close,
            sourceID: source
        )
    }

    private func datedBars(count: Int, qMode: (Int) -> (Double, Double, Double, Double)) -> [RSRangeBreadthSignalBar] {
        let calendar = Calendar(identifier: .gregorian)
        let start = BacktestSeriesAlignment.historicalSeriesDate(from: "2020-01-01")!
        return (0..<count).map { index in
            let values = qMode(index)
            let date = calendar.date(byAdding: .day, value: index, to: start)!.recordDateString
            return RSRangeBreadthSignalBar(
                date: date,
                open: values.0,
                high: values.1,
                low: values.2,
                close: values.3,
                sourceID: "synthetic"
            )
        }
    }

    private func config(executableDates: [String] = []) -> RSRangeBreadthFreezeConfig {
        RSRangeBreadthFreezeConfig(
            gitCommit: "91c6bd4b05fa34d637686f42e96e62ad6cd48189",
            fixturePath: "fixture.json",
            fixtureSHA256: String(repeating: "1", count: 64),
            manifestPath: "manifest.json",
            manifestSHA256: String(repeating: "2", count: 64),
            runtime: .formal,
            actualWindows: [
                .init(id: "full", requestedStart: nil, actualStart: "2020-09-09", actualEnd: "2021-01-01"),
                .init(id: "since_2020", requestedStart: "2020-01-01", actualStart: "2020-09-09", actualEnd: "2021-01-01")
            ],
            executableDates: executableDates
        )
    }

    func testRogersSatchellFormulaAndBitPatternGolden() throws {
        let value = try XCTUnwrap(RSRangeBreadthFactor.dailyRS(open: 100, high: 110, low: 90, close: 100))
        XCTAssertEqual(value, log(1.1) * log(1.1) + log(0.9) * log(0.9))
        XCTAssertEqual(bits(value), "3f94ab579aa0ed00")
        XCTAssertEqual(RSRangeBreadthFactor.clampMicroNegative(-Double.leastNonzeroMagnitude), 0)
        XCTAssertEqual(bits(RSRangeBreadthFactor.clampMicroNegative(-Double.leastNonzeroMagnitude)), "0000000000000000")
        XCTAssertNil(RSRangeBreadthFactor.dailyRS(open: 100, high: 99, low: 90, close: 100))
    }

    func testXEqualityIsCalmAndZeroLongMeanIsInvalid() throws {
        let positive = Array(repeating: try XCTUnwrap(RSRangeBreadthFactor.dailyRS(open: 100, high: 110, low: 90, close: 100)), count: 252)
        let equal = RSRangeBreadthFactor.factor(qValues: positive)
        XCTAssertTrue(equal.valid)
        XCTAssertEqual(equal.state, .calm)
        XCTAssertEqual(bits(try XCTUnwrap(equal.x)), "0000000000000000")

        let invalid = RSRangeBreadthFactor.factor(qValues: Array(repeating: 0, count: 252))
        XCTAssertFalse(invalid.valid)
        XCTAssertNil(invalid.x)
        XCTAssertEqual(invalid.state, .invalid)
    }

    func testClockUsesOwn252BarsAndEvery21stJointDateIncludingAnchor() throws {
        let base = datedBars(count: 296) { _ in (100, 110, 90, 100) }
        var nasdaq = base
        nasdaq.remove(at: 260)
        let assets = [
            RSRangeBreadthAssetInput(symbol: "gold_cny", sourceID: "g", currency: "CNY", bars: base),
            RSRangeBreadthAssetInput(symbol: "nasdaq", sourceID: "n", currency: "CNY", bars: nasdaq),
            RSRangeBreadthAssetInput(symbol: "sp500", sourceID: "s", currency: "CNY", bars: base)
        ]
        let result = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config())
        XCTAssertEqual(result.reviews.map(\.date), [base[251].date, base[273].date, base[294].date])
        XCTAssertEqual(result.reviews[1].assets[1].bars.count, 252)
        XCTAssertLessThanOrEqual(result.reviews[1].assets[1].bars.last!.date, result.reviews[1].date)
    }

    func testCandidatePlaceboNaturalTargetsAndEventSuppression() throws {
        let lowRange = (100.0, 101.0, 99.0, 100.0)
        let highRange = (100.0, 130.0, 70.0, 100.0)
        let bars = datedBars(count: 294) { index in index >= 273 ? highRange : lowRange }
        let calm = datedBars(count: 294) { _ in lowRange }
        let result = try RSRangeBreadthScheduleBuilder.build(assets: [
            .init(symbol: "gold_cny", sourceID: "g", currency: "CNY", bars: bars),
            .init(symbol: "nasdaq", sourceID: "n", currency: "CNY", bars: calm),
            .init(symbol: "sp500", sourceID: "s", currency: "CNY", bars: calm)
        ], config: config())
        XCTAssertEqual(result.reviews.count, 3)
        XCTAssertEqual(result.reviews[0].candidate.weights.map(\.value), [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0])
        XCTAssertEqual(result.reviews[0].natural.weights.map(\.value), [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0])
        XCTAssertEqual(result.reviews[0].placebo.weights.map(\.value), [0, 0, 0])
        XCTAssertTrue(result.reviews[1].candidate.suppressed)
        XCTAssertTrue(result.reviews[1].natural.suppressed)
        XCTAssertFalse(result.reviews[2].candidate.suppressed)
        XCTAssertEqual(result.reviews[2].candidate.weights.map(\.value), [0, 0.5, 0.5])
        XCTAssertEqual(result.reviews[2].placebo.weights.map(\.value), [1, 0, 0])
    }

    func testBitExactSyntheticFingerprintGoldenAndMutationSensitivity() throws {
        let bars = datedBars(count: 273) { index in
            index == 272 ? (100, 120, 80, 100) : (100, 110, 90, 100)
        }
        let assets = RSRangeBreadthStrategy.assetOrder.enumerated().map { offset, symbol in
            RSRangeBreadthAssetInput(symbol: symbol, sourceID: "source-\(offset)", currency: "CNY", bars: bars)
        }
        let frozen = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config())
        XCTAssertEqual(frozen.combinedFingerprint, "a403012272e69b7c8516e5352cd6f0d2b389615ad65831a14163bd9476ea6df5")
        XCTAssertEqual(frozen.scheduleFingerprints.candidate, "83dd346fe7dd9ff5b20b22cae03d9673bf516afab7522c0c85fc06c4e3a6b45f")

        var changedBars = bars
        changedBars[0] = .init(
            date: bars[0].date,
            open: bars[0].open.nextUp,
            high: bars[0].high,
            low: bars[0].low,
            close: bars[0].close,
            sourceID: bars[0].sourceID
        )
        let changedAssets = RSRangeBreadthStrategy.assetOrder.enumerated().map { offset, symbol in
            RSRangeBreadthAssetInput(symbol: symbol, sourceID: "source-\(offset)", currency: "CNY", bars: offset == 0 ? changedBars : bars)
        }
        let changed = try RSRangeBreadthScheduleBuilder.build(assets: changedAssets, config: config())
        XCTAssertNotEqual(changed.combinedFingerprint, frozen.combinedFingerprint)
    }

    func testArtifactLoaderRejectsHashMismatchAndConsumerUsesFrozenTargets() throws {
        let bars = datedBars(count: 273) { _ in (100, 110, 90, 100) }
        let assets = RSRangeBreadthStrategy.assetOrder.enumerated().map { offset, symbol in
            RSRangeBreadthAssetInput(symbol: symbol, sourceID: "source-\(offset)", currency: "CNY", bars: bars)
        }
        let frozen = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config())
        let data = try RSRangeBreadthArtifactCodec.encode(frozen)
        let loaded = try RSRangeBreadthArtifactLoader.load(data: data, enforceFormalRuntime: false)
        XCTAssertEqual(loaded.target(variant: .candidate, reviewDate: frozen.reviews[0].date), frozen.reviews[0].candidate.valuesBySymbol)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["combinedFingerprint"] = String(repeating: "0", count: 64)
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try RSRangeBreadthArtifactLoader.load(data: tampered, enforceFormalRuntime: false))

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try RSRangeBreadthArtifactLoader.load(
            data: try JSONSerialization.data(withJSONObject: object), enforceFormalRuntime: false
        ))

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var reviews = try XCTUnwrap(object["reviews"] as? [[String: Any]])
        var first = reviews[0]
        var candidate = try XCTUnwrap(first["candidate"] as? [String: Any])
        var weights = try XCTUnwrap(candidate["weights"] as? [[String: Any]])
        weights[0]["bits"] = "not-a-binary64"
        candidate["weights"] = weights; first["candidate"] = candidate; reviews[0] = first; object["reviews"] = reviews
        XCTAssertThrowsError(try RSRangeBreadthArtifactLoader.load(
            data: try JSONSerialization.data(withJSONObject: object), enforceFormalRuntime: false
        ))
    }

    func testExecutableDatesAreCanonicalizedAndFingerprintBound() throws {
        let bars = datedBars(count: 273) { _ in (100, 110, 90, 100) }
        let assets = RSRangeBreadthStrategy.assetOrder.enumerated().map { offset, symbol in
            RSRangeBreadthAssetInput(symbol: symbol, sourceID: "source-\(offset)", currency: "CNY", bars: bars)
        }
        let plain = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config())
        let bound = try RSRangeBreadthScheduleBuilder.build(
            assets: assets,
            config: config(executableDates: ["2020-09-10", "2020-09-09", "2020-09-10"])
        )
        XCTAssertEqual(bound.executableDates, ["2020-09-09", "2020-09-10"])
        XCTAssertNotEqual(bound.combinedFingerprint, plain.combinedFingerprint)
    }

    func testSharedSimulatorCompletesSellThenBuyBeforeNextReview() throws {
        let calm: (Int) -> (Double, Double, Double, Double) = { _ in (100, 110, 90, 100) }
        let base = datedBars(count: 315, qMode: calm)
        var gold = base
        for index in 252..<273 {
            gold[index] = .init(date: gold[index].date, open: 100, high: 130, low: 70, close: 100, sourceID: "synthetic")
        }
        let assets = RSRangeBreadthStrategy.assetOrder.enumerated().map { offset, symbol in
            RSRangeBreadthAssetInput(symbol: symbol, sourceID: "source-\(offset)", currency: "CNY", bars: symbol == "gold_cny" ? gold : base)
        }
        let dates = base.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0.date)! }
        let dateTexts = base.map(\.date)
        let artifact = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config(executableDates: dateTexts))
        let options = Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { symbol in
            (symbol, BacktestAssetOption(symbol: symbol, title: symbol, color: .blue, requiresHistoricalFX: false, historicalFXSymbol: nil))
        })
        let frame = MarketDataFrame(
            dates: dates,
            pricesBySymbol: Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, Array(repeating: 100.0, count: dates.count)) }),
            observedBySymbol: Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, Array(repeating: true, count: dates.count)) }),
            ohlcBySymbol: [:], tradableSymbols: RSRangeBreadthStrategy.assetOrder,
            optionBySymbol: options, simulationRange: 1...(dates.count - 1)
        )
        let validated = try RSRangeBreadthSharedSimulator.run(
            artifact: artifact,
            variant: .candidate,
            frame: frame,
            execution: .init(initialCash: 100_000, feeRate: 0.001, slippageRate: 0.001, rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "RS contract test")
        )
        XCTAssertEqual(validated.trace.map(\.reviewDate), artifact.reviews.filter { $0.candidate.event }.map(\.date))
        XCTAssertEqual(validated.trace[1].completionDate, base[274].date)
        XCTAssertLessThan(validated.trace[1].completionDate, artifact.reviews[2].date)
    }

    func testSharedSimulatorRejectsIncompleteFrameCoverage() throws {
        let base = datedBars(count: 315, qMode: { _ in (100, 110, 90, 100) })
        let assets = RSRangeBreadthStrategy.assetOrder.enumerated().map { offset, symbol in
            RSRangeBreadthAssetInput(symbol: symbol, sourceID: "source-\(offset)", currency: "CNY", bars: base)
        }
        let dates = base.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0.date)! }
        let artifact = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config(executableDates: base.map(\.date)))
        let incompleteOptions = Array(RSRangeBreadthStrategy.assetOrder.dropLast())
        let frame = MarketDataFrame(
            dates: dates,
            pricesBySymbol: Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, Array(repeating: 100.0, count: dates.count)) }),
            observedBySymbol: Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, Array(repeating: true, count: dates.count)) }),
            ohlcBySymbol: [:], tradableSymbols: RSRangeBreadthStrategy.assetOrder,
            optionBySymbol: Dictionary(uniqueKeysWithValues: incompleteOptions.map { ($0, BacktestAssetOption(symbol: $0, title: $0, color: .blue, requiresHistoricalFX: false, historicalFXSymbol: nil)) }),
            simulationRange: 1...(dates.count - 1)
        )
        XCTAssertThrowsError(try RSRangeBreadthSharedSimulator.run(
            artifact: artifact, variant: .candidate, frame: frame,
            execution: .init(initialCash: 100_000, feeRate: 0, slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "coverage test")
        ))
    }

    func testSharedSimulatorRejectsCompletionOutsideFrozenExecutableDates() throws {
        let base = datedBars(count: 315, qMode: { _ in (100, 110, 90, 100) })
        let assets = RSRangeBreadthStrategy.assetOrder.enumerated().map { offset, symbol in
            RSRangeBreadthAssetInput(symbol: symbol, sourceID: "source-\(offset)", currency: "CNY", bars: base)
        }
        let dates = base.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0.date)! }
        let baselineArtifact = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config(executableDates: base.map(\.date)))
        let firstEventDate = try XCTUnwrap(baselineArtifact.reviews.first(where: { $0.candidate.event })?.date)
        let firstEventIndex = try XCTUnwrap(base.firstIndex(where: { $0.date == firstEventDate }))
        let omittedCompletion = base[firstEventIndex + 1].date
        let executableDates = base.map(\.date).filter { $0 != omittedCompletion }
        let artifact = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config(executableDates: executableDates))
        let options = Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { symbol in
            (symbol, BacktestAssetOption(symbol: symbol, title: symbol, color: .blue, requiresHistoricalFX: false, historicalFXSymbol: nil))
        })
        let frame = MarketDataFrame(
            dates: dates,
            pricesBySymbol: Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, Array(repeating: 100.0, count: dates.count)) }),
            observedBySymbol: Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, Array(repeating: true, count: dates.count)) }),
            ohlcBySymbol: [:], tradableSymbols: RSRangeBreadthStrategy.assetOrder,
            optionBySymbol: options, simulationRange: 1...(dates.count - 1)
        )
        XCTAssertThrowsError(try RSRangeBreadthSharedSimulator.run(
            artifact: artifact, variant: .candidate, frame: frame,
            execution: .init(initialCash: 100_000, feeRate: 0, slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "executable date test")
        ))
    }

    func testSharedSimulatorRejectsMalformedDatesRangeAndDuplicateTradables() throws {
        let base = datedBars(count: 315, qMode: { _ in (100, 110, 90, 100) })
        let assets = RSRangeBreadthStrategy.assetOrder.enumerated().map { offset, symbol in
            RSRangeBreadthAssetInput(symbol: symbol, sourceID: "source-\(offset)", currency: "CNY", bars: base)
        }
        let dates = base.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0.date)! }
        let artifact = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config(executableDates: base.map(\.date)))
        let prices = Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, Array(repeating: 100.0, count: dates.count)) })
        let observed = Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, Array(repeating: true, count: dates.count)) })
        let options = Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, BacktestAssetOption(symbol: $0, title: $0, color: .blue, requiresHistoricalFX: false, historicalFXSymbol: nil)) })
        let execution = BacktestExecutionConfig(initialCash: 100_000, feeRate: 0, slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "malformed frame test")

        var duplicateDates = dates
        duplicateDates[10] = duplicateDates[9]
        let duplicateDateFrame = MarketDataFrame(
            dates: duplicateDates, pricesBySymbol: prices, observedBySymbol: observed, ohlcBySymbol: [:],
            tradableSymbols: RSRangeBreadthStrategy.assetOrder, optionBySymbol: options, simulationRange: 1...(dates.count - 1)
        )
        XCTAssertThrowsError(try RSRangeBreadthSharedSimulator.run(artifact: artifact, variant: .candidate, frame: duplicateDateFrame, execution: execution))

        let duplicateTradableFrame = MarketDataFrame(
            dates: dates, pricesBySymbol: prices, observedBySymbol: observed, ohlcBySymbol: [:],
            tradableSymbols: RSRangeBreadthStrategy.assetOrder + [RSRangeBreadthStrategy.assetOrder[0]], optionBySymbol: options,
            simulationRange: 1...(dates.count - 1)
        )
        XCTAssertThrowsError(try RSRangeBreadthSharedSimulator.run(artifact: artifact, variant: .candidate, frame: duplicateTradableFrame, execution: execution))

        let outOfRangeFrame = MarketDataFrame(
            dates: dates, pricesBySymbol: prices, observedBySymbol: observed, ohlcBySymbol: [:],
            tradableSymbols: RSRangeBreadthStrategy.assetOrder, optionBySymbol: options, simulationRange: 1...dates.count
        )
        XCTAssertThrowsError(try RSRangeBreadthSharedSimulator.run(artifact: artifact, variant: .candidate, frame: outOfRangeFrame, execution: execution))
    }

    func testSharedSimulatorDefersUntilJointRealExecutionDate() throws {
        let base = datedBars(count: 315, qMode: { _ in (100, 110, 90, 100) })
        let assets = RSRangeBreadthStrategy.assetOrder.enumerated().map { offset, symbol in
            RSRangeBreadthAssetInput(symbol: symbol, sourceID: "source-\(offset)", currency: "CNY", bars: base)
        }
        let dates = base.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0.date)! }
        let baselineArtifact = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config(executableDates: base.map(\.date)))
        let firstEventDate = try XCTUnwrap(baselineArtifact.reviews.first(where: { $0.candidate.event })?.date)
        let firstEventIndex = try XCTUnwrap(base.firstIndex(where: { $0.date == firstEventDate }))
        let closedIndex = firstEventIndex + 1
        let completionIndex = firstEventIndex + 2
        let executableDates = base.map(\.date).filter { $0 != base[closedIndex].date }
        let artifact = try RSRangeBreadthScheduleBuilder.build(assets: assets, config: config(executableDates: executableDates))
        var observed = Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, Array(repeating: true, count: dates.count)) })
        observed[RSRangeBreadthStrategy.assetOrder[2]]![closedIndex] = false
        let options = Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, BacktestAssetOption(symbol: $0, title: $0, color: .blue, requiresHistoricalFX: false, historicalFXSymbol: nil)) })
        let frame = MarketDataFrame(
            dates: dates,
            pricesBySymbol: Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.assetOrder.map { ($0, Array(repeating: 100.0, count: dates.count)) }),
            observedBySymbol: observed, ohlcBySymbol: [:], tradableSymbols: RSRangeBreadthStrategy.assetOrder,
            optionBySymbol: options, simulationRange: 1...(dates.count - 1)
        )
        let validated = try RSRangeBreadthSharedSimulator.run(
            artifact: artifact, variant: .candidate, frame: frame,
            execution: .init(initialCash: 100_000, feeRate: 0, slippageRate: 0, rebalanceBand: 0, financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: "joint observation test")
        )
        XCTAssertEqual(validated.trace.first?.reviewDate, firstEventDate)
        XCTAssertEqual(validated.trace.first?.completionDate, base[completionIndex].date)
    }
}
