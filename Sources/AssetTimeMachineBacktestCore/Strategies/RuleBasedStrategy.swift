import Foundation

nonisolated public enum RuleBasedStrategy {
    public static func runAdvancedStrategy(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestInstrument,
        fxSeries: PublicHistorySeries?,
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings,
        onDailyState: ((BacktestDailyState) -> Void)? = nil
    ) -> AdvancedBacktestReport? {
        guard let preparedSeries = MarketInputPreparation.preparedAdvancedSeries(assetSeries: assetSeries, assetOption: assetOption, fxSeries: fxSeries) else { return nil }
        return runAdvancedStrategy(
            preparedSeries: preparedSeries,
            initialCash: initialCash,
            tradeAmount: tradeAmount,
            buyRule: buyRule,
            sellRule: sellRule,
            settings: settings,
            onDailyState: onDailyState
        )
    }

    static func runAdvancedStrategy(
        preparedSeries: PreparedAdvancedSeries,
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings,
        onDailyState: ((BacktestDailyState) -> Void)? = nil
    ) -> AdvancedBacktestReport? {
        let assetOption = preparedSeries.assetOption
        let pricePoints = preparedSeries.pricePoints
        let ma20 = preparedSeries.ma20
        let ma60 = preparedSeries.ma60
        let boll20 = preparedSeries.boll20
        let normalizedInitialCash = max(initialCash, 0)
        let normalizedTradeAmount = max(tradeAmount, 0)
        let normalizedFeeRate = max(settings.feeRate, 0) / 100
        let normalizedSlippageRate = max(settings.slippageRate, 0) / 100
        let normalizedMaxPositionRatio = min(max(settings.maxPositionRatio, 0), 100) / 100
        let normalizedCooldownDays = max(settings.cooldownDays, 0)
        let normalizedStopLossRatio = max(settings.stopLossRatio, 0) / 100
        let normalizedTakeProfitRatio = max(settings.takeProfitRatio, 0) / 100
        guard normalizedInitialCash > 0, normalizedTradeAmount > 0, normalizedMaxPositionRatio > 0 else { return nil }

        let buyThreshold = max(buyRule.days, 1)
        let sellThreshold = max(sellRule.days, 1)

        var cash = normalizedInitialCash
        var unitsHeld = 0.0
        var averageEntryPrice: Double?
        var positionCostBasis = 0.0
        var firstEntryDate: Date?
        var lastTradeDate: Date?
        var upStreakByIndex = Array(repeating: 0, count: pricePoints.count)
        var downStreakByIndex = Array(repeating: 0, count: pricePoints.count)
        if pricePoints.count > 1 {
            for index in 1..<pricePoints.count {
                let currentPrice = pricePoints[index].cnyPrice
                let previousPrice = pricePoints[index - 1].cnyPrice
                if currentPrice > previousPrice {
                    upStreakByIndex[index] = upStreakByIndex[index - 1] + 1
                    downStreakByIndex[index] = 0
                } else if currentPrice < previousPrice {
                    upStreakByIndex[index] = 0
                    downStreakByIndex[index] = downStreakByIndex[index - 1] + 1
                } else {
                    upStreakByIndex[index] = 0
                    downStreakByIndex[index] = 0
                }
            }
        }
        var points: [BacktestSeriesPoint] = []
        var trades: [AdvancedBacktestTrade] = []
        var peakValue = normalizedInitialCash
        var maxDrawdown = 0.0
        var exposureSum = 0.0
        var exposureSampleCount = 0
        var cashRatioSum = 0.0
        var cashRatioSampleCount = 0
        var cashInterestEarned = 0.0
        var cashAnnualRateSum = 0.0
        var cashAnnualRateSampleCount = 0
        var exposurePoints: [BacktestExposurePoint] = []

        for (index, point) in pricePoints.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }

            if index > 0 {
                let annualCashRate = CashYieldCNY.annualRate(on: pricePoints[index - 1].date)
                cashAnnualRateSum += annualCashRate
                cashAnnualRateSampleCount += 1
                if cash > 0 {
                    let cashInterest = cash * CashYieldCNY.periodReturn(
                        from: pricePoints[index - 1].date,
                        to: point.date
                    )
                    if cashInterest.isFinite, cashInterest > 0 {
                        cash += cashInterest
                        cashInterestEarned += cashInterest
                    }
                }
            }

            if index > 0 {
                let signalIndex = index - 1
                let signalPoint = pricePoints[signalIndex]
                let shouldBuy = advancedRuleTriggered(
                    buyRule,
                    at: signalIndex,
                    pricePoints: pricePoints,
                    ma20: ma20,
                    ma60: ma60,
                    boll20: boll20,
                    upStreak: upStreakByIndex[signalIndex],
                    downStreak: downStreakByIndex[signalIndex],
                    threshold: buyThreshold
                )
                let shouldSell = advancedRuleTriggered(
                    sellRule,
                    at: signalIndex,
                    pricePoints: pricePoints,
                    ma20: ma20,
                    ma60: ma60,
                    boll20: boll20,
                    upStreak: upStreakByIndex[signalIndex],
                    downStreak: downStreakByIndex[signalIndex],
                    threshold: sellThreshold
                )

                let daysSinceLastTrade = lastTradeDate.map { BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents([.day], from: $0, to: point.date).day ?? 0 } ?? Int.max
                let cooldownAllowsTrade = daysSinceLastTrade >= normalizedCooldownDays
                let positionMarketValue = unitsHeld * point.cnyPrice
                let portfolioBeforeTrade = cash + positionMarketValue
                let stopLossTriggered = normalizedStopLossRatio > 0
                    && unitsHeld > 0
                    && averageEntryPrice.map { signalPoint.cnyPrice <= $0 * (1 - normalizedStopLossRatio) } == true
                let takeProfitTriggered = normalizedTakeProfitRatio > 0
                    && unitsHeld > 0
                    && averageEntryPrice.map { signalPoint.cnyPrice >= $0 * (1 + normalizedTakeProfitRatio) } == true

                if (shouldSell || stopLossTriggered || takeProfitTriggered), unitsHeld > 0, cooldownAllowsTrade {
                    let executionPrice = max(point.cnyPrice * (1 - normalizedSlippageRate), 0)
                    let grossProceeds = unitsHeld * executionPrice
                    let fee = grossProceeds * normalizedFeeRate
                    let proceeds = max(grossProceeds - fee, 0)
                    let realizedCostBasis = positionCostBasis > 0 ? positionCostBasis : (averageEntryPrice ?? executionPrice) * unitsHeld
                    let realizedProfit = proceeds - realizedCostBasis
                    let realizedReturn = realizedCostBasis > 0 ? realizedProfit / realizedCostBasis : nil
                    let holdingDays = firstEntryDate.map { BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents([.day], from: $0, to: point.date).day ?? 0 }
                    let sellReason: String
                    if stopLossTriggered {
                        sellReason = BacktestText.string("止损触发")
                    } else if takeProfitTriggered {
                        sellReason = BacktestText.string("止盈触发")
                    } else {
                        sellReason = sellRule.direction.shortTitle
                    }
                    trades.append(
                        AdvancedBacktestTrade(
                            assetSymbol: assetOption.symbol,
                            assetTitle: assetOption.title,
                            date: point.date,
                            action: .sell,
                            price: executionPrice,
                            cashAmount: proceeds,
                            units: unitsHeld,
                            reason: sellReason,
                            realizedProfit: realizedProfit,
                            realizedReturn: realizedReturn,
                            holdingDays: holdingDays
                        )
                    )
                    cash += proceeds
                    unitsHeld = 0
                    averageEntryPrice = nil
                    positionCostBasis = 0
                    firstEntryDate = nil
                    lastTradeDate = point.date
                } else if shouldBuy, cash > 0, cooldownAllowsTrade {
                    let maxPositionValue = portfolioBeforeTrade * normalizedMaxPositionRatio
                    let remainingPositionCapacity = max(maxPositionValue - positionMarketValue, 0)
                    let amountToSpend = min(cash, normalizedTradeAmount, remainingPositionCapacity)
                    if amountToSpend > 0 {
                        let executionPrice = point.cnyPrice * (1 + normalizedSlippageRate)
                        let fee = amountToSpend * normalizedFeeRate
                        let amountToInvest = max(amountToSpend - fee, 0)
                        let boughtUnits = executionPrice > 0 ? amountToInvest / executionPrice : 0
                        if boughtUnits > 0 {
                            let wasFlat = unitsHeld <= 0
                            let previousSignalCost = (averageEntryPrice ?? 0) * unitsHeld
                            let newSignalCost = previousSignalCost + amountToInvest
                            trades.append(
                                AdvancedBacktestTrade(
                                    assetSymbol: assetOption.symbol,
                                    assetTitle: assetOption.title,
                                    date: point.date,
                                    action: .buy,
                                    price: executionPrice,
                                    cashAmount: amountToSpend,
                                    units: boughtUnits,
                                    reason: buyRule.direction.shortTitle,
                                    realizedProfit: nil,
                                    realizedReturn: nil,
                                    holdingDays: nil
                                )
                            )
                            cash -= amountToSpend
                            unitsHeld += boughtUnits
                            positionCostBasis += amountToSpend
                            if wasFlat {
                                firstEntryDate = point.date
                            }
                            averageEntryPrice = unitsHeld > 0 ? newSignalCost / unitsHeld : nil
                            lastTradeDate = point.date
                        }
                    }
                }
            }

            let portfolioValue = cash + unitsHeld * point.cnyPrice
            peakValue = max(peakValue, portfolioValue)
            if peakValue > 0 {
                maxDrawdown = max(maxDrawdown, (peakValue - portfolioValue) / peakValue)
            }
            if portfolioValue > 0 {
                let exposureRatio = min(max((unitsHeld * point.cnyPrice) / portfolioValue, 0), 1)
                exposureSum += exposureRatio
                exposureSampleCount += 1
                cashRatioSum += min(max(cash / portfolioValue, 0), 1)
                cashRatioSampleCount += 1
                exposurePoints.append(BacktestExposurePoint(
                    date: point.date,
                    ratio: exposureRatio,
                    sequence: exposurePoints.count
                ))
            }
            points.append(.init(date: point.date, portfolioValue: portfolioValue, sequence: points.count))
            if let onDailyState {
                let value = unitsHeld * point.cnyPrice
                onDailyState(.init(date: point.date,
                    targetWeights: value > 0 && portfolioValue > 0 ? [assetOption.symbol: value / portfolioValue] : [:],
                    cash: cash, holdingsBySymbol: value > 0 ? [assetOption.symbol: value] : [:],
                    portfolioValue: portfolioValue))
            }
        }

        guard let last = points.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: points) else { return nil }

        let priceHistory = pricePoints.enumerated().map { index, point in
            AdvancedBacktestPricePoint(date: point.date, price: point.cnyPrice, sequence: index)
        }
        let benchmarkPoints: [BacktestSeriesPoint]
        if let firstPrice = pricePoints.first?.cnyPrice, firstPrice > 0 {
            benchmarkPoints = pricePoints.enumerated().map { index, point in
                BacktestSeriesPoint(date: point.date, portfolioValue: normalizedInitialCash * point.cnyPrice / firstPrice, sequence: index)
            }
        } else {
            benchmarkPoints = []
        }
        let assetReport = AdvancedBacktestAssetReport(
            symbol: assetOption.symbol,
            title: assetOption.title,
            points: points,
            benchmarkPoints: benchmarkPoints,
            pricePoints: priceHistory,
            trades: trades,
            finalPortfolioValue: last.portfolioValue,
            finalCash: cash,
            finalUnits: unitsHeld,
            exposureRatio: exposureSampleCount > 0 ? exposureSum / Double(exposureSampleCount) : 0
        )

        let benchmarkSeries = AdvancedBacktestBenchmarkSeries(
            id: assetOption.symbol,
            title: assetOption.title,
            points: benchmarkPoints
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: cashInterestEarned,
            averageCashRatio: cashRatioSampleCount > 0 ? cashRatioSum / Double(cashRatioSampleCount) : 0,
            averageAnnualRate: cashAnnualRateSampleCount > 0 ? cashAnnualRateSum / Double(cashAnnualRateSampleCount) : 0
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: benchmarkPoints,
            benchmarkSeries: [benchmarkSeries],
            trades: trades,
            assetReports: [assetReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: cash,
            finalUnits: unitsHeld,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil,
            exposurePoints: exposurePoints,
            assetExposureSeries: [
                BacktestAssetExposureSeries(
                    symbol: assetOption.symbol,
                    title: assetOption.title,
                    points: BacktestExposureSampling.sampled(
                        exposurePoints,
                        maxCount: BacktestExposureSampling.assetSeriesMaxCount
                    )
                )
            ]
        )
    }

    public static func runAdvancedStrategies(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings,
        onDailyState: ((BacktestDailyState) -> Void)? = nil
    ) -> AdvancedBacktestReport? {
        let validInputs = assetInputs.filter { input in
            input.assetSeries != nil && (!input.assetOption.requiresHistoricalFX || input.fxSeries != nil)
        }
        guard !validInputs.isEmpty else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let perAssetInitialCash = normalizedInitialCash / Double(validInputs.count)
        guard perAssetInitialCash > 0 else { return nil }

        let preparedSeries = validInputs.compactMap { input in
            MarketInputPreparation.preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard !preparedSeries.isEmpty else { return nil }

        return runAdvancedStrategies(
            preparedSeries: preparedSeries,
            initialCash: initialCash,
            tradeAmount: tradeAmount,
            buyRule: buyRule,
            sellRule: sellRule,
            settings: settings,
            onDailyState: onDailyState
        )
    }

    static func runAdvancedStrategies(
        preparedSeries: [PreparedAdvancedSeries],
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings,
        onDailyState: ((BacktestDailyState) -> Void)? = nil
    ) -> AdvancedBacktestReport? {
        guard !preparedSeries.isEmpty else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let perAssetInitialCash = normalizedInitialCash / Double(preparedSeries.count)
        guard perAssetInitialCash > 0 else { return nil }

        var traces: [[BacktestDailyState]] = []
        let reports = preparedSeries.compactMap { series -> AdvancedBacktestReport? in
            var trace: [BacktestDailyState] = []
            let report = runAdvancedStrategy(
                preparedSeries: series, initialCash: perAssetInitialCash, tradeAmount: tradeAmount,
                buyRule: buyRule, sellRule: sellRule, settings: settings,
                onDailyState: onDailyState == nil ? nil : { trace.append($0) })
            if report != nil, onDailyState != nil { traces.append(trace) }
            return report
        }
        guard !reports.isEmpty else { return nil }
        if reports.count == 1, let report = reports.first {
            if let onDailyState { traces[0].forEach(onDailyState) }
            return report
        }

        let allDates = Set(reports.flatMap { $0.points.map(\.date) }).sorted()
        guard !allDates.isEmpty else { return nil }

        var valueByReportIndex = Array(repeating: perAssetInitialCash, count: reports.count)
        var benchmarkValueByReportIndex = Array(repeating: perAssetInitialCash, count: reports.count)
        var cursors = Array(repeating: 0, count: reports.count)
        var benchmarkCursors = Array(repeating: 0, count: reports.count)
        var exposureCursors = Array(repeating: 0, count: reports.count)
        var exposureByReportIndex = Array(repeating: 0.0, count: reports.count)
        var combinedPoints: [BacktestSeriesPoint] = []
        var combinedBenchmarkPoints: [BacktestSeriesPoint] = []
        var combinedExposurePoints: [BacktestExposurePoint] = []
        var combinedAssetExposurePoints = Array(repeating: [BacktestExposurePoint](), count: reports.count)
        combinedPoints.reserveCapacity(allDates.count)
        combinedBenchmarkPoints.reserveCapacity(allDates.count)
        combinedExposurePoints.reserveCapacity(allDates.count)
        for index in combinedAssetExposurePoints.indices {
            combinedAssetExposurePoints[index].reserveCapacity(allDates.count)
        }

        for date in allDates {
            guard !Task.isCancelled else { return nil }
            for reportIndex in reports.indices {
                let reportPoints = reports[reportIndex].points
                var cursor = cursors[reportIndex]
                while cursor < reportPoints.count, reportPoints[cursor].date <= date {
                    valueByReportIndex[reportIndex] = reportPoints[cursor].portfolioValue
                    cursor += 1
                }
                cursors[reportIndex] = cursor

                let benchmarkPoints = reports[reportIndex].benchmarkPoints
                var benchmarkCursor = benchmarkCursors[reportIndex]
                while benchmarkCursor < benchmarkPoints.count, benchmarkPoints[benchmarkCursor].date <= date {
                    benchmarkValueByReportIndex[reportIndex] = benchmarkPoints[benchmarkCursor].portfolioValue
                    benchmarkCursor += 1
                }
                benchmarkCursors[reportIndex] = benchmarkCursor

                let exposurePoints = reports[reportIndex].exposurePoints
                var exposureCursor = exposureCursors[reportIndex]
                while exposureCursor < exposurePoints.count, exposurePoints[exposureCursor].date <= date {
                    exposureByReportIndex[reportIndex] = exposurePoints[exposureCursor].ratio
                    exposureCursor += 1
                }
                exposureCursors[reportIndex] = exposureCursor
            }

            let totalValue = valueByReportIndex.reduce(0, +)
            let totalBenchmarkValue = benchmarkValueByReportIndex.reduce(0, +)
            combinedPoints.append(BacktestSeriesPoint(date: date, portfolioValue: totalValue, sequence: combinedPoints.count))
            if let onDailyState {
                var cash = 0.0
                var holdings: [String: Double] = [:]
                for reportIndex in reports.indices {
                    let index = cursors[reportIndex] - 1
                    if index >= 0 {
                        let state = traces[reportIndex][index]
                        cash += state.cash
                        for (symbol, value) in state.holdingsBySymbol { holdings[symbol, default: 0] += value }
                    } else { cash += perAssetInitialCash }
                }
                onDailyState(.init(date: date, targetWeights: totalValue > 0 ? holdings.mapValues { $0 / totalValue } : [:],
                    cash: cash, holdingsBySymbol: holdings, portfolioValue: totalValue))
            }
            combinedBenchmarkPoints.append(BacktestSeriesPoint(date: date, portfolioValue: totalBenchmarkValue, sequence: combinedBenchmarkPoints.count))
            if totalValue > 0 {
                let investedValue = reports.indices.reduce(0.0) { partial, reportIndex in
                    partial + valueByReportIndex[reportIndex] * exposureByReportIndex[reportIndex]
                }
                combinedExposurePoints.append(BacktestExposurePoint(
                    date: date,
                    ratio: max(investedValue / totalValue, 0),
                    sequence: combinedExposurePoints.count
                ))
                for reportIndex in reports.indices {
                    let investedAssetValue = valueByReportIndex[reportIndex] * exposureByReportIndex[reportIndex]
                    combinedAssetExposurePoints[reportIndex].append(BacktestExposurePoint(
                        date: date,
                        ratio: max(investedAssetValue / totalValue, 0),
                        sequence: combinedAssetExposurePoints[reportIndex].count
                    ))
                }
            }
        }

        guard let last = combinedPoints.last,
              let metrics = BacktestReportBuilder.performanceMetrics(from: combinedPoints) else { return nil }

        let assetReports = reports.flatMap(\.assetReports)
        let assetExposureSeries = reports.indices.compactMap { reportIndex -> BacktestAssetExposureSeries? in
            let sourceSeries = reports[reportIndex].assetExposureSeries.first
            let sourceReport = reports[reportIndex].assetReports.first
            guard let symbol = sourceSeries?.symbol ?? sourceReport?.symbol,
                  let title = sourceSeries?.title ?? sourceReport?.title else { return nil }
            return BacktestAssetExposureSeries(
                symbol: symbol,
                title: title,
                points: BacktestExposureSampling.sampled(
                    combinedAssetExposurePoints[reportIndex],
                    maxCount: BacktestExposureSampling.assetSeriesMaxCount
                )
            )
        }
        let benchmarkSeries = reports.flatMap(\.benchmarkSeries)
        let trades = reports.flatMap(\.trades).sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.assetSymbol < rhs.assetSymbol }
            return lhs.date < rhs.date
        }
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: combinedPoints.first?.date,
            endDate: combinedPoints.last?.date,
            totalCashInterest: reports.reduce(0) { $0 + $1.cashYieldSummary.totalCashInterest },
            averageCashRatio: reports.isEmpty ? 0 : reports.reduce(0) { $0 + $1.cashYieldSummary.averageCashRatio } / Double(reports.count),
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: allDates)
        )

        return AdvancedBacktestReport(
            points: combinedPoints,
            benchmarkPoints: combinedBenchmarkPoints,
            benchmarkSeries: benchmarkSeries,
            trades: trades,
            assetReports: assetReports,
            finalPortfolioValue: last.portfolioValue,
            finalCash: reports.reduce(0) { $0 + $1.finalCash },
            finalUnits: reports.reduce(0) { $0 + $1.finalUnits },
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil,
            exposurePoints: combinedExposurePoints,
            assetExposureSeries: assetExposureSeries
        )
    }

    static func advancedRuleTriggered(
        _ rule: AdvancedBacktestRule,
        at index: Int,
        pricePoints: [(date: Date, cnyPrice: Double)],
        ma20: [Double?],
        ma60: [Double?],
        boll20: [(middle: Double, lower: Double, upper: Double)?],
        upStreak: Int,
        downStreak: Int,
        threshold: Int
    ) -> Bool {
        guard index > 0 else { return false }

        switch rule.direction {
        case .alwaysBuy:
            return true
        case .neverSell:
            return false
        case .consecutiveDown:
            return downStreak == threshold
        case .consecutiveUp:
            return upStreak == threshold
        case .priceAboveMA20:
            guard let currentMA20 = ma20[index] else { return false }
            return pricePoints[index].cnyPrice > currentMA20
        case .priceBelowMA20:
            guard let currentMA20 = ma20[index] else { return false }
            return pricePoints[index].cnyPrice < currentMA20
        case .priceAboveMA60:
            guard let currentMA60 = ma60[index] else { return false }
            return pricePoints[index].cnyPrice > currentMA60
        case .priceBelowMA60:
            guard let currentMA60 = ma60[index] else { return false }
            return pricePoints[index].cnyPrice < currentMA60
        case .priceCrossesAboveMA20:
            guard let previousMA20 = ma20[index - 1], let currentMA20 = ma20[index] else { return false }
            return pricePoints[index - 1].cnyPrice <= previousMA20 && pricePoints[index].cnyPrice > currentMA20
        case .priceCrossesBelowMA20:
            guard let previousMA20 = ma20[index - 1], let currentMA20 = ma20[index] else { return false }
            return pricePoints[index - 1].cnyPrice >= previousMA20 && pricePoints[index].cnyPrice < currentMA20
        case .ma20CrossesAboveMA60:
            guard let previousMA20 = ma20[index - 1],
                  let currentMA20 = ma20[index],
                  let previousMA60 = ma60[index - 1],
                  let currentMA60 = ma60[index] else { return false }
            return previousMA20 <= previousMA60 && currentMA20 > currentMA60
        case .ma20CrossesBelowMA60:
            guard let previousMA20 = ma20[index - 1],
                  let currentMA20 = ma20[index],
                  let previousMA60 = ma60[index - 1],
                  let currentMA60 = ma60[index] else { return false }
            return previousMA20 >= previousMA60 && currentMA20 < currentMA60
        case .priceCrossesAboveBollMiddle:
            guard let previousBand = boll20[index - 1], let currentBand = boll20[index] else { return false }
            return pricePoints[index - 1].cnyPrice <= previousBand.middle && pricePoints[index].cnyPrice > currentBand.middle
        case .priceCrossesBelowBollMiddle:
            guard let previousBand = boll20[index - 1], let currentBand = boll20[index] else { return false }
            return pricePoints[index - 1].cnyPrice >= previousBand.middle && pricePoints[index].cnyPrice < currentBand.middle
        case .touchesBollLower:
            guard let previousBand = boll20[index - 1], let currentBand = boll20[index] else { return false }
            return pricePoints[index - 1].cnyPrice > previousBand.lower && pricePoints[index].cnyPrice <= currentBand.lower
        case .touchesBollUpper:
            guard let previousBand = boll20[index - 1], let currentBand = boll20[index] else { return false }
            return pricePoints[index - 1].cnyPrice < previousBand.upper && pricePoints[index].cnyPrice >= currentBand.upper
        }
    }
}
