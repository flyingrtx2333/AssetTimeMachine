import Foundation

nonisolated public enum KVOGoldSatelliteDualEngineStrategy {
    public static let defaultKVOWeight: Double = 0.55
    public static let defaultDrawdownReentryWeight: Double = 0.25
    public static let defaultSatelliteWeight: Double = 0.15
    public static let defaultVolManagedWeight: Double = 0.05

    public static func advice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)]
    ) -> StrategyRebalanceAdvice? {
        let preparedInputs = MarketInputPreparation.publicIndexHistoryInputs(assetInputs)
        let kvoAdvice = KE25LiveStrategy.advice(assetInputs: preparedInputs, useKVO: true)
        let ddAdvice = StrategyAdviceCalculator.advancedRotationRebalanceAdvice(
            assetInputs: assetInputs,
            mode: .drawdownReentryMomentum
        )
        let satAdvice = StrategyAdviceCalculator.advancedRotationRebalanceAdvice(
            assetInputs: preparedInputs,
            mode: .coreGoldSatelliteAssetRiskGateMomentum
        )
        let volAdvice = StrategyAdviceCalculator.advancedRotationRebalanceAdvice(
            assetInputs: assetInputs,
            mode: .coreGoldSatelliteOneWayVolManagedMomentum
        )

        let wK = defaultKVOWeight
        let wD = defaultDrawdownReentryWeight
        let wS = defaultSatelliteWeight
        let wV = defaultVolManagedWeight

        var combinedWeights: [String: Double] = [:]
        var titlesBySymbol: [String: String] = [:]

        if let kvo = kvoAdvice {
            for alloc in kvo.allocations {
                combinedWeights[alloc.symbol, default: 0] += alloc.targetWeight * wK
                titlesBySymbol[alloc.symbol] = alloc.title
            }
        }
        if let dd = ddAdvice {
            for alloc in dd.allocations {
                combinedWeights[alloc.symbol, default: 0] += alloc.targetWeight * wD
                titlesBySymbol[alloc.symbol] = alloc.title
            }
        }
        if let sat = satAdvice {
            for alloc in sat.allocations {
                combinedWeights[alloc.symbol, default: 0] += alloc.targetWeight * wS
                titlesBySymbol[alloc.symbol] = alloc.title
            }
        }
        if let vol = volAdvice {
            for alloc in vol.allocations {
                combinedWeights[alloc.symbol, default: 0] += alloc.targetWeight * wV
                titlesBySymbol[alloc.symbol] = alloc.title
            }
        }

        let allocations = combinedWeights.compactMap { symbol, weight -> StrategyRebalanceAllocation? in
            guard weight > 0.0001, let title = titlesBySymbol[symbol] else { return nil }
            return StrategyRebalanceAllocation(
                symbol: symbol,
                title: title,
                targetWeight: weight,
                momentum: nil,
                annualizedVolatility: nil
            )
        }.sorted {
            $0.targetWeight == $1.targetWeight ? $0.symbol < $1.symbol : $0.targetWeight > $1.targetWeight
        }

        let asOfDate = satAdvice?.asOfDate ?? kvoAdvice?.asOfDate ?? ddAdvice?.asOfDate ?? Date()

        return StrategyRebalanceAdvice(
            strategyTitle: BacktestText.string("KVO黄金卫星双引擎"),
            asOfDate: asOfDate,
            lookbackSessions: 313,
            rebalanceSessions: 1,
            targetAnnualVolatility: nil,
            allocations: allocations,
            signalReason: BacktestText.string("四引擎宏观量价复合：55% KVO量价防守 ＋ 25% 回撤再入场 ＋ 15% 黄金卫星 ＋ 5% 控波单向动量"),
            nextReviewDate: BacktestSeriesAlignment.nextStrategyWeekday(after: asOfDate)
        )
    }

    public static func run(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedRotationStrategyRun? {
        let preparedInputs = MarketInputPreparation.publicIndexHistoryInputs(assetInputs)
        let wK = defaultKVOWeight
        let wD = defaultDrawdownReentryWeight
        let wS = defaultSatelliteWeight
        let wV = defaultVolManagedWeight

        // 1. KVO run
        let kvoInput = StrategyRuntimeRegistry.Input(
            assetInputs: preparedInputs,
            initialCash: initialCash * wK,
            settings: settings,
            nfciAsOf: nil,
            dateBounds: dateBounds
        )
        guard let kvoRun = StrategyRuntimeRegistry.specialized[.kvo]?(kvoInput) else { return nil }

        // 2. Drawdown Reentry run
        let ddInput = StrategyRuntimeRegistry.Input(
            assetInputs: assetInputs,
            initialCash: initialCash * wD,
            settings: settings,
            nfciAsOf: nil,
            dateBounds: dateBounds
        )
        guard let ddRun = StrategyRuntimeRegistry.run(mode: .drawdownReentryMomentum, input: ddInput) else { return nil }

        // 3. Core Gold Satellite run
        let satInput = StrategyRuntimeRegistry.Input(
            assetInputs: preparedInputs,
            initialCash: initialCash * wS,
            settings: settings,
            nfciAsOf: nil,
            dateBounds: dateBounds
        )
        guard let satRun = StrategyRuntimeRegistry.run(mode: .coreGoldSatelliteAssetRiskGateMomentum, input: satInput) else { return nil }

        // 4. Vol Managed run
        let volInput = StrategyRuntimeRegistry.Input(
            assetInputs: assetInputs,
            initialCash: initialCash * wV,
            settings: settings,
            nfciAsOf: nil,
            dateBounds: dateBounds
        )
        guard let volRun = StrategyRuntimeRegistry.run(mode: .coreGoldSatelliteOneWayVolManagedMomentum, input: volInput) else { return nil }

        let allKVOStates = kvoRun.dailyStates
        guard !allKVOStates.isEmpty, let satFirst = satRun.dailyStates.first else { return nil }

        let allDates = allKVOStates.map { $0.date }
        let allCivilDates = allDates.map { BacktestSeriesAlignment.historicalSeriesDateString(from: $0) }

        var ddStateMap: [String: BacktestDailyState] = [:]
        for s in ddRun.dailyStates { ddStateMap[BacktestSeriesAlignment.historicalSeriesDateString(from: s.date)] = s }

        var satStateMap: [String: BacktestDailyState] = [:]
        for s in satRun.dailyStates { satStateMap[BacktestSeriesAlignment.historicalSeriesDateString(from: s.date)] = s }

        var volStateMap: [String: BacktestDailyState] = [:]
        for s in volRun.dailyStates { volStateMap[BacktestSeriesAlignment.historicalSeriesDateString(from: s.date)] = s }

        let satStartDate = BacktestSeriesAlignment.historicalSeriesDateString(from: satFirst.date)

        var satCashPre = initialCash * wS
        var satActivated = false
        var lastSatState: BacktestDailyState?

        var points: [BacktestSeriesPoint] = []
        var dailyStates: [BacktestDailyState] = []
        var allTrades: [AdvancedBacktestTrade] = []

        // Aggregated physical trades from each audited engine
        allTrades.append(contentsOf: kvoRun.report.trades)
        allTrades.append(contentsOf: ddRun.report.trades)
        allTrades.append(contentsOf: satRun.report.trades)
        allTrades.append(contentsOf: volRun.report.trades)
        allTrades.sort { $0.date == $1.date ? $0.assetSymbol < $1.assetSymbol : $0.date < $1.date }

        var scaleK = 1.0
        var scaleD = 1.0
        var scaleS = 1.0
        var scaleV = 1.0
        var previousYear = String(allCivilDates[0].prefix(4))

        for i in 0..<allDates.count {
            let date = allDates[i]
            let civilDate = allCivilDates[i]
            let currentYear = String(civilDate.prefix(4))

            let sK = allKVOStates[i]
            let sD = ddStateMap[civilDate] ?? sK
            var sS = satStateMap[civilDate]
            let sV = volStateMap[civilDate] ?? sK

            if let ss = sS {
                lastSatState = ss
            } else if civilDate >= satStartDate {
                sS = lastSatState
            }

            // Cash interest before activation
            if i > 0 {
                let priorDate = allDates[i - 1]
                if !satActivated && civilDate < satStartDate {
                    satCashPre += satCashPre * CashYieldCNY.periodReturn(from: priorDate, to: date)
                }
            }

            // Activation handoff: bridge accumulated cash into satellite sleeve
            if !satActivated && civilDate >= satStartDate {
                satActivated = true
                guard let validSatState = sS else { return nil }
                scaleS = satCashPre / validSatState.portfolioValue
            }

            var valK = sK.portfolioValue * scaleK
            var valD = sD.portfolioValue * scaleD
            var valS = !satActivated ? satCashPre : (sS!.portfolioValue * scaleS)
            var valV = sV.portfolioValue * scaleV
            var totalVal = valK + valD + valS + valV

            // Annual sleeve rebalancing with realistic turnover fee
            if currentYear != previousYear && satActivated {
                let targetK = totalVal * wK
                let targetD = totalVal * wD
                let targetS = totalVal * wS
                let targetV = totalVal * wV

                let diffK = abs(targetK - valK)
                let diffD = abs(targetD - valD)
                let diffS = abs(targetS - valS)
                let diffV = abs(targetV - valV)
                let fee = (diffK + diffD + diffS + diffV) * 0.5 * 0.00025
                totalVal -= fee

                scaleK = (totalVal * wK) / sK.portfolioValue
                scaleD = (totalVal * wD) / sD.portfolioValue
                scaleS = (totalVal * wS) / sS!.portfolioValue
                scaleV = (totalVal * wV) / sV.portfolioValue

                valK = sK.portfolioValue * scaleK
                valD = sD.portfolioValue * scaleD
                valS = sS!.portfolioValue * scaleS
                valV = sV.portfolioValue * scaleV
                previousYear = currentYear
            } else if currentYear != previousYear {
                previousYear = currentYear
            }

            let cashK = sK.cash * scaleK
            let cashD = sD.cash * scaleD
            let cashS = !satActivated ? satCashPre : (sS!.cash * scaleS)
            let cashV = sV.cash * scaleV
            let totalCash = cashK + cashD + cashS + cashV

            var totalHoldings: [String: Double] = [:]
            for (sym, qty) in sK.holdingsBySymbol { totalHoldings[sym, default: 0] += qty * scaleK }
            for (sym, qty) in sD.holdingsBySymbol { totalHoldings[sym, default: 0] += qty * scaleD }
            if satActivated, let sS {
                for (sym, qty) in sS.holdingsBySymbol { totalHoldings[sym, default: 0] += qty * scaleS }
            }
            for (sym, qty) in sV.holdingsBySymbol { totalHoldings[sym, default: 0] += qty * scaleV }

            // Target weights mirror strategy policy perfectly (100% parity with advice)
            var targetWeights: [String: Double] = [:]
            for (sym, w) in sK.targetWeights { targetWeights[sym, default: 0] += w * wK }
            for (sym, w) in sD.targetWeights { targetWeights[sym, default: 0] += w * wD }
            if satActivated, let sS {
                for (sym, w) in sS.targetWeights { targetWeights[sym, default: 0] += w * wS }
            }
            for (sym, w) in sV.targetWeights { targetWeights[sym, default: 0] += w * wV }

            points.append(BacktestSeriesPoint(date: date, portfolioValue: totalVal, sequence: i))
            dailyStates.append(BacktestDailyState(
                date: date,
                targetWeights: targetWeights,
                cash: totalCash,
                holdingsBySymbol: totalHoldings,
                portfolioValue: totalVal
            ))
        }

        guard let metrics = BacktestMetricsCalculator.performanceMetrics(from: points) else { return nil }

        let tradableSymbols = Array(Set(dailyStates.flatMap { $0.holdingsBySymbol.keys })).sorted()
        let optionBySymbol = Dictionary(uniqueKeysWithValues: assetInputs.map { ($0.assetOption.symbol, $0.assetOption) })

        let finalValue = points.last?.portfolioValue ?? initialCash
        let finalCash = dailyStates.last?.cash ?? initialCash
        let exposureRatio = points.last.map { max(0, ($0.portfolioValue - finalCash) / $0.portfolioValue) } ?? 0

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "kvo_satellite_dual_engine",
            title: BacktestText.string("KVO黄金卫星双引擎"),
            points: points,
            benchmarkPoints: kvoRun.report.benchmarkPoints,
            pricePoints: [],
            trades: allTrades,
            finalPortfolioValue: finalValue,
            finalCash: finalCash,
            finalUnits: 0,
            exposureRatio: exposureRatio
        )

        let report = AdvancedBacktestReport(
            points: points,
            benchmarkPoints: kvoRun.report.benchmarkPoints,
            benchmarkSeries: kvoRun.report.benchmarkSeries,
            trades: allTrades,
            assetReports: [syntheticReport],
            finalPortfolioValue: finalValue,
            finalCash: finalCash,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: kvoRun.report.cashYieldSummary,
            riskSignalSummary: kvoRun.report.riskSignalSummary,
            exposurePoints: BacktestReportBuilder.exposurePoints(from: dailyStates),
            assetExposureSeries: BacktestReportBuilder.assetExposureSeries(
                from: dailyStates,
                symbolOrder: tradableSymbols,
                titlesBySymbol: optionBySymbol.mapValues(\.title)
            )
        )

        return AdvancedRotationStrategyRun(report: report, dailyStates: dailyStates)
    }
}
