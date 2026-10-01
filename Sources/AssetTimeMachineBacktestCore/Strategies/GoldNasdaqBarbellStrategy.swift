import Foundation

nonisolated public enum GoldNasdaqBarbellStrategy {
    static func runGoldNasdaqDualTrendBarbellWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil
    ) -> ResearchTargetStrategyRun? {
        let parameters = GoldNasdaqBarbellParameters.frozenV1
        let config = ResearchTargetStrategyConfig(
            symbol: "gold_nasdaq_dual_trend_barbell",
            title: BacktestText.string("金纳双趋势"),
            warmupSessions: parameters.warmupSessions,
            rebalanceSessions: parameters.rebalanceSessions,
            rebalanceBand: parameters.rebalanceBand,
            maxGrossExposure: 1.0,
            allowsFinancedExposure: false,
            buyReason: BacktestText.string("金纳双趋势调仓")
        )
        return TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            targetWeights: { context, data in
                let signalIndex = context.signalIndex
                guard let gold = data.pricesBySymbol["gold_cny"],
                      let nasdaq = data.pricesBySymbol["nasdaq"],
                      gold.indices.contains(signalIndex),
                      nasdaq.indices.contains(signalIndex),
                      let goldMA200 = PortfolioIndicators.movingAverageAt(values: gold, at: signalIndex, period: parameters.movingAverageSessions),
                      let nasdaqMA200 = PortfolioIndicators.movingAverageAt(values: nasdaq, at: signalIndex, period: parameters.movingAverageSessions),
                      let goldMomentum126 = TechnicalIndicators.priceMomentum(values: gold, at: signalIndex, lookback: parameters.strongMomentumSessions),
                      let nasdaqMomentum126 = TechnicalIndicators.priceMomentum(values: nasdaq, at: signalIndex, lookback: parameters.strongMomentumSessions),
                      let goldMomentum252 = TechnicalIndicators.priceMomentum(values: gold, at: signalIndex, lookback: parameters.weakMomentumSessions),
                      let nasdaqMomentum252 = TechnicalIndicators.priceMomentum(values: nasdaq, at: signalIndex, lookback: parameters.weakMomentumSessions) else { return [:] }

                let goldStrong = gold[signalIndex] > goldMA200 && goldMomentum126 > 0
                let nasdaqStrong = nasdaq[signalIndex] > nasdaqMA200 && nasdaqMomentum126 > 0
                let goldWeak = gold[signalIndex] < goldMA200 && goldMomentum252 < 0
                let nasdaqWeak = nasdaq[signalIndex] < nasdaqMA200 && nasdaqMomentum252 < 0

                let goldScale = goldStrong ? parameters.goldStrongScale : (goldWeak ? parameters.goldWeakScale : parameters.goldNeutralScale)
                let nasdaqScale = nasdaqStrong ? parameters.nasdaqStrongScale : (nasdaqWeak ? parameters.nasdaqWeakScale : parameters.nasdaqNeutralScale)
                return [
                    "gold_cny": parameters.goldWeight * goldScale,
                    "nasdaq": parameters.nasdaqWeight * nasdaqScale
                ]
            }
        )
    }

    public static func runGoldNasdaqDualTrendBarbell(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedBacktestReport? {
        runGoldNasdaqDualTrendBarbellWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            dateBounds: dateBounds
        )?.report
    }
}
