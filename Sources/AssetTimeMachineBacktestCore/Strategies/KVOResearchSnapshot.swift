import Foundation

/// Replays the completed KVO research policy on its original market-data vintage.
/// This historical strategy intentionally supplies no current allocation advice.
nonisolated public enum KVOResearchSnapshot {
    public static let strategyID = "research-kvo-quarter"
    public static let lastCivilDate = "2026-09-30"

    private struct Frame: Decodable {
        let dates: [String]
        let simulationRange: [Int]
        let tradableSymbols: [String]
        let pricesBySymbol: [String: [Double]]
        let observedBySymbol: [String: [Bool]]
    }
    private struct Target: Decodable {
        let sourceFrameIndex: Int
        let featureEpochFrameIndex: Int
        let modelAvailableFrameIndex: Int?
        let targetWeights: [String: Double]
    }
    private static func resource(_ name: String) -> Data? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "RecentWindow")
                ?? Bundle.module.url(forResource: name, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }
    private static let snapshot: (Frame, [Target])? = {
        guard let frameData = resource("kvo-frame"), let targetsData = resource("kvo-targets"),
              let frame = try? JSONDecoder().decode(Frame.self, from: frameData),
              let targets = try? JSONDecoder().decode([Target].self, from: targetsData),
              frame.dates.count == 5756, frame.dates.last == lastCivilDate,
              frame.simulationRange == [21, 5755], targets.count == 5735,
              frame.dates == frame.dates.sorted(), Set(frame.dates).count == frame.dates.count,
              targets.enumerated().allSatisfy({ $0.element.sourceFrameIndex == $0.offset + 21 }),
              frame.tradableSymbols.allSatisfy({ symbol in
                  frame.pricesBySymbol[symbol]?.count == frame.dates.count
                    && frame.observedBySymbol[symbol]?.count == frame.dates.count
              }), targets.allSatisfy({ target in
                  target.featureEpochFrameIndex <= target.sourceFrameIndex
                    && (target.modelAvailableFrameIndex ?? 21) <= target.sourceFrameIndex
                    && Set(target.targetWeights.keys).isSubset(of: Set(frame.tradableSymbols))
                    && target.targetWeights.values.allSatisfy { $0.isFinite && $0 >= 0 }
                    && target.targetWeights.values.reduce(0, +) <= 1 + 1e-12
              }) else { return nil }
        return (frame, targets)
    }()

    public static func run(initialCash: Double, settings: AdvancedBacktestRiskSettings,
                           dateBounds: ClosedRange<Date>? = nil) -> AdvancedRotationStrategyRun? {
        guard initialCash.isFinite, initialCash > 0,
              settings.feeRate.isFinite, settings.feeRate >= 0,
              settings.slippageRate.isFinite, settings.slippageRate >= 0,
              let (saved, targets) = snapshot else { return nil }
        let dates = saved.dates.compactMap { BacktestSeriesAlignment.historicalSeriesDate(from: $0) }
        guard dates.count == saved.dates.count,
              let end = dates.lastIndex(where: { (dateBounds?.upperBound ?? dates.last!) >= $0 }),
              end > 21, dateBounds.map({ $0.lowerBound <= dates[end] }) ?? true else { return nil }
        let options = BacktestCoreDefaults.strategyAssetOptions.filter { saved.tradableSymbols.contains($0.symbol) }
        let optionBySymbol = Dictionary(uniqueKeysWithValues: options.map { ($0.symbol, $0) })
        guard optionBySymbol.count == saved.tradableSymbols.count else { return nil }
        let frame = MarketDataFrame(dates: Array(dates.prefix(end + 1)),
            pricesBySymbol: saved.pricesBySymbol.mapValues { Array($0.prefix(end + 1)) },
            observedBySymbol: saved.observedBySymbol.mapValues { Array($0.prefix(end + 1)) },
            ohlcBySymbol: [:], tradableSymbols: saved.tradableSymbols,
            optionBySymbol: optionBySymbol, simulationRange: 21...end)
        let targetByIndex = Dictionary(uniqueKeysWithValues: targets.map { ($0.sourceFrameIndex, $0) })
        let maintenance = Set(targets.map(\.featureEpochFrameIndex)).union([21])
        var latest: Target?
        var submitted: [String: Double]?
        var queuedMaintenance = false
        var pending = false
        let execution = BacktestExecutionConfig(initialCash: initialCash,
            feeRate: settings.feeRate / 100, slippageRate: settings.slippageRate / 100,
            rebalanceBand: 0.04, tradeToBandBoundary: false,
            financingAnnualRate: 0, allowsFinancedExposure: false, buyReason: AdvancedBacktestStrategyMode.kvoResearchSnapshot.title)
        guard let simulation = BacktestDailySimulator.run(frame: frame, execution: execution,
            provider: StrategyTargetProvider { _ in
                guard let latest else { return [:] }
                submitted = latest.targetWeights
                queuedMaintenance = false
                pending = true
                // Keep explicit zero keys and exact stored weight bits.
                return latest.targetWeights
            }, rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
            contextualRebalanceDecision: { context in
                if let target = targetByIndex[context.signalIndex] { latest = target }
                if maintenance.contains(context.signalIndex) { queuedMaintenance = true }
                let changed = latest.map { submitted == nil || submitted! != $0.targetWeights } ?? false
                return .init(shouldRebalance: !pending && latest != nil && (changed || queuedMaintenance), refreshOverlay: false)
            }, didExecuteTarget: { _ in pending = false }),
              let last = simulation.points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: simulation.points) else { return nil }
        let benchmarks = frame.tradableSymbols.compactMap { symbol -> AdvancedBacktestBenchmarkSeries? in
            guard let prices = frame.pricesBySymbol[symbol], let option = optionBySymbol[symbol] else { return nil }
            let first = frame.simulationRange.first { prices[$0] > 0 && frame.observedBySymbol[symbol]?[$0] == true }
            let allocation = initialCash / Double(frame.tradableSymbols.count)
            let points = frame.simulationRange.enumerated().map { sequence, index in
                BacktestSeriesPoint(date: frame.dates[index], portfolioValue: first.map {
                    $0 <= index ? allocation * prices[index] / prices[$0] : allocation
                } ?? allocation, sequence: sequence)
            }
            return .init(id: symbol, title: option.title, points: points)
        }
        let asset = AdvancedBacktestAssetReport(symbol: strategyID, title: AdvancedBacktestStrategyMode.kvoResearchSnapshot.title,
            points: simulation.points, benchmarkPoints: simulation.benchmarkPoints, pricePoints: [],
            trades: simulation.trades, finalPortfolioValue: last.portfolioValue, finalCash: simulation.finalCash,
            finalUnits: simulation.finalUnits, exposureRatio: simulation.exposureRatio)
        let report = AdvancedBacktestReport(points: simulation.points, benchmarkPoints: simulation.benchmarkPoints,
            benchmarkSeries: benchmarks, trades: simulation.trades, assetReports: [asset],
            finalPortfolioValue: last.portfolioValue, finalCash: simulation.finalCash, finalUnits: simulation.finalUnits,
            totalReturn: metrics.totalReturn, annualizedReturn: metrics.annualizedReturn, maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility, sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: simulation.cashYieldSummary, riskSignalSummary: nil,
            exposurePoints: BacktestReportBuilder.exposurePoints(from: simulation.dailyStates),
            assetExposureSeries: BacktestReportBuilder.assetExposureSeries(from: simulation.dailyStates,
                symbolOrder: frame.tradableSymbols, titlesBySymbol: optionBySymbol.mapValues(\.title)))
        return .init(report: report, dailyStates: simulation.dailyStates)
    }
}
