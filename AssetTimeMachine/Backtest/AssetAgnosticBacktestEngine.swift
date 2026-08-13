import Foundation

/// Asset-name-independent allocation engine used for cross-market research and OOS validation.
///
/// Design constraints:
/// - strategy logic never branches on symbol, country, region or asset label;
/// - every decision at execution session T uses prices only through T-1;
/// - long-only, cash is allowed, no financing and no negative cash;
/// - execution uses the same adverse close-price slippage convention as the App backtest;
/// - parameters are frozen in `frozenV1` and are intended to be validated on unseen assets without retuning.
nonisolated struct AssetAgnosticStrategyConfig: Sendable, Equatable {
    let warmupSessions: Int
    let reviewSessions: Int
    let shortMomentumSessions: Int
    let mediumMomentumSessions: Int
    let longMomentumSessions: Int
    let trendMASessions: Int
    let volatilitySessions: Int
    let covarianceSessions: Int
    let targetAnnualizedVolatility: Double
    let maxAssetWeight: Double
    let maxAssets: Int
    let rebalanceBand: Double
    let targetTurnoverThreshold: Double
    let feeRate: Double
    let slippageRate: Double

    static let frozenV1 = AssetAgnosticStrategyConfig(
        warmupSessions: 252,
        reviewSessions: 21,
        shortMomentumSessions: 63,
        mediumMomentumSessions: 126,
        longMomentumSessions: 252,
        trendMASessions: 200,
        volatilitySessions: 63,
        covarianceSessions: 63,
        targetAnnualizedVolatility: 0.10,
        maxAssetWeight: 0.45,
        maxAssets: 3,
        rebalanceBand: 0.15,
        targetTurnoverThreshold: 0.12,
        feeRate: 0.01,
        slippageRate: 0.0005
    )

    /// Frozen after the first diagnostic run, before loading the final cross-market holdout set.
    /// V2 deliberately becomes simpler and more diversified: slower reviews, more eligible assets,
    /// a less restrictive volatility budget and wider execution hysteresis for the App's 1% fee assumption.
    static let frozenV2 = AssetAgnosticStrategyConfig(
        warmupSessions: 252,
        reviewSessions: 42,
        shortMomentumSessions: 63,
        mediumMomentumSessions: 126,
        longMomentumSessions: 252,
        trendMASessions: 200,
        volatilitySessions: 63,
        covarianceSessions: 63,
        targetAnnualizedVolatility: 0.14,
        maxAssetWeight: 0.40,
        maxAssets: 8,
        rebalanceBand: 0.20,
        targetTurnoverThreshold: 0.18,
        feeRate: 0.01,
        slippageRate: 0.0005
    )

    /// Frozen after V3 development on the former V2 holdout plus the legacy diagnostic set.
    /// Do not retune this configuration using the second country-market holdout.
    static let frozenV3 = AssetAgnosticStrategyConfig(
        warmupSessions: 252,
        reviewSessions: 42,
        shortMomentumSessions: 63,
        mediumMomentumSessions: 126,
        longMomentumSessions: 252,
        trendMASessions: 200,
        volatilitySessions: 63,
        covarianceSessions: 63,
        targetAnnualizedVolatility: 0.075,
        maxAssetWeight: 0.20,
        maxAssets: 8,
        rebalanceBand: 0.42,
        targetTurnoverThreshold: 0.24,
        feeRate: 0.01,
        slippageRate: 0.0005
    )

    /// Frozen V4 candidate after development across every previously exposed cross-market set.
    /// Do not retune this configuration using the third country-market holdout.
    static let frozenV4 = AssetAgnosticStrategyConfig(
        warmupSessions: 252,
        reviewSessions: 105,
        shortMomentumSessions: 63,
        mediumMomentumSessions: 105,
        longMomentumSessions: 252,
        trendMASessions: 250,
        volatilitySessions: 63,
        covarianceSessions: 63,
        targetAnnualizedVolatility: 0.075,
        maxAssetWeight: 0.20,
        maxAssets: 8,
        rebalanceBand: 0.55,
        targetTurnoverThreshold: 0.36,
        feeRate: 0.01,
        slippageRate: 0.0005
    )
}

/// V3 research configuration. V2 remains reproducible above; V3 has a separate execution path so
/// fixes discovered after the first frozen holdout do not rewrite the historical V2 experiment.
nonisolated struct AssetAgnosticV3Config: Sendable, Equatable {
    let warmupSessions: Int
    let allocationReviewSessions: Int
    let shortMomentumSessions: Int
    let mediumMomentumSessions: Int
    let longMomentumSessions: Int
    let fastMomentumSessions: Int
    let trendMASessions: Int
    let shortVolatilitySessions: Int
    let volatilitySessions: Int
    let covarianceSessions: Int
    let targetAnnualizedVolatility: Double
    let maxAssetWeight: Double
    let maxAssets: Int
    let rebalanceBand: Double
    let targetTurnoverThreshold: Double
    let trendExitBuffer: Double
    let fastExitMomentum: Double
    let mediumExitMomentum: Double
    let volatilitySpikeRatio: Double
    let highCorrelationThreshold: Double
    let feeRate: Double
    let slippageRate: Double

    /// Development starting point. This value is intentionally not called "frozen" until the
    /// second, untouched country holdout protocol has been preregistered and the binary compiled.
    static let development = AssetAgnosticV3Config(
        warmupSessions: 252,
        allocationReviewSessions: 42,
        shortMomentumSessions: 63,
        mediumMomentumSessions: 126,
        longMomentumSessions: 252,
        fastMomentumSessions: 20,
        trendMASessions: 200,
        shortVolatilitySessions: 20,
        volatilitySessions: 63,
        covarianceSessions: 63,
        targetAnnualizedVolatility: 0.12,
        maxAssetWeight: 0.35,
        maxAssets: 8,
        rebalanceBand: 0.15,
        targetTurnoverThreshold: 0.14,
        trendExitBuffer: 0.985,
        fastExitMomentum: -0.08,
        mediumExitMomentum: -0.04,
        volatilitySpikeRatio: 1.55,
        highCorrelationThreshold: 0.75,
        feeRate: 0.01,
        slippageRate: 0.0005
    )
}

nonisolated struct AssetAgnosticTrade: Codable, Sendable, Equatable {
    enum Side: String, Codable, Sendable {
        case buy
        case sell
    }

    let date: String
    let symbol: String
    let side: Side
    let executionPrice: Double
    let notional: Double
    let fee: Double
}

nonisolated struct AssetAgnosticPerformance: Codable, Sendable, Equatable {
    let startDate: String
    let endDate: String
    let totalReturn: Double
    let annualizedReturn: Double
    let maxDrawdown: Double
    let annualizedVolatility: Double
    let sharpeRatio: Double
    let turnover: Double
    let tradeCount: Int
}

nonisolated struct AssetAgnosticBacktestResult: Codable, Sendable, Equatable {
    let symbols: [String]
    let performance: AssetAgnosticPerformance
    let benchmark: AssetAgnosticPerformance
    let finalWeights: [String: Double]
    let cashWeight: Double
    let trades: [AssetAgnosticTrade]
}

nonisolated enum AssetAgnosticBacktestEngine {
    private struct AlignedFrame {
        let dates: [String]
        let pricesBySymbol: [String: [Double]]
    }

    private struct Candidate {
        let symbol: String
        let order: Int
        let score: Double
        let volatility: Double
        let quality: Double
    }

    private struct MetricsCore {
        let totalReturn: Double
        let annualizedReturn: Double
        let maxDrawdown: Double
        let annualizedVolatility: Double
        let sharpeRatio: Double
    }

    static func run(
        history: PublicHistoryResponse,
        symbols requestedSymbols: [String],
        initialCash: Double = 100_000,
        config: AssetAgnosticStrategyConfig = .frozenV2
    ) -> AssetAgnosticBacktestResult? {
        let requestedSet = Set(requestedSymbols)
        // Preserve the history payload's series order instead of sorting by ticker text.
        // Renaming a symbol therefore cannot alter execution order or floating-point accumulation.
        let symbols = history.series.map(\.symbol).filter { requestedSet.contains($0) }
        guard initialCash > 0,
              !symbols.isEmpty,
              config.warmupSessions >= config.longMomentumSessions,
              config.reviewSessions > 0,
              config.feeRate >= 0,
              config.slippageRate >= 0,
              let frame = alignedFrame(history: history, symbols: symbols),
              frame.dates.count > config.warmupSessions + 2
        else { return nil }

        let startIndex = config.warmupSessions + 1
        var cash = initialCash
        var units = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        var previousTarget = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        var equityCurve: [Double] = []
        var curveDates: [String] = []
        var trades: [AssetAgnosticTrade] = []
        var cumulativeTurnover = 0.0
        var runningPeak = initialCash

        func portfolioValue(at index: Int) -> Double {
            symbols.reduce(cash) { partial, symbol in
                partial + (units[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?[index] ?? 0)
            }
        }

        for index in startIndex..<frame.dates.count {
            let signalIndex = index - 1
            let preTradeValue = max(portfolioValue(at: index), 0)
            runningPeak = max(runningPeak, preTradeValue)
            let portfolioDrawdown = runningPeak > 0 ? max(1 - preTradeValue / runningPeak, 0) : 0

            let shouldReview = index == startIndex || (index - startIndex).isMultiple(of: config.reviewSessions)
            if shouldReview {
                let proposedTarget = targetWeights(
                    symbols: symbols,
                    pricesBySymbol: frame.pricesBySymbol,
                    signalIndex: signalIndex,
                    portfolioDrawdown: portfolioDrawdown,
                    previousTarget: previousTarget,
                    config: config
                )
                let targetChange = symbols.reduce(0.0) { partial, symbol in
                    partial + abs((proposedTarget[symbol] ?? 0) - (previousTarget[symbol] ?? 0))
                }
                let proposedGross = positiveWeightSum(proposedTarget)
                let previousGross = positiveWeightSum(previousTarget)
                let meaningfulRiskCut = proposedGross + 0.08 < previousGross
                let target = previousGross <= 0 || targetChange >= config.targetTurnoverThreshold || meaningfulRiskCut
                    ? proposedTarget
                    : previousTarget

                if target != previousTarget || index == startIndex {
                    executeRebalance(
                        date: frame.dates[index],
                        index: index,
                        symbols: symbols,
                        pricesBySymbol: frame.pricesBySymbol,
                        targetWeights: target,
                        preTradeValue: preTradeValue,
                        config: config,
                        cash: &cash,
                        units: &units,
                        trades: &trades,
                        cumulativeTurnover: &cumulativeTurnover
                    )
                    previousTarget = target
                }
            }

            let value = max(portfolioValue(at: index), 0)
            runningPeak = max(runningPeak, value)
            equityCurve.append(value)
            curveDates.append(frame.dates[index])
        }

        guard let firstDate = curveDates.first,
              let lastDate = curveDates.last,
              equityCurve.count >= 2,
              let core = performanceMetrics(values: equityCurve, dates: curveDates)
        else { return nil }

        let finalValue = equityCurve.last ?? initialCash
        let finalWeights: [String: Double] = Dictionary(uniqueKeysWithValues: symbols.map { symbol in
            let marketValue = (units[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?.last ?? 0)
            return (symbol, finalValue > 0 ? max(marketValue / finalValue, 0) : 0)
        })
        let cashWeight = finalValue > 0 ? max(cash / finalValue, 0) : 0
        let strategyPerformance = AssetAgnosticPerformance(
            startDate: firstDate,
            endDate: lastDate,
            totalReturn: core.totalReturn,
            annualizedReturn: core.annualizedReturn,
            maxDrawdown: core.maxDrawdown,
            annualizedVolatility: core.annualizedVolatility,
            sharpeRatio: core.sharpeRatio,
            turnover: cumulativeTurnover,
            tradeCount: trades.count
        )

        guard let benchmarkPerformance = buyAndHoldBenchmark(
            frame: frame,
            symbols: symbols,
            startIndex: startIndex,
            initialCash: initialCash,
            config: config
        ) else { return nil }

        return AssetAgnosticBacktestResult(
            symbols: symbols,
            performance: strategyPerformance,
            benchmark: benchmarkPerformance,
            finalWeights: finalWeights,
            cashWeight: cashWeight,
            trades: trades
        )
    }

    private static func targetWeights(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        portfolioDrawdown: Double,
        previousTarget: [String: Double],
        config: AssetAgnosticStrategyConfig
    ) -> [String: Double] {
        var candidates: [Candidate] = []
        for (order, symbol) in symbols.enumerated() {
            guard let prices = pricesBySymbol[symbol], prices.indices.contains(signalIndex),
                  let ma = movingAverage(prices, at: signalIndex, lookback: config.trendMASessions),
                  let mShort = momentum(prices, at: signalIndex, lookback: config.shortMomentumSessions),
                  let mMedium = momentum(prices, at: signalIndex, lookback: config.mediumMomentumSessions),
                  let mLong = momentum(prices, at: signalIndex, lookback: config.longMomentumSessions),
                  let vol = annualizedVolatility(prices, at: signalIndex, lookback: config.volatilitySessions),
                  let downsideVol = annualizedDownsideVolatility(prices, at: signalIndex, lookback: config.volatilitySessions),
                  let efficiency = trendEfficiency(prices, at: signalIndex, lookback: config.mediumMomentumSessions),
                  vol > 0
            else { continue }

            let price = prices[signalIndex]
            // Generic time-series momentum with hysteresis. Entry is strict; an existing position
            // receives a small neutral zone so 1% one-way costs are not paid on every MA touch.
            let wasHeld = (previousTarget[symbol] ?? 0) > 0.005
            let entryConfirmed = price > ma && mMedium > 0 && mLong > -0.05
            let holdConfirmed = price > ma * 0.98 && mMedium > -0.03 && mLong > -0.08
            guard wasHeld ? holdConfirmed : entryConfirmed else { continue }

            let safeDownsideVol = max(downsideVol, vol * 0.35, 0.01)
            let score = 0.50 * mMedium / max(vol, 0.01)
                + 0.30 * mLong / max(vol, 0.01)
                + 0.20 * mShort / safeDownsideVol
                + 0.20 * efficiency
            let quality = clamp(0.65 + 1.5 * max(mMedium, 0) + 0.50 * efficiency, lower: 0.50, upper: 2.00)
            candidates.append(.init(symbol: symbol, order: order, score: score, volatility: vol, quality: quality))
        }

        guard !candidates.isEmpty else {
            return Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        }

        candidates.sort {
            if abs($0.score - $1.score) > 1e-12 { return $0.score > $1.score }
            if abs($0.volatility - $1.volatility) > 1e-12 { return $0.volatility < $1.volatility }
            if abs($0.quality - $1.quality) > 1e-12 { return $0.quality > $1.quality }
            return $0.order < $1.order
        }
        let selected = Array(candidates.prefix(max(1, min(config.maxAssets, candidates.count))))
        let selectedSymbols = selected.map(\.symbol)

        var rawWeights = Array(repeating: 0.0, count: selected.count)
        for index in selected.indices {
            let candidate = selected[index]
            var correlationTotal = 0.0
            var correlationCount = 0
            for peerIndex in selected.indices where peerIndex != index {
                let peer = selected[peerIndex].symbol
                guard let lhs = pricesBySymbol[candidate.symbol],
                      let rhs = pricesBySymbol[peer],
                      let corr = correlation(lhs, rhs, at: signalIndex, lookback: config.covarianceSessions)
                else { continue }
                correlationTotal += max(corr, 0)
                correlationCount += 1
            }
            let averagePositiveCorrelation = correlationCount > 0 ? correlationTotal / Double(correlationCount) : 0
            let diversificationPenalty = 1 + 1.25 * averagePositiveCorrelation
            rawWeights[index] = candidate.quality / (pow(max(candidate.volatility, 0.05), 1.20) * diversificationPenalty)
        }

        let rawSum = rawWeights.reduce(0, +)
        guard rawSum > 0 else {
            return Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        }
        var normalizedWeights = rawWeights.map { $0 / rawSum }
        normalizedWeights = capAndRedistributeV3(
            normalizedWeights,
            maxWeight: max(config.maxAssetWeight, 1 / Double(max(selected.count, 1)))
        )
        var normalized = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        for index in selected.indices {
            normalized[selected[index].symbol] = normalizedWeights[index]
        }

        let estimatedVol = portfolioVolatilityV3(
            orderedSymbols: selectedSymbols,
            weights: normalized,
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            lookback: config.covarianceSessions
        )
        let volatilityScale = estimatedVol > 0
            ? min(1.0, config.targetAnnualizedVolatility / estimatedVol)
            : 0.0
        let breadth = Double(candidates.count) / Double(max(symbols.count, 1))
        let breadthScale: Double
        switch breadth {
        case ..<0.25: breadthScale = 0.50
        case ..<0.50: breadthScale = 0.70
        case ..<0.75: breadthScale = 0.90
        default: breadthScale = 1.00
        }
        let drawdownScale: Double
        switch portfolioDrawdown {
        case 0.12...: drawdownScale = 0.40
        case 0.08...: drawdownScale = 0.60
        case 0.05...: drawdownScale = 0.80
        default: drawdownScale = 1.00
        }
        let grossScale = min(1.0, volatilityScale * breadthScale * drawdownScale)

        var result = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        for index in selected.indices {
            let symbol = selected[index].symbol
            result[symbol] = max(normalizedWeights[index] * grossScale, 0)
        }
        let gross = orderedWeightSum(symbols: symbols, weights: result)
        if gross > 1 {
            result = result.mapValues { $0 / gross }
        }
        return result
    }

    private static func executeRebalance(
        date: String,
        index: Int,
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        targetWeights: [String: Double],
        preTradeValue: Double,
        config: AssetAgnosticStrategyConfig,
        cash: inout Double,
        units: inout [String: Double],
        trades: inout [AssetAgnosticTrade],
        cumulativeTurnover: inout Double
    ) {
        guard preTradeValue > 0 else { return }

        // Sell first so a no-leverage portfolio can finance buys without assuming negative cash.
        for symbol in symbols {
            guard let price = pricesBySymbol[symbol]?[index], price > 0 else { continue }
            let heldUnits = max(units[symbol] ?? 0, 0)
            let currentValue = heldUnits * price
            let targetValue = preTradeValue * max(targetWeights[symbol] ?? 0, 0)
            let shouldExit = targetValue <= 0 && heldUnits > 0
            let shouldTrim = currentValue > targetValue * (1 + config.rebalanceBand)
            guard shouldExit || shouldTrim else { continue }

            let valueToSell = shouldExit ? currentValue : max(currentValue - targetValue, 0)
            let unitsToSell = min(heldUnits, valueToSell / price)
            guard unitsToSell > 0 else { continue }
            let executionPrice = max(price * (1 - config.slippageRate), 0)
            let gross = unitsToSell * executionPrice
            let fee = gross * config.feeRate
            let proceeds = max(gross - fee, 0)
            cash += proceeds
            units[symbol] = max(heldUnits - unitsToSell, 0)
            cumulativeTurnover += gross / preTradeValue
            trades.append(.init(date: date, symbol: symbol, side: .sell, executionPrice: executionPrice, notional: gross, fee: fee))
        }

        // Compute all buy demands against the same pre-trade portfolio value and scale them
        // pro-rata to available cash. This removes symbol-order dependence from execution.
        var desiredSpend = Array(repeating: 0.0, count: symbols.count)
        for (position, symbol) in symbols.enumerated() {
            guard let price = pricesBySymbol[symbol]?[index], price > 0 else { continue }
            let currentValue = max(units[symbol] ?? 0, 0) * price
            let targetValue = preTradeValue * max(targetWeights[symbol] ?? 0, 0)
            let shouldAdd = currentValue < targetValue * (1 - config.rebalanceBand)
            guard shouldAdd else { continue }
            desiredSpend[position] = max(targetValue - currentValue, 0)
        }
        let totalDesiredSpend = desiredSpend.reduce(0, +)
        let buyScale = totalDesiredSpend > 0 ? min(1.0, max(cash, 0) / totalDesiredSpend) : 0
        let startingCash = max(cash, 0)
        var spentCash = 0.0
        for (position, symbol) in symbols.enumerated() {
            let requestedSpend = desiredSpend[position]
            guard requestedSpend > 0,
                  let price = pricesBySymbol[symbol]?[index], price > 0
            else { continue }
            let amountToSpend = requestedSpend * buyScale
            guard amountToSpend > 0 else { continue }
            let executionPrice = price * (1 + config.slippageRate)
            let fee = amountToSpend * config.feeRate
            let invested = max(amountToSpend - fee, 0)
            let boughtUnits = executionPrice > 0 ? invested / executionPrice : 0
            guard boughtUnits > 0 else { continue }
            units[symbol, default: 0] += boughtUnits
            spentCash += amountToSpend
            cumulativeTurnover += amountToSpend / preTradeValue
            trades.append(.init(date: date, symbol: symbol, side: .buy, executionPrice: executionPrice, notional: amountToSpend, fee: fee))
        }
        cash = max(startingCash - spentCash, 0)

        // Numerical guard: this engine must never finance exposure.
        if cash < 0 && cash > -1e-8 { cash = 0 }
    }

    private static func buyAndHoldBenchmark(
        frame: AlignedFrame,
        symbols: [String],
        startIndex: Int,
        initialCash: Double,
        config: AssetAgnosticStrategyConfig
    ) -> AssetAgnosticPerformance? {
        guard symbols.count > 0, frame.dates.indices.contains(startIndex) else { return nil }
        let perAssetCash = initialCash / Double(symbols.count)
        var benchmarkUnits: [String: Double] = [:]
        var entryFees = 0.0
        for symbol in symbols {
            guard let price = frame.pricesBySymbol[symbol]?[startIndex], price > 0 else { return nil }
            let fee = perAssetCash * config.feeRate
            entryFees += fee
            let invested = max(perAssetCash - fee, 0)
            benchmarkUnits[symbol] = invested / (price * (1 + config.slippageRate))
        }
        var values: [Double] = []
        var dates: [String] = []
        for index in startIndex..<frame.dates.count {
            let value = symbols.reduce(0.0) { partial, symbol in
                partial + (benchmarkUnits[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?[index] ?? 0)
            }
            values.append(value)
            dates.append(frame.dates[index])
        }
        guard let metrics = performanceMetrics(values: values, dates: dates),
              let first = dates.first, let last = dates.last
        else { return nil }
        return .init(
            startDate: first,
            endDate: last,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            turnover: max(1 - entryFees / initialCash, 0),
            tradeCount: symbols.count
        )
    }

    private static func alignedFrame(history: PublicHistoryResponse, symbols: [String]) -> AlignedFrame? {
        let lookup = Dictionary(uniqueKeysWithValues: history.series.map { ($0.symbol, $0) })
        var datePriceMaps: [String: [String: Double]] = [:]
        for symbol in symbols {
            guard let series = lookup[symbol] else { return nil }
            var map: [String: Double] = [:]
            for (date, price) in zip(series.dates, series.prices) where price.isFinite && price > 0 {
                map[date] = price
            }
            guard map.count > 2 else { return nil }
            datePriceMaps[symbol] = map
        }

        var commonDates: Set<String>?
        for symbol in symbols {
            let dates = Set(datePriceMaps[symbol]?.keys ?? Dictionary<String, Double>().keys)
            commonDates = commonDates.map { $0.intersection(dates) } ?? dates
        }
        let dates = Array(commonDates ?? []).sorted()
        guard dates.count > 2 else { return nil }

        var pricesBySymbol: [String: [Double]] = [:]
        for symbol in symbols {
            guard let map = datePriceMaps[symbol] else { return nil }
            let prices = dates.compactMap { map[$0] }
            guard prices.count == dates.count else { return nil }
            pricesBySymbol[symbol] = prices
        }
        return .init(dates: dates, pricesBySymbol: pricesBySymbol)
    }

    private static func performanceMetrics(values: [Double], dates: [String]) -> MetricsCore? {
        guard values.count == dates.count, values.count >= 2,
              let first = values.first, let last = values.last,
              first > 0, last >= 0
        else { return nil }

        var peak = first
        var maxDrawdown = 0.0
        var returns: [Double] = []
        for index in values.indices {
            let value = max(values[index], 0)
            peak = max(peak, value)
            if peak > 0 { maxDrawdown = max(maxDrawdown, 1 - value / peak) }
            if index > 0, values[index - 1] > 0 {
                returns.append(value / values[index - 1] - 1)
            }
        }
        let totalReturn = last / first - 1
        let years = calendarYears(from: dates.first, to: dates.last) ?? (Double(values.count - 1) / 252)
        let annualizedReturn = years > 0 && last > 0 ? pow(last / first, 1 / years) - 1 : totalReturn
        let dailyMean = mean(returns)
        let dailyStd = sampleStandardDeviation(returns)
        let annualizedVolatility = dailyStd * sqrt(252)
        let sharpe = dailyStd > 0 ? dailyMean / dailyStd * sqrt(252) : 0
        return .init(
            totalReturn: totalReturn,
            annualizedReturn: annualizedReturn,
            maxDrawdown: maxDrawdown,
            annualizedVolatility: annualizedVolatility,
            sharpeRatio: sharpe
        )
    }

    private static func calendarYears(from start: String?, to end: String?) -> Double? {
        guard let start, let end else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startDate = formatter.date(from: start), let endDate = formatter.date(from: end), endDate > startDate else { return nil }
        return endDate.timeIntervalSince(startDate) / (365.25 * 86_400)
    }

    private static func movingAverage(_ prices: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0, index >= lookback - 1 else { return nil }
        let range = (index - lookback + 1)...index
        return range.reduce(0.0) { $0 + prices[$1] } / Double(lookback)
    }

    private static func momentum(_ prices: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0, index >= lookback, prices[index - lookback] > 0 else { return nil }
        return prices[index] / prices[index - lookback] - 1
    }

    private static func dailyReturns(_ prices: [Double], at index: Int, lookback: Int) -> [Double]? {
        guard lookback > 1, index >= lookback else { return nil }
        let start = index - lookback
        var result: [Double] = []
        result.reserveCapacity(lookback)
        for item in (start + 1)...index {
            let previous = prices[item - 1]
            guard previous > 0 else { return nil }
            result.append(prices[item] / previous - 1)
        }
        return result
    }

    private static func annualizedVolatility(_ prices: [Double], at index: Int, lookback: Int) -> Double? {
        guard let returns = dailyReturns(prices, at: index, lookback: lookback) else { return nil }
        return sampleStandardDeviation(returns) * sqrt(252)
    }

    private static func annualizedDownsideVolatility(_ prices: [Double], at index: Int, lookback: Int) -> Double? {
        guard let returns = dailyReturns(prices, at: index, lookback: lookback) else { return nil }
        let downside = returns.map { min($0, 0) }
        return sqrt(downside.map { $0 * $0 }.reduce(0, +) / Double(max(downside.count, 1))) * sqrt(252)
    }

    private static func trendEfficiency(_ prices: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 1, index >= lookback else { return nil }
        let start = index - lookback
        let net = abs(prices[index] - prices[start])
        var path = 0.0
        for item in (start + 1)...index { path += abs(prices[item] - prices[item - 1]) }
        return path > 0 ? min(net / path, 1) : 0
    }

    private static func correlation(_ lhs: [Double], _ rhs: [Double], at index: Int, lookback: Int) -> Double? {
        guard let left = dailyReturns(lhs, at: index, lookback: lookback),
              let right = dailyReturns(rhs, at: index, lookback: lookback),
              left.count == right.count, left.count > 1
        else { return nil }
        let leftMean = mean(left)
        let rightMean = mean(right)
        var covariance = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for item in left.indices {
            let a = left[item] - leftMean
            let b = right[item] - rightMean
            covariance += a * b
            leftVariance += a * a
            rightVariance += b * b
        }
        let denominator = sqrt(leftVariance * rightVariance)
        return denominator > 0 ? covariance / denominator : 0
    }

    private static func portfolioVolatility(
        weights: [String: Double],
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        lookback: Int
    ) -> Double {
        let active = weights.filter { $0.value > 0 }.map(\.key).sorted()
        guard !active.isEmpty else { return 0 }
        var returnsBySymbol: [String: [Double]] = [:]
        for symbol in active {
            guard let prices = pricesBySymbol[symbol],
                  let returns = dailyReturns(prices, at: signalIndex, lookback: lookback)
            else { return 0 }
            returnsBySymbol[symbol] = returns
        }
        var dailyVariance = 0.0
        for lhs in active {
            for rhs in active {
                guard let left = returnsBySymbol[lhs], let right = returnsBySymbol[rhs] else { continue }
                let covariance = sampleCovariance(left, right)
                dailyVariance += (weights[lhs] ?? 0) * (weights[rhs] ?? 0) * covariance
            }
        }
        return sqrt(max(dailyVariance, 0)) * sqrt(252)
    }

    private static func capAndRedistribute(_ weights: [String: Double], maxWeight: Double) -> [String: Double] {
        guard !weights.isEmpty else { return weights }
        let cap = clamp(maxWeight, lower: 0, upper: 1)
        var result = weights
        for _ in 0..<weights.count + 2 {
            let over = result.filter { $0.value > cap + 1e-12 }
            guard !over.isEmpty else { break }
            let excess = over.reduce(0.0) { $0 + ($1.value - cap) }
            for (symbol, _) in over { result[symbol] = cap }
            let under = result.filter { $0.value < cap - 1e-12 }
            let underSum = under.values.reduce(0, +)
            guard excess > 0, underSum > 0 else { break }
            for (symbol, value) in under {
                result[symbol] = min(cap, value + excess * value / underSum)
            }
        }
        let sum = result.values.reduce(0, +)
        return sum > 0 ? result.mapValues { $0 / sum } : result
    }

    private static func positiveWeightSum(_ weights: [String: Double]) -> Double {
        weights.values.reduce(0) { $0 + max($1, 0) }
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func sampleStandardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0.0) { $0 + pow($1 - average, 2) } / Double(values.count - 1)
        return sqrt(max(variance, 0))
    }

    private static func sampleCovariance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, lhs.count > 1 else { return 0 }
        let lhsMean = mean(lhs)
        let rhsMean = mean(rhs)
        let total = lhs.indices.reduce(0.0) { partial, index in
            partial + (lhs[index] - lhsMean) * (rhs[index] - rhsMean)
        }
        return total / Double(lhs.count - 1)
    }

    // MARK: - Sparse V3 engine

    /// A deliberately small evolution of the V2 allocator: same asset-agnostic target model and
    /// sparse review cadence, but portfolio state is strictly known through T-1 and the first
    /// transaction cost is included in reported performance. This is the preferred V3 research path.
    static func runSparseV3(
        history: PublicHistoryResponse,
        symbols requestedSymbols: [String],
        initialCash: Double = 100_000,
        config: AssetAgnosticStrategyConfig
    ) -> AssetAgnosticBacktestResult? {
        let requestedSet = Set(requestedSymbols)
        let symbols = history.series.map(\.symbol).filter { requestedSet.contains($0) }
        guard initialCash > 0,
              !symbols.isEmpty,
              config.warmupSessions >= config.longMomentumSessions,
              config.reviewSessions > 0,
              let frame = alignedFrame(history: history, symbols: symbols),
              frame.dates.count > config.warmupSessions + 2
        else { return nil }

        let startIndex = config.warmupSessions + 1
        var cash = initialCash
        var units = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        var previousTarget = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        var trades: [AssetAgnosticTrade] = []
        var cumulativeTurnover = 0.0
        var equityCurve = [initialCash]
        var curveDates = [frame.dates[startIndex - 1]]
        var knownPeak = initialCash

        func portfolioValue(at index: Int) -> Double {
            symbols.reduce(cash) { partial, symbol in
                partial + (units[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?[index] ?? 0)
            }
        }

        for index in startIndex..<frame.dates.count {
            let signalIndex = index - 1
            let knownValue = max(equityCurve.last ?? initialCash, 0)
            knownPeak = max(knownPeak, knownValue)
            let knownDrawdown = knownPeak > 0 ? max(1 - knownValue / knownPeak, 0) : 0
            let preTradeValue = max(portfolioValue(at: index), 0)
            let shouldReview = index == startIndex || (index - startIndex).isMultiple(of: config.reviewSessions)

            if shouldReview {
                let proposedTarget = targetWeights(
                    symbols: symbols,
                    pricesBySymbol: frame.pricesBySymbol,
                    signalIndex: signalIndex,
                    portfolioDrawdown: knownDrawdown,
                    previousTarget: previousTarget,
                    config: config
                )
                let targetChange = orderedWeightDistance(symbols: symbols, lhs: proposedTarget, rhs: previousTarget)
                let proposedGross = orderedWeightSum(symbols: symbols, weights: proposedTarget)
                let previousGross = orderedWeightSum(symbols: symbols, weights: previousTarget)
                let meaningfulRiskCut = proposedGross + 0.08 < previousGross
                let target = previousGross <= 0 || targetChange >= config.targetTurnoverThreshold || meaningfulRiskCut
                    ? proposedTarget
                    : previousTarget

                if target != previousTarget || index == startIndex {
                    executeRebalance(
                        date: frame.dates[index],
                        index: index,
                        symbols: symbols,
                        pricesBySymbol: frame.pricesBySymbol,
                        targetWeights: target,
                        preTradeValue: preTradeValue,
                        config: config,
                        cash: &cash,
                        units: &units,
                        trades: &trades,
                        cumulativeTurnover: &cumulativeTurnover
                    )
                    previousTarget = target
                }
            }

            let value = max(portfolioValue(at: index), 0)
            equityCurve.append(value)
            curveDates.append(frame.dates[index])
            knownPeak = max(knownPeak, value)
        }

        guard let core = performanceMetrics(values: equityCurve, dates: curveDates),
              let firstDate = curveDates.first,
              let lastDate = curveDates.last,
              let benchmark = buyAndHoldBenchmarkV3(
                frame: frame,
                symbols: symbols,
                startIndex: startIndex,
                initialCash: initialCash,
                feeRate: config.feeRate,
                slippageRate: config.slippageRate
              )
        else { return nil }

        let finalValue = equityCurve.last ?? initialCash
        let finalWeights = Dictionary(uniqueKeysWithValues: symbols.map { symbol in
            let marketValue = (units[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?.last ?? 0)
            return (symbol, finalValue > 0 ? max(marketValue / finalValue, 0) : 0)
        })
        let cashWeight = finalValue > 0 ? max(cash / finalValue, 0) : 0
        let performance = AssetAgnosticPerformance(
            startDate: firstDate,
            endDate: lastDate,
            totalReturn: core.totalReturn,
            annualizedReturn: core.annualizedReturn,
            maxDrawdown: core.maxDrawdown,
            annualizedVolatility: core.annualizedVolatility,
            sharpeRatio: core.sharpeRatio,
            turnover: cumulativeTurnover,
            tradeCount: trades.count
        )
        return .init(
            symbols: symbols,
            performance: performance,
            benchmark: benchmark,
            finalWeights: finalWeights,
            cashWeight: cashWeight,
            trades: trades
        )
    }

    // MARK: - Experimental daily-risk V3 engine

    private struct V3Candidate {
        let symbol: String
        let order: Int
        let score: Double
        let volatility: Double
        let downsideVolatility: Double
        let quality: Double
        let shortVolatilityRatio: Double
    }

    /// V3 keeps slow allocation selection but adds a daily, sell-only risk layer. All decision
    /// inputs come from `signalIndex == T-1`; only execution sizing/prices use session T.
    static func runV3(
        history: PublicHistoryResponse,
        symbols requestedSymbols: [String],
        initialCash: Double = 100_000,
        config: AssetAgnosticV3Config = .development
    ) -> AssetAgnosticBacktestResult? {
        let requestedSet = Set(requestedSymbols)
        let symbols = history.series.map(\.symbol).filter { requestedSet.contains($0) }
        guard initialCash > 0,
              !symbols.isEmpty,
              config.warmupSessions >= config.longMomentumSessions,
              config.allocationReviewSessions > 0,
              let frame = alignedFrame(history: history, symbols: symbols),
              frame.dates.count > config.warmupSessions + 2
        else { return nil }

        let startIndex = config.warmupSessions + 1
        var cash = initialCash
        var units = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        var strategicTarget = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        var activeTarget = strategicTarget
        var trades: [AssetAgnosticTrade] = []
        var cumulativeTurnover = 0.0

        // Include untouched starting cash in metrics so the first rebalance fee/slippage is counted.
        var equityCurve = [initialCash]
        var curveDates = [frame.dates[startIndex - 1]]
        var knownPeak = initialCash

        func portfolioValue(at index: Int) -> Double {
            symbols.reduce(cash) { partial, symbol in
                partial + (units[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?[index] ?? 0)
            }
        }

        for index in startIndex..<frame.dates.count {
            let signalIndex = index - 1
            // This value is known at T-1. Do not use today's close to compute a decision state.
            let knownValue = max(equityCurve.last ?? initialCash, 0)
            knownPeak = max(knownPeak, knownValue)
            let knownDrawdown = knownPeak > 0 ? max(1 - knownValue / knownPeak, 0) : 0
            let preTradeValue = max(portfolioValue(at: index), 0)
            let shouldReview = index == startIndex || (index - startIndex).isMultiple(of: config.allocationReviewSessions)

            if shouldReview {
                let proposed = targetWeightsV3(
                    symbols: symbols,
                    pricesBySymbol: frame.pricesBySymbol,
                    signalIndex: signalIndex,
                    knownPortfolioDrawdown: knownDrawdown,
                    config: config
                )
                let targetChange = orderedWeightDistance(symbols: symbols, lhs: proposed, rhs: strategicTarget)
                let proposedGross = orderedWeightSum(symbols: symbols, weights: proposed)
                let strategicGross = orderedWeightSum(symbols: symbols, weights: strategicTarget)
                let meaningfulRiskCut = proposedGross + 0.06 < strategicGross
                if strategicGross <= 0 || targetChange >= config.targetTurnoverThreshold || meaningfulRiskCut {
                    strategicTarget = proposed
                }

                let reviewedTarget = applyDailyRiskCapsV3(
                    baseTarget: strategicTarget,
                    symbols: symbols,
                    pricesBySymbol: frame.pricesBySymbol,
                    signalIndex: signalIndex,
                    knownPortfolioDrawdown: knownDrawdown,
                    config: config,
                    allowOnlyCuts: false
                )
                executeRebalanceV3(
                    date: frame.dates[index],
                    index: index,
                    symbols: symbols,
                    pricesBySymbol: frame.pricesBySymbol,
                    targetWeights: reviewedTarget,
                    preTradeValue: preTradeValue,
                    band: config.rebalanceBand,
                    config: config,
                    cash: &cash,
                    units: &units,
                    trades: &trades,
                    cumulativeTurnover: &cumulativeTurnover
                )
                activeTarget = reviewedTarget
            } else {
                // Between slow allocation reviews, risk can only be reduced. This avoids a daily
                // trend strategy paying the App's intentionally harsh 1% one-way fee.
                let riskTarget = applyDailyRiskCapsV3(
                    baseTarget: activeTarget,
                    symbols: symbols,
                    pricesBySymbol: frame.pricesBySymbol,
                    signalIndex: signalIndex,
                    knownPortfolioDrawdown: knownDrawdown,
                    config: config,
                    allowOnlyCuts: true
                )
                if orderedWeightDistance(symbols: symbols, lhs: riskTarget, rhs: activeTarget) > 1e-10 {
                    executeRiskCutsV3(
                        date: frame.dates[index],
                        index: index,
                        symbols: symbols,
                        pricesBySymbol: frame.pricesBySymbol,
                        targetWeights: riskTarget,
                        preTradeValue: preTradeValue,
                        config: config,
                        cash: &cash,
                        units: &units,
                        trades: &trades,
                        cumulativeTurnover: &cumulativeTurnover
                    )
                    activeTarget = riskTarget
                }
            }

            let value = max(portfolioValue(at: index), 0)
            equityCurve.append(value)
            curveDates.append(frame.dates[index])
            knownPeak = max(knownPeak, value)
        }

        guard let core = performanceMetrics(values: equityCurve, dates: curveDates),
              let firstDate = curveDates.first,
              let lastDate = curveDates.last,
              let benchmark = buyAndHoldBenchmarkV3(
                frame: frame,
                symbols: symbols,
                startIndex: startIndex,
                initialCash: initialCash,
                feeRate: config.feeRate,
                slippageRate: config.slippageRate
              )
        else { return nil }

        let finalValue = equityCurve.last ?? initialCash
        let finalWeights = Dictionary(uniqueKeysWithValues: symbols.map { symbol in
            let marketValue = (units[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?.last ?? 0)
            return (symbol, finalValue > 0 ? max(marketValue / finalValue, 0) : 0)
        })
        let cashWeight = finalValue > 0 ? max(cash / finalValue, 0) : 0
        let performance = AssetAgnosticPerformance(
            startDate: firstDate,
            endDate: lastDate,
            totalReturn: core.totalReturn,
            annualizedReturn: core.annualizedReturn,
            maxDrawdown: core.maxDrawdown,
            annualizedVolatility: core.annualizedVolatility,
            sharpeRatio: core.sharpeRatio,
            turnover: cumulativeTurnover,
            tradeCount: trades.count
        )
        return .init(
            symbols: symbols,
            performance: performance,
            benchmark: benchmark,
            finalWeights: finalWeights,
            cashWeight: cashWeight,
            trades: trades
        )
    }

    private static func targetWeightsV3(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        knownPortfolioDrawdown: Double,
        config: AssetAgnosticV3Config
    ) -> [String: Double] {
        var candidates: [V3Candidate] = []
        for (order, symbol) in symbols.enumerated() {
            guard let prices = pricesBySymbol[symbol],
                  let ma = movingAverage(prices, at: signalIndex, lookback: config.trendMASessions),
                  let mShort = momentum(prices, at: signalIndex, lookback: config.shortMomentumSessions),
                  let mMedium = momentum(prices, at: signalIndex, lookback: config.mediumMomentumSessions),
                  let mLong = momentum(prices, at: signalIndex, lookback: config.longMomentumSessions),
                  let vol = annualizedVolatility(prices, at: signalIndex, lookback: config.volatilitySessions),
                  let shortVol = annualizedVolatility(prices, at: signalIndex, lookback: config.shortVolatilitySessions),
                  let downsideVol = annualizedDownsideVolatility(prices, at: signalIndex, lookback: config.volatilitySessions),
                  let efficiency = trendEfficiency(prices, at: signalIndex, lookback: config.mediumMomentumSessions),
                  vol > 0
            else { continue }
            let price = prices[signalIndex]
            guard price > ma, mMedium > 0, mLong > -0.05, mShort > -0.04 else { continue }

            let safeVol = max(vol, 0.04)
            let safeDownside = max(downsideVol, safeVol * 0.35, 0.01)
            let score = 0.42 * mMedium / safeVol
                + 0.28 * mLong / safeVol
                + 0.22 * mShort / safeDownside
                + 0.18 * efficiency
            let quality = clamp(0.80 + 1.20 * max(mMedium, 0) + 0.45 * efficiency, lower: 0.60, upper: 1.80)
            candidates.append(.init(
                symbol: symbol,
                order: order,
                score: score,
                volatility: vol,
                downsideVolatility: downsideVol,
                quality: quality,
                shortVolatilityRatio: shortVol / max(vol, 0.01)
            ))
        }

        guard !candidates.isEmpty else {
            return Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        }
        candidates.sort {
            if abs($0.score - $1.score) > 1e-12 { return $0.score > $1.score }
            if abs($0.volatility - $1.volatility) > 1e-12 { return $0.volatility < $1.volatility }
            return $0.order < $1.order
        }
        let selected = Array(candidates.prefix(max(1, min(config.maxAssets, candidates.count))))

        var rawWeights = Array(repeating: 0.0, count: selected.count)
        var positiveCorrelationTotal = 0.0
        var correlationPairs = 0
        for index in selected.indices {
            let candidate = selected[index]
            var positiveCorrelation = 0.0
            var peers = 0
            for peerIndex in selected.indices where peerIndex != index {
                guard let lhs = pricesBySymbol[candidate.symbol],
                      let rhs = pricesBySymbol[selected[peerIndex].symbol],
                      let corr = correlation(lhs, rhs, at: signalIndex, lookback: config.covarianceSessions)
                else { continue }
                positiveCorrelation += max(corr, 0)
                peers += 1
                if peerIndex > index {
                    positiveCorrelationTotal += max(corr, 0)
                    correlationPairs += 1
                }
            }
            let avgPositiveCorrelation = peers > 0 ? positiveCorrelation / Double(peers) : 0
            let diversificationPenalty = 1 + 1.15 * avgPositiveCorrelation
            rawWeights[index] = candidate.quality / (pow(max(candidate.volatility, 0.05), 1.10) * diversificationPenalty)
        }
        let rawSum = rawWeights.reduce(0, +)
        guard rawSum > 0 else {
            return Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        }
        var normalized = rawWeights.map { $0 / rawSum }
        let feasibleCap = max(config.maxAssetWeight, 1 / Double(max(selected.count, 1)))
        normalized = capAndRedistributeV3(normalized, maxWeight: feasibleCap)

        var normalizedBySymbol = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        for index in selected.indices { normalizedBySymbol[selected[index].symbol] = normalized[index] }
        let estimatedVol = portfolioVolatilityV3(
            orderedSymbols: selected.map(\.symbol),
            weights: normalizedBySymbol,
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            lookback: config.covarianceSessions
        )
        let volatilityScale = estimatedVol > 0 ? min(1.0, config.targetAnnualizedVolatility / estimatedVol) : 0

        let breadth = Double(candidates.count) / Double(max(symbols.count, 1))
        let breadthScale: Double = breadth >= 0.75 ? 1.0 : (breadth >= 0.50 ? 0.95 : (breadth >= 0.25 ? 0.82 : 0.62))
        let averageCorrelation = correlationPairs > 0 ? positiveCorrelationTotal / Double(correlationPairs) : 0
        let correlationScale: Double
        if averageCorrelation <= config.highCorrelationThreshold {
            correlationScale = 1.0
        } else {
            let stress = (averageCorrelation - config.highCorrelationThreshold) / max(1 - config.highCorrelationThreshold, 0.01)
            correlationScale = clamp(1 - 0.45 * stress, lower: 0.55, upper: 1.0)
        }
        let averageVolRatio = selected.map(\.shortVolatilityRatio).reduce(0, +) / Double(selected.count)
        let volatilityRegimeScale: Double
        if averageVolRatio >= config.volatilitySpikeRatio * 1.20 {
            volatilityRegimeScale = 0.55
        } else if averageVolRatio >= config.volatilitySpikeRatio {
            volatilityRegimeScale = 0.75
        } else {
            volatilityRegimeScale = 1.0
        }
        let drawdownCap = portfolioGrossCapV3(for: knownPortfolioDrawdown)
        let gross = min(1.0, volatilityScale * breadthScale * correlationScale * volatilityRegimeScale, drawdownCap)

        var result = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 0.0) })
        for index in selected.indices {
            result[selected[index].symbol] = normalized[index] * gross
        }
        return result
    }

    private static func applyDailyRiskCapsV3(
        baseTarget: [String: Double],
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        knownPortfolioDrawdown: Double,
        config: AssetAgnosticV3Config,
        allowOnlyCuts: Bool
    ) -> [String: Double] {
        var result = Dictionary(uniqueKeysWithValues: symbols.map { ($0, max(baseTarget[$0] ?? 0, 0)) })
        for symbol in symbols where (result[symbol] ?? 0) > 0 {
            guard let prices = pricesBySymbol[symbol],
                  let ma = movingAverage(prices, at: signalIndex, lookback: config.trendMASessions),
                  let fastMomentum = momentum(prices, at: signalIndex, lookback: config.fastMomentumSessions),
                  let mediumMomentum = momentum(prices, at: signalIndex, lookback: config.shortMomentumSessions),
                  let shortVol = annualizedVolatility(prices, at: signalIndex, lookback: config.shortVolatilitySessions),
                  let longVol = annualizedVolatility(prices, at: signalIndex, lookback: config.volatilitySessions)
            else { continue }
            let price = prices[signalIndex]
            let trendBreak = price < ma * config.trendExitBuffer && mediumMomentum < 0
            let momentumBreak = fastMomentum <= config.fastExitMomentum || mediumMomentum <= config.mediumExitMomentum
            let volatilityBreak = shortVol / max(longVol, 0.01) >= config.volatilitySpikeRatio && fastMomentum < -0.02
            if trendBreak || momentumBreak || volatilityBreak {
                result[symbol] = 0
            }
        }

        // Generic breadth stress: no country/asset role enters this calculation.
        var healthy = 0
        var observed = 0
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol],
                  let ma = movingAverage(prices, at: signalIndex, lookback: config.trendMASessions),
                  let m = momentum(prices, at: signalIndex, lookback: config.shortMomentumSessions)
            else { continue }
            observed += 1
            if prices[signalIndex] > ma && m > 0 { healthy += 1 }
        }
        let healthyFraction = observed > 0 ? Double(healthy) / Double(observed) : 0
        let breadthGrossCap: Double = healthyFraction >= 0.75 ? 1.0 : (healthyFraction >= 0.50 ? 0.85 : (healthyFraction >= 0.25 ? 0.65 : 0.40))
        let grossCap = min(portfolioGrossCapV3(for: knownPortfolioDrawdown), breadthGrossCap)
        let gross = orderedWeightSum(symbols: symbols, weights: result)
        if gross > grossCap, gross > 0 {
            let scale = grossCap / gross
            for symbol in symbols { result[symbol] = (result[symbol] ?? 0) * scale }
        }

        if allowOnlyCuts {
            for symbol in symbols {
                result[symbol] = min(result[symbol] ?? 0, baseTarget[symbol] ?? 0)
            }
        }
        return result
    }

    private static func portfolioGrossCapV3(for drawdown: Double) -> Double {
        // Never force permanent all-cash from an all-time drawdown state. A non-zero risk floor
        // keeps a recovery path while still cutting gross exposure progressively in stress.
        switch drawdown {
        case 0.18...: return 0.40
        case 0.14...: return 0.55
        case 0.10...: return 0.70
        case 0.07...: return 0.85
        default: return 1.0
        }
    }

    private static func executeRiskCutsV3(
        date: String,
        index: Int,
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        targetWeights: [String: Double],
        preTradeValue: Double,
        config: AssetAgnosticV3Config,
        cash: inout Double,
        units: inout [String: Double],
        trades: inout [AssetAgnosticTrade],
        cumulativeTurnover: inout Double
    ) {
        guard preTradeValue > 0 else { return }
        for symbol in symbols {
            guard let price = pricesBySymbol[symbol]?[index], price > 0 else { continue }
            let heldUnits = max(units[symbol] ?? 0, 0)
            let currentValue = heldUnits * price
            let targetValue = preTradeValue * max(targetWeights[symbol] ?? 0, 0)
            guard currentValue > targetValue + 1e-8 else { continue }
            let unitsToSell = min(heldUnits, (currentValue - targetValue) / price)
            guard unitsToSell > 0 else { continue }
            let executionPrice = max(price * (1 - config.slippageRate), 0)
            let gross = unitsToSell * executionPrice
            let fee = gross * config.feeRate
            cash += max(gross - fee, 0)
            units[symbol] = max(heldUnits - unitsToSell, 0)
            cumulativeTurnover += gross / preTradeValue
            trades.append(.init(date: date, symbol: symbol, side: .sell, executionPrice: executionPrice, notional: gross, fee: fee))
        }
    }

    private static func executeRebalanceV3(
        date: String,
        index: Int,
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        targetWeights: [String: Double],
        preTradeValue: Double,
        band: Double,
        config: AssetAgnosticV3Config,
        cash: inout Double,
        units: inout [String: Double],
        trades: inout [AssetAgnosticTrade],
        cumulativeTurnover: inout Double
    ) {
        guard preTradeValue > 0 else { return }
        for symbol in symbols {
            guard let price = pricesBySymbol[symbol]?[index], price > 0 else { continue }
            let heldUnits = max(units[symbol] ?? 0, 0)
            let currentValue = heldUnits * price
            let targetValue = preTradeValue * max(targetWeights[symbol] ?? 0, 0)
            let exit = targetValue <= 0 && heldUnits > 0
            let trim = currentValue > targetValue * (1 + max(band, 0))
            guard exit || trim else { continue }
            let valueToSell = exit ? currentValue : max(currentValue - targetValue, 0)
            let unitsToSell = min(heldUnits, valueToSell / price)
            guard unitsToSell > 0 else { continue }
            let executionPrice = max(price * (1 - config.slippageRate), 0)
            let gross = unitsToSell * executionPrice
            let fee = gross * config.feeRate
            cash += max(gross - fee, 0)
            units[symbol] = max(heldUnits - unitsToSell, 0)
            cumulativeTurnover += gross / preTradeValue
            trades.append(.init(date: date, symbol: symbol, side: .sell, executionPrice: executionPrice, notional: gross, fee: fee))
        }

        var desired = Array(repeating: 0.0, count: symbols.count)
        for (position, symbol) in symbols.enumerated() {
            guard let price = pricesBySymbol[symbol]?[index], price > 0 else { continue }
            let currentValue = max(units[symbol] ?? 0, 0) * price
            let targetValue = preTradeValue * max(targetWeights[symbol] ?? 0, 0)
            if currentValue < targetValue * (1 - max(band, 0)) {
                desired[position] = max(targetValue - currentValue, 0)
            }
        }
        let totalDesired = desired.reduce(0, +)
        let scale = totalDesired > 0 ? min(1.0, max(cash, 0) / totalDesired) : 0
        let startingCash = max(cash, 0)
        var spent = 0.0
        for (position, symbol) in symbols.enumerated() where desired[position] > 0 {
            guard let price = pricesBySymbol[symbol]?[index], price > 0 else { continue }
            let spend = desired[position] * scale
            let executionPrice = price * (1 + config.slippageRate)
            let fee = spend * config.feeRate
            let invested = max(spend - fee, 0)
            let boughtUnits = executionPrice > 0 ? invested / executionPrice : 0
            guard boughtUnits > 0 else { continue }
            units[symbol, default: 0] += boughtUnits
            spent += spend
            cumulativeTurnover += spend / preTradeValue
            trades.append(.init(date: date, symbol: symbol, side: .buy, executionPrice: executionPrice, notional: spend, fee: fee))
        }
        cash = max(startingCash - spent, 0)
    }

    private static func buyAndHoldBenchmarkV3(
        frame: AlignedFrame,
        symbols: [String],
        startIndex: Int,
        initialCash: Double,
        feeRate: Double,
        slippageRate: Double
    ) -> AssetAgnosticPerformance? {
        guard !symbols.isEmpty, frame.dates.indices.contains(startIndex), startIndex > 0 else { return nil }
        let perAssetCash = initialCash / Double(symbols.count)
        var units: [String: Double] = [:]
        for symbol in symbols {
            guard let price = frame.pricesBySymbol[symbol]?[startIndex], price > 0 else { return nil }
            let invested = perAssetCash * (1 - feeRate)
            units[symbol] = invested / (price * (1 + slippageRate))
        }
        var values = [initialCash]
        var dates = [frame.dates[startIndex - 1]]
        for index in startIndex..<frame.dates.count {
            values.append(symbols.reduce(0.0) { partial, symbol in
                partial + (units[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?[index] ?? 0)
            })
            dates.append(frame.dates[index])
        }
        guard let metrics = performanceMetrics(values: values, dates: dates),
              let first = dates.first, let last = dates.last
        else { return nil }
        return .init(
            startDate: first,
            endDate: last,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            turnover: 1.0,
            tradeCount: symbols.count
        )
    }

    private static func capAndRedistributeV3(_ weights: [Double], maxWeight: Double) -> [Double] {
        guard !weights.isEmpty else { return weights }
        let cap = clamp(maxWeight, lower: 0, upper: 1)
        var result = weights
        for _ in 0..<(weights.count + 2) {
            var excess = 0.0
            for index in result.indices where result[index] > cap + 1e-12 {
                excess += result[index] - cap
                result[index] = cap
            }
            guard excess > 1e-12 else { break }
            let underIndices = result.indices.filter { result[$0] < cap - 1e-12 }
            let underSum = underIndices.reduce(0.0) { $0 + result[$1] }
            guard underSum > 0 else { break }
            for index in underIndices {
                result[index] = min(cap, result[index] + excess * result[index] / underSum)
            }
        }
        let sum = result.reduce(0, +)
        return sum > 0 ? result.map { $0 / sum } : result
    }

    private static func portfolioVolatilityV3(
        orderedSymbols: [String],
        weights: [String: Double],
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        lookback: Int
    ) -> Double {
        guard !orderedSymbols.isEmpty else { return 0 }
        var returns: [[Double]] = []
        for symbol in orderedSymbols {
            guard let prices = pricesBySymbol[symbol],
                  let seriesReturns = dailyReturns(prices, at: signalIndex, lookback: lookback)
            else { return 0 }
            returns.append(seriesReturns)
        }
        var variance = 0.0
        for lhs in orderedSymbols.indices {
            for rhs in orderedSymbols.indices {
                variance += (weights[orderedSymbols[lhs]] ?? 0)
                    * (weights[orderedSymbols[rhs]] ?? 0)
                    * sampleCovariance(returns[lhs], returns[rhs])
            }
        }
        return sqrt(max(variance, 0)) * sqrt(252)
    }

    private static func orderedWeightSum(symbols: [String], weights: [String: Double]) -> Double {
        symbols.reduce(0.0) { $0 + max(weights[$1] ?? 0, 0) }
    }

    private static func orderedWeightDistance(symbols: [String], lhs: [String: Double], rhs: [String: Double]) -> Double {
        symbols.reduce(0.0) { $0 + abs((lhs[$1] ?? 0) - (rhs[$1] ?? 0)) }
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
