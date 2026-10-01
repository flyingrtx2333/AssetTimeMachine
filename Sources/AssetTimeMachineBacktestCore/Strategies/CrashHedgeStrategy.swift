import Foundation

nonisolated enum CrashHedgeStrategy {
    static func syntheticCrashHedgeSeries(
        from assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)]
    ) -> PublicHistorySeries? {
        let inputBySymbol = Dictionary(uniqueKeysWithValues: assetInputs.map { ($0.assetOption.symbol, $0) })
        guard let gold = inputBySymbol["gold_cny"]?.assetSeries,
              let nasdaq = inputBySymbol["nasdaq"]?.assetSeries,
              let sp500 = inputBySymbol["sp500"]?.assetSeries,
              let dow = inputBySymbol["dowjones"]?.assetSeries,
              let csi300 = inputBySymbol["csi300"]?.assetSeries,
              let shanghai = inputBySymbol["shanghai_composite"]?.assetSeries,
              let shenzhen = inputBySymbol["shenzhen_component"]?.assetSeries,
              let fx = inputBySymbol["nasdaq"]?.fxSeries ?? inputBySymbol["sp500"]?.fxSeries else {
            return nil
        }

        let baseDates = gold.dates.filter { $0 >= "2002-01-04" }
        guard baseDates.count > 62 else { return nil }
        let fxMap = Dictionary(uniqueKeysWithValues: zip(fx.dates, fx.prices))

        func aligned(_ series: PublicHistorySeries, convertUSD: Bool) -> [Double]? {
            let priceMap = Dictionary(uniqueKeysWithValues: zip(series.dates, series.prices))
            var values: [Double] = []
            values.reserveCapacity(baseDates.count)
            var lastPrice: Double?
            var lastFX: Double?
            for date in baseDates {
                if let value = priceMap[date], value.isFinite, value > 0 { lastPrice = value }
                if let value = fxMap[date], value.isFinite, value > 0 { lastFX = value }
                guard let price = lastPrice else { return nil }
                if convertUSD {
                    guard let exchangeRate = lastFX else { return nil }
                    values.append(price / exchangeRate)
                } else {
                    values.append(price)
                }
            }
            return values
        }

        guard let nasdaqPrices = aligned(nasdaq, convertUSD: true),
              let sp500Prices = aligned(sp500, convertUSD: true),
              let dowPrices = aligned(dow, convertUSD: true),
              let csiPrices = aligned(csi300, convertUSD: false),
              let shanghaiPrices = aligned(shanghai, convertUSD: false),
              let shenzhenPrices = aligned(shenzhen, convertUSD: false) else { return nil }

        func composite(_ components: [[Double]]) -> [Double] {
            guard let first = components.first else { return [] }
            var output = Array(repeating: 100.0, count: first.count)
            for index in 1..<first.count {
                let returns = components.compactMap { values -> Double? in
                    guard values.indices.contains(index), values[index - 1] > 0 else { return nil }
                    return values[index] / values[index - 1] - 1
                }
                let averageReturn = returns.isEmpty ? 0 : returns.reduce(0, +) / Double(returns.count)
                output[index] = output[index - 1] * max(1 + averageReturn, 0.5)
            }
            return output
        }

        let markets = [
            composite([nasdaqPrices, sp500Prices, dowPrices]),
            composite([csiPrices, shanghaiPrices, shenzhenPrices]),
        ]
        let marketWeights = [0.30, 0.30]
        let warmup = 63

        func volatility(_ prices: [Double], end: Int) -> Double {
            let start = max(1, end - 62)
            var returns: [Double] = []
            for index in start...end where prices[index - 1] > 0 {
                returns.append(prices[index] / prices[index - 1] - 1)
            }
            guard returns.count > 1 else { return 0.20 }
            let mean = returns.reduce(0, +) / Double(returns.count)
            let variance = returns.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(returns.count - 1)
            return sqrt(max(variance, 0)) * sqrt(252)
        }

        var dates = Array(baseDates[warmup...])
        var values = Array(repeating: 100.0, count: dates.count)
        var positions = Array(repeating: 0.0, count: markets.count)
        var previousPositions = positions
        let internalTurnoverCost = 0.0005

        for sourceIndex in (warmup + 1)..<baseDates.count {
            previousPositions = positions
            for marketIndex in markets.indices {
                let prices = markets[marketIndex]
                func momentum(_ lookback: Int) -> Double {
                    guard sourceIndex - 1 >= lookback, prices[sourceIndex - 1 - lookback] > 0 else { return 0 }
                    return prices[sourceIndex - 1] / prices[sourceIndex - 1 - lookback] - 1
                }
                let m5 = momentum(5)
                let m10 = momentum(10)
                let m20 = momentum(20)
                let m60 = momentum(60)
                let severeBreak = m5 <= -0.03 || m10 <= -0.05
                let confirmedBreak = m20 <= -0.04 && m60 < 0
                let existingShort = positions[marketIndex] < 0
                let release = m5 > 0.02 && m20 > 0
                let shortSignal = severeBreak || confirmedBreak || (existingShort && !release)
                let volatilityScale = min(0.12 / max(volatility(prices, end: sourceIndex - 1), 0.06), 1.50)
                positions[marketIndex] = shortSignal ? max(-3.0 * volatilityScale, -2.50) : 0
            }

            var dailyReturn = 0.0
            for marketIndex in markets.indices {
                let prices = markets[marketIndex]
                guard prices[sourceIndex - 1] > 0 else { continue }
                dailyReturn += marketWeights[marketIndex]
                    * positions[marketIndex]
                    * (prices[sourceIndex] / prices[sourceIndex - 1] - 1)
            }
            let turnover = zip(positions, previousPositions).enumerated().reduce(0.0) { partial, item in
                partial + marketWeights[item.offset] * abs(item.element.0 - item.element.1)
            }
            dailyReturn -= turnover * internalTurnoverCost
            dailyReturn = min(max(dailyReturn, -0.12), 0.12)
            let outputIndex = sourceIndex - warmup
            if values.indices.contains(outputIndex), values.indices.contains(outputIndex - 1) {
                values[outputIndex] = values[outputIndex - 1] * max(1 + dailyReturn, 0.50)
            }
        }
        if dates.count > values.count { dates = Array(dates.prefix(values.count)) }
        return PublicHistorySeries(
            symbol: "crash_hedge_cta",
            category: "synthetic_crisis_hedge",
            label: BacktestText.string("极速空头危机袖套"),
            currency: "CNY",
            unit: "index",
            source: "T-1 synthetic equity short overlay",
            dates: dates,
            prices: values,
            hasOHLC: false,
            ohlcSource: nil,
            ohlcCoverageRatio: nil,
            openPrices: nil,
            highPrices: nil,
            lowPrices: nil,
            closePrices: nil,
            volumes: nil
        )
    }

    static func runConvexCrashHedgeCompositeWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil
    ) -> ResearchTargetStrategyRun? {
        let modes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
            .goldNasdaqDualTrendBarbell,
        ]
        var targetMaps: [AdvancedBacktestStrategyMode: [String: [String: Double]]] = [:]
        for mode in modes {
            guard let run = BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(
                assetInputs: MarketInputPreparation.inputs(for: mode, from: assetInputs),
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            targetMaps[mode] = Dictionary(uniqueKeysWithValues: run.dailyStates.map {
                ($0.date.backtestDateString, $0.targetWeights)
            })
        }
        guard let crashSeries = syntheticCrashHedgeSeries(from: assetInputs) else { return nil }
        let crashOption = BacktestInstrument(
            symbol: crashSeries.symbol,
            title: BacktestText.string("极速空头危机袖套"),

            requiresHistoricalFX: false,
            historicalFXSymbol: nil
        )
        let requiredSymbols = Set(modes.flatMap(\.requiredSignalAssetSymbols))
        var simulationInputs = assetInputs.filter { requiredSymbols.contains($0.assetOption.symbol) }
        simulationInputs.append((assetSeries: crashSeries, assetOption: crashOption, fxSeries: nil))

        let config = ResearchTargetStrategyConfig(
            symbol: "convex_crash_hedge_composite",
            title: BacktestText.string("凸性极速空头组合"),
            warmupSessions: 1,
            rebalanceSessions: 1,
            rebalanceBand: 0.08,
            maxGrossExposure: 1.10,
            allowsFinancedExposure: true,
            financingAnnualRate: 0.05,
            buyReason: BacktestText.string("凸性极速空头组合调仓")
        )
        let shares: [AdvancedBacktestStrategyMode: Double] = [
            .coreGoldSatelliteSharpeStateGateMomentum: 0.35,
            .coreGoldSatelliteRiskBudgetStateGateMomentum: 0.26,
            .goldNasdaqDualTrendBarbell: 0.39,
        ]
        var latest: [AdvancedBacktestStrategyMode: [String: Double]] = [:]
        var pending: [String: Double] = [:]
        var previous: [String: Double] = [:]

        return TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: simulationInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            rebalanceDecision: { index, _, data in
                guard data.dates.indices.contains(index) else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }
                let dateKey = data.dates[index].backtestDateString
                for mode in modes {
                    if let weights = targetMaps[mode]?[dateKey] { latest[mode] = weights }
                }
                guard latest.count == modes.count else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                var target: [String: Double] = [:]
                for mode in modes {
                    let share = shares[mode] ?? 0
                    for (symbol, weight) in latest[mode] ?? [:] {
                        target[symbol, default: 0] += weight * share * 1.50
                    }
                }
                let crashWeight = 0.03
                let riskCap = 1.10 - crashWeight
                let riskGross = target.values.reduce(0, +)
                if riskGross > riskCap, riskGross > 0 {
                    target = target.mapValues { $0 * riskCap / riskGross }
                }
                target[crashOption.symbol] = crashWeight

                let symbols = Set(previous.keys).union(target.keys)
                let difference = symbols.reduce(0.0) {
                    $0 + abs((previous[$1] ?? 0) - (target[$1] ?? 0))
                }
                pending = target
                let shouldRebalance = previous.isEmpty ? !target.isEmpty : difference > 0.06
                if shouldRebalance { previous = target }
                return BacktestRebalanceDecision(shouldRebalance: shouldRebalance, refreshOverlay: false)
            },
            targetWeights: { _, _ in pending }
        )
    }
}
