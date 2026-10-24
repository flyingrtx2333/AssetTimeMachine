import Foundation

nonisolated public enum KVOGoldSatelliteDualEngineStrategy {
    public static let defaultKVOWeight: Double = 0.68
    public static let defaultSatelliteWeight: Double = 0.32

    public static func advice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)]
    ) -> StrategyRebalanceAdvice? {
        let kvoAdvice = KE25LiveStrategy.advice(assetInputs: assetInputs, useKVO: true)
        let satAdvice = StrategyAdviceCalculator.advancedRotationRebalanceAdvice(
            assetInputs: assetInputs,
            mode: .coreGoldSatelliteAssetRiskGateMomentum
        )

        let wKVO = defaultKVOWeight
        let wSat = defaultSatelliteWeight

        var combinedWeights: [String: Double] = [:]
        var titlesBySymbol: [String: String] = [:]

        if let kvo = kvoAdvice {
            for alloc in kvo.allocations {
                combinedWeights[alloc.symbol, default: 0] += alloc.targetWeight * wKVO
                titlesBySymbol[alloc.symbol] = alloc.title
            }
        }
        if let sat = satAdvice {
            for alloc in sat.allocations {
                combinedWeights[alloc.symbol, default: 0] += alloc.targetWeight * wSat
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

        let asOfDate = satAdvice?.asOfDate ?? kvoAdvice?.asOfDate ?? Date()

        return StrategyRebalanceAdvice(
            strategyTitle: BacktestText.string("KVO黄金卫星双引擎"),
            asOfDate: asOfDate,
            lookbackSessions: 313,
            rebalanceSessions: 1,
            targetAnnualVolatility: nil,
            allocations: allocations,
            signalReason: BacktestText.string("KVO量价防守底仓（68%）搭配黄金卫星动量（32%）宏观协同"),
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
        let wKVO = defaultKVOWeight
        let wSat = defaultSatelliteWeight

        let kvoInput = StrategyRuntimeRegistry.Input(
            assetInputs: preparedInputs,
            initialCash: initialCash * wKVO,
            settings: settings,
            nfciAsOf: nil,
            dateBounds: dateBounds
        )
        guard let kvoRun = StrategyRuntimeRegistry.specialized[.kvo]?(kvoInput) else { return nil }

        let satInput = StrategyRuntimeRegistry.Input(
            assetInputs: preparedInputs,
            initialCash: initialCash * wSat,
            settings: settings,
            nfciAsOf: nil,
            dateBounds: dateBounds
        )
        guard let satRun = StrategyRuntimeRegistry.run(mode: .coreGoldSatelliteAssetRiskGateMomentum, input: satInput) else { return nil }

        let allKVOStates = kvoRun.dailyStates
        guard !allKVOStates.isEmpty, let satFirst = satRun.dailyStates.first else { return nil }

        let allDates = allKVOStates.map { $0.date }
        let allCivilDates = allDates.map { BacktestSeriesAlignment.historicalSeriesDateString(from: $0) }

        var satStateMap: [String: BacktestDailyState] = [:]
        for s in satRun.dailyStates {
            let key = BacktestSeriesAlignment.historicalSeriesDateString(from: s.date)
            satStateMap[key] = s
        }

        let satStartDate = BacktestSeriesAlignment.historicalSeriesDateString(from: satFirst.date)

        var scaleKVO: Double = 1.0
        var scaleSat: Double = 1.0

        var satCashPre = initialCash * wSat
        var satActivated = false
        var lastSatState: BacktestDailyState?

        var points: [BacktestSeriesPoint] = []
        var dailyStates: [BacktestDailyState] = []
        var totalRebalanceFees: Double = 0.0

        var previousYear = String(allCivilDates[0].prefix(4))

        for i in 0..<allDates.count {
            let date = allDates[i]
            let civilDate = allCivilDates[i]
            let currentYear = String(civilDate.prefix(4))

            let sK = allKVOStates[i]
            var sS = satStateMap[civilDate]

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

            // Activation handoff: scale seamlessly bridges accumulated cash into sleeve initial value
            if !satActivated && civilDate >= satStartDate {
                satActivated = true
                guard let validSatState = sS else { return nil }
                scaleSat = satCashPre / validSatState.portfolioValue
            }

            var valKVO = sK.portfolioValue * scaleKVO
            var valSat = !satActivated ? satCashPre : (sS!.portfolioValue * scaleSat)
            var totalVal = valKVO + valSat

            // Annual rebalancing (from 2006 onwards, once both are active)
            if currentYear != previousYear && satActivated {
                let targetKVO = totalVal * wKVO
                let targetSat = totalVal * wSat

                let diffKVO = abs(targetKVO - valKVO)
                let diffSat = abs(targetSat - valSat)
                let fee = (diffKVO + diffSat) * 0.5 * 0.00025
                totalRebalanceFees += fee
                totalVal -= fee

                scaleKVO = (totalVal * wKVO) / sK.portfolioValue
                scaleSat = (totalVal * wSat) / sS!.portfolioValue

                valKVO = sK.portfolioValue * scaleKVO
                valSat = sS!.portfolioValue * scaleSat
                previousYear = currentYear
            } else if currentYear != previousYear {
                previousYear = currentYear
            }

            let cashKVO = sK.cash * scaleKVO
            let cashSat = !satActivated ? satCashPre : (sS!.cash * scaleSat)
            let totalCash = cashKVO + cashSat

            var totalHoldings: [String: Double] = [:]
            for (sym, qty) in sK.holdingsBySymbol { totalHoldings[sym, default: 0] += qty * scaleKVO }
            if satActivated, let sS {
                for (sym, qty) in sS.holdingsBySymbol { totalHoldings[sym, default: 0] += qty * scaleSat }
            }

            let actualWeightKVO = valKVO / totalVal
            let actualWeightSat = valSat / totalVal

            var targetWeights: [String: Double] = [:]
            for (sym, w) in sK.targetWeights { targetWeights[sym, default: 0] += w * actualWeightKVO }
            if satActivated, let sS {
                for (sym, w) in sS.targetWeights { targetWeights[sym, default: 0] += w * actualWeightSat }
            }

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
            trades: [],
            finalPortfolioValue: finalValue,
            finalCash: finalCash,
            finalUnits: 0,
            exposureRatio: exposureRatio
        )

        let report = AdvancedBacktestReport(
            points: points,
            benchmarkPoints: kvoRun.report.benchmarkPoints,
            benchmarkSeries: kvoRun.report.benchmarkSeries,
            trades: [],
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
