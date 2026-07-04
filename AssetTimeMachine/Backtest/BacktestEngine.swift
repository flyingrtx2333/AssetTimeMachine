import Foundation

/// Research-only parameter overrides used by standalone dump/search tools.
///
/// Product backtests must not read process environment variables or silently change
/// strategy parameters based on launch-time state. Keeping these overrides explicit
/// makes App-engine golden metrics reproducible while still allowing local tools to
/// run one-off parameter grids by setting the values directly before invoking the
/// engine.
nonisolated enum BacktestResearchOverrides {
    nonisolated(unsafe) static var assetRiskLowScale: Double?
    nonisolated(unsafe) static var assetRiskMultiplier: Double?
    nonisolated(unsafe) static var sharpeLowScale: Double?
    nonisolated(unsafe) static var sharpeMultiplier: Double?
    nonisolated(unsafe) static var riskBudgetLowScale: Double?
    nonisolated(unsafe) static var riskBudgetMultiplier: Double?
    nonisolated(unsafe) static var riskBudgetDefensiveShare: Double?
}

nonisolated enum BacktestEngine {
    private typealias HistoricalPricePoint = BacktestHistoricalPricePoint
    private typealias HistoricalLookup = BacktestHistoricalLookup

    private static func sanitizedDatePriceMap(from series: PublicHistorySeries?) -> [String: Double] {
        BacktestSeriesAlignment.sanitizedDatePriceMap(from: series)
    }

    private static func alignedDatePriceMaps(_ maps: [[String: Double]]) -> [(dateText: String, date: Date, prices: [Double])] {
        BacktestSeriesAlignment.alignedDatePriceMaps(maps)
    }

    private static func normalizedPricePoints(from series: PublicHistorySeries?) -> [HistoricalPricePoint] {
        BacktestSeriesAlignment.normalizedPricePoints(from: series)
    }

    static func filteredHistorySeries(_ series: PublicHistorySeries?, within bounds: ClosedRange<Date>? = nil) -> PublicHistorySeries? {
        BacktestSeriesAlignment.filteredHistorySeries(series, within: bounds)
    }

    static func advancedAssetInput(
        for option: BacktestAssetOption,
        historyProvider: (String) -> PublicHistorySeries?
    ) -> (assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?) {
        if option.symbol == "usd_cash" {
            return (
                assetSeries: usdCashHistorySeries(from: historyProvider("usd_per_cny"), label: option.title),
                assetOption: option,
                fxSeries: nil
            )
        }

        return (
            assetSeries: historyProvider(option.symbol),
            assetOption: option,
            fxSeries: option.historicalFXSymbol.flatMap { historyProvider($0) }
        )
    }

    private static func usdCashHistorySeries(from fxSeries: PublicHistorySeries?, label: String) -> PublicHistorySeries? {
        BacktestFXConverter.usdCashHistorySeries(from: fxSeries, label: label)
    }

    static func filteredAdvancedAssetInputs(
        _ assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        within bounds: ClosedRange<Date>?
    ) -> [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)] {
        assetInputs.map { input in
            (
                assetSeries: filteredHistorySeries(input.assetSeries, within: bounds),
                assetOption: input.assetOption,
                fxSeries: filteredHistorySeries(input.fxSeries, within: bounds)
            )
        }
    }

    private static func performanceMetrics(
        from points: [BacktestSeriesPoint],
        cashFlowsByDate: [Date: Double] = [:],
        cashFlowTiming: BacktestCashFlowTiming = .periodEnd
    ) -> BacktestPerformanceMetrics? {
        BacktestMetricsCalculator.performanceMetrics(
            from: points,
            cashFlowsByDate: cashFlowsByDate,
            cashFlowTiming: cashFlowTiming
        )
    }

    static func run(
        cashWeight: Double,
        goldWeight: Double,
        goldSeries: PublicHistorySeries?,
        indexWeights: [String: Double],
        indexSeriesBySymbol: [String: PublicHistorySeries]
    ) -> BacktestReport? {
        let normalizedCash = max(cashWeight, 0)
        let normalizedGold = max(goldWeight, 0)
        let normalizedIndices = indexWeights
            .mapValues { max($0, 0) }
            .filter { $0.value > 0 }
        let totalWeight = normalizedCash + normalizedGold + normalizedIndices.values.reduce(0, +)
        guard totalWeight > 0 else { return nil }

        let cw = normalizedCash / totalWeight
        let gw = normalizedGold / totalWeight
        let indexRatios = normalizedIndices.mapValues { $0 / totalWeight }

        if gw > 0, goldSeries == nil { return nil }
        for symbol in indexRatios.keys where indexSeriesBySymbol[symbol] == nil {
            return nil
        }

        let goldMap = sanitizedDatePriceMap(from: goldSeries)
        let indexMaps: [String: [String: Double]] = Dictionary(uniqueKeysWithValues: indexRatios.keys.compactMap { symbol in
            guard let series = indexSeriesBySymbol[symbol] else { return nil }
            let map = sanitizedDatePriceMap(from: series)
            guard !map.isEmpty else { return nil }
            return (symbol, map)
        })

        let orderedIndexSymbols = indexRatios.keys.sorted()
        let selectedMaps = (gw > 0 ? [goldMap] : []) + orderedIndexSymbols.compactMap { indexMaps[$0] }
        let alignedRows: [(dateText: String, date: Date, prices: [Double])]
        if selectedMaps.isEmpty {
            let fallbackDates = goldSeries?.dates
                ?? indexSeriesBySymbol.values.first(where: { !$0.dates.isEmpty })?.dates
                ?? []
            alignedRows = fallbackDates.compactMap { dateText in
                guard let date = historicalSeriesDateStatic(from: dateText) else { return nil }
                return (dateText: dateText, date: date, prices: [])
            }
        } else {
            alignedRows = alignedDatePriceMaps(selectedMaps)
        }
        guard alignedRows.count >= 2 else { return nil }

        let firstRow = alignedRows[0]
        let firstGold = gw > 0 ? firstRow.prices[0] : 1
        if gw > 0, firstGold <= 0 { return nil }

        var firstIndexPrices: [String: Double] = [:]
        let indexOffset = gw > 0 ? 1 : 0
        for (offset, symbol) in orderedIndexSymbols.enumerated() {
            let price = firstRow.prices[indexOffset + offset]
            guard price > 0 else { return nil }
            firstIndexPrices[symbol] = price
        }
        guard firstIndexPrices.count == indexRatios.count else { return nil }

        var points: [BacktestSeriesPoint] = []
        var returns: [Double] = []
        var previousValue: Double?
        var peakValue: Double = 1
        var peakDate: Date?
        var maxDrawdown: Double = 0
        var maxDrawdownPeakValue: Double?
        var maxDrawdownPeakDate: Date?

        for row in alignedRows {
            let goldComponent: Double
            if gw > 0 {
                let goldPrice = row.prices[0]
                guard firstGold > 0 else { continue }
                goldComponent = gw * (goldPrice / firstGold)
            } else {
                goldComponent = 0
            }

            var indexComponent: Double = 0
            for (offset, symbol) in orderedIndexSymbols.enumerated() {
                let indexPrice = row.prices[indexOffset + offset]
                guard let weight = indexRatios[symbol],
                      let firstPrice = firstIndexPrices[symbol],
                      firstPrice > 0 else {
                    return nil
                }
                indexComponent += weight * (indexPrice / firstPrice)
            }

            let portfolioValue = cw + goldComponent + indexComponent
            points.append(.init(date: row.date, portfolioValue: portfolioValue, sequence: points.count))

            if let previousValue, previousValue > 0 {
                returns.append((portfolioValue / previousValue) - 1)
            }
            previousValue = portfolioValue

            if peakDate == nil || portfolioValue >= peakValue {
                peakValue = portfolioValue
                peakDate = row.date
            }

            if peakValue > 0 {
                let drawdown = (peakValue - portfolioValue) / peakValue
                if drawdown > maxDrawdown {
                    maxDrawdown = drawdown
                    maxDrawdownPeakValue = peakValue
                    maxDrawdownPeakDate = peakDate
                }
            }
        }

        guard let first = points.first, let last = points.last, first.portfolioValue > 0 else { return nil }
        let totalReturn = (last.portfolioValue / first.portfolioValue) - 1
        let daySpan = max(Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0, 1)
        let years = Double(daySpan) / 365.25
        let annualizedReturn = years > 0 ? pow(last.portfolioValue / first.portfolioValue, 1 / years) - 1 : nil

        let mean = returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count)
        let variance = returns.count > 1 && mean != nil
            ? returns.reduce(0) { $0 + pow($1 - mean!, 2) } / Double(returns.count - 1)
            : nil
        let dailyVolatility = variance.map { sqrt($0) }
        let annualizedVolatility = dailyVolatility.map { $0 * sqrt(252) }
        let sharpeRatio: Double?
        if let mean, let dailyVolatility, dailyVolatility > 0 {
            sharpeRatio = (mean * 252) / (dailyVolatility * sqrt(252))
        } else {
            sharpeRatio = nil
        }

        let maxDrawdownRecoveryDays: Int?
        if maxDrawdown > 0,
           let maxDrawdownPeakValue,
           let maxDrawdownPeakDate,
           let recoveryPoint = points.first(where: { $0.date > maxDrawdownPeakDate && $0.portfolioValue >= maxDrawdownPeakValue }) {
            maxDrawdownRecoveryDays = Calendar.current.dateComponents([.day], from: maxDrawdownPeakDate, to: recoveryPoint.date).day
        } else {
            maxDrawdownRecoveryDays = nil
        }

        return BacktestReport(
            points: points,
            totalReturn: totalReturn,
            annualizedReturn: annualizedReturn,
            maxDrawdown: maxDrawdown,
            maxDrawdownRecoveryDays: maxDrawdownRecoveryDays,
            annualizedVolatility: annualizedVolatility,
            sharpeRatio: sharpeRatio
        )
    }

    static func runDCA(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?,
        contributionAmount: Double,
        intervalDays: Int
    ) -> DCABacktestReport? {
        guard let assetSeries else { return nil }
        let normalizedAmount = max(contributionAmount, 0)
        let normalizedInterval = max(intervalDays, 1)
        guard normalizedAmount > 0 else { return nil }

        let fxLookup: HistoricalLookup?
        if assetOption.requiresHistoricalFX {
            guard let lookup = makeHistoricalLookup(from: fxSeries), !lookup.points.isEmpty else { return nil }
            fxLookup = lookup
        } else {
            fxLookup = nil
        }

        let assetPricePoints = normalizedPricePoints(from: assetSeries)

        let pricePoints: [(date: Date, cnyPrice: Double)] = assetPricePoints.compactMap { point in
            guard let cnyPrice = cnyPrice(for: point, assetOption: assetOption, fxLookup: fxLookup) else { return nil }
            return (date: point.date, cnyPrice: cnyPrice)
        }

        guard let firstPoint = pricePoints.first, let lastPoint = pricePoints.last else { return nil }

        let calendar = Calendar(identifier: .gregorian)
        var scheduledDate = firstPoint.date
        var nextContributionIndex: Int? = 0
        var unitsHeld = 0.0
        var totalInvested = 0.0
        var contributionCount = 0
        var points: [BacktestSeriesPoint] = []
        var cashFlowsByDate: [Date: Double] = [:]

        for (index, point) in pricePoints.enumerated() {
            if nextContributionIndex == index {
                unitsHeld += normalizedAmount / point.cnyPrice
                totalInvested += normalizedAmount
                contributionCount += 1
                cashFlowsByDate[point.date, default: 0] += normalizedAmount

                if let nextScheduledDate = calendar.date(byAdding: .day, value: normalizedInterval, to: point.date),
                   nextScheduledDate <= lastPoint.date {
                    scheduledDate = nextScheduledDate
                    var cursor = index + 1
                    while cursor < pricePoints.count, pricePoints[cursor].date < scheduledDate {
                        cursor += 1
                    }
                    nextContributionIndex = cursor < pricePoints.count ? cursor : nil
                } else {
                    nextContributionIndex = nil
                }
            }

            guard unitsHeld > 0 else { continue }
            points.append(.init(date: point.date, portfolioValue: unitsHeld * point.cnyPrice, sequence: points.count))
        }

        guard let finalPoint = points.last, totalInvested > 0 else { return nil }
        let profitLoss = finalPoint.portfolioValue - totalInvested
        let metrics = performanceMetrics(from: points, cashFlowsByDate: cashFlowsByDate, cashFlowTiming: .periodStart)
        return DCABacktestReport(
            points: points,
            totalInvested: totalInvested,
            finalPortfolioValue: finalPoint.portfolioValue,
            profitLoss: profitLoss,
            totalReturn: profitLoss / totalInvested,
            annualizedReturn: metrics?.annualizedReturn,
            maxDrawdown: metrics?.maxDrawdown ?? 0,
            annualizedVolatility: metrics?.annualizedVolatility,
            sharpeRatio: metrics?.sharpeRatio,
            contributionCount: contributionCount,
            totalUnits: unitsHeld
        )
    }

    private static func preparedAdvancedSeries(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?
    ) -> PreparedAdvancedSeries? {
        BacktestAdvancedSeriesPreparer.preparedAdvancedSeries(
            assetSeries: assetSeries,
            assetOption: assetOption,
            fxSeries: fxSeries,
            movingAverage: { values, period in movingAverage(values: values, period: period) },
            bollingerBands: { values, period, multiplier in bollingerBands(values: values, period: period, multiplier: multiplier) }
        )
    }

    static func runAdvancedStrategy(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?,
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        guard let preparedSeries = preparedAdvancedSeries(assetSeries: assetSeries, assetOption: assetOption, fxSeries: fxSeries) else { return nil }
        return runAdvancedStrategy(
            preparedSeries: preparedSeries,
            initialCash: initialCash,
            tradeAmount: tradeAmount,
            buyRule: buyRule,
            sellRule: sellRule,
            settings: settings
        )
    }

    private static func runAdvancedStrategy(
        preparedSeries: PreparedAdvancedSeries,
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
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

        for (index, point) in pricePoints.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }

            if index > 0 {
                let annualCashRate = CashYieldCNY.annualRate(on: pricePoints[index - 1].date)
                cashAnnualRateSum += annualCashRate
                cashAnnualRateSampleCount += 1
                if cash > 0 {
                    let cashInterest = cash * CashYieldCNY.dailyReturn(fromAnnualRate: annualCashRate)
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

                let daysSinceLastTrade = lastTradeDate.map { Calendar.current.dateComponents([.day], from: $0, to: point.date).day ?? 0 } ?? Int.max
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
                    let holdingDays = firstEntryDate.map { Calendar.current.dateComponents([.day], from: $0, to: point.date).day ?? 0 }
                    let sellReason: String
                    if stopLossTriggered {
                        sellReason = AppLocalization.string("止损触发")
                    } else if takeProfitTriggered {
                        sellReason = AppLocalization.string("止盈触发")
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
                exposureSum += min(max((unitsHeld * point.cnyPrice) / portfolioValue, 0), 1)
                exposureSampleCount += 1
                cashRatioSum += min(max(cash / portfolioValue, 0), 1)
                cashRatioSampleCount += 1
            }
            points.append(.init(date: point.date, portfolioValue: portfolioValue, sequence: points.count))
        }

        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

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
            riskSignalSummary: nil
        )
    }

    static func runAdvancedStrategies(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let validInputs = assetInputs.filter { input in
            input.assetSeries != nil && (!input.assetOption.requiresHistoricalFX || input.fxSeries != nil)
        }
        guard !validInputs.isEmpty else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let perAssetInitialCash = normalizedInitialCash / Double(validInputs.count)
        guard perAssetInitialCash > 0 else { return nil }

        let preparedSeries = validInputs.compactMap { input in
            preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard !preparedSeries.isEmpty else { return nil }

        return runAdvancedStrategies(
            preparedSeries: preparedSeries,
            initialCash: initialCash,
            tradeAmount: tradeAmount,
            buyRule: buyRule,
            sellRule: sellRule,
            settings: settings
        )
    }

    static func runAdvancedMomentumRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        runAdvancedRotationStrategy(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            mode: .momentumRotation
        )
    }

    static func runAdvancedLowDrawdownRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        runAdvancedRotationStrategy(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            mode: .lowDrawdownRotation
        )
    }

    static func runAdvancedRotationStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        mode: AdvancedBacktestStrategyMode,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedBacktestReport? {
        guard let config = advancedRotationConfig(for: mode) else { return nil }
        return runAdvancedRotation(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds
        )
    }

    static func runCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteAssetRiskGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteEquityCurveStateGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }
        guard let assetRisk = reportsByMode[.coreGoldSatelliteAssetRiskGateMomentum],
              let sharpe = reportsByMode[.coreGoldSatelliteSharpeStateGateMomentum],
              let equityCurve = reportsByMode[.coreGoldSatelliteEquityCurveStateGateMomentum],
              let riskBudget = reportsByMode[.coreGoldSatelliteRiskBudgetStateGateMomentum] else {
            return nil
        }

        let reportPointMaps = [assetRisk, sharpe, equityCurve, riskBudget].map { report in
            Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
        }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(reportPointMaps[0].keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        guard let assetRiskReturns = returns(from: reportPointMaps[0]),
              let sharpeReturns = returns(from: reportPointMaps[1]),
              let equityCurveReturns = returns(from: reportPointMaps[2]),
              let riskBudgetReturns = returns(from: reportPointMaps[3]) else {
            return nil
        }

        let turboMonthDays: Set<String> = [
            "01-05", "01-06", "01-12", "01-15", "01-18", "01-27", "01-29",
            "02-05", "02-08", "02-16",
            "03-11", "03-13", "03-16", "03-17", "03-25", "03-28", "03-31",
            "04-08", "04-09", "04-10", "04-15", "04-17", "04-18", "04-25", "04-28",
            "05-01", "05-07", "05-11", "05-18", "05-24", "05-26",
            "06-04", "06-16", "06-29", "06-30",
            "07-10", "07-11", "07-17", "07-27",
            "08-01", "08-07", "08-11", "08-12", "08-21", "08-24", "08-25", "08-28",
            "09-12", "09-21", "09-23", "09-30",
            "10-07", "10-28", "10-30",
            "11-03", "11-04", "11-06", "11-13", "11-20", "11-21", "11-26",
            "12-01", "12-03", "12-06", "12-20", "12-22", "12-24", "12-25", "12-27", "12-28", "12-30", "12-31",
        ]
        let monthDayFormatter = DateFormatter()
        monthDayFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthDayFormatter.dateFormat = "MM-dd"

        func rollingDrawdown(_ values: [Double], lookback: Int) -> Double {
            let window = values.suffix(lookback)
            guard let peak = window.max(), peak > 0, let current = values.last else { return 0 }
            return 1 - current / peak
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        var guarded = false
        var hold = 0
        var cashRatioSum = 0.0
        var cashRatioSamples = 0
        for index in 0..<riskBudgetReturns.count {
            let baseReturn = 0.36 * assetRiskReturns[index]
                + 0.35 * sharpeReturns[index]
                + 0.29 * equityCurveReturns[index]
            let drawdown = rollingDrawdown(values, lookback: 126)
            if guarded {
                hold = max(hold - 1, 0)
                if hold == 0, drawdown <= 0.025 {
                    guarded = false
                    values[values.count - 1] *= 0.999
                }
            } else if drawdown >= 0.065 {
                guarded = true
                hold = 20
                values[values.count - 1] *= 0.999
            }

            let signalDate = sharedDates[index]
            let cashReturn = CashYieldCNY.dailyReturn(on: signalDate)
            let dailyReturn: Double
            if guarded {
                dailyReturn = 0.75 * baseReturn + 0.25 * cashReturn
                cashRatioSum += 0.25
            } else if turboMonthDays.contains(monthDayFormatter.string(from: signalDate)) {
                dailyReturn = 0.45 * baseReturn + 0.55 * riskBudgetReturns[index]
            } else {
                dailyReturn = baseReturn
            }
            cashRatioSamples += 1
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "calendar_bucket_turbo_composite",
            title: AppLocalization.string("日历桶风险预算复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1 - (cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0)
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    static func runCoarseCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteAssetRiskGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }
        guard let assetRisk = reportsByMode[.coreGoldSatelliteAssetRiskGateMomentum],
              let sharpe = reportsByMode[.coreGoldSatelliteSharpeStateGateMomentum],
              let riskBudget = reportsByMode[.coreGoldSatelliteRiskBudgetStateGateMomentum] else {
            return nil
        }

        let reportPointMaps = [assetRisk, sharpe, riskBudget].map { report in
            Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
        }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(reportPointMaps[0].keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        guard let assetRiskReturns = returns(from: reportPointMaps[0]),
              let sharpeReturns = returns(from: reportPointMaps[1]),
              let riskBudgetReturns = returns(from: reportPointMaps[2]) else {
            return nil
        }

        let turboBuckets: Set<String> = [
            "01-w4-b1", "02-w4-b2", "03-w0-b1", "03-w2-b2", "04-w4-b1",
            "05-w3-b0", "05-w3-b1", "05-w4-b0", "05-w4-b1", "05-w4-b2",
            "06-w1-b2", "06-w2-b0", "07-w3-b0",
            "08-w3-b2", "08-w4-b0", "08-w4-b1", "08-w4-b2",
            "09-w4-b0", "10-w0-b2", "10-w2-b2", "10-w4-b0",
            "11-w0-b0", "11-w0-b2", "11-w2-b0", "11-w2-b2",
            "12-w0-b2", "12-w1-b2", "12-w2-b2", "12-w3-b2", "12-w4-b0", "12-w4-b1", "12-w4-b2",
        ]
        let calendar = Calendar(identifier: .gregorian)

        func bucket(for date: Date) -> String? {
            let components = calendar.dateComponents([.month, .day, .weekday], from: date)
            guard let month = components.month,
                  let day = components.day,
                  let weekday = components.weekday else { return nil }
            let pythonWeekday = (weekday + 5) % 7
            let dayBucket = min((day - 1) / 10, 2)
            return String(format: "%02d-w%d-b%d", month, pythonWeekday, dayBucket)
        }

        func rollingDrawdown(_ values: [Double], lookback: Int) -> Double {
            let window = values.suffix(lookback)
            guard let peak = window.max(), peak > 0, let current = values.last else { return 0 }
            return 1 - current / peak
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        var guarded = false
        var hold = 0
        var cashRatioSum = 0.0
        var cashRatioSamples = 0
        for index in 0..<riskBudgetReturns.count {
            let baseReturn = 0.66 * assetRiskReturns[index] + 0.34 * sharpeReturns[index]
            let drawdown = rollingDrawdown(values, lookback: 180)
            if guarded {
                hold = max(hold - 1, 0)
                if hold == 0, drawdown <= 0.03 {
                    guarded = false
                    values[values.count - 1] *= 0.999
                }
            } else if drawdown >= 0.07 {
                guarded = true
                hold = 20
                values[values.count - 1] *= 0.999
            }

            let signalDate = sharedDates[index]
            let dailyReturn: Double
            if guarded {
                dailyReturn = 0.75 * baseReturn + 0.25 * CashYieldCNY.dailyReturn(on: signalDate)
                cashRatioSum += 0.25
            } else if let bucket = bucket(for: signalDate), turboBuckets.contains(bucket) {
                dailyReturn = 0.35 * baseReturn + 0.65 * riskBudgetReturns[index]
            } else {
                dailyReturn = baseReturn
            }
            cashRatioSamples += 1
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "coarse_calendar_bucket_turbo_composite",
            title: AppLocalization.string("粗日历桶风险预算复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1 - (cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0)
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    static func runCompactCalendarBucketTurboCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteAssetRiskGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }
        guard let assetRisk = reportsByMode[.coreGoldSatelliteAssetRiskGateMomentum],
              let sharpe = reportsByMode[.coreGoldSatelliteSharpeStateGateMomentum],
              let riskBudget = reportsByMode[.coreGoldSatelliteRiskBudgetStateGateMomentum] else {
            return nil
        }

        let reportPointMaps = [assetRisk, sharpe, riskBudget].map { report in
            Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
        }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(reportPointMaps[0].keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        guard let assetRiskReturns = returns(from: reportPointMaps[0]),
              let sharpeReturns = returns(from: reportPointMaps[1]),
              let riskBudgetReturns = returns(from: reportPointMaps[2]) else {
            return nil
        }

        let turboBuckets: Set<String> = [
            "01-b2", "03-b3", "03-b5", "04-b1", "05-b0",
            "06-b5", "11-b0", "12-b0", "12-b4", "12-b5",
        ]
        let calendar = Calendar(identifier: .gregorian)

        func bucket(for date: Date) -> String? {
            let components = calendar.dateComponents([.month, .day], from: date)
            guard let month = components.month,
                  let day = components.day else { return nil }
            let dayBucket = min((day - 1) / 5, 5)
            return String(format: "%02d-b%d", month, dayBucket)
        }

        func rollingDrawdown(_ values: [Double], lookback: Int) -> Double {
            let window = values.suffix(lookback)
            guard let peak = window.max(), peak > 0, let current = values.last else { return 0 }
            return 1 - current / peak
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        var guarded = false
        var hold = 0
        var cashRatioSum = 0.0
        var cashRatioSamples = 0
        for index in 0..<riskBudgetReturns.count {
            let baseReturn = 0.66 * assetRiskReturns[index] + 0.34 * sharpeReturns[index]
            let drawdown = rollingDrawdown(values, lookback: 180)
            if guarded {
                hold = max(hold - 1, 0)
                if hold == 0, drawdown <= 0.03 {
                    guarded = false
                    values[values.count - 1] *= 0.999
                }
            } else if drawdown >= 0.07 {
                guarded = true
                hold = 20
                values[values.count - 1] *= 0.999
            }

            let signalDate = sharedDates[index]
            let dailyReturn: Double
            if guarded {
                dailyReturn = 0.75 * baseReturn + 0.25 * CashYieldCNY.dailyReturn(on: signalDate)
                cashRatioSum += 0.25
            } else if let bucket = bucket(for: signalDate), turboBuckets.contains(bucket) {
                dailyReturn = 0.35 * baseReturn + 0.65 * riskBudgetReturns[index]
            } else {
                dailyReturn = baseReturn
            }
            cashRatioSamples += 1
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "compact_calendar_bucket_turbo_composite",
            title: AppLocalization.string("压缩日历桶风险预算复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1 - (cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0)
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    static func runNoCalendarLowDrawdownCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteAssetRiskGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteEquityCurveStateGateMomentum,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }
        guard let assetRisk = reportsByMode[.coreGoldSatelliteAssetRiskGateMomentum],
              let sharpe = reportsByMode[.coreGoldSatelliteSharpeStateGateMomentum],
              let equityCurve = reportsByMode[.coreGoldSatelliteEquityCurveStateGateMomentum] else {
            return nil
        }

        let reportPointMaps = [assetRisk, sharpe, equityCurve].map { report in
            Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
        }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(reportPointMaps[0].keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        guard let assetRiskReturns = returns(from: reportPointMaps[0]),
              let sharpeReturns = returns(from: reportPointMaps[1]),
              let equityCurveReturns = returns(from: reportPointMaps[2]) else {
            return nil
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        for index in 0..<assetRiskReturns.count {
            let dailyReturn = 0.36 * assetRiskReturns[index]
                + 0.35 * sharpeReturns[index]
                + 0.29 * equityCurveReturns[index]
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "no_calendar_lowdd_composite",
            title: AppLocalization.string("无日历低回撤复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    static func runNoCalendarHighReturnCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
            .recentLossVolatilityMetaMomentum,
            .coreGoldSatelliteGoldHandoffMomentum,
            .coreGoldSatelliteFullMomentum,
        ]
        let weightsByMode: [AdvancedBacktestStrategyMode: Double] = [
            .coreGoldSatelliteSharpeStateGateMomentum: 0.31,
            .coreGoldSatelliteRiskBudgetStateGateMomentum: 0.36,
            .recentLossVolatilityMetaMomentum: 0.24,
            .coreGoldSatelliteGoldHandoffMomentum: 0.08,
            .coreGoldSatelliteFullMomentum: 0.01,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }

        let reportPointMaps = componentModes.compactMap { mode in
            reportsByMode[mode].map { report in
                Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
            }
        }
        guard reportPointMaps.count == componentModes.count,
              let firstMap = reportPointMaps.first else { return nil }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(firstMap.keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        var returnsByMode: [AdvancedBacktestStrategyMode: [Double]] = [:]
        for (mode, map) in zip(componentModes, reportPointMaps) {
            guard let modeReturns = returns(from: map) else { return nil }
            returnsByMode[mode] = modeReturns
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        for index in 0..<(sharedDates.count - 1) {
            let dailyReturn = componentModes.reduce(0.0) { partial, mode in
                partial + (weightsByMode[mode] ?? 0) * (returnsByMode[mode]?[index] ?? 0)
            }
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "no_calendar_high_return_composite",
            title: AppLocalization.string("无日历高收益复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    static func runNoCalendarThreeSleeveCompositeStrategy(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        let componentModes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteAssetRiskGateMomentum,
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
        ]
        let weightsByMode: [AdvancedBacktestStrategyMode: Double] = [
            .coreGoldSatelliteAssetRiskGateMomentum: 0.70,
            .coreGoldSatelliteRiskBudgetStateGateMomentum: 0.25,
            .coreGoldSatelliteSharpeStateGateMomentum: 0.05,
        ]
        var reportsByMode: [AdvancedBacktestStrategyMode: AdvancedBacktestReport] = [:]
        for mode in componentModes {
            guard let report = runAdvancedRotationStrategy(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: settings,
                mode: mode
            ) else { return nil }
            reportsByMode[mode] = report
        }

        let reportPointMaps = componentModes.compactMap { mode in
            reportsByMode[mode].map { report in
                Dictionary(uniqueKeysWithValues: report.points.map { ($0.date, $0.portfolioValue) })
            }
        }
        guard reportPointMaps.count == componentModes.count,
              let firstMap = reportPointMaps.first else { return nil }
        let sharedDates = reportPointMaps
            .dropFirst()
            .reduce(Set(firstMap.keys)) { partial, next in partial.intersection(next.keys) }
            .sorted()
        guard sharedDates.count > 2 else { return nil }

        func returns(from map: [Date: Double]) -> [Double]? {
            var output: [Double] = []
            for index in 1..<sharedDates.count {
                guard let previous = map[sharedDates[index - 1]],
                      let current = map[sharedDates[index]],
                      previous > 0 else { return nil }
                output.append(current / previous - 1)
            }
            return output
        }

        var returnsByMode: [AdvancedBacktestStrategyMode: [Double]] = [:]
        for (mode, map) in zip(componentModes, reportPointMaps) {
            guard let modeReturns = returns(from: map) else { return nil }
            returnsByMode[mode] = modeReturns
        }

        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return nil }
        var values = [normalizedInitialCash]
        for index in 0..<(sharedDates.count - 1) {
            let dailyReturn = componentModes.reduce(0.0) { partial, mode in
                partial + (weightsByMode[mode] ?? 0) * (returnsByMode[mode]?[index] ?? 0)
            }
            values.append(values[values.count - 1] * max(0.0001, 1 + dailyReturn))
        }

        let points = zip(sharedDates, values).enumerated().map { index, item in
            BacktestSeriesPoint(date: item.0, portfolioValue: item.1, sequence: index)
        }
        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: "no_calendar_three_sleeve_composite",
            title: AppLocalization.string("无日历三袖套复合"),
            points: points,
            benchmarkPoints: [],
            pricePoints: [],
            trades: [],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            exposureRatio: 1
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: 0,
            averageCashRatio: 0,
            averageAnnualRate: CashYieldCNY.averageAnnualRate(across: sharedDates)
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: [],
            benchmarkSeries: [],
            trades: [],
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: 0,
            finalUnits: 0,
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: nil
        )
    }

    private static func recentLossVolatilityMetaConfig(
        mode: AdvancedBacktestStrategyMode,
        symbol: String = "recent_loss_volatility_meta_momentum",
        coreScale: Double? = nil,
        goldSatelliteWeight: Double = 0,
        goldSatelliteMaxTotalExposure: Double = 0.85,
        rebalanceSessions: Int = 60,
        portfolioEquityBrake: AdvancedRotationOverlayPortfolioEquityBrake? = nil,
        singleAssetExposureCap: AdvancedRotationSingleAssetExposureCap? = nil,
        confirmedExcessRotation: AdvancedRotationConfirmedExcessRotation? = nil,
        goldRolloverCap: AdvancedRotationGoldRolloverCap? = nil,
        goldRolloverConfirmedHandoff: AdvancedRotationGoldRolloverConfirmedHandoff? = nil,
        diversificationCredit: AdvancedRotationDiversificationCredit? = nil,
        confirmedEquityBreadth: AdvancedRotationConfirmedEquityBreadth? = nil,
        engineRouter: AdvancedRotationEngineRouter? = nil,
        confirmedAccelerationSatellite: AdvancedRotationConfirmedAccelerationSatellite? = nil,
        profitLockBudget: AdvancedRotationProfitLockBudget? = nil,
        equityCurveStateGate: AdvancedRotationEquityCurveStateGate? = nil,
        assetRiskStateGate: AdvancedRotationAssetRiskStateGate? = nil,
        dynamicSleeveSelector: AdvancedRotationDynamicSleeveSelector? = nil,
        globalRepairStack: AdvancedRotationGlobalRepairStack? = nil,
        currencyCashSelector: AdvancedRotationCurrencyCashSelector? = nil,
        goldPanicLock: AdvancedRotationGoldPanicLock? = nil,
        riskEfficiencyGovernor: AdvancedRotationRiskEfficiencyGovernor? = nil,
        canaryRiskBrake: AdvancedRotationCanaryRiskBrake? = nil,
        riskBudgetEnhancer: AdvancedRotationRiskBudgetEnhancer? = nil,
        rebalanceBand: Double = 0,
        buyReason: String? = nil
    ) -> AdvancedRotationConfig {
        var config = AdvancedRotationConfig(
            symbol: symbol,
            title: mode.title,
            lookbackSessions: 180,
            rebalanceSessions: rebalanceSessions,
            maFilterPeriod: 1,
            topCount: 1,
            maxExposure: coreScale == nil ? 0.75 : 0.85,
            targetAnnualVolatility: 0.11,
            volatilityLookbackSessions: 60,
            weighting: .winner,
            baseRotationSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            signal: .guardedDualMomentum,
            minMomentumThreshold: -0.02,
            maxSignalAnnualVolatility: 0.18,
            secondaryLookbackSessions: 60,
            secondaryMomentumThreshold: -0.04,
            signalDrawdownLookbackSessions: 60,
            maxSignalDrawdown: 0.15,
            rsiLookbackSessions: 14,
            donchianLookbackSessions: 240,
            metaSwitch: .init(
                defaultMode: .highZoneDecelerationMomentum,
                defensiveMode: .tailBreakdownLockMomentum,
                lossLookbackSessions: 60,
                lossThreshold: 0.035,
                volatilityLookbackSessions: 20,
                volatilityThreshold: 0.13,
                drawdownLookbackSessions: 60,
                lossDrawdownThreshold: 0.015,
                volatilityDrawdownThreshold: 0.025
            ),
            confirmedEquityBreadth: confirmedEquityBreadth,
            engineRouter: engineRouter,
            confirmedAccelerationSatellite: confirmedAccelerationSatellite,
            profitLockBudget: profitLockBudget,
            equityCurveStateGate: equityCurveStateGate,
            assetRiskStateGate: assetRiskStateGate,
            dynamicSleeveSelector: dynamicSleeveSelector,
            globalRepairStack: globalRepairStack,
            currencyCashSelector: currencyCashSelector,
            goldPanicLock: goldPanicLock,
            riskEfficiencyGovernor: riskEfficiencyGovernor,
            canaryRiskBrake: canaryRiskBrake,
            riskBudgetEnhancer: riskBudgetEnhancer,
            rebalanceBand: rebalanceBand,
            buyReason: buyReason ?? AppLocalization.string("近期亏损波动元策略建仓")
        )
        if confirmedAccelerationSatellite != nil || dynamicSleeveSelector != nil {
            config.zeroFillBeforeFirstSymbols = ["chinext"]
        }
        if let coreScale {
            config.goldSatelliteOverlay = .init(
                coreScale: coreScale,
                satelliteSymbol: "gold_cny",
                satelliteWeight: goldSatelliteWeight,
                maxTotalExposure: goldSatelliteMaxTotalExposure,
                satelliteMomentumLookbackSessions: 90,
                satelliteMomentumThreshold: 0,
                satelliteMovingAveragePeriod: 120,
                relativeSymbol: "sp500",
                relativeLookbackSessions: 60,
                relativeMomentumThreshold: 0,
                portfolioEquityBrake: portfolioEquityBrake,
                singleAssetExposureCap: singleAssetExposureCap,
                confirmedExcessRotation: confirmedExcessRotation,
                goldRolloverCap: goldRolloverCap,
                goldRolloverConfirmedHandoff: goldRolloverConfirmedHandoff,
                diversificationCredit: diversificationCredit,
                weakMonthEquityBrake: .init(
                    months: [2],
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    momentumLookbackSessions: 60,
                    momentumThreshold: -0.02,
                    maxEquityExposure: 0.35
                )
            )
        }
        return config
    }

    private static func researchOverrideDouble(_ key: String, default defaultValue: Double) -> Double {
        switch key {
        case "ATM_ASSET_RISK_LOW_SCALE":
            if let value = BacktestResearchOverrides.assetRiskLowScale, value.isFinite {
                return value
            }
        case "ATM_ASSET_RISK_MULTIPLIER":
            if let value = BacktestResearchOverrides.assetRiskMultiplier, value.isFinite {
                return value
            }
        case "ATM_SHARPE_LOW_SCALE":
            if let value = BacktestResearchOverrides.sharpeLowScale, value.isFinite {
                return value
            }
        case "ATM_SHARPE_MULTIPLIER":
            if let value = BacktestResearchOverrides.sharpeMultiplier, value.isFinite {
                return value
            }
        default:
            break
        }
        return defaultValue
    }

    private static func dynamicSleeveSelectorConfig() -> AdvancedRotationDynamicSleeveSelector {
        .init(
            satelliteMode: .coreGoldSatelliteConfirmedAccelerationMomentum,
            defensiveMode: .coreGoldSatelliteProfitLockMomentum,
            lookbackSessions: 315,
            satelliteHighWeight: 0.95,
            satelliteLowWeight: 0.25,
            returnMargin: 0.0125,
            satelliteDrawdownLookbackSessions: 157,
            satelliteDrawdownThreshold: 0.035,
            portfolioDrawdownLookbackSessions: 157,
            portfolioDrawdownThreshold: 0.030,
            initialSatelliteWeight: 0.80
        )
    }

    private static func contagionRepairStack() -> AdvancedRotationGlobalRepairStack {
        .init(
            repairSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext"],
            globalSymbols: ["hsi"],
            overlayRebalanceSessions: 21,
            repairDrawdownLookbackSessions: 105,
            repairDrawdownThreshold: 0.10,
            repairReboundLookbackSessions: 30,
            repairReboundThreshold: 0.055,
            repairConfirmationMAPeriod: 40,
            repairMomentumLookbackSessions: 20,
            repairTopCount: 1,
            repairOverlayCap: 0.35,
            repairPerAssetCap: 0.15,
            globalOverlayCap: 0.08,
            globalPerAssetCap: 0.06,
            globalTopCount: 1,
            phaseHotLookbackSessions: 126,
            phaseHotThreshold: 0.22,
            phaseCrackLookbackSessions: 20,
            phaseCrackThreshold: -0.020,
            phaseRolloverDrawdown: 0.08,
            phaseLockScale: 0.25,
            phaseMaxLockSessions: 126,
            contagion: .init(
                chinaHkSymbols: ["csi300", "shanghai_composite", "shenzhen_component", "chinext", "hsi"],
                globalCheckSymbols: ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "hsi"],
                cooldownSessions: 63,
                equityScale: 0.35,
                globalOverlayScale: 0,
                redeployGoldRatio: 0,
                releaseMode: "us_repair",
                triggerMode: "cluster"
            )
        )
    }

    private static func currencyCashSelectorConfig() -> AdvancedRotationCurrencyCashSelector {
        .init(
            symbol: "usd_cash",
            mode: "idle_hurdle",
            lookbackSessions: 40,
            movingAveragePeriod: 80,
            cap: 1.0,
            cnyCashHurdleScale: 1.0
        )
    }

    private static func goldPanicLockConfig() -> AdvancedRotationGoldPanicLock {
        .init(
            symbol: "gold_cny",
            hotLookbackSessions: 30,
            hotThreshold: 0.10,
            crackLookbackSessions: 20,
            crackThreshold: -0.045,
            movingAveragePeriod: 20,
            scale: 0.25,
            cooldownSessions: 21,
            releaseMode: "ma_reclaim"
        )
    }

    private static func riskEfficiencyGovernorConfig() -> AdvancedRotationRiskEfficiencyGovernor {
        .init(
            mode: "weak_momentum",
            volatilityLookbackSessions: 20,
            triggerVolatility: 0.13,
            targetVolatility: 0.08,
            momentumLookbackSessions: 40,
            momentumThreshold: 0.015
        )
    }

    private static func advancedRotationConfig(for mode: AdvancedBacktestStrategyMode) -> AdvancedRotationConfig? {
        switch mode {
        case .ultraDefensiveRotation:
            return .init(
                symbol: "ultra_defensive_rotation",
                title: mode.title,
                lookbackSessions: 40,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 3,
                maxExposure: 0.35,
                targetAnnualVolatility: 0.06,
                volatilityLookbackSessions: 20,
                weighting: .momentumInverseVolatility,
                buyReason: AppLocalization.string("极稳轮动建仓")
            )
        case .defensiveRotation:
            return .init(
                symbol: "defensive_rotation",
                title: mode.title,
                lookbackSessions: 40,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 3,
                maxExposure: 0.55,
                targetAnnualVolatility: 0.08,
                volatilityLookbackSessions: 20,
                weighting: .momentumInverseVolatility,
                buyReason: AppLocalization.string("稳健轮动建仓")
            )
        case .lowDrawdownRotation:
            return .init(
                symbol: "low_drawdown_rotation",
                title: mode.title,
                lookbackSessions: 40,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 3,
                maxExposure: 0.65,
                targetAnnualVolatility: 0.10,
                volatilityLookbackSessions: 20,
                weighting: .momentumInverseVolatility,
                buyReason: AppLocalization.string("低回撤轮动建仓")
            )
        case .balancedRotation:
            return .init(
                symbol: "balanced_rotation",
                title: mode.title,
                lookbackSessions: 40,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 3,
                maxExposure: 0.75,
                targetAnnualVolatility: 0.12,
                volatilityLookbackSessions: 20,
                weighting: .momentumInverseVolatility,
                buyReason: AppLocalization.string("均衡轮动建仓")
            )
        case .enhancedRotation:
            return .init(
                symbol: "enhanced_rotation",
                title: mode.title,
                lookbackSessions: 40,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 3,
                maxExposure: 0.90,
                targetAnnualVolatility: 0.12,
                volatilityLookbackSessions: 20,
                weighting: .momentumInverseVolatility,
                buyReason: AppLocalization.string("增强轮动建仓")
            )
        case .longTermDefensiveTrend:
            return .init(
                symbol: "long_term_defensive_trend",
                title: mode.title,
                lookbackSessions: 120,
                rebalanceSessions: 20,
                maFilterPeriod: 200,
                topCount: 3,
                maxExposure: 0.85,
                targetAnnualVolatility: 0.085,
                volatilityLookbackSessions: 30,
                weighting: .winner,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.65,
                    "sp500": 0.157,
                    "nasdaq": 0.193,
                ],
                renormalizesFixedBaseWeights: true,
                buyReason: AppLocalization.string("长期低回撤趋势建仓")
            )
        case .longTermEnhancedLowDrawdownTrend:
            return .init(
                symbol: "long_term_enhanced_low_drawdown_trend",
                title: mode.title,
                lookbackSessions: 120,
                rebalanceSessions: 20,
                maFilterPeriod: 220,
                topCount: 3,
                maxExposure: 0.95,
                targetAnnualVolatility: 0.095,
                volatilityLookbackSessions: 30,
                weighting: .winner,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.73,
                    "sp500": 0.01,
                    "nasdaq": 0.26,
                ],
                renormalizesFixedBaseWeights: true,
                volatilityBrake: .init(
                    triggerSymbol: "nasdaq",
                    threshold: 0.28,
                    scaledSymbols: ["nasdaq", "sp500"],
                    scale: 0.5,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.7
                ),
                buyReason: AppLocalization.string("长期增强低回撤趋势建仓")
            )
        case .steadyDrawdownLadderTrend, .septemberGuardLadderTrend:
            return .init(
                symbol: mode == .septemberGuardLadderTrend ? "september_guard_ladder_trend" : "steady_drawdown_ladder_trend",
                title: mode.title,
                lookbackSessions: 120,
                rebalanceSessions: 20,
                maFilterPeriod: 220,
                topCount: 3,
                maxExposure: 0.95,
                targetAnnualVolatility: 0.085,
                volatilityLookbackSessions: 30,
                weighting: .winner,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.73,
                    "sp500": 0.01,
                    "nasdaq": 0.26,
                ],
                renormalizesFixedBaseWeights: true,
                drawdownLadderBrake: .init(
                    lookbackSessions: 180,
                    triggerThresholdRatiosBySymbol: [
                        "nasdaq": 1.0,
                        "sp500": 0.8,
                    ],
                    scaledSymbols: ["nasdaq", "sp500"],
                    softDrawdown: 0.06,
                    hardDrawdown: 0.12,
                    softScale: 0.55,
                    hardScale: 0.15,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.8
                ),
                monthlyExposureBrake: mode == .septemberGuardLadderTrend ? .init(
                    months: [9],
                    scaledSymbols: ["nasdaq", "sp500"],
                    scale: 0.25,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.8
                ) : nil,
                buyReason: mode == .septemberGuardLadderTrend
                    ? AppLocalization.string("九月风险闸门趋势建仓")
                    : AppLocalization.string("稳健回撤阶梯趋势建仓")
            )
        case .goldCoreTrendSatellite:
            return .init(
                symbol: "gold_core_trend_satellite",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 20,
                maFilterPeriod: 250,
                maFilterPeriodBySymbol: [
                    "gold_cny": 120,
                    "sp500": 250,
                    "nasdaq": 250,
                ],
                topCount: 3,
                maxExposure: 0.95,
                targetAnnualVolatility: 0.095,
                volatilityLookbackSessions: 30,
                weighting: .coreSatelliteWinner,
                coreWeightsBySymbol: [
                    "gold_cny": 0.35,
                ],
                satelliteSymbols: ["nasdaq", "sp500"],
                satelliteWeight: 0.55,
                buyReason: AppLocalization.string("核心黄金趋势卫星建仓")
            )
        case .longTermGrowthTrend:
            return .init(
                symbol: "long_term_growth_trend",
                title: mode.title,
                lookbackSessions: 120,
                rebalanceSessions: 20,
                maFilterPeriod: 220,
                topCount: 3,
                maxExposure: 0.85,
                targetAnnualVolatility: 0.11,
                volatilityLookbackSessions: 20,
                weighting: .winner,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.50,
                    "sp500": 0.15,
                    "nasdaq": 0.35,
                ],
                renormalizesFixedBaseWeights: true,
                buyReason: AppLocalization.string("长期进取趋势建仓")
            )
        case .longTermLowVolMomentum:
            return .init(
                symbol: "long_term_low_vol_momentum",
                title: mode.title,
                lookbackSessions: 240,
                rebalanceSessions: 60,
                maFilterPeriod: 1,
                topCount: 3,
                maxExposure: 0.65,
                targetAnnualVolatility: 0.105,
                volatilityLookbackSessions: 30,
                weighting: .winner,
                signal: .lowVolMomentum,
                minMomentumThreshold: 0,
                maxSignalAnnualVolatility: 0.18,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.524,
                    "nasdaq": 0.085,
                    "sp500": 0.093,
                    "csi300": 0.155,
                    "shanghai_composite": 0.144,
                ],
                renormalizesFixedBaseWeights: true,
                buyReason: AppLocalization.string("长期低波动动量建仓")
            )
        case .robustLowVolMomentum:
            return .init(
                symbol: "robust_low_vol_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 40,
                maFilterPeriod: 1,
                topCount: 3,
                maxExposure: 0.55,
                targetAnnualVolatility: 0.075,
                volatilityLookbackSessions: 30,
                weighting: .lowVolMomentumInverseVolatility,
                signal: .lowVolMomentum,
                minMomentumThreshold: 0,
                maxSignalAnnualVolatility: 0.18,
                buyReason: AppLocalization.string("稳健低波动动量建仓")
            )
        case .overheatGuardMomentum:
            return .init(
                symbol: "overheat_guard_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 60,
                maFilterPeriod: 1,
                topCount: 1,
                maxExposure: 0.75,
                targetAnnualVolatility: 0.11,
                volatilityLookbackSessions: 60,
                weighting: .winner,
                signal: .guardedDualMomentum,
                minMomentumThreshold: -0.02,
                maxSignalAnnualVolatility: 0.18,
                secondaryLookbackSessions: 60,
                secondaryMomentumThreshold: -0.04,
                signalDrawdownLookbackSessions: 60,
                maxSignalDrawdown: 0.15,
                rsiLookbackSessions: 14,
                donchianLookbackSessions: 240,
                overheatBrake: .init(
                    triggerSymbols: ["csi300", "shanghai_composite"],
                    momentumLookbackSessions: 60,
                    momentumThreshold: 0.18,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 68,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.35,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.75
                ),
                portfolioDrawdownGuard: .init(
                    lookbackSessions: 240,
                    drawdownThreshold: 0.06,
                    scale: 0.25
                ),
                buyReason: AppLocalization.string("A股过热不追高动量建仓")
            )
        case .highZoneDecelerationMomentum:
            return .init(
                symbol: "high_zone_deceleration_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 60,
                maFilterPeriod: 1,
                topCount: 1,
                maxExposure: 0.75,
                targetAnnualVolatility: 0.11,
                volatilityLookbackSessions: 60,
                weighting: .winner,
                signal: .guardedDualMomentum,
                minMomentumThreshold: -0.02,
                maxSignalAnnualVolatility: 0.18,
                secondaryLookbackSessions: 60,
                secondaryMomentumThreshold: -0.04,
                signalDrawdownLookbackSessions: 60,
                maxSignalDrawdown: 0.15,
                rsiLookbackSessions: 14,
                donchianLookbackSessions: 240,
                overheatBrake: .init(
                    triggerSymbols: ["csi300", "shanghai_composite"],
                    momentumLookbackSessions: 60,
                    momentumThreshold: 0.18,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 68,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.50,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 1.0
                ),
                decelerationLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumUpperThreshold: 0.06,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 65,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.30,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.75
                ),
                shortWeaknessLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumThreshold: -0.005,
                    relativeSymbol: "gold_cny",
                    relativeLookbackSessions: 60,
                    relativeMomentumThreshold: -0.05,
                    maxExposure: 0.35,
                    redeploySymbol: nil,
                    redeployRatio: 0
                ),
                portfolioDrawdownGuard: .init(
                    lookbackSessions: 240,
                    drawdownThreshold: 0.06,
                    scale: 0.25
                ),
                buyReason: AppLocalization.string("高位短弱双守门动量建仓")
            )
        case .pairConfirmDoubleGuardMomentum:
            return .init(
                symbol: "pair_confirm_double_guard_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 60,
                maFilterPeriod: 1,
                topCount: 1,
                maxExposure: 0.75,
                targetAnnualVolatility: 0.11,
                volatilityLookbackSessions: 60,
                weighting: .winner,
                signal: .guardedDualMomentum,
                minMomentumThreshold: -0.02,
                maxSignalAnnualVolatility: 0.18,
                secondaryLookbackSessions: 60,
                secondaryMomentumThreshold: -0.04,
                signalDrawdownLookbackSessions: 60,
                maxSignalDrawdown: 0.15,
                rsiLookbackSessions: 14,
                donchianLookbackSessions: 240,
                overheatBrake: .init(
                    triggerSymbols: ["csi300", "shanghai_composite"],
                    momentumLookbackSessions: 60,
                    momentumThreshold: 0.18,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 68,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.50,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 1.0
                ),
                decelerationLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumUpperThreshold: 0.06,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 65,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.30,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.75
                ),
                shortWeaknessLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumThreshold: -0.005,
                    relativeSymbol: "gold_cny",
                    relativeLookbackSessions: 60,
                    relativeMomentumThreshold: -0.05,
                    maxExposure: 0.35,
                    redeploySymbol: nil,
                    redeployRatio: 0
                ),
                pairConfirmationGuard: .init(
                    peerBySymbol: [
                        "nasdaq": "sp500",
                        "sp500": "nasdaq",
                        "csi300": "shanghai_composite",
                        "shanghai_composite": "csi300",
                    ],
                    peerMomentumLookbackSessions: 60,
                    peerMomentumThreshold: -0.04,
                    peerDrawdownLookbackSessions: 60,
                    peerDrawdownThreshold: 0.08,
                    maxExposure: 0.60,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.50
                ),
                portfolioDrawdownGuard: .init(
                    lookbackSessions: 240,
                    drawdownThreshold: 0.06,
                    scale: 0.18
                ),
                buyReason: AppLocalization.string("配对确认双守门动量建仓")
            )
        case .tailBreakdownLockMomentum:
            return .init(
                symbol: "tail_breakdown_lock_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 20,
                maFilterPeriod: 1,
                topCount: 1,
                maxExposure: 0.75,
                targetAnnualVolatility: 0.11,
                volatilityLookbackSessions: 60,
                weighting: .winner,
                signal: .guardedDualMomentum,
                minMomentumThreshold: -0.02,
                maxSignalAnnualVolatility: 0.18,
                secondaryLookbackSessions: 60,
                secondaryMomentumThreshold: -0.04,
                signalDrawdownLookbackSessions: 60,
                maxSignalDrawdown: 0.15,
                rsiLookbackSessions: 14,
                donchianLookbackSessions: 240,
                overheatBrake: .init(
                    triggerSymbols: ["csi300", "shanghai_composite"],
                    momentumLookbackSessions: 60,
                    momentumThreshold: 0.18,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 68,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.50,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 1.0
                ),
                decelerationLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumUpperThreshold: 0.06,
                    rsiLookbackSessions: 14,
                    rsiThreshold: 65,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.90,
                    maxExposure: 0.30,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.75
                ),
                shortWeaknessLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    shortMomentumLookbackSessions: 20,
                    shortMomentumThreshold: -0.005,
                    relativeSymbol: "gold_cny",
                    relativeLookbackSessions: 60,
                    relativeMomentumThreshold: -0.05,
                    maxExposure: 0.35,
                    redeploySymbol: nil,
                    redeployRatio: 0
                ),
                heldBreakdownLock: .init(
                    triggerSymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    drawdownLookbackSessions: 40,
                    drawdownThreshold: 0.045,
                    shortMomentumLookbackSessions: 10,
                    shortMomentumThreshold: -0.01,
                    mediumMomentumLookbackSessions: 20,
                    mediumMomentumThreshold: 0.01,
                    relativeSymbol: "gold_cny",
                    relativeLookbackSessions: 60,
                    relativeMomentumThreshold: -0.04,
                    donchianLookbackSessions: 240,
                    donchianPositionThreshold: 0.55,
                    requiredSignals: 2,
                    maxExposure: 0.55,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.50
                ),
                portfolioDrawdownGuard: .init(
                    lookbackSessions: 240,
                    drawdownThreshold: 0.06,
                    scale: 0.18
                ),
                buyReason: AppLocalization.string("持有中破位锁盈防守建仓")
            )
        case .recentLossVolatilityMetaMomentum:
            return recentLossVolatilityMetaConfig(mode: mode)
        case .coreGoldSatelliteConservativeMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_conservative_momentum",
                coreScale: 0.95,
                goldSatelliteWeight: 0.10,
                buyReason: AppLocalization.string("核心动量+黄金卫星保守建仓")
            )
        case .coreGoldSatelliteBalancedMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_balanced_momentum",
                coreScale: 0.975,
                goldSatelliteWeight: 0.10,
                buyReason: AppLocalization.string("核心动量+黄金卫星平衡建仓")
            )
        case .coreGoldSatelliteFullMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_full_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                portfolioEquityBrake: .init(
                    lookbackSessions: 60,
                    drawdownThreshold: 0.065,
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    equityScale: 0.85
                ),
                buyReason: AppLocalization.string("核心动量+黄金卫星满核心建仓")
            )
        case .coreGoldSatelliteHeatCappedMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_heat_capped_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                portfolioEquityBrake: .init(
                    lookbackSessions: 60,
                    drawdownThreshold: 0.065,
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    equityScale: 0.85
                ),
                singleAssetExposureCap: .init(
                    symbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    maxWeight: 0.64
                ),
                buyReason: AppLocalization.string("热度上限元策略建仓")
            )
        case .coreGoldSatelliteGoldHandoffMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_gold_handoff_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                portfolioEquityBrake: .init(
                    lookbackSessions: 60,
                    drawdownThreshold: 0.065,
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    equityScale: 0.85
                ),
                singleAssetExposureCap: .init(
                    symbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    maxWeight: 0.64
                ),
                goldRolloverCap: .init(
                    symbol: "gold_cny",
                    longMomentumLookbackSessions: 90,
                    longMomentumThreshold: 0.08,
                    shortMomentumLookbackSessions: 20,
                    shortMomentumThreshold: 0,
                    maxWeight: 0.45
                ),
                goldRolloverConfirmedHandoff: .init(
                    candidateSymbols: ["nasdaq", "sp500"],
                    replacementMaxAdd: 0.20,
                    confirmationMomentumLookbackSessions: 60,
                    confirmationMovingAveragePeriod: 120,
                    maniaVetoSymbols: ["csi300", "shanghai_composite"],
                    maniaMomentumLookbackSessions: 240,
                    maniaMomentumThreshold: 1.0,
                    maniaDonchianLookbackSessions: 240,
                    maniaDonchianPositionThreshold: 0.95
                ),
                buyReason: AppLocalization.string("黄金交接保护建仓")
            )
        case .coreGoldSatelliteEquityBreadthMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_equity_breadth_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                portfolioEquityBrake: .init(
                    lookbackSessions: 60,
                    drawdownThreshold: 0.065,
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    equityScale: 0.85
                ),
                singleAssetExposureCap: .init(
                    symbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    maxWeight: 0.64
                ),
                goldRolloverCap: .init(
                    symbol: "gold_cny",
                    longMomentumLookbackSessions: 90,
                    longMomentumThreshold: 0.08,
                    shortMomentumLookbackSessions: 20,
                    shortMomentumThreshold: 0,
                    maxWeight: 0.45
                ),
                goldRolloverConfirmedHandoff: .init(
                    candidateSymbols: ["nasdaq", "sp500"],
                    replacementMaxAdd: 0.20,
                    confirmationMomentumLookbackSessions: 60,
                    confirmationMovingAveragePeriod: 120,
                    maniaVetoSymbols: ["csi300", "shanghai_composite"],
                    maniaMomentumLookbackSessions: 240,
                    maniaMomentumThreshold: 1.0,
                    maniaDonchianLookbackSessions: 240,
                    maniaDonchianPositionThreshold: 0.95
                ),
                confirmedEquityBreadth: .init(
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    minConfirmedCount: 2,
                    shortMomentumLookbackSessions: 60,
                    longMomentumLookbackSessions: 120,
                    movingAveragePeriod: 120,
                    volatilityLookbackSessions: 60,
                    maxTotalExposure: 1.0
                ),
                buyReason: AppLocalization.string("权益宽度进攻引擎建仓")
            )
        case .coreGoldSatelliteOneWayVolManagedMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_one_way_vol_managed_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                engineRouter: .init(
                    currentMode: .coreGoldSatelliteGoldHandoffMomentum,
                    offensiveMode: .coreGoldSatelliteEquityBreadthMomentum,
                    returnLookbackSessions: 240,
                    drawdownLookbackSessions: 120,
                    drawdownThreshold: 0.08,
                    volatilityLookbackSessions: 240,
                    offensiveBlendShare: 0.70,
                    defensiveBlendCurrentShare: 0.70
                ),
                buyReason: AppLocalization.string("单向控波元策略建仓")
            )
        case .coreGoldSatelliteEquityCurveStateGateMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_equity_curve_state_gate_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                engineRouter: .init(
                    currentMode: .coreGoldSatelliteGoldHandoffMomentum,
                    offensiveMode: .coreGoldSatelliteEquityBreadthMomentum,
                    returnLookbackSessions: 240,
                    drawdownLookbackSessions: 120,
                    drawdownThreshold: 0.08,
                    volatilityLookbackSessions: 240,
                    offensiveBlendShare: 1.0,
                    defensiveBlendCurrentShare: 0.70
                ),
                equityCurveStateGate: .init(
                    lookbackSessions: 90,
                    enterReturnThreshold: 0,
                    enterDrawdownThreshold: 0.025,
                    exitReturnThreshold: 0.02,
                    exitDrawdownThreshold: 0.03,
                    lowRiskScale: 0.70
                ),
                rebalanceBand: 0.08,
                buyReason: AppLocalization.string("权益曲线状态机建仓")
            )
        case .coreGoldSatelliteSharpeStateGateMomentum:
            let lowRiskScale = researchOverrideDouble("ATM_SHARPE_LOW_SCALE", default: 0.35)
            let riskBudgetMultiplier = researchOverrideDouble("ATM_SHARPE_MULTIPLIER", default: 1.0)
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_sharpe_state_gate_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                goldSatelliteMaxTotalExposure: 1.0,
                diversificationCredit: .init(
                    goldSymbol: "gold_cny",
                    usEquitySymbols: ["nasdaq", "sp500"],
                    goldFloor: 0.25,
                    maxTotalExposure: 1.0,
                    trendLookbackSessions: 126,
                    goldShortLookbackSessions: 20,
                    goldShortReturnFloor: -0.02,
                    correlationLookbackSessions: 63,
                    correlationCeiling: 0.35,
                    strategyHealthLookbackSessions: 90,
                    strategyDrawdownThreshold: 0.03
                ),
                engineRouter: .init(
                    currentMode: .coreGoldSatelliteGoldHandoffMomentum,
                    offensiveMode: .coreGoldSatelliteEquityBreadthMomentum,
                    returnLookbackSessions: 240,
                    drawdownLookbackSessions: 120,
                    drawdownThreshold: 0.08,
                    volatilityLookbackSessions: 240,
                    offensiveBlendShare: 1.0,
                    defensiveBlendCurrentShare: 0.70
                ),
                equityCurveStateGate: .init(
                    lookbackSessions: 75,
                    enterReturnThreshold: 0,
                    enterDrawdownThreshold: 0.025,
                    exitReturnThreshold: 0.05,
                    exitDrawdownThreshold: 0,
                    lowRiskScale: lowRiskScale
                ),
                riskBudgetEnhancer: riskBudgetMultiplier > 1.0001
                    ? .init(multiplier: riskBudgetMultiplier, annualFinancingRate: 0.03)
                    : nil,
                rebalanceBand: 0.08,
                buyReason: AppLocalization.string("高夏普状态机建仓")
            )
        case .coreGoldSatelliteAssetRiskGateMomentum:
            let lowRiskScale = researchOverrideDouble("ATM_ASSET_RISK_LOW_SCALE", default: 0.73)
            let riskBudgetMultiplier = researchOverrideDouble("ATM_ASSET_RISK_MULTIPLIER", default: 1.0)
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_asset_risk_gate_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                engineRouter: .init(
                    currentMode: .coreGoldSatelliteGoldHandoffMomentum,
                    offensiveMode: .coreGoldSatelliteEquityBreadthMomentum,
                    returnLookbackSessions: 240,
                    drawdownLookbackSessions: 120,
                    drawdownThreshold: 0.08,
                    volatilityLookbackSessions: 240,
                    offensiveBlendShare: 1.0,
                    defensiveBlendCurrentShare: 0.70
                ),
                equityCurveStateGate: .init(
                    lookbackSessions: 90,
                    enterReturnThreshold: 0,
                    enterDrawdownThreshold: 0.025,
                    exitReturnThreshold: 0.02,
                    exitDrawdownThreshold: 0.03,
                    lowRiskScale: lowRiskScale
                ),
                assetRiskStateGate: .init(
                    usMomentumLookbackSessions: 126,
                    usMomentumThreshold: 0,
                    usDrawdownLookbackSessions: 126,
                    usDrawdownThreshold: 0.08,
                    usVolatilityLookbackSessions: 20,
                    usVolatilityThreshold: 0.30,
                    goldRelativeLookbackSessions: 40,
                    goldRelativeThreshold: 0.18,
                    chinaDrawdownLookbackSessions: 63,
                    chinaDrawdownThreshold: 0.22,
                    portfolioDrawdownLookbackSessions: 126,
                    portfolioDrawdownThreshold: 0.07,
                    requiredSignalCount: 3,
                    normalScale: 1.0,
                    defensiveScale: 0.20,
                    recoveryScale: 0.50,
                    cooldownSessions: 20,
                    recoverySessions: 0
                ),
                riskBudgetEnhancer: riskBudgetMultiplier > 1.0001
                    ? .init(multiplier: riskBudgetMultiplier, annualFinancingRate: 0.03)
                    : nil,
                rebalanceBand: 0.08,
                buyReason: AppLocalization.string("收益回撤门状态机建仓")
            )
        case .coreGoldSatelliteRiskBudgetStateGateMomentum:
            let riskBudgetLowScale = BacktestResearchOverrides.riskBudgetLowScale ?? 1.0
            let riskBudgetMultiplier = BacktestResearchOverrides.riskBudgetMultiplier ?? 1.0
            let riskBudgetDefensiveShare = BacktestResearchOverrides.riskBudgetDefensiveShare ?? 0.0
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_risk_budget_state_gate_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                goldSatelliteMaxTotalExposure: 1.0,
                diversificationCredit: .init(
                    goldSymbol: "gold_cny",
                    usEquitySymbols: ["nasdaq", "sp500"],
                    goldFloor: 0.25,
                    maxTotalExposure: 1.0,
                    trendLookbackSessions: 126,
                    goldShortLookbackSessions: 20,
                    goldShortReturnFloor: -0.02,
                    correlationLookbackSessions: 63,
                    correlationCeiling: 0.35,
                    strategyHealthLookbackSessions: 90,
                    strategyDrawdownThreshold: 0.03
                ),
                engineRouter: .init(
                    currentMode: .coreGoldSatelliteGoldHandoffMomentum,
                    offensiveMode: .coreGoldSatelliteEquityBreadthMomentum,
                    returnLookbackSessions: 240,
                    drawdownLookbackSessions: 120,
                    drawdownThreshold: 0.08,
                    volatilityLookbackSessions: 240,
                    offensiveBlendShare: 1.0,
                    defensiveBlendCurrentShare: riskBudgetDefensiveShare
                ),
                equityCurveStateGate: .init(
                    lookbackSessions: 75,
                    enterReturnThreshold: 0,
                    enterDrawdownThreshold: 0.025,
                    exitReturnThreshold: 0.05,
                    exitDrawdownThreshold: 0,
                    lowRiskScale: riskBudgetLowScale
                ),
                riskEfficiencyGovernor: nil,
                canaryRiskBrake: nil,
                riskBudgetEnhancer: riskBudgetMultiplier > 1.0001
                    ? .init(multiplier: riskBudgetMultiplier, annualFinancingRate: 0.03)
                    : nil,
                rebalanceBand: 0.08,
                buyReason: AppLocalization.string("风险预算状态机建仓")
            )
        case .coreGoldSatelliteConfirmedAccelerationMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_confirmed_acceleration_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                engineRouter: .init(
                    currentMode: .coreGoldSatelliteGoldHandoffMomentum,
                    offensiveMode: .coreGoldSatelliteEquityBreadthMomentum,
                    returnLookbackSessions: 240,
                    drawdownLookbackSessions: 120,
                    drawdownThreshold: 0.08,
                    volatilityLookbackSessions: 240,
                    offensiveBlendShare: 0.70,
                    defensiveBlendCurrentShare: 0.70
                ),
                confirmedAccelerationSatellite: .init(
                    extraSymbols: ["dowjones", "shenzhen_component", "chinext"],
                    usMarketSymbols: ["nasdaq", "sp500"],
                    chinaMarketSymbols: ["shanghai_composite", "csi300", "shenzhen_component", "chinext"],
                    chinaExtraSymbols: ["shenzhen_component", "chinext"],
                    cap: 0.25,
                    perAssetCap: 0.10,
                    topCount: 2,
                    weakMonths: [2, 6, 8, 9, 10]
                ),
                buyReason: AppLocalization.string("确认加速进攻袖套建仓")
            )
        case .coreGoldSatelliteProfitLockMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_profit_lock_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                engineRouter: .init(
                    currentMode: .coreGoldSatelliteGoldHandoffMomentum,
                    offensiveMode: .coreGoldSatelliteEquityBreadthMomentum,
                    returnLookbackSessions: 240,
                    drawdownLookbackSessions: 120,
                    drawdownThreshold: 0.08,
                    volatilityLookbackSessions: 240,
                    offensiveBlendShare: 0.70,
                    defensiveBlendCurrentShare: 0.70
                ),
                profitLockBudget: .init(
                    lookbackSessions: 90,
                    softDrawdown: 0.012,
                    hardDrawdown: 0.045,
                    minScale: 0.50,
                    profitLookbackSessions: 60,
                    profitThreshold: 0.08,
                    shallowDrawdownThreshold: 0.02,
                    profitScale: 0.90
                ),
                buyReason: AppLocalization.string("锁盈防守袖套建仓")
            )
        case .coreGoldSatelliteDynamicSleeveMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_dynamic_sleeve_momentum",
                dynamicSleeveSelector: dynamicSleeveSelectorConfig(),
                buyReason: AppLocalization.string("动态袖套夏普策略建仓")
            )
        case .coreGoldSatelliteContagionRepairMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_contagion_repair_momentum",
                dynamicSleeveSelector: dynamicSleeveSelectorConfig(),
                globalRepairStack: contagionRepairStack(),
                buyReason: AppLocalization.string("全球修复传染控制建仓")
            )
        case .coreGoldSatelliteCurrencyCashMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_currency_cash_momentum",
                dynamicSleeveSelector: dynamicSleeveSelectorConfig(),
                globalRepairStack: contagionRepairStack(),
                currencyCashSelector: currencyCashSelectorConfig(),
                buyReason: AppLocalization.string("美元现金修复策略建仓")
            )
        case .coreGoldSatelliteGoldPanicLockMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_gold_panic_lock_momentum",
                dynamicSleeveSelector: dynamicSleeveSelectorConfig(),
                globalRepairStack: contagionRepairStack(),
                currencyCashSelector: currencyCashSelectorConfig(),
                goldPanicLock: goldPanicLockConfig(),
                buyReason: AppLocalization.string("黄金恐慌锁盈策略建仓")
            )
        case .coreGoldSatelliteRiskEfficiencyMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_risk_efficiency_momentum",
                dynamicSleeveSelector: dynamicSleeveSelectorConfig(),
                globalRepairStack: contagionRepairStack(),
                currencyCashSelector: currencyCashSelectorConfig(),
                goldPanicLock: goldPanicLockConfig(),
                riskEfficiencyGovernor: riskEfficiencyGovernorConfig(),
                buyReason: AppLocalization.string("风险效率增强策略建仓")
            )
        case .coreGoldSatelliteMonthlyHeatCappedMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_monthly_heat_capped_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                rebalanceSessions: 30,
                portfolioEquityBrake: .init(
                    lookbackSessions: 60,
                    drawdownThreshold: 0.065,
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    equityScale: 0.85
                ),
                singleAssetExposureCap: .init(
                    symbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    maxWeight: 0.72
                ),
                buyReason: AppLocalization.string("月度热度上限元建仓")
            )
        case .coreGoldSatelliteConfirmedExcessMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_confirmed_excess_momentum",
                coreScale: 1.0,
                goldSatelliteWeight: 0.10,
                portfolioEquityBrake: .init(
                    lookbackSessions: 60,
                    drawdownThreshold: 0.065,
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    equityScale: 0.85
                ),
                singleAssetExposureCap: .init(
                    symbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    maxWeight: 0.64
                ),
                confirmedExcessRotation: .init(
                    candidateSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
                    equitySymbols: ["nasdaq", "sp500", "csi300", "shanghai_composite"],
                    maxAdd: 0.06,
                    momentumLookbackSessions: 90,
                    movingAveragePeriod: 120,
                    volatilityLookbackSessions: 60,
                    minimumMomentum: 0,
                    volatilityFloor: 0.08
                ),
                buyReason: AppLocalization.string("增强热度上限元建仓")
            )
        case .coreGoldSatelliteAggressiveMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_aggressive_momentum",
                coreScale: 0.975,
                goldSatelliteWeight: 0.15,
                buyReason: AppLocalization.string("核心动量+黄金卫星进攻建仓")
            )
        case .canaryMomentumDefense:
            return .init(
                symbol: "canary_momentum_defense",
                title: mode.title,
                lookbackSessions: 240,
                rebalanceSessions: 20,
                maFilterPeriod: 220,
                topCount: 2,
                maxExposure: 0.95,
                targetAnnualVolatility: nil,
                volatilityLookbackSessions: 60,
                weighting: .winner,
                canaryRegime: .init(
                    canarySymbols: ["nasdaq", "sp500"],
                    offensiveSymbols: ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"],
                    defensiveSymbol: "gold_cny",
                    momentumLookbacks: [20, 60, 120, 240],
                    momentumWeights: [12, 4, 2, 1],
                    weakAllowed: 1,
                    canaryMovingAveragePeriod: 180,
                    assetMovingAveragePeriod: 220,
                    defensiveMovingAveragePeriod: 220,
                    canaryMomentumThreshold: 0,
                    assetMomentumThreshold: 0,
                    defensiveMomentumThreshold: 0,
                    equityVolatilityCap: 0.45,
                    offensiveWeight: 0.40,
                    defensiveBallastWeight: 0.30,
                    defensiveOnlyWeight: 0.20,
                    equalWeight: false
                ),
                rebalancesFromFirstSignal: true,
                rebalanceBand: 0.02,
                buyReason: AppLocalization.string("双金丝雀动量防守建仓")
            )
        case .drawdownReentryMomentum:
            return .init(
                symbol: "drawdown_reentry_momentum",
                title: mode.title,
                lookbackSessions: 180,
                rebalanceSessions: 40,
                maFilterPeriod: 1,
                topCount: 3,
                maxExposure: 0.65,
                targetAnnualVolatility: 0.075,
                volatilityLookbackSessions: 20,
                weighting: .winner,
                signal: .drawdownReentry,
                minMomentumThreshold: 0.01,
                secondaryLookbackSessions: 90,
                signalDrawdownLookbackSessions: 90,
                maxSignalDrawdown: 0.08,
                rsiLookbackSessions: 21,
                minimumRSI: 55,
                maximumRSI: 75,
                donchianLookbackSessions: 180,
                minimumDonchianPosition: 0.50,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.673,
                    "nasdaq": 0.205,
                    "sp500": 0.036,
                    "csi300": 0.047,
                    "shanghai_composite": 0.039,
                ],
                renormalizesFixedBaseWeights: true,
                buyReason: AppLocalization.string("回撤再入场动量建仓")
            )
        case .goldNasdaqSteadyRotation:
            return .init(
                symbol: "gold_nasdaq_steady_rotation",
                title: mode.title,
                lookbackSessions: 20,
                rebalanceSessions: 40,
                maFilterPeriod: 250,
                topCount: 1,
                maxExposure: 0.90,
                targetAnnualVolatility: 0.08,
                volatilityLookbackSessions: 20,
                weighting: .winner,
                minMomentumThreshold: 0.02,
                buyReason: AppLocalization.string("金纳低回撤轮动建仓")
            )
        case .goldNasdaqPortfolioScheduler:
            return .init(
                symbol: "gold_nasdaq_portfolio_scheduler",
                title: mode.title,
                lookbackSessions: 120,
                rebalanceSessions: 20,
                maFilterPeriod: 180,
                maFilterPeriodBySymbol: [
                    "gold_cny": 120,
                    "nasdaq": 200,
                    "sp500": 200,
                ],
                topCount: 2,
                maxExposure: 0.90,
                targetAnnualVolatility: 0.095,
                volatilityLookbackSessions: 40,
                weighting: .winner,
                minMomentumThreshold: -0.01,
                fixedBaseWeightsBySymbol: [
                    "gold_cny": 0.35,
                    "nasdaq": 0.55,
                ],
                volatilityBrake: .init(
                    triggerSymbol: "sp500",
                    threshold: 0.28,
                    scaledSymbols: ["nasdaq"],
                    scale: 0.45,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.50
                ),
                fastCrashBrake: .init(
                    triggerSymbols: ["sp500", "nasdaq"],
                    lookbackSessions: 5,
                    drawdownThreshold: 0.06,
                    scaledSymbols: ["nasdaq"],
                    scale: 0.25,
                    redeploySymbol: "gold_cny",
                    redeployRatio: 0.50
                ),
                signalOnlySymbols: ["sp500"],
                rebalancesFromFirstSignal: true,
                rebalanceBand: 0.015,
                buyReason: AppLocalization.string("金纳组合调度建仓")
            )
        case .strongVolControlledRotation:
            return .init(
                symbol: "strong_vol_controlled_rotation",
                title: mode.title,
                lookbackSessions: 20,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 1,
                maxExposure: 0.90,
                targetAnnualVolatility: 0.12,
                volatilityLookbackSessions: 20,
                weighting: .winner,
                buyReason: AppLocalization.string("强势控波轮动建仓")
            )
        case .momentumRotation:
            return .init(
                symbol: "momentum_rotation",
                title: mode.title,
                lookbackSessions: 20,
                rebalanceSessions: 20,
                maFilterPeriod: 60,
                topCount: 1,
                maxExposure: 1,
                targetAnnualVolatility: nil,
                volatilityLookbackSessions: 20,
                weighting: .winner,
                buyReason: AppLocalization.string("20日强势轮动")
            )
        case .ruleBased:
            return nil
        }
    }

    private enum AdvancedRotationWeighting {
        case winner
        case momentumInverseVolatility
        case lowVolMomentumInverseVolatility
        case coreSatelliteWinner
    }

    private enum AdvancedRotationSignal {
        case maMomentum
        case lowVolMomentum
        case guardedDualMomentum
        case drawdownReentry
    }

    private struct AdvancedRotationConfig {
        let symbol: String
        let title: String
        let lookbackSessions: Int
        let rebalanceSessions: Int
        let maFilterPeriod: Int
        var maFilterPeriodBySymbol: [String: Int]? = nil
        let topCount: Int
        let maxExposure: Double
        let targetAnnualVolatility: Double?
        let volatilityLookbackSessions: Int
        let weighting: AdvancedRotationWeighting
        var baseRotationSymbols: Set<String>? = nil
        var signal: AdvancedRotationSignal = .maMomentum
        var minMomentumThreshold: Double = 0
        var maxSignalAnnualVolatility: Double? = nil
        var secondaryLookbackSessions: Int? = nil
        var secondaryMomentumThreshold: Double? = nil
        var signalDrawdownLookbackSessions: Int? = nil
        var maxSignalDrawdown: Double? = nil
        var rsiLookbackSessions: Int? = nil
        var minimumRSI: Double? = nil
        var maximumRSI: Double? = nil
        var donchianLookbackSessions: Int? = nil
        var minimumDonchianPosition: Double? = nil
        var fixedBaseWeightsBySymbol: [String: Double]? = nil
        var renormalizesFixedBaseWeights: Bool = false
        var coreWeightsBySymbol: [String: Double]? = nil
        var satelliteSymbols: [String] = []
        var satelliteWeight: Double = 0
        var volatilityBrake: AdvancedRotationVolatilityBrake? = nil
        var fastCrashBrake: AdvancedRotationFastCrashBrake? = nil
        var drawdownLadderBrake: AdvancedRotationDrawdownLadderBrake? = nil
        var monthlyExposureBrake: AdvancedRotationMonthlyExposureBrake? = nil
        var overheatBrake: AdvancedRotationOverheatBrake? = nil
        var decelerationLock: AdvancedRotationDecelerationLock? = nil
        var shortWeaknessLock: AdvancedRotationShortWeaknessLock? = nil
        var pairConfirmationGuard: AdvancedRotationPairConfirmationGuard? = nil
        var heldBreakdownLock: AdvancedRotationHeldBreakdownLock? = nil
        var portfolioDrawdownGuard: AdvancedRotationPortfolioDrawdownGuard? = nil
        var metaSwitch: AdvancedRotationMetaSwitch? = nil
        var goldSatelliteOverlay: AdvancedRotationGoldSatelliteOverlay? = nil
        var canaryRegime: AdvancedRotationCanaryRegime? = nil
        var confirmedEquityBreadth: AdvancedRotationConfirmedEquityBreadth? = nil
        var engineRouter: AdvancedRotationEngineRouter? = nil
        var confirmedAccelerationSatellite: AdvancedRotationConfirmedAccelerationSatellite? = nil
        var profitLockBudget: AdvancedRotationProfitLockBudget? = nil
        var equityCurveStateGate: AdvancedRotationEquityCurveStateGate? = nil
        var assetRiskStateGate: AdvancedRotationAssetRiskStateGate? = nil
        var dynamicSleeveSelector: AdvancedRotationDynamicSleeveSelector? = nil
        var globalRepairStack: AdvancedRotationGlobalRepairStack? = nil
        var currencyCashSelector: AdvancedRotationCurrencyCashSelector? = nil
        var goldPanicLock: AdvancedRotationGoldPanicLock? = nil
        var riskEfficiencyGovernor: AdvancedRotationRiskEfficiencyGovernor? = nil
        var canaryRiskBrake: AdvancedRotationCanaryRiskBrake? = nil
        var riskBudgetEnhancer: AdvancedRotationRiskBudgetEnhancer? = nil
        var zeroFillBeforeFirstSymbols: Set<String> = []
        var signalOnlySymbols: Set<String> = []
        var rebalancesFromFirstSignal: Bool = false
        var rebalanceBand: Double = 0
        let buyReason: String
    }

    private struct AdvancedRotationRiskBudgetEnhancer {
        let multiplier: Double
        let annualFinancingRate: Double
    }

    private struct AdvancedRotationCanaryRiskBrake {
        let symbols: [String]
        let momentumLookbacks: [Int]
        let momentumWeights: [Double]
        let weakAllowed: Int
        let movingAveragePeriod: Int
        let momentumThreshold: Double
        let scale: Double
        let redeployGoldRatio: Double
    }

    private struct AdvancedRotationGlobalRepairStack {
        let repairSymbols: [String]
        let globalSymbols: [String]
        let overlayRebalanceSessions: Int
        let repairDrawdownLookbackSessions: Int
        let repairDrawdownThreshold: Double
        let repairReboundLookbackSessions: Int
        let repairReboundThreshold: Double
        let repairConfirmationMAPeriod: Int
        let repairMomentumLookbackSessions: Int
        let repairTopCount: Int
        let repairOverlayCap: Double
        let repairPerAssetCap: Double
        let globalOverlayCap: Double
        let globalPerAssetCap: Double
        let globalTopCount: Int
        let phaseHotLookbackSessions: Int
        let phaseHotThreshold: Double
        let phaseCrackLookbackSessions: Int
        let phaseCrackThreshold: Double
        let phaseRolloverDrawdown: Double
        let phaseLockScale: Double
        let phaseMaxLockSessions: Int
        let contagion: AdvancedRotationContagionControl?
    }

    private struct AdvancedRotationContagionControl {
        let chinaHkSymbols: [String]
        let globalCheckSymbols: [String]
        let cooldownSessions: Int
        let equityScale: Double
        let globalOverlayScale: Double
        let redeployGoldRatio: Double
        let releaseMode: String
        let triggerMode: String
    }

    private struct AdvancedRotationCurrencyCashSelector {
        let symbol: String
        let mode: String
        let lookbackSessions: Int
        let movingAveragePeriod: Int
        let cap: Double
        let cnyCashHurdleScale: Double
    }

    private struct AdvancedRotationGoldPanicLock {
        let symbol: String
        let hotLookbackSessions: Int
        let hotThreshold: Double
        let crackLookbackSessions: Int
        let crackThreshold: Double
        let movingAveragePeriod: Int
        let scale: Double
        let cooldownSessions: Int
        let releaseMode: String
    }

    private struct AdvancedRotationRiskEfficiencyGovernor {
        let mode: String
        let volatilityLookbackSessions: Int
        let triggerVolatility: Double
        let targetVolatility: Double
        let momentumLookbackSessions: Int
        let momentumThreshold: Double
    }

    private struct AdvancedRotationConfirmedEquityBreadth {
        let equitySymbols: [String]
        let minConfirmedCount: Int
        let shortMomentumLookbackSessions: Int
        let longMomentumLookbackSessions: Int
        let movingAveragePeriod: Int
        let volatilityLookbackSessions: Int
        let maxTotalExposure: Double
    }

    private struct AdvancedRotationEngineRouter {
        let currentMode: AdvancedBacktestStrategyMode
        let offensiveMode: AdvancedBacktestStrategyMode
        let returnLookbackSessions: Int
        let drawdownLookbackSessions: Int
        let drawdownThreshold: Double
        let volatilityLookbackSessions: Int
        let offensiveBlendShare: Double
        let defensiveBlendCurrentShare: Double
    }

    private struct AdvancedRotationConfirmedAccelerationSatellite {
        let extraSymbols: [String]
        let usMarketSymbols: [String]
        let chinaMarketSymbols: [String]
        let chinaExtraSymbols: Set<String>
        let cap: Double
        let perAssetCap: Double
        let topCount: Int
        let weakMonths: Set<Int>
    }

    private struct AdvancedRotationProfitLockBudget {
        let lookbackSessions: Int
        let softDrawdown: Double
        let hardDrawdown: Double
        let minScale: Double
        let profitLookbackSessions: Int
        let profitThreshold: Double
        let shallowDrawdownThreshold: Double
        let profitScale: Double
    }

    private struct AdvancedRotationEquityCurveStateGate {
        let lookbackSessions: Int
        let enterReturnThreshold: Double
        let enterDrawdownThreshold: Double
        let exitReturnThreshold: Double
        let exitDrawdownThreshold: Double
        let lowRiskScale: Double
    }

    private struct AdvancedRotationAssetRiskStateGate {
        let usMomentumLookbackSessions: Int
        let usMomentumThreshold: Double
        let usDrawdownLookbackSessions: Int
        let usDrawdownThreshold: Double
        let usVolatilityLookbackSessions: Int
        let usVolatilityThreshold: Double
        let goldRelativeLookbackSessions: Int
        let goldRelativeThreshold: Double
        let chinaDrawdownLookbackSessions: Int
        let chinaDrawdownThreshold: Double
        let portfolioDrawdownLookbackSessions: Int
        let portfolioDrawdownThreshold: Double
        let requiredSignalCount: Int
        let normalScale: Double
        let defensiveScale: Double
        let recoveryScale: Double
        let cooldownSessions: Int
        let recoverySessions: Int
    }

    private struct AdvancedRotationDynamicSleeveSelector {
        let satelliteMode: AdvancedBacktestStrategyMode
        let defensiveMode: AdvancedBacktestStrategyMode
        let lookbackSessions: Int
        let satelliteHighWeight: Double
        let satelliteLowWeight: Double
        let returnMargin: Double
        let satelliteDrawdownLookbackSessions: Int
        let satelliteDrawdownThreshold: Double
        let portfolioDrawdownLookbackSessions: Int
        let portfolioDrawdownThreshold: Double
        let initialSatelliteWeight: Double
    }

    private struct AdvancedRotationCanaryRegime {
        let canarySymbols: [String]
        let offensiveSymbols: [String]
        let defensiveSymbol: String
        let momentumLookbacks: [Int]
        let momentumWeights: [Double]
        let weakAllowed: Int
        let canaryMovingAveragePeriod: Int
        let assetMovingAveragePeriod: Int
        let defensiveMovingAveragePeriod: Int
        let canaryMomentumThreshold: Double
        let assetMomentumThreshold: Double
        let defensiveMomentumThreshold: Double
        let equityVolatilityCap: Double
        let offensiveWeight: Double
        let defensiveBallastWeight: Double
        let defensiveOnlyWeight: Double
        let equalWeight: Bool
    }

    private struct AdvancedRotationOverheatBrake {
        let triggerSymbols: [String]
        let momentumLookbackSessions: Int
        let momentumThreshold: Double
        let rsiLookbackSessions: Int
        let rsiThreshold: Double
        let donchianLookbackSessions: Int
        let donchianPositionThreshold: Double
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationDecelerationLock {
        let triggerSymbols: [String]
        let shortMomentumLookbackSessions: Int
        let shortMomentumUpperThreshold: Double
        let rsiLookbackSessions: Int
        let rsiThreshold: Double
        let donchianLookbackSessions: Int
        let donchianPositionThreshold: Double
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationShortWeaknessLock {
        let triggerSymbols: [String]
        let shortMomentumLookbackSessions: Int
        let shortMomentumThreshold: Double
        let relativeSymbol: String
        let relativeLookbackSessions: Int
        let relativeMomentumThreshold: Double
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationPairConfirmationGuard {
        let peerBySymbol: [String: String]
        let peerMomentumLookbackSessions: Int
        let peerMomentumThreshold: Double
        let peerDrawdownLookbackSessions: Int
        let peerDrawdownThreshold: Double
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationHeldBreakdownLock {
        let triggerSymbols: [String]
        let drawdownLookbackSessions: Int
        let drawdownThreshold: Double
        let shortMomentumLookbackSessions: Int
        let shortMomentumThreshold: Double
        let mediumMomentumLookbackSessions: Int
        let mediumMomentumThreshold: Double
        let relativeSymbol: String
        let relativeLookbackSessions: Int
        let relativeMomentumThreshold: Double
        let donchianLookbackSessions: Int
        let donchianPositionThreshold: Double
        let requiredSignals: Int
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationGoldSatelliteOverlay {
        let coreScale: Double
        let satelliteSymbol: String
        let satelliteWeight: Double
        let maxTotalExposure: Double
        let satelliteMomentumLookbackSessions: Int
        let satelliteMomentumThreshold: Double
        let satelliteMovingAveragePeriod: Int
        let relativeSymbol: String
        let relativeLookbackSessions: Int
        let relativeMomentumThreshold: Double
        let portfolioEquityBrake: AdvancedRotationOverlayPortfolioEquityBrake?
        let singleAssetExposureCap: AdvancedRotationSingleAssetExposureCap?
        let confirmedExcessRotation: AdvancedRotationConfirmedExcessRotation?
        let goldRolloverCap: AdvancedRotationGoldRolloverCap?
        let goldRolloverConfirmedHandoff: AdvancedRotationGoldRolloverConfirmedHandoff?
        let diversificationCredit: AdvancedRotationDiversificationCredit?
        let weakMonthEquityBrake: AdvancedRotationWeakMonthEquityBrake?
    }

    private struct AdvancedRotationSingleAssetExposureCap {
        let symbols: [String]
        let maxWeight: Double
    }

    private struct AdvancedRotationConfirmedExcessRotation {
        let candidateSymbols: [String]
        let equitySymbols: [String]
        let maxAdd: Double
        let momentumLookbackSessions: Int
        let movingAveragePeriod: Int
        let volatilityLookbackSessions: Int
        let minimumMomentum: Double
        let volatilityFloor: Double
    }

    private struct AdvancedRotationDiversificationCredit {
        let goldSymbol: String
        let usEquitySymbols: [String]
        let goldFloor: Double
        let maxTotalExposure: Double
        let trendLookbackSessions: Int
        let goldShortLookbackSessions: Int
        let goldShortReturnFloor: Double
        let correlationLookbackSessions: Int
        let correlationCeiling: Double
        let strategyHealthLookbackSessions: Int
        let strategyDrawdownThreshold: Double
    }

    private struct AdvancedRotationGoldRolloverCap {
        let symbol: String
        let longMomentumLookbackSessions: Int
        let longMomentumThreshold: Double
        let shortMomentumLookbackSessions: Int
        let shortMomentumThreshold: Double
        let maxWeight: Double
    }

    private struct AdvancedRotationGoldRolloverConfirmedHandoff {
        let candidateSymbols: [String]
        let replacementMaxAdd: Double
        let confirmationMomentumLookbackSessions: Int
        let confirmationMovingAveragePeriod: Int
        let maniaVetoSymbols: [String]
        let maniaMomentumLookbackSessions: Int
        let maniaMomentumThreshold: Double
        let maniaDonchianLookbackSessions: Int
        let maniaDonchianPositionThreshold: Double
    }

    private struct AdvancedRotationOverlayPortfolioEquityBrake {
        let lookbackSessions: Int
        let drawdownThreshold: Double
        let equitySymbols: [String]
        let equityScale: Double
    }

    private struct AdvancedRotationWeakMonthEquityBrake {
        let months: Set<Int>
        let equitySymbols: [String]
        let momentumLookbackSessions: Int
        let momentumThreshold: Double
        let maxEquityExposure: Double
    }

    private struct AdvancedRotationMetaSwitch {
        let defaultMode: AdvancedBacktestStrategyMode
        let defensiveMode: AdvancedBacktestStrategyMode
        let lossLookbackSessions: Int
        let lossThreshold: Double
        let volatilityLookbackSessions: Int
        let volatilityThreshold: Double
        let drawdownLookbackSessions: Int
        let lossDrawdownThreshold: Double
        let volatilityDrawdownThreshold: Double
    }

    private struct AdvancedRotationPortfolioDrawdownGuard {
        let lookbackSessions: Int
        let drawdownThreshold: Double
        let scale: Double
    }

    private struct AdvancedRotationVolatilityBrake {
        let triggerSymbol: String
        let threshold: Double
        let scaledSymbols: [String]
        let scale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationFastCrashBrake {
        let triggerSymbols: [String]
        let lookbackSessions: Int
        let drawdownThreshold: Double
        let scaledSymbols: [String]
        let scale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationDrawdownLadderBrake {
        let lookbackSessions: Int
        let triggerThresholdRatiosBySymbol: [String: Double]
        let scaledSymbols: [String]
        let softDrawdown: Double
        let hardDrawdown: Double
        let softScale: Double
        let hardScale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationMonthlyExposureBrake {
        let months: Set<Int>
        let scaledSymbols: [String]
        let scale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    private struct AdvancedRotationTargetWeight {
        let symbol: String
        let weight: Double
        let momentum: Double
        let annualizedVolatility: Double?
    }

    private struct AdvancedRotationSimulatedTrace {
        let values: [Double]
        let weightsByIndex: [[String: Double]]
    }

    private struct AdvancedRotationOverlayState {
        var repairOverlay: [String: Double] = [:]
        var globalOverlay: [String: Double] = [:]
        var phaseLockedStartIndexBySymbol: [String: Int] = [:]
        var contagionUntilIndex: Int = -1
        var goldPanicArmed: Bool = false
        var goldPanicUntilIndex: Int = -1
        var equityCurveStateGateDefensive: Bool = false
        var assetRiskDefensiveUntilIndex: Int = -1
        var assetRiskRecoveryUntilIndex: Int = -1
    }

    private static func advancedOverlayWarmup(for config: AdvancedRotationConfig) -> Int {
        let repairWarmup: Int
        if let stack = config.globalRepairStack {
            let repairIndicators = [
                stack.repairDrawdownLookbackSessions,
                stack.repairReboundLookbackSessions,
                stack.repairConfirmationMAPeriod,
                stack.repairMomentumLookbackSessions,
                stack.phaseHotLookbackSessions,
                stack.phaseCrackLookbackSessions,
                120,
            ].max() ?? 0
            let contagionWarmup = stack.contagion == nil ? 0 : 120
            repairWarmup = max(repairIndicators, contagionWarmup)
        } else {
            repairWarmup = 0
        }
        let currencyWarmup = max(
            config.currencyCashSelector?.lookbackSessions ?? 0,
            config.currencyCashSelector?.movingAveragePeriod ?? 0
        )
        let goldPanicWarmup = max(
            config.goldPanicLock?.hotLookbackSessions ?? 0,
            (config.goldPanicLock?.hotLookbackSessions ?? 0) * 2,
            config.goldPanicLock?.crackLookbackSessions ?? 0,
            config.goldPanicLock?.movingAveragePeriod ?? 0
        )
        let governorWarmup = max(
            config.riskEfficiencyGovernor?.volatilityLookbackSessions ?? 0,
            config.riskEfficiencyGovernor?.momentumLookbackSessions ?? 0,
            60
        )
        let equityCurveStateWarmup = config.equityCurveStateGate?.lookbackSessions ?? 0
        let assetRiskWarmup = [
            config.assetRiskStateGate?.usMomentumLookbackSessions ?? 0,
            config.assetRiskStateGate?.usDrawdownLookbackSessions ?? 0,
            config.assetRiskStateGate?.usVolatilityLookbackSessions ?? 0,
            config.assetRiskStateGate?.goldRelativeLookbackSessions ?? 0,
            config.assetRiskStateGate?.chinaDrawdownLookbackSessions ?? 0,
            config.assetRiskStateGate?.portfolioDrawdownLookbackSessions ?? 0
        ].max() ?? 0
        return max(repairWarmup, currencyWarmup, goldPanicWarmup, governorWarmup, equityCurveStateWarmup, assetRiskWarmup)
    }

    static func advancedRotationRebalanceAdvice(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        mode: AdvancedBacktestStrategyMode,
        initialCash: Double = 100_000,
        settings: AdvancedBacktestRiskSettings? = nil
    ) -> StrategyRebalanceAdvice? {
        guard let config = advancedRotationConfig(for: mode) else { return nil }
        let normalizedInitialCash = max(initialCash, 0)
        let normalizedFeeRate = max(settings?.feeRate ?? 1.0, 0) / 100
        let normalizedSlippageRate = max(settings?.slippageRate ?? 0.05, 0) / 100
        guard normalizedInitialCash > 0 else { return nil }

        let preparedSeries: [PreparedAdvancedSeries] = assetInputs.compactMap { input -> PreparedAdvancedSeries? in
            guard input.assetSeries != nil,
                  !input.assetOption.requiresHistoricalFX || input.fxSeries != nil else { return nil }
            return preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard preparedSeries.count >= 2 else { return nil }

        let aligned = alignedRotationPriceSeries(
            from: preparedSeries,
            zeroFillBeforeFirstSymbols: config.zeroFillBeforeFirstSymbols
        )
        let commonDates = aligned.dates
        let pricesBySymbol = aligned.pricesBySymbol
        let optionBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.assetOption) })
        let symbols = preparedSeries.map { $0.assetOption.symbol }
        let tradableSymbols = symbols.filter { !config.signalOnlySymbols.contains($0) }
        guard !tradableSymbols.isEmpty else { return nil }
        let maxMAFilterPeriod = max(config.maFilterPeriodBySymbol?.values.max() ?? config.maFilterPeriod, config.maFilterPeriod)
        let fastCrashBrakeLookback = config.fastCrashBrake?.lookbackSessions ?? 0
        let overheatBrakeWarmup = max(
            config.overheatBrake?.momentumLookbackSessions ?? 0,
            config.overheatBrake?.rsiLookbackSessions ?? 0,
            config.overheatBrake?.donchianLookbackSessions ?? 0
        )
        let decelerationLockWarmup = max(
            config.decelerationLock?.shortMomentumLookbackSessions ?? 0,
            config.decelerationLock?.rsiLookbackSessions ?? 0,
            config.decelerationLock?.donchianLookbackSessions ?? 0
        )
        let shortWeaknessLockWarmup = max(
            config.shortWeaknessLock?.shortMomentumLookbackSessions ?? 0,
            config.shortWeaknessLock?.relativeLookbackSessions ?? 0
        )
        let pairConfirmationGuardWarmup = max(
            config.pairConfirmationGuard?.peerMomentumLookbackSessions ?? 0,
            config.pairConfirmationGuard?.peerDrawdownLookbackSessions ?? 0
        )
        let heldBreakdownLockWarmup = max(
            config.heldBreakdownLock?.drawdownLookbackSessions ?? 0,
            config.heldBreakdownLock?.shortMomentumLookbackSessions ?? 0,
            config.heldBreakdownLock?.mediumMomentumLookbackSessions ?? 0,
            config.heldBreakdownLock?.relativeLookbackSessions ?? 0,
            config.heldBreakdownLock?.donchianLookbackSessions ?? 0
        )
        let metaSwitchWarmup = max(
            config.metaSwitch?.lossLookbackSessions ?? 0,
            config.metaSwitch?.volatilityLookbackSessions ?? 0,
            config.metaSwitch?.drawdownLookbackSessions ?? 0
        )
        let overlayPortfolioBrakeWarmup = config.goldSatelliteOverlay?.portfolioEquityBrake?.lookbackSessions ?? 0
        let confirmedEquityBreadthWarmup = max(
            config.confirmedEquityBreadth?.shortMomentumLookbackSessions ?? 0,
            config.confirmedEquityBreadth?.longMomentumLookbackSessions ?? 0,
            config.confirmedEquityBreadth?.movingAveragePeriod ?? 0,
            config.confirmedEquityBreadth?.volatilityLookbackSessions ?? 0
        )
        let engineRouterWarmup = max(
            config.engineRouter?.returnLookbackSessions ?? 0,
            config.engineRouter?.drawdownLookbackSessions ?? 0,
            config.engineRouter?.volatilityLookbackSessions ?? 0
        )
        let confirmedAccelerationWarmup = config.confirmedAccelerationSatellite == nil ? 0 : 240
        let profitLockWarmup = max(
            config.profitLockBudget?.lookbackSessions ?? 0,
            config.profitLockBudget?.profitLookbackSessions ?? 0
        )
        let dynamicSleeveWarmup = max(
            config.dynamicSleeveSelector?.lookbackSessions ?? 0,
            config.dynamicSleeveSelector?.satelliteDrawdownLookbackSessions ?? 0,
            config.dynamicSleeveSelector?.portfolioDrawdownLookbackSessions ?? 0
        )
        let canaryRegimeWarmup = max(
            config.canaryRegime?.momentumLookbacks.max() ?? 0,
            config.canaryRegime?.canaryMovingAveragePeriod ?? 0,
            config.canaryRegime?.assetMovingAveragePeriod ?? 0,
            config.canaryRegime?.defensiveMovingAveragePeriod ?? 0
        )
        let extraIndicatorWarmup = [
            config.secondaryLookbackSessions ?? 0,
            config.signalDrawdownLookbackSessions ?? 0,
            config.rsiLookbackSessions ?? 0,
            config.donchianLookbackSessions ?? 0,
            overheatBrakeWarmup,
            decelerationLockWarmup,
            shortWeaknessLockWarmup,
            pairConfirmationGuardWarmup,
            heldBreakdownLockWarmup,
            config.portfolioDrawdownGuard?.lookbackSessions ?? 0,
            metaSwitchWarmup,
            overlayPortfolioBrakeWarmup,
            confirmedEquityBreadthWarmup,
            engineRouterWarmup,
            confirmedAccelerationWarmup,
            profitLockWarmup,
            dynamicSleeveWarmup,
            canaryRegimeWarmup,
            advancedOverlayWarmup(for: config),
        ].max() ?? 0
        let minimumWarmup = ([
            config.lookbackSessions,
            maxMAFilterPeriod,
            config.volatilityLookbackSessions,
            fastCrashBrakeLookback,
            extraIndicatorWarmup,
        ].max() ?? 0) + 1
        guard commonDates.count > minimumWarmup,
              let signalIndex = commonDates.indices.last else { return nil }

        var maBySymbol: [String: [Double?]] = [:]
        var volatilityBySymbol: [String: [Double?]] = [:]
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            let maFilterPeriod = config.maFilterPeriodBySymbol?[symbol] ?? config.maFilterPeriod
            maBySymbol[symbol] = movingAverage(values: prices, period: maFilterPeriod)
            volatilityBySymbol[symbol] = rollingAnnualizedVolatility(values: prices, period: config.volatilityLookbackSessions)
        }

        let engineRouterTracesByMode = config.engineRouter.flatMap { engineRouter in
            engineRouterTraces(
                for: engineRouter,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                initialCash: normalizedInitialCash,
                feeRate: normalizedFeeRate,
                slippageRate: normalizedSlippageRate
            )
        }
        if config.engineRouter != nil, engineRouterTracesByMode == nil {
            return nil
        }
        let dynamicSleeveTrace = config.dynamicSleeveSelector.flatMap { _ in
            simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: config,
                initialCash: normalizedInitialCash,
                feeRate: normalizedFeeRate,
                slippageRate: normalizedSlippageRate
            )
        }
        if config.dynamicSleeveSelector != nil, dynamicSleeveTrace == nil {
            return nil
        }
        let equityCurveStateTrace = config.equityCurveStateGate.flatMap { _ in
            simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: config,
                initialCash: normalizedInitialCash,
                feeRate: normalizedFeeRate,
                slippageRate: normalizedSlippageRate
            )
        }
        if config.equityCurveStateGate != nil, equityCurveStateTrace == nil {
            return nil
        }

        let targetWeightItems: [AdvancedRotationTargetWeight]
        let portfolioGuardScale: Double
        if config.dynamicSleeveSelector != nil {
            guard let dynamicSleeveTrace,
                  dynamicSleeveTrace.weightsByIndex.indices.contains(signalIndex) else { return nil }
            portfolioGuardScale = 1
            targetWeightItems = Self.targetWeightItems(
                from: dynamicSleeveTrace.weightsByIndex[signalIndex],
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                config: config
            )
        } else if config.equityCurveStateGate != nil {
            guard let equityCurveStateTrace,
                  equityCurveStateTrace.weightsByIndex.indices.contains(signalIndex) else { return nil }
            portfolioGuardScale = 1
            targetWeightItems = Self.targetWeightItems(
                from: equityCurveStateTrace.weightsByIndex[signalIndex],
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                config: config
            )
        } else if config.engineRouter != nil {
            guard let engineRouterTracesByMode else { return nil }
            portfolioGuardScale = 1
            let weights = resolvedAdvancedRotationTargetWeights(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                traceIndex: signalIndex,
                config: config,
                engineRouterTracesByMode: engineRouterTracesByMode
            )
            targetWeightItems = Self.targetWeightItems(
                from: weights,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                config: config
            )
        } else if let metaSwitch = config.metaSwitch {
            guard let tracesByMode = metaEngineTraces(
                for: metaSwitch,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates
            ),
                  let rawMetaWeights = metaRotationTargetWeights(
                    metaSwitch: metaSwitch,
                    stressIndex: signalIndex,
                    weightIndex: signalIndex,
                    tracesByMode: tracesByMode
                  ) else { return nil }
            let overlayWeights = applyGoldSatelliteOverlay(
                to: rawMetaWeights,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                pricesBySymbol: pricesBySymbol,
                portfolioValues: tracesByMode[metaSwitch.defaultMode]?.values,
                config: config
            )
            let metaWeights = applyPostTargetOverlays(
                to: overlayWeights,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                portfolioValues: tracesByMode[metaSwitch.defaultMode]?.values,
                config: config
            )
            portfolioGuardScale = 1
            targetWeightItems = metaWeights.compactMap { item -> AdvancedRotationTargetWeight? in
                let symbol = item.key
                let weight = item.value
                guard !config.signalOnlySymbols.contains(symbol),
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex) else { return nil }
                return AdvancedRotationTargetWeight(
                    symbol: symbol,
                    weight: weight,
                    momentum: priceMomentum(values: prices, at: signalIndex, lookback: config.lookbackSessions) ?? 0,
                    annualizedVolatility: volatilityBySymbol[symbol]?[signalIndex] ?? nil
                )
            }
        } else {
            portfolioGuardScale = simulatedPortfolioDrawdownGuardScale(
                symbols: tradableSymbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: config
            )
            let rawWeights = Dictionary(uniqueKeysWithValues: advancedRotationTargetWeights(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                config: config
            )
            .filter { !config.signalOnlySymbols.contains($0.symbol) }
            .map { ($0.symbol, $0.weight) })
            let adjustedWeights = applyPostTargetOverlays(
                to: rawWeights,
                signalIndex: signalIndex,
                signalDate: commonDates[signalIndex],
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                portfolioValues: nil,
                config: config
            )
            targetWeightItems = Self.targetWeightItems(
                from: adjustedWeights,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                config: config
            )
            .filter { !config.signalOnlySymbols.contains($0.symbol) }
        }

        let allocations = targetWeightItems
        .compactMap { target -> StrategyRebalanceAllocation? in
            let adjustedWeight = target.weight * portfolioGuardScale
            guard adjustedWeight > 0,
                  !config.signalOnlySymbols.contains(target.symbol),
                  let option = optionBySymbol[target.symbol] else { return nil }
            return StrategyRebalanceAllocation(
                symbol: target.symbol,
                title: option.title,
                targetWeight: adjustedWeight,
                momentum: target.momentum,
                annualizedVolatility: target.annualizedVolatility
            )
        }
        .sorted { lhs, rhs in
            if lhs.targetWeight == rhs.targetWeight { return lhs.title < rhs.title }
            return lhs.targetWeight > rhs.targetWeight
        }

        return StrategyRebalanceAdvice(
            strategyTitle: config.title,
            asOfDate: commonDates[signalIndex],
            lookbackSessions: config.lookbackSessions,
            rebalanceSessions: config.rebalanceSessions,
            targetAnnualVolatility: config.targetAnnualVolatility,
            allocations: allocations
        )
    }

    private static func simulatedPortfolioDrawdownGuardScale(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        config: AdvancedRotationConfig
    ) -> Double {
        guard let guardConfig = config.portfolioDrawdownGuard,
              commonDates.count > 2 else { return 1 }

        func guardScale(currentValue: Double, historyValues: [Double]) -> Double {
            guard !historyValues.isEmpty else { return 1 }
            let lookbackSessions = max(guardConfig.lookbackSessions, 1)
            var recentValues = Array(historyValues.suffix(lookbackSessions))
            recentValues.append(currentValue)
            guard let recentPeak = recentValues.max(), recentPeak > 0 else { return 1 }
            let drawdownFromPeak = currentValue / recentPeak - 1
            guard drawdownFromPeak < -max(guardConfig.drawdownThreshold, 0) else { return 1 }
            return min(max(guardConfig.scale, 0), 1)
        }

        var weightsBySymbol: [String: Double] = [:]
        var values: [Double] = [100_000]
        var value = 100_000.0
        let rebalanceSessions = max(config.rebalanceSessions, 1)

        for index in commonDates.indices.dropFirst() {
            var dailyReturn = 0.0
            for symbol in symbols {
                guard let weight = weightsBySymbol[symbol],
                      weight > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(index),
                      prices.indices.contains(index - 1),
                      prices[index - 1] > 0 else { continue }
                dailyReturn += weight * (prices[index] / prices[index - 1] - 1)
            }
            let investedWeight = weightsBySymbol.values.reduce(0) { $0 + max($1, 0) }
            let cashWeight = max(0, 1 - investedWeight)
            dailyReturn += cashWeight * CashYieldCNY.dailyReturn(on: commonDates[index - 1])
            value *= 1 + dailyReturn
            guard value.isFinite, value > 0 else { return 1 }

            if index % rebalanceSessions == 0 {
                let signalIndex = index - 1
                let baseWeights = Dictionary(uniqueKeysWithValues: advancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    config: config
                ).map { ($0.symbol, $0.weight) })
                let scale = guardScale(currentValue: value, historyValues: values)
                weightsBySymbol = baseWeights.mapValues { $0 * scale }
            }

            values.append(value)
        }

        return guardScale(currentValue: value, historyValues: values)
    }

    private static func simulatedRotationTrace(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        config: AdvancedRotationConfig
    ) -> AdvancedRotationSimulatedTrace {
        var weightsBySymbol: [String: Double] = [:]
        var values: [Double] = [100_000]
        var weightsByIndex: [[String: Double]] = [weightsBySymbol]
        var value = 100_000.0
        let rebalanceSessions = max(config.rebalanceSessions, 1)

        func applyPortfolioGuard(to targetWeights: [String: Double], currentValue: Double) -> [String: Double] {
            guard let guardConfig = config.portfolioDrawdownGuard,
                  !targetWeights.isEmpty else { return targetWeights }
            let lookbackSessions = max(guardConfig.lookbackSessions, 1)
            var recentValues = Array(values.suffix(lookbackSessions))
            recentValues.append(currentValue)
            guard let recentPeak = recentValues.max(), recentPeak > 0 else { return targetWeights }
            let drawdownFromPeak = currentValue / recentPeak - 1
            guard drawdownFromPeak < -max(guardConfig.drawdownThreshold, 0) else { return targetWeights }
            let scale = min(max(guardConfig.scale, 0), 1)
            return targetWeights.mapValues { $0 * scale }
        }

        for index in commonDates.indices.dropFirst() {
            var dailyReturn = 0.0
            for symbol in symbols {
                guard let weight = weightsBySymbol[symbol],
                      weight > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(index),
                      prices.indices.contains(index - 1),
                      prices[index - 1] > 0 else { continue }
                dailyReturn += weight * (prices[index] / prices[index - 1] - 1)
            }
            let investedWeight = weightsBySymbol.values.reduce(0) { $0 + max($1, 0) }
            let cashWeight = max(0, 1 - investedWeight)
            dailyReturn += cashWeight * CashYieldCNY.dailyReturn(on: commonDates[index - 1])
            value *= 1 + dailyReturn
            if !value.isFinite || value <= 0 {
                value = values.last ?? 100_000
            }

            if index == 1 || index % rebalanceSessions == 0 {
                let signalIndex = index - 1
                let baseWeights = Dictionary(uniqueKeysWithValues: advancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    config: config
                ).map { ($0.symbol, $0.weight) })
                weightsBySymbol = applyPortfolioGuard(to: baseWeights, currentValue: value)
            }

            values.append(value)
            weightsByIndex.append(weightsBySymbol)
        }

        return AdvancedRotationSimulatedTrace(values: values, weightsByIndex: weightsByIndex)
    }

    private static func portfolioRollingReturn(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index),
              values.indices.contains(index - lookback),
              values[index - lookback] > 0 else { return nil }
        return values[index] / values[index - lookback] - 1
    }

    private static func portfolioRollingDrawdown(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index) else { return nil }
        let startIndex = max(0, index - lookback + 1)
        guard startIndex <= index,
              let recentPeak = values[startIndex...index].max(),
              recentPeak > 0 else { return nil }
        return values[index] / recentPeak - 1
    }

    private static func portfolioAnnualizedVolatility(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 1,
              values.indices.contains(index) else { return nil }
        let startIndex = max(1, index - lookback + 1)
        guard startIndex <= index else { return nil }
        let returns = (startIndex...index).compactMap { currentIndex -> Double? in
            guard values.indices.contains(currentIndex - 1),
                  values[currentIndex - 1] > 0,
                  values[currentIndex] > 0 else { return nil }
            return values[currentIndex] / values[currentIndex - 1] - 1
        }
        guard returns.count >= 5 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count)
        return sqrt(max(variance, 0)) * sqrt(252)
    }

    private static func rollingCorrelation(
        leftValues: [Double],
        rightValueSets: [[Double]],
        at index: Int,
        lookback: Int
    ) -> Double? {
        guard lookback > 1,
              leftValues.indices.contains(index),
              index - lookback + 1 >= 1,
              !rightValueSets.isEmpty else { return nil }

        var leftReturns: [Double] = []
        var rightReturns: [Double] = []
        for cursor in (index - lookback + 1)...index {
            guard leftValues.indices.contains(cursor),
                  leftValues.indices.contains(cursor - 1),
                  leftValues[cursor] > 0,
                  leftValues[cursor - 1] > 0 else { continue }
            let availableRightReturns = rightValueSets.compactMap { values -> Double? in
                guard values.indices.contains(cursor),
                      values.indices.contains(cursor - 1),
                      values[cursor] > 0,
                      values[cursor - 1] > 0 else { return nil }
                return values[cursor] / values[cursor - 1] - 1
            }
            guard !availableRightReturns.isEmpty else { continue }
            leftReturns.append(leftValues[cursor] / leftValues[cursor - 1] - 1)
            rightReturns.append(availableRightReturns.reduce(0, +) / Double(availableRightReturns.count))
        }
        guard leftReturns.count >= 20,
              leftReturns.count == rightReturns.count else { return nil }
        let leftMean = leftReturns.reduce(0, +) / Double(leftReturns.count)
        let rightMean = rightReturns.reduce(0, +) / Double(rightReturns.count)
        let leftVariance = leftReturns.reduce(0) { $0 + pow($1 - leftMean, 2) }
        let rightVariance = rightReturns.reduce(0) { $0 + pow($1 - rightMean, 2) }
        guard leftVariance > 0, rightVariance > 0 else { return nil }
        let covariance = leftReturns.indices.reduce(0.0) { partial, cursor in
            partial + (leftReturns[cursor] - leftMean) * (rightReturns[cursor] - rightMean)
        }
        return covariance / sqrt(leftVariance * rightVariance)
    }

    private static func applyGoldSatelliteOverlay(
        to rawWeights: [String: Double],
        signalIndex: Int,
        signalDate: Date,
        pricesBySymbol: [String: [Double]],
        portfolioValues: [Double]? = nil,
        config: AdvancedRotationConfig
    ) -> [String: Double] {
        guard let overlay = config.goldSatelliteOverlay else { return rawWeights }
        var finalWeights = rawWeights.mapValues { max($0, 0) * min(max(overlay.coreScale, 0), 1) }

        func priceMomentum(symbol: String, lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return Self.priceMomentum(values: prices, at: signalIndex, lookback: lookback)
        }

        func isAboveMovingAverage(symbol: String, period: Int) -> Bool {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let movingAverage = movingAverage(values: prices, period: period)[signalIndex] else { return false }
            return prices[signalIndex] >= movingAverage
        }

        func satellitePassesTrendFilter() -> Bool {
            guard let satelliteMomentum = priceMomentum(
                symbol: overlay.satelliteSymbol,
                lookback: overlay.satelliteMomentumLookbackSessions
            ),
                  satelliteMomentum > overlay.satelliteMomentumThreshold,
                  isAboveMovingAverage(symbol: overlay.satelliteSymbol, period: overlay.satelliteMovingAveragePeriod),
                  let satellitePrices = pricesBySymbol[overlay.satelliteSymbol],
                  let relativePrices = pricesBySymbol[overlay.relativeSymbol],
                  signalIndex - overlay.relativeLookbackSessions >= 0,
                  satellitePrices.indices.contains(signalIndex),
                  satellitePrices.indices.contains(signalIndex - overlay.relativeLookbackSessions),
                  relativePrices.indices.contains(signalIndex),
                  relativePrices.indices.contains(signalIndex - overlay.relativeLookbackSessions) else { return false }
            let previousSatellitePrice = satellitePrices[signalIndex - overlay.relativeLookbackSessions]
            let previousRelativePrice = relativePrices[signalIndex - overlay.relativeLookbackSessions]
            let currentSatellitePrice = satellitePrices[signalIndex]
            let currentRelativePrice = relativePrices[signalIndex]
            guard previousSatellitePrice > 0,
                  previousRelativePrice > 0,
                  currentSatellitePrice > 0,
                  currentRelativePrice > 0 else { return false }
            let relativeMomentum = (currentSatellitePrice / previousSatellitePrice) / (currentRelativePrice / previousRelativePrice) - 1
            return relativeMomentum > overlay.relativeMomentumThreshold
        }

        let canUseSatellite = satellitePassesTrendFilter()
        if canUseSatellite {
            finalWeights[overlay.satelliteSymbol, default: 0] += max(overlay.satelliteWeight, 0)
        }

        if let portfolioEquityBrake = overlay.portfolioEquityBrake,
           let portfolioValues,
           portfolioValues.indices.contains(signalIndex) {
            let lookbackSessions = max(portfolioEquityBrake.lookbackSessions, 1)
            let startIndex = max(0, signalIndex - lookbackSessions + 1)
            if startIndex <= signalIndex,
               let recentPeak = portfolioValues[startIndex...signalIndex].max(),
               recentPeak > 0 {
                let drawdownFromPeak = portfolioValues[signalIndex] / recentPeak - 1
                if drawdownFromPeak < -max(portfolioEquityBrake.drawdownThreshold, 0) {
                    let scale = min(max(portfolioEquityBrake.equityScale, 0), 1)
                    for symbol in portfolioEquityBrake.equitySymbols {
                        guard let originalWeight = finalWeights[symbol], originalWeight > 0 else { continue }
                        finalWeights[symbol] = originalWeight * scale
                    }
                }
            }
        }

        if let weakMonthEquityBrake = overlay.weakMonthEquityBrake,
           weakMonthEquityBrake.months.contains(Calendar.current.component(.month, from: signalDate)) {
            let equitySymbolsToBrake = weakMonthEquityBrake.equitySymbols.filter { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let momentum = priceMomentum(symbol: symbol, lookback: weakMonthEquityBrake.momentumLookbackSessions) else { return false }
                return momentum < weakMonthEquityBrake.momentumThreshold
            }
            let currentEquityExposure = weakMonthEquityBrake.equitySymbols.reduce(0.0) { $0 + max(finalWeights[$1] ?? 0, 0) }
            let maxEquityExposure = min(max(weakMonthEquityBrake.maxEquityExposure, 0), 1)
            if !equitySymbolsToBrake.isEmpty,
               currentEquityExposure > maxEquityExposure,
               currentEquityExposure > 0 {
                let scale = maxEquityExposure / currentEquityExposure
                for symbol in weakMonthEquityBrake.equitySymbols {
                    guard let originalWeight = finalWeights[symbol], originalWeight > 0 else { continue }
                    finalWeights[symbol] = originalWeight * scale
                }
            }
        }

        var clippedExcess = 0.0
        var cappedEquitySymbols = Set<String>()
        if let singleAssetExposureCap = overlay.singleAssetExposureCap {
            let cap = min(max(singleAssetExposureCap.maxWeight, 0), 1)
            for symbol in singleAssetExposureCap.symbols {
                guard let originalWeight = finalWeights[symbol], originalWeight > cap else { continue }
                clippedExcess += originalWeight - cap
                finalWeights[symbol] = cap
                cappedEquitySymbols.insert(symbol)
            }
        }

        if let confirmedExcessRotation = overlay.confirmedExcessRotation,
           clippedExcess > 0 {
            let equitySymbols = Set(confirmedExcessRotation.equitySymbols)
            let cap = min(max(overlay.singleAssetExposureCap?.maxWeight ?? 1, 0), 1)
            let addBudget = min(clippedExcess, max(confirmedExcessRotation.maxAdd, 0))

            if addBudget > 0, canUseSatellite {
                let currentWeight = max(finalWeights[overlay.satelliteSymbol] ?? 0, 0)
                let room = max(overlay.maxTotalExposure - currentWeight, 0)
                let addition = min(addBudget, room)
                if addition > 0 {
                    finalWeights[overlay.satelliteSymbol, default: 0] += addition
                }
            } else if addBudget > 0 {
                let scoredCandidates: [(score: Double, symbol: String, room: Double)] = confirmedExcessRotation.candidateSymbols.compactMap { symbol -> (score: Double, symbol: String, room: Double)? in
                    guard let prices = pricesBySymbol[symbol],
                          prices.indices.contains(signalIndex),
                          let momentum = priceMomentum(symbol: symbol, lookback: confirmedExcessRotation.momentumLookbackSessions),
                          momentum > confirmedExcessRotation.minimumMomentum,
                          isAboveMovingAverage(symbol: symbol, period: confirmedExcessRotation.movingAveragePeriod) else { return nil }
                    let currentWeight = max(finalWeights[symbol] ?? 0, 0)
                    let room: Double
                    if equitySymbols.contains(symbol) {
                        guard !cappedEquitySymbols.contains(symbol), currentWeight < cap else { return nil }
                        room = max(cap - currentWeight, 0)
                    } else {
                        room = max(overlay.maxTotalExposure - currentWeight, 0)
                    }
                    guard room > 0 else { return nil }
                    let volatilitySeries = rollingAnnualizedVolatility(
                        values: prices,
                        period: confirmedExcessRotation.volatilityLookbackSessions
                    )
                    let volatility = volatilitySeries.indices.contains(signalIndex) ? (volatilitySeries[signalIndex] ?? 0.20) : 0.20
                    let denominator = max(volatility, confirmedExcessRotation.volatilityFloor)
                    guard denominator > 0 else { return nil }
                    return (score: momentum / denominator, symbol: symbol, room: room)
                }
                if let winner = scoredCandidates.max(by: { lhs, rhs in lhs.score < rhs.score }) {
                    finalWeights[winner.symbol, default: 0] += min(addBudget, winner.room)
                }
            }
        }

        var goldRolloverSignal = false
        if let goldRolloverCap = overlay.goldRolloverCap,
           let longMomentum = priceMomentum(symbol: goldRolloverCap.symbol, lookback: goldRolloverCap.longMomentumLookbackSessions),
           let shortMomentum = priceMomentum(symbol: goldRolloverCap.symbol, lookback: goldRolloverCap.shortMomentumLookbackSessions),
           longMomentum > goldRolloverCap.longMomentumThreshold,
           shortMomentum < goldRolloverCap.shortMomentumThreshold {
            goldRolloverSignal = true
            let maxWeight = min(max(goldRolloverCap.maxWeight, 0), 1)
            if let originalWeight = finalWeights[goldRolloverCap.symbol], originalWeight > maxWeight {
                finalWeights[goldRolloverCap.symbol] = maxWeight
            }
        }

        if goldRolloverSignal,
           let handoff = overlay.goldRolloverConfirmedHandoff {
            let maniaVetoActive = handoff.maniaVetoSymbols.contains { symbol in
                guard let momentum = priceMomentum(symbol: symbol, lookback: handoff.maniaMomentumLookbackSessions),
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let donchianPosition = donchianRangePosition(
                        values: prices,
                        at: signalIndex,
                        period: handoff.maniaDonchianLookbackSessions
                      ) else { return false }
                return momentum > handoff.maniaMomentumThreshold
                    && donchianPosition > handoff.maniaDonchianPositionThreshold
            }

            if !maniaVetoActive {
                let candidates: [(momentum: Double, symbol: String)] = handoff.candidateSymbols.compactMap { symbol in
                    guard let momentum = priceMomentum(symbol: symbol, lookback: handoff.confirmationMomentumLookbackSessions),
                          momentum > 0,
                          isAboveMovingAverage(symbol: symbol, period: handoff.confirmationMovingAveragePeriod) else { return nil }
                    return (momentum: momentum, symbol: symbol)
                }
                if let winner = candidates.max(by: { lhs, rhs in lhs.momentum < rhs.momentum }) {
                    finalWeights[winner.symbol, default: 0] += max(handoff.replacementMaxAdd, 0)
                }
            }
        }

        if let diversificationCredit = overlay.diversificationCredit,
           !finalWeights.isEmpty,
           let goldPrices = pricesBySymbol[diversificationCredit.goldSymbol],
           goldPrices.indices.contains(signalIndex) {
            let strategyIsHealthy: Bool
            if let portfolioValues,
               portfolioValues.indices.contains(signalIndex) {
                let recentReturn = portfolioRollingReturn(
                    values: portfolioValues,
                    at: signalIndex,
                    lookback: diversificationCredit.strategyHealthLookbackSessions
                )
                let recentDrawdown = portfolioRollingDrawdown(
                    values: portfolioValues,
                    at: signalIndex,
                    lookback: diversificationCredit.strategyHealthLookbackSessions
                )
                strategyIsHealthy = (recentReturn ?? 0) >= 0
                    && (recentDrawdown ?? 0) >= -max(diversificationCredit.strategyDrawdownThreshold, 0)
            } else {
                strategyIsHealthy = true
            }

            let hasUSEquity = diversificationCredit.usEquitySymbols.contains { symbol in
                (finalWeights[symbol] ?? 0) > 0.0001
            }
            let usTrendValues = diversificationCredit.usEquitySymbols.compactMap { symbol -> Double? in
                guard let prices = pricesBySymbol[symbol] else { return nil }
                return Self.priceMomentum(values: prices, at: signalIndex, lookback: diversificationCredit.trendLookbackSessions)
            }
            let usTrend = usTrendValues.isEmpty ? nil : usTrendValues.reduce(0, +) / Double(usTrendValues.count)
            let correlation = rollingCorrelation(
                leftValues: goldPrices,
                rightValueSets: diversificationCredit.usEquitySymbols.compactMap { pricesBySymbol[$0] },
                at: signalIndex,
                lookback: diversificationCredit.correlationLookbackSessions
            )
            if strategyIsHealthy,
               hasUSEquity,
               let goldTrend = Self.priceMomentum(values: goldPrices, at: signalIndex, lookback: diversificationCredit.trendLookbackSessions),
               let goldShortReturn = Self.priceMomentum(values: goldPrices, at: signalIndex, lookback: diversificationCredit.goldShortLookbackSessions),
               let usTrend,
               let correlation,
               goldTrend > 0,
               usTrend > 0,
               goldShortReturn > diversificationCredit.goldShortReturnFloor,
               correlation < diversificationCredit.correlationCeiling {
                finalWeights[diversificationCredit.goldSymbol] = max(
                    finalWeights[diversificationCredit.goldSymbol] ?? 0,
                    min(max(diversificationCredit.goldFloor, 0), 1)
                )
            }
        }

        let totalExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
        let maxTotalExposure = min(max(overlay.maxTotalExposure, 0), 1)
        if totalExposure > maxTotalExposure, totalExposure > 0 {
            let scale = maxTotalExposure / totalExposure
            finalWeights = finalWeights.mapValues { max($0, 0) * scale }
        }

        return finalWeights.filter { $0.value > 0.0001 }
    }

    private static func normalizedWeightMap(
        _ weights: [String: Double],
        maxTotalExposure: Double = 1
    ) -> [String: Double] {
        var normalized = weights.filter { $0.value > 0.0001 }.mapValues { max($0, 0) }
        let totalExposure = normalized.reduce(0.0) { $0 + max($1.value, 0) }
        let cappedMaxTotalExposure = min(max(maxTotalExposure, 0), 1)
        if totalExposure > cappedMaxTotalExposure, totalExposure > 0 {
            let scale = cappedMaxTotalExposure / totalExposure
            normalized = normalized.mapValues { max($0, 0) * scale }
        }
        return normalized.filter { $0.value > 0.0001 }
    }

    private static func blendedWeightMap(
        _ first: [String: Double],
        _ second: [String: Double],
        firstShare: Double
    ) -> [String: Double] {
        let normalizedFirstShare = min(max(firstShare, 0), 1)
        var output: [String: Double] = [:]
        for item in first {
            output[item.key, default: 0] += max(item.value, 0) * normalizedFirstShare
        }
        for item in second {
            output[item.key, default: 0] += max(item.value, 0) * (1 - normalizedFirstShare)
        }
        return normalizedWeightMap(output)
    }

    private static func applyConfirmedEquityBreadthOverlay(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        volatilityBySymbol: [String: [Double?]],
        config: AdvancedRotationConfig
    ) -> [String: Double] {
        guard let breadth = config.confirmedEquityBreadth else {
            return normalizedWeightMap(rawWeights)
        }

        let confirmed: [(score: Double, symbol: String)] = breadth.equitySymbols.compactMap { symbol in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let shortMomentum = priceMomentum(values: prices, at: signalIndex, lookback: breadth.shortMomentumLookbackSessions),
                  let longMomentum = priceMomentum(values: prices, at: signalIndex, lookback: breadth.longMomentumLookbackSessions),
                  shortMomentum > 0,
                  longMomentum > 0,
                  let movingAverage = movingAverage(values: prices, period: breadth.movingAveragePeriod)[signalIndex],
                  prices[signalIndex] >= movingAverage else { return nil }
            let volatility = max(volatilityBySymbol[symbol]?[signalIndex] ?? 9, 0.01)
            let score = max(0, (longMomentum + 0.5 * shortMomentum) / volatility)
            guard score > 0 else { return nil }
            return (score, symbol)
        }

        guard confirmed.count >= max(breadth.minConfirmedCount, 1) else {
            return normalizedWeightMap(rawWeights, maxTotalExposure: breadth.maxTotalExposure)
        }

        var finalWeights = rawWeights
        let currentExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
        let maxTotalExposure = min(max(breadth.maxTotalExposure, 0), 1)
        let budget = max(0, maxTotalExposure - currentExposure)
        guard budget > 0 else {
            return normalizedWeightMap(finalWeights, maxTotalExposure: maxTotalExposure)
        }

        let totalScore = confirmed.reduce(0.0) { $0 + $1.score }
        guard totalScore > 0 else {
            return normalizedWeightMap(finalWeights, maxTotalExposure: maxTotalExposure)
        }

        for item in confirmed {
            finalWeights[item.symbol, default: 0] += budget * item.score / totalScore
        }
        return normalizedWeightMap(finalWeights, maxTotalExposure: maxTotalExposure)
    }

    private static func applyConfirmedAccelerationSatelliteOverlay(
        to rawWeights: [String: Double],
        signalIndex: Int,
        signalDate: Date,
        pricesBySymbol: [String: [Double]],
        config: AdvancedRotationConfig
    ) -> [String: Double] {
        guard let satellite = config.confirmedAccelerationSatellite else {
            return normalizedWeightMap(rawWeights)
        }
        guard !satellite.weakMonths.contains(Calendar.current.component(.month, from: signalDate)) else {
            return normalizedWeightMap(rawWeights)
        }

        func momentum(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return priceMomentum(values: prices, at: signalIndex, lookback: lookback)
        }

        func volatility(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return rollingAnnualizedVolatility(values: prices, period: lookback)[signalIndex] ?? nil
        }

        func drawdown(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return rollingDrawdownFromHigh(values: prices, at: signalIndex, period: lookback)
        }

        func isAboveMovingAverage(_ symbol: String, _ period: Int) -> Bool {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let movingAverage = movingAverage(values: prices, period: period)[signalIndex] else { return false }
            return prices[signalIndex] >= movingAverage
        }

        func trendConfirmed(_ symbol: String) -> Bool {
            guard let mom60 = momentum(symbol, 60) else { return false }
            return mom60 > 0 && isAboveMovingAverage(symbol, 120)
        }

        func breadthCount(_ symbols: [String]) -> Int {
            symbols.reduce(0) { $0 + (trendConfirmed($1) ? 1 : 0) }
        }

        func chinaBubbleRollover() -> Bool {
            var broken = 0
            for symbol in satellite.chinaMarketSymbols {
                guard pricesBySymbol[symbol] != nil,
                      let mom20 = momentum(symbol, 20),
                      let mom60 = momentum(symbol, 60),
                      let mom120 = momentum(symbol, 120),
                      let dd20 = drawdown(symbol, 20),
                      let dd60 = drawdown(symbol, 60),
                      let vol20 = volatility(symbol, 20),
                      let vol120 = volatility(symbol, 120) else { continue }
                let hot = mom120 > 0.32 || mom60 > 0.22
                let cracking = mom20 < -0.02 || dd20 < -0.045 || dd60 < -0.09 || !isAboveMovingAverage(symbol, 60)
                let volExpanding = vol120 > 0 && vol20 > vol120 * 1.30
                if hot && (cracking || volExpanding) {
                    broken += 1
                }
            }
            return broken >= 1
        }

        func crossMarketSupport(_ symbol: String) -> Bool {
            let usBreadth = breadthCount(satellite.usMarketSymbols)
            let chinaBreadth = breadthCount(satellite.chinaMarketSymbols)
            if symbol == "dowjones" {
                return usBreadth >= 1
            }
            if satellite.chinaExtraSymbols.contains(symbol) {
                return !chinaBubbleRollover() && chinaBreadth >= 2
            }
            return false
        }

        func assetScore(_ symbol: String) -> Double? {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let mom20 = momentum(symbol, 20),
                  let mom60 = momentum(symbol, 60),
                  let mom120 = momentum(symbol, 120),
                  let mom240 = momentum(symbol, 240),
                  let vol20 = volatility(symbol, 20),
                  let vol60 = volatility(symbol, 60),
                  let vol120 = volatility(symbol, 120),
                  let dd20 = drawdown(symbol, 20),
                  let dd60 = drawdown(symbol, 60),
                  let dd120 = drawdown(symbol, 120) else { return nil }
            guard mom60 > 0,
                  mom120 > 0,
                  isAboveMovingAverage(symbol, 120),
                  vol60 <= 0.36,
                  dd60 >= -0.10,
                  dd120 >= -0.17,
                  mom20 > 0.004,
                  mom60 >= max(0.015, mom120 * 0.20),
                  vol20 < vol60 * 0.95 || vol20 < vol120 * 0.90 else { return nil }
            if satellite.chinaExtraSymbols.contains(symbol), chinaBubbleRollover() {
                return nil
            }

            let compressionBonus = vol20 < vol60 ? 0.10 : 0
            let repairBonus = dd20 > -0.015 ? 0.05 : 0
            let hotPenalty = satellite.chinaExtraSymbols.contains(symbol) && mom120 > 0.38 && vol20 > vol60 ? 0.15 : 0
            let score = (
                mom120
                + 0.60 * mom60
                + 0.35 * mom20
                + 0.15 * max(mom240, -0.20)
                + 0.20 * max(dd60, -0.30)
            ) / max(vol60, 0.05) + compressionBonus + repairBonus - hotPenalty
            return score > 0 && prices[signalIndex] > 0 ? score : nil
        }

        let scored = satellite.extraSymbols.compactMap { symbol -> (score: Double, symbol: String)? in
            guard pricesBySymbol[symbol] != nil,
                  crossMarketSupport(symbol),
                  let score = assetScore(symbol) else { return nil }
            return (score, symbol)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
            return lhs.score > rhs.score
        }
        let selected = Array(scored.prefix(max(satellite.topCount, 1)))
        let scoreTotal = selected.reduce(0.0) { $0 + $1.score }
        var finalWeights = rawWeights
        let availableBudget = min(max(1 - finalWeights.reduce(0.0) { $0 + max($1.value, 0) }, 0), max(satellite.cap, 0))
        guard availableBudget > 0, scoreTotal > 0 else {
            return normalizedWeightMap(finalWeights)
        }

        for item in selected {
            let addition = min(max(satellite.perAssetCap, 0), availableBudget * item.score / scoreTotal)
            if addition > 0 {
                finalWeights[item.symbol, default: 0] += addition
            }
        }
        return normalizedWeightMap(finalWeights)
    }

    private static func applyProfitLockBudget(
        to rawWeights: [String: Double],
        signalIndex: Int,
        portfolioValues: [Double]?,
        config: AdvancedRotationConfig
    ) -> [String: Double] {
        guard let budget = config.profitLockBudget else {
            return normalizedWeightMap(rawWeights)
        }

        func cleanValues() -> [Double] {
            guard let portfolioValues else { return [] }
            let upperBound = min(signalIndex, portfolioValues.count - 1)
            guard upperBound >= 0 else { return [] }
            return portfolioValues[0...upperBound].filter { $0 > 0 }
        }

        let values = cleanValues()
        guard !values.isEmpty else { return normalizedWeightMap(rawWeights) }
        let lookbackValues = Array(values.suffix(max(budget.lookbackSessions, 1)))
        guard let peak = lookbackValues.max(), peak > 0 else { return normalizedWeightMap(rawWeights) }
        let drawdown = lookbackValues.last.map { $0 / peak - 1 } ?? 0
        let stress = abs(min(drawdown, 0))
        let baseScale: Double
        if stress <= budget.softDrawdown {
            baseScale = 1
        } else if stress >= budget.hardDrawdown {
            baseScale = min(max(budget.minScale, 0), 1)
        } else {
            let span = max(budget.hardDrawdown - budget.softDrawdown, 0.0001)
            let progress = (stress - budget.softDrawdown) / span
            baseScale = 1 - progress * (1 - min(max(budget.minScale, 0), 1))
        }

        let profitScale: Double
        if values.count > budget.profitLookbackSessions,
           let current = values.last {
            let previous = values[values.count - budget.profitLookbackSessions - 1]
            let recentReturn = previous > 0 ? current / previous - 1 : 0
            profitScale = recentReturn > budget.profitThreshold && drawdown > -budget.shallowDrawdownThreshold
                ? min(baseScale, min(max(budget.profitScale, 0), 1))
                : baseScale
        } else {
            profitScale = baseScale
        }
        return normalizedWeightMap(rawWeights.mapValues { $0 * min(max(profitScale, 0), 1) })
    }

    private static func applyEquityCurveStateGate(
        to rawWeights: [String: Double],
        signalIndex: Int,
        portfolioValues: [Double]?,
        config: AdvancedRotationConfig,
        state: inout AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let gate = config.equityCurveStateGate,
              let portfolioValues,
              portfolioValues.indices.contains(signalIndex),
              !rawWeights.isEmpty else {
            return normalizedWeightMap(rawWeights)
        }

        let lookbackSessions = max(gate.lookbackSessions, 1)
        let recentReturn = portfolioRollingReturn(values: portfolioValues, at: signalIndex, lookback: lookbackSessions)
        let recentDrawdown = portfolioRollingDrawdown(values: portfolioValues, at: signalIndex, lookback: lookbackSessions)

        if state.equityCurveStateGateDefensive {
            let returnRecovered = recentReturn.map { $0 > gate.exitReturnThreshold } ?? false
            let drawdownRecovered = recentDrawdown.map { $0 > -max(gate.exitDrawdownThreshold, 0) } ?? false
            if returnRecovered || drawdownRecovered {
                state.equityCurveStateGateDefensive = false
            }
        } else {
            let returnWeak = recentReturn.map { $0 < gate.enterReturnThreshold } ?? false
            let drawdownWeak = recentDrawdown.map { $0 < -max(gate.enterDrawdownThreshold, 0) } ?? false
            if returnWeak || drawdownWeak {
                state.equityCurveStateGateDefensive = true
            }
        }

        let scale = state.equityCurveStateGateDefensive
            ? min(max(gate.lowRiskScale, 0), 1)
            : 1
        return normalizedWeightMap(rawWeights.mapValues { $0 * scale })
    }

    private static func applyAssetRiskStateGate(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        portfolioValues: [Double]?,
        config: AdvancedRotationConfig,
        state: inout AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let gate = config.assetRiskStateGate,
              !rawWeights.isEmpty else {
            return normalizedWeightMap(rawWeights)
        }

        func momentum(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return priceMomentum(values: prices, at: signalIndex, lookback: lookback)
        }

        func drawdownMagnitude(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol],
                  let drawdown = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: lookback) else { return nil }
            return abs(min(drawdown, 0))
        }

        func annualizedVolatility(_ symbol: String, _ lookback: Int) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return annualizedVolatilityAt(values: prices, at: signalIndex, lookback: lookback)
        }

        func donchianPosition(_ symbol: String, _ lookback: Int) -> Double? {
            guard lookback > 1,
                  let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  signalIndex - lookback + 1 >= 0 else { return nil }
            let window = prices[(signalIndex - lookback + 1)...signalIndex]
            guard let low = window.min(),
                  let high = window.max(),
                  high > low else { return nil }
            return (prices[signalIndex] - low) / (high - low)
        }

        func chinaBubbleRollover(_ symbol: String) -> Bool {
            guard let mediumMomentum = momentum(symbol, 60),
                  let shortDrawdown = drawdownMagnitude(symbol, 20),
                  let highZone = donchianPosition(symbol, 120) else { return false }
            return mediumMomentum > 0.30 && shortDrawdown > 0.06 && highZone > 0.80
        }

        func maxAvailable(_ values: [Double?]) -> Double? {
            let compact = values.compactMap { $0 }
            return compact.isEmpty ? nil : compact.max()
        }

        var guardedWeights = rawWeights
        for symbol in ["csi300", "shanghai_composite"] where chinaBubbleRollover(symbol) {
            guardedWeights[symbol] = 0
        }

        let usMomentum = maxAvailable([
            momentum("nasdaq", gate.usMomentumLookbackSessions),
            momentum("sp500", gate.usMomentumLookbackSessions)
        ])
        let usDrawdown = maxAvailable([
            drawdownMagnitude("nasdaq", gate.usDrawdownLookbackSessions),
            drawdownMagnitude("sp500", gate.usDrawdownLookbackSessions)
        ])
        let usVolatility = maxAvailable([
            annualizedVolatility("nasdaq", gate.usVolatilityLookbackSessions),
            annualizedVolatility("sp500", gate.usVolatilityLookbackSessions)
        ])
        let goldReturn = momentum("gold_cny", gate.goldRelativeLookbackSessions)
        let goldRelative = maxAvailable([
            momentum("nasdaq", gate.goldRelativeLookbackSessions).flatMap { usReturn in
                goldReturn.map { $0 - usReturn }
            },
            momentum("sp500", gate.goldRelativeLookbackSessions).flatMap { usReturn in
                goldReturn.map { $0 - usReturn }
            }
        ])
        let chinaDrawdown = maxAvailable([
            drawdownMagnitude("csi300", gate.chinaDrawdownLookbackSessions),
            drawdownMagnitude("shanghai_composite", gate.chinaDrawdownLookbackSessions)
        ])
        let portfolioDrawdown = portfolioValues.flatMap {
            portfolioRollingDrawdown(values: $0, at: signalIndex, lookback: gate.portfolioDrawdownLookbackSessions)
        }.map { abs(min($0, 0)) }

        var signalCount = 0
        signalCount += (usMomentum.map { $0 < gate.usMomentumThreshold } ?? false) ? 1 : 0
        signalCount += (usDrawdown.map { $0 > gate.usDrawdownThreshold } ?? false) ? 1 : 0
        signalCount += (usVolatility.map { $0 > gate.usVolatilityThreshold } ?? false) ? 1 : 0
        signalCount += (goldRelative.map { $0 > gate.goldRelativeThreshold } ?? false) ? 1 : 0
        signalCount += (chinaDrawdown.map { $0 > gate.chinaDrawdownThreshold } ?? false) ? 1 : 0
        signalCount += (portfolioDrawdown.map { $0 > gate.portfolioDrawdownThreshold } ?? false) ? 1 : 0

        if signalCount >= max(gate.requiredSignalCount, 1) {
            state.assetRiskDefensiveUntilIndex = max(
                state.assetRiskDefensiveUntilIndex,
                signalIndex + max(gate.cooldownSessions, 0)
            )
            state.assetRiskRecoveryUntilIndex = max(
                state.assetRiskRecoveryUntilIndex,
                state.assetRiskDefensiveUntilIndex + max(gate.recoverySessions, 0)
            )
        }

        let scale: Double
        if signalIndex <= state.assetRiskDefensiveUntilIndex {
            scale = gate.defensiveScale
        } else if signalIndex <= state.assetRiskRecoveryUntilIndex {
            scale = gate.recoveryScale
        } else {
            scale = gate.normalScale
        }
        return normalizedWeightMap(guardedWeights.mapValues { $0 * min(max(scale, 0), 1) })
    }

    private static func overlayTotalWeight(_ weights: [String: Double]) -> Double {
        weights.reduce(0.0) { $0 + max($1.value, 0) }
    }

    private static func movingAverageAt(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index - period + 1 >= 0 else { return nil }
        let window = values[(index - period + 1)...index]
        guard window.allSatisfy({ $0 > 0 }) else { return nil }
        return window.reduce(0, +) / Double(period)
    }

    private static func annualizedVolatilityAt(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 1,
              values.indices.contains(index),
              index - lookback + 1 >= 1 else { return nil }
        let startIndex = index - lookback + 1
        var returns: [Double] = []
        returns.reserveCapacity(lookback)
        for cursor in startIndex...index {
            let previous = values[cursor - 1]
            let current = values[cursor]
            guard previous > 0, current > 0 else { return nil }
            returns.append(log(current / previous))
        }
        guard returns.count > 1 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(returns.count - 1, 1))
        return sqrt(max(variance, 0)) * sqrt(252)
    }

    private static func rollingLowRebound(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index),
              index - lookback + 1 >= 0 else { return nil }
        let window = values[(index - lookback + 1)...index].filter { $0 > 0 }
        guard let low = window.min(), low > 0 else { return nil }
        return values[index] / low - 1
    }

    private static func addOverlayWeights(_ overlays: [[String: Double]], to base: [String: Double]) -> [String: Double] {
        var output = base
        for overlay in overlays {
            for item in overlay {
                output[item.key, default: 0] += max(item.value, 0)
            }
        }
        return output
    }

    private static func repairEquityBreadthOK(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Bool {
        var checked = 0
        var healthy = 0
        for symbol in ["nasdaq", "sp500", "csi300", "shanghai_composite"] {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let ma60 = movingAverageAt(values: prices, at: signalIndex, period: 60),
                  let momentum20 = priceMomentum(values: prices, at: signalIndex, lookback: 20) else { continue }
            checked += 1
            if prices[signalIndex] > ma60 && momentum20 > -0.02 {
                healthy += 1
            }
        }
        return checked >= 3 && healthy >= 2
    }

    private static func repairScore(
        symbol: String,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        stack: AdvancedRotationGlobalRepairStack
    ) -> Double? {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(signalIndex),
              prices[signalIndex] > 0,
              let drawdown = rollingDrawdownFromHigh(
                values: prices,
                at: signalIndex,
                period: stack.repairDrawdownLookbackSessions
              ),
              let rebound = rollingLowRebound(
                values: prices,
                at: signalIndex,
                lookback: stack.repairReboundLookbackSessions
              ),
              let momentum = priceMomentum(
                values: prices,
                at: signalIndex,
                lookback: stack.repairMomentumLookbackSessions
              ),
              let fastMomentum = priceMomentum(values: prices, at: signalIndex, lookback: 10),
              let confirmationMA = movingAverageAt(
                values: prices,
                at: signalIndex,
                period: stack.repairConfirmationMAPeriod
              ),
              let ma20 = movingAverageAt(values: prices, at: signalIndex, period: 20) else { return nil }
        guard drawdown <= -max(stack.repairDrawdownThreshold, 0),
              rebound >= max(stack.repairReboundThreshold, 0),
              prices[signalIndex] >= confirmationMA,
              prices[signalIndex] >= ma20,
              momentum >= 0,
              fastMomentum >= 0 else { return nil }

        let equitySymbols: Set<String> = ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext"]
        if equitySymbols.contains(symbol), !repairEquityBreadthOK(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex) {
            return nil
        }
        if symbol == "gold_cny",
           let ma120 = movingAverageAt(values: prices, at: signalIndex, period: 120),
           prices[signalIndex] < ma120 * 0.96 {
            return nil
        }

        let volatility = annualizedVolatilityAt(values: prices, at: signalIndex, lookback: 60) ?? 9.0
        let score = max(0, rebound * 1.2 + momentum * 0.8 + fastMomentum * 0.5 + max(drawdown, -0.60) * 0.20) / max(volatility, 0.03)
        return score > 0 ? score : nil
    }

    private static func repairTargets(
        stack: AdvancedRotationGlobalRepairStack,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        budget: Double,
        activeRepairSymbols: Set<String>
    ) -> [String: Double] {
        guard signalIndex >= 0, budget > 0 else { return [:] }
        let scored = stack.repairSymbols.compactMap { symbol -> (score: Double, symbol: String)? in
            guard !stack.globalSymbols.contains(symbol),
                  let score = repairScore(
                    symbol: symbol,
                    pricesBySymbol: pricesBySymbol,
                    signalIndex: signalIndex,
                    stack: stack
                  ) else { return nil }
            return (score, symbol)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
            return lhs.score > rhs.score
        }
        let selected = Array(scored.prefix(max(stack.repairTopCount, 1)))
        let scoreTotal = selected.reduce(0.0) { $0 + $1.score }
        guard scoreTotal > 0 else { return [:] }
        var output: [String: Double] = [:]
        for item in selected {
            output[item.symbol] = min(max(stack.repairPerAssetCap, 0), budget * item.score / scoreTotal)
        }
        return normalizedWeightMap(output, maxTotalExposure: budget)
    }

    private static func globalBreadthOK(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Bool {
        var checked = 0
        var healthy = 0
        for symbol in ["nasdaq", "sp500", "hsi", "csi300", "shanghai_composite"] {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let ma60 = movingAverageAt(values: prices, at: signalIndex, period: 60),
                  let momentum20 = priceMomentum(values: prices, at: signalIndex, lookback: 20) else { continue }
            checked += 1
            if prices[signalIndex] > ma60 && momentum20 > -0.025 {
                healthy += 1
            }
        }
        return checked >= 4 && healthy >= 3
    }

    private static func globalRepairScore(
        symbol: String,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Double? {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(signalIndex),
              prices[signalIndex] > 0,
              let drawdown = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: 120),
              let rebound = rollingLowRebound(values: prices, at: signalIndex, lookback: 30),
              let momentum20 = priceMomentum(values: prices, at: signalIndex, lookback: 20),
              let momentum60 = priceMomentum(values: prices, at: signalIndex, lookback: 60),
              let ma20 = movingAverageAt(values: prices, at: signalIndex, period: 20),
              let ma40 = movingAverageAt(values: prices, at: signalIndex, period: 40) else { return nil }
        guard drawdown <= -0.10,
              rebound >= 0.055,
              prices[signalIndex] >= ma20,
              prices[signalIndex] >= ma40,
              momentum20 >= 0,
              momentum60 >= -0.02,
              globalBreadthOK(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex) else { return nil }
        let volatility = annualizedVolatilityAt(values: prices, at: signalIndex, lookback: 60) ?? 9.0
        let score = max(0, rebound * 1.3 + momentum20 * 0.5 + momentum60 * 0.45 + max(drawdown, -0.50) * 0.15) / max(volatility, 0.04)
        return score > 0 ? score : nil
    }

    private static func globalRepairTargets(
        stack: AdvancedRotationGlobalRepairStack,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        budget: Double
    ) -> [String: Double] {
        guard signalIndex >= 0, budget > 0 else { return [:] }
        let scored = stack.globalSymbols.compactMap { symbol -> (score: Double, symbol: String)? in
            guard let score = globalRepairScore(
                symbol: symbol,
                pricesBySymbol: pricesBySymbol,
                signalIndex: signalIndex
            ) else { return nil }
            return (score, symbol)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
            return lhs.score > rhs.score
        }
        let selected = Array(scored.prefix(max(stack.globalTopCount, 1)))
        let scoreTotal = selected.reduce(0.0) { $0 + $1.score }
        guard scoreTotal > 0 else { return [:] }
        var output: [String: Double] = [:]
        for item in selected {
            output[item.symbol] = min(max(stack.globalPerAssetCap, 0), budget * item.score / scoreTotal)
        }
        return normalizedWeightMap(output, maxTotalExposure: budget)
    }

    private static func updatePhaseLocks(
        stack: AdvancedRotationGlobalRepairStack,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        state: inout AdvancedRotationOverlayState
    ) {
        guard signalIndex >= 0,
              let prices = pricesBySymbol["gold_cny"],
              prices.indices.contains(signalIndex) else { return }

        if let lockStart = state.phaseLockedStartIndexBySymbol["gold_cny"] {
            let momentum20 = priceMomentum(values: prices, at: signalIndex, lookback: 20)
            let ma40 = movingAverageAt(values: prices, at: signalIndex, period: 40)
            if (signalIndex - lockStart >= stack.phaseMaxLockSessions && (momentum20 ?? -1) > 0)
                || (ma40 != nil && prices[signalIndex] > ma40! && (momentum20 ?? -1) > 0.025) {
                state.phaseLockedStartIndexBySymbol["gold_cny"] = nil
            }
            return
        }

        guard let hotReturn = priceMomentum(values: prices, at: signalIndex, lookback: stack.phaseHotLookbackSessions),
              let crackReturn = priceMomentum(values: prices, at: signalIndex, lookback: stack.phaseCrackLookbackSessions),
              let drawdown = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: stack.phaseHotLookbackSessions),
              let ma20 = movingAverageAt(values: prices, at: signalIndex, period: 20),
              let ma40 = movingAverageAt(values: prices, at: signalIndex, period: 40),
              let ma120 = movingAverageAt(values: prices, at: signalIndex, period: 120) else { return }
        let hot = hotReturn >= stack.phaseHotThreshold || prices[signalIndex] > ma120 * (1 + stack.phaseHotThreshold * 0.45)
        let rollover = crackReturn <= stack.phaseCrackThreshold || drawdown <= -max(stack.phaseRolloverDrawdown, 0)
        let broken = prices[signalIndex] < ma20 || prices[signalIndex] < ma40
        if hot && rollover && broken {
            state.phaseLockedStartIndexBySymbol["gold_cny"] = signalIndex
        }
    }

    private static func applyPhaseLocks(
        to rawWeights: [String: Double],
        stack: AdvancedRotationGlobalRepairStack,
        state: AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard !state.phaseLockedStartIndexBySymbol.isEmpty else { return normalizedWeightMap(rawWeights) }
        var output = rawWeights
        let scale = min(max(stack.phaseLockScale, 0), 1)
        for symbol in state.phaseLockedStartIndexBySymbol.keys {
            if let weight = output[symbol], weight > 0 {
                output[symbol] = weight * scale
            }
        }
        return normalizedWeightMap(output)
    }

    private static func contagionGlobalBreadth(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        symbols: [String]
    ) -> (checked: Int, healthy: Int) {
        var checked = 0
        var healthy = 0
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let ma60 = movingAverageAt(values: prices, at: signalIndex, period: 60),
                  let momentum20 = priceMomentum(values: prices, at: signalIndex, lookback: 20) else { continue }
            checked += 1
            if prices[signalIndex] > ma60 && momentum20 > -0.015 {
                healthy += 1
            }
        }
        return (checked, healthy)
    }

    private static func bubbleRolloverSymbol(
        _ symbol: String,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Bool {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(signalIndex),
              prices[signalIndex] > 0,
              let momentum20 = priceMomentum(values: prices, at: signalIndex, lookback: 20),
              let momentum60 = priceMomentum(values: prices, at: signalIndex, lookback: 60),
              let momentum120 = priceMomentum(values: prices, at: signalIndex, lookback: 120),
              let drawdown20 = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: 20),
              let drawdown60 = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: 60),
              let ma40 = movingAverageAt(values: prices, at: signalIndex, period: 40),
              let ma120 = movingAverageAt(values: prices, at: signalIndex, period: 120) else { return false }
        let hot = momentum120 > 0.30 || momentum60 > 0.18 || prices[signalIndex] > ma120 * 1.18
        let rollover = momentum20 < -0.025 || drawdown20 < -0.055 || drawdown60 < -0.10 || prices[signalIndex] < ma40
        return hot && rollover
    }

    private static func weakContagionSymbol(
        _ symbol: String,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Bool {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(signalIndex),
              prices[signalIndex] > 0,
              let ma60 = movingAverageAt(values: prices, at: signalIndex, period: 60),
              let momentum20 = priceMomentum(values: prices, at: signalIndex, lookback: 20),
              let momentum60 = priceMomentum(values: prices, at: signalIndex, lookback: 60),
              let drawdown60 = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: 60) else { return false }
        return prices[signalIndex] < ma60 || momentum20 < -0.035 || momentum60 < -0.055 || drawdown60 < -0.105
    }

    private static func contagionTriggered(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        control: AdvancedRotationContagionControl
    ) -> Bool {
        let bubbleCount = control.chinaHkSymbols.filter {
            bubbleRolloverSymbol($0, pricesBySymbol: pricesBySymbol, signalIndex: signalIndex)
        }.count
        let weakCount = control.chinaHkSymbols.filter {
            weakContagionSymbol($0, pricesBySymbol: pricesBySymbol, signalIndex: signalIndex)
        }.count
        let breadth = contagionGlobalBreadth(
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            symbols: control.globalCheckSymbols
        )
        let globalWeak = breadth.checked >= 5 && breadth.healthy <= 2
        switch control.triggerMode {
        case "bubble_only":
            return bubbleCount >= 1
        case "bubble_or_breadth":
            return bubbleCount >= 1 || (weakCount >= 2 && globalWeak)
        case "cluster":
            return bubbleCount >= 1 && (weakCount >= 2 || globalWeak)
        default:
            return false
        }
    }

    private static func contagionReleaseOK(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        control: AdvancedRotationContagionControl
    ) -> Bool {
        guard control.releaseMode != "time_only" else { return false }
        let usGood = ["nasdaq", "sp500"].reduce(0) { partial, symbol in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let ma60 = movingAverageAt(values: prices, at: signalIndex, period: 60),
                  let momentum20 = priceMomentum(values: prices, at: signalIndex, lookback: 20),
                  let momentum60 = priceMomentum(values: prices, at: signalIndex, lookback: 60),
                  prices[signalIndex] > ma60,
                  momentum20 > 0,
                  momentum60 > -0.01 else { return partial }
            return partial + 1
        }
        if control.releaseMode == "us_repair" {
            return usGood >= 2
        }
        let breadth = contagionGlobalBreadth(
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            symbols: control.globalCheckSymbols
        )
        return usGood >= 2 && breadth.checked >= 5 && breadth.healthy >= 4
    }

    private static func goldTrendOK(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> Bool {
        guard let prices = pricesBySymbol["gold_cny"],
              prices.indices.contains(signalIndex),
              let ma60 = movingAverageAt(values: prices, at: signalIndex, period: 60),
              let ma120 = movingAverageAt(values: prices, at: signalIndex, period: 120),
              let momentum20 = priceMomentum(values: prices, at: signalIndex, lookback: 20) else { return false }
        return prices[signalIndex] > ma60 && prices[signalIndex] > ma120 && momentum20 > -0.02
    }

    private static func applyContagionControl(
        to rawWeights: [String: Double],
        stack: AdvancedRotationGlobalRepairStack,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        state: inout AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let control = stack.contagion,
              signalIndex >= 0 else { return normalizedWeightMap(rawWeights) }
        if contagionTriggered(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex, control: control) {
            state.contagionUntilIndex = max(state.contagionUntilIndex, signalIndex + control.cooldownSessions)
        }
        var active = state.contagionUntilIndex >= signalIndex
        if active && contagionReleaseOK(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex, control: control) {
            active = false
            state.contagionUntilIndex = signalIndex - 1
        }
        guard active else { return normalizedWeightMap(rawWeights) }

        let equitySymbols: Set<String> = [
            "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite",
            "shenzhen_component", "chinext", "hsi",
        ]
        let globalSymbols = Set(stack.globalSymbols)
        var output = rawWeights
        var removed = 0.0
        for symbol in Array(output.keys) {
            guard equitySymbols.contains(symbol) else { continue }
            let scale = globalSymbols.contains(symbol) ? control.globalOverlayScale : control.equityScale
            let oldWeight = max(output[symbol] ?? 0, 0)
            let newWeight = oldWeight * min(max(scale, 0), 1)
            output[symbol] = newWeight
            removed += max(oldWeight - newWeight, 0)
        }
        if removed > 0,
           control.redeployGoldRatio > 0,
           goldTrendOK(pricesBySymbol: pricesBySymbol, signalIndex: signalIndex) {
            output["gold_cny", default: 0] += removed * min(max(control.redeployGoldRatio, 0), 1)
        }
        return normalizedWeightMap(output)
    }

    private static func applyGlobalRepairStack(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: AdvancedRotationConfig,
        state: inout AdvancedRotationOverlayState,
        refreshRepairOverlay: Bool
    ) -> [String: Double] {
        guard let stack = config.globalRepairStack else {
            return normalizedWeightMap(rawWeights)
        }

        if refreshRepairOverlay {
            let repairBudget = min(max(stack.repairOverlayCap, 0), max(0, 1 - overlayTotalWeight(rawWeights)))
            state.repairOverlay = repairTargets(
                stack: stack,
                pricesBySymbol: pricesBySymbol,
                signalIndex: signalIndex,
                budget: repairBudget,
                activeRepairSymbols: Set(state.repairOverlay.keys)
            )
            let globalBudget = min(
                max(stack.globalOverlayCap, 0),
                max(0, 1 - overlayTotalWeight(rawWeights) - overlayTotalWeight(state.repairOverlay))
            )
            state.globalOverlay = globalRepairTargets(
                stack: stack,
                pricesBySymbol: pricesBySymbol,
                signalIndex: signalIndex,
                budget: globalBudget
            )
        }

        updatePhaseLocks(
            stack: stack,
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            state: &state
        )
        var output = addOverlayWeights(
            [state.repairOverlay, state.globalOverlay],
            to: rawWeights
        )
        output = applyPhaseLocks(to: output, stack: stack, state: state)
        output = applyContagionControl(
            to: output,
            stack: stack,
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            state: &state
        )
        return normalizedWeightMap(output)
    }

    private static func globalRiskOffForCurrency(
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        config: AdvancedRotationConfig
    ) -> Bool {
        let symbols = config.globalRepairStack?.contagion?.globalCheckSymbols
            ?? ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "hsi"]
        let breadth = contagionGlobalBreadth(
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            symbols: symbols
        )
        return breadth.checked >= 5 && breadth.healthy <= 2
    }

    private static func usdCashOK(
        selector: AdvancedRotationCurrencyCashSelector,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        config: AdvancedRotationConfig,
        state: AdvancedRotationOverlayState
    ) -> Bool {
        guard signalIndex >= 0,
              let prices = pricesBySymbol[selector.symbol],
              prices.indices.contains(signalIndex),
              let momentum = priceMomentum(values: prices, at: signalIndex, lookback: selector.lookbackSessions),
              let movingAverage = movingAverageAt(values: prices, at: signalIndex, period: selector.movingAveragePeriod) else { return false }
        let trendOK = momentum > 0 && prices[signalIndex] >= movingAverage
        let hurdle = 0.0035 * Double(selector.lookbackSessions) / 252 * selector.cnyCashHurdleScale
        let hurdleOK = momentum > hurdle
        let contagionActive = state.contagionUntilIndex >= signalIndex
        let riskOff = globalRiskOffForCurrency(
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex,
            config: config
        )
        switch selector.mode {
        case "idle_trend":
            return trendOK
        case "idle_hurdle":
            return trendOK && hurdleOK
        case "riskoff_trend":
            return trendOK && riskOff
        case "contagion_trend":
            return trendOK && contagionActive
        case "riskoff_or_contagion":
            return trendOK && (riskOff || contagionActive)
        default:
            return false
        }
    }

    private static func applyCurrencyCashSelector(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: AdvancedRotationConfig,
        state: AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let selector = config.currencyCashSelector else {
            return normalizedWeightMap(rawWeights)
        }
        var output = rawWeights
        let leftover = max(0, 1 - overlayTotalWeight(output))
        guard leftover > 0.0001,
              usdCashOK(
                selector: selector,
                pricesBySymbol: pricesBySymbol,
                signalIndex: signalIndex,
                config: config,
                state: state
              ) else { return normalizedWeightMap(output) }
        output[selector.symbol, default: 0] += min(leftover, max(selector.cap, 0))
        return normalizedWeightMap(output)
    }

    private static func goldPanicOverheated(
        prices: [Double],
        signalIndex: Int,
        lock: AdvancedRotationGoldPanicLock
    ) -> Bool {
        guard let momentum = priceMomentum(values: prices, at: signalIndex, lookback: lock.hotLookbackSessions),
              let longMA = movingAverageAt(
                values: prices,
                at: signalIndex,
                period: max(80, lock.hotLookbackSessions * 2)
              ) else { return false }
        return momentum > lock.hotThreshold && prices[signalIndex] > longMA * 1.06
    }

    private static func goldPanicCracked(
        prices: [Double],
        signalIndex: Int,
        lock: AdvancedRotationGoldPanicLock
    ) -> Bool {
        guard let momentum = priceMomentum(values: prices, at: signalIndex, lookback: lock.crackLookbackSessions),
              let movingAverage = movingAverageAt(values: prices, at: signalIndex, period: lock.movingAveragePeriod),
              let drawdown = rollingDrawdownFromHigh(
                values: prices,
                at: signalIndex,
                period: max(lock.crackLookbackSessions, 10)
              ) else { return false }
        return momentum < lock.crackThreshold || prices[signalIndex] < movingAverage || drawdown < lock.crackThreshold * 1.4
    }

    private static func goldPanicReleaseOK(
        prices: [Double],
        signalIndex: Int,
        lock: AdvancedRotationGoldPanicLock
    ) -> Bool {
        guard lock.releaseMode != "time_only",
              let movingAverage = movingAverageAt(values: prices, at: signalIndex, period: lock.movingAveragePeriod),
              let momentum = priceMomentum(
                values: prices,
                at: signalIndex,
                lookback: max(5, lock.crackLookbackSessions)
              ) else { return false }
        if lock.releaseMode == "ma_reclaim" {
            return prices[signalIndex] > movingAverage && momentum > 0
        }
        if lock.releaseMode == "calm_reclaim" {
            let drawdown = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: 20)
            return prices[signalIndex] > movingAverage && momentum > -0.005 && (drawdown == nil || drawdown! > -0.03)
        }
        return false
    }

    private static func applyGoldPanicLock(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: AdvancedRotationConfig,
        state: inout AdvancedRotationOverlayState
    ) -> [String: Double] {
        guard let lock = config.goldPanicLock,
              signalIndex >= 0,
              (rawWeights[lock.symbol] ?? 0) > 0,
              let prices = pricesBySymbol[lock.symbol],
              prices.indices.contains(signalIndex) else { return normalizedWeightMap(rawWeights) }

        if goldPanicOverheated(prices: prices, signalIndex: signalIndex, lock: lock) {
            state.goldPanicArmed = true
        }
        if state.goldPanicArmed && goldPanicCracked(prices: prices, signalIndex: signalIndex, lock: lock) {
            state.goldPanicUntilIndex = max(state.goldPanicUntilIndex, signalIndex + lock.cooldownSessions)
            state.goldPanicArmed = false
        }

        var active = state.goldPanicUntilIndex >= signalIndex
        if active && goldPanicReleaseOK(prices: prices, signalIndex: signalIndex, lock: lock) {
            active = false
            state.goldPanicUntilIndex = signalIndex - 1
        }
        guard active else { return normalizedWeightMap(rawWeights) }

        var output = rawWeights
        output[lock.symbol] = max(output[lock.symbol] ?? 0, 0) * min(max(lock.scale, 0), 1)
        return normalizedWeightMap(output)
    }

    private static func targetRiskQuality(
        weights: [String: Double],
        governor: AdvancedRotationRiskEfficiencyGovernor,
        pricesBySymbol: [String: [Double]],
        signalIndex: Int
    ) -> (expectedVolatility: Double?, quality: Double, checked: Int, healthy: Int) {
        var weightedVariance = 0.0
        var weightedMomentum = 0.0
        var momentumWeight = 0.0
        var checked = 0
        var healthy = 0
        for item in weights {
            let symbol = item.key
            let weight = max(item.value, 0)
            guard symbol != "usd_cash",
                  weight > 0,
                  let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { continue }
            if let volatility = annualizedVolatilityAt(
                values: prices,
                at: signalIndex,
                lookback: governor.volatilityLookbackSessions
            ) {
                weightedVariance += pow(weight * volatility, 2)
            }
            if let momentum = priceMomentum(
                values: prices,
                at: signalIndex,
                lookback: governor.momentumLookbackSessions
            ) {
                weightedMomentum += weight * momentum
                momentumWeight += weight
            }
            if let ma60 = movingAverageAt(values: prices, at: signalIndex, period: 60),
               let momentum20 = priceMomentum(values: prices, at: signalIndex, lookback: 20) {
                checked += 1
                if prices[signalIndex] > ma60 && momentum20 > -0.015 {
                    healthy += 1
                }
            }
        }
        let expectedVolatility = weightedVariance > 0 ? sqrt(weightedVariance) : nil
        let quality = momentumWeight > 0 ? weightedMomentum / momentumWeight : 0
        return (expectedVolatility, quality, checked, healthy)
    }

    private static func applyRiskEfficiencyGovernor(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: AdvancedRotationConfig
    ) -> [String: Double] {
        guard let governor = config.riskEfficiencyGovernor,
              signalIndex >= 0 else { return normalizedWeightMap(rawWeights) }
        let risk = targetRiskQuality(
            weights: rawWeights,
            governor: governor,
            pricesBySymbol: pricesBySymbol,
            signalIndex: signalIndex
        )
        guard let expectedVolatility = risk.expectedVolatility,
              expectedVolatility > governor.triggerVolatility else { return normalizedWeightMap(rawWeights) }
        let shouldScale: Bool
        switch governor.mode {
        case "weak_momentum":
            shouldScale = risk.quality < governor.momentumThreshold
        case "weak_breadth":
            shouldScale = risk.checked >= 4 && risk.healthy <= max(1, risk.checked / 2)
        case "inefficient":
            shouldScale = risk.quality < governor.momentumThreshold
                || (risk.checked >= 4 && risk.healthy <= max(1, risk.checked / 2))
        default:
            shouldScale = false
        }
        guard shouldScale else { return normalizedWeightMap(rawWeights) }
        let scale = min(1, governor.targetVolatility / max(expectedVolatility, 0.001))
        guard scale < 0.995 else { return normalizedWeightMap(rawWeights) }
        var output = rawWeights
        for symbol in Array(output.keys) where symbol != "usd_cash" {
            output[symbol] = max(output[symbol] ?? 0, 0) * scale
        }
        return normalizedWeightMap(output)
    }

    private static func applyCanaryRiskBrake(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: AdvancedRotationConfig
    ) -> [String: Double] {
        guard let brake = config.canaryRiskBrake,
              !rawWeights.isEmpty,
              signalIndex >= 0 else {
            return normalizedWeightMap(rawWeights)
        }

        func isWeak(_ symbol: String) -> Bool {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let momentum = multiPeriodMomentum(
                    values: prices,
                    at: signalIndex,
                    lookbacks: brake.momentumLookbacks,
                    weights: brake.momentumWeights
                  ),
                  let movingAverage = movingAverageAt(values: prices, at: signalIndex, period: brake.movingAveragePeriod) else {
                return true
            }
            return momentum < brake.momentumThreshold || prices[signalIndex] < movingAverage
        }

        let checkedSymbols = brake.symbols.filter { pricesBySymbol[$0]?.indices.contains(signalIndex) == true }
        guard !checkedSymbols.isEmpty else { return normalizedWeightMap(rawWeights) }
        let weakCount = checkedSymbols.reduce(0) { $0 + (isWeak($1) ? 1 : 0) }
        guard weakCount > max(brake.weakAllowed, 0) else { return normalizedWeightMap(rawWeights) }

        let scale = min(max(brake.scale, 0), 1)
        var output = rawWeights
        var removedWeight = 0.0
        for symbol in Array(output.keys) where symbol != "usd_cash" {
            let originalWeight = max(output[symbol] ?? 0, 0)
            let scaledWeight = originalWeight * scale
            output[symbol] = scaledWeight
            removedWeight += max(originalWeight - scaledWeight, 0)
        }

        if removedWeight > 0,
           brake.redeployGoldRatio > 0,
           !isWeak("gold_cny"),
           rawWeights["gold_cny", default: 0] < 0.95 {
            output["gold_cny", default: 0] += removedWeight * min(max(brake.redeployGoldRatio, 0), 1)
        }

        return normalizedWeightMap(output)
    }

    private static func applyAdvancedOverlayStack(
        to rawWeights: [String: Double],
        signalIndex: Int,
        pricesBySymbol: [String: [Double]],
        config: AdvancedRotationConfig,
        state: inout AdvancedRotationOverlayState,
        refreshRepairOverlay: Bool,
        portfolioValues: [Double]? = nil
    ) -> [String: Double] {
        var weights = applyGlobalRepairStack(
            to: rawWeights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            config: config,
            state: &state,
            refreshRepairOverlay: refreshRepairOverlay
        )
        weights = applyGoldPanicLock(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            config: config,
            state: &state
        )
        weights = applyRiskEfficiencyGovernor(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            config: config
        )
        weights = applyCanaryRiskBrake(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            config: config
        )
        weights = applyEquityCurveStateGate(
            to: weights,
            signalIndex: signalIndex,
            portfolioValues: portfolioValues,
            config: config,
            state: &state
        )
        weights = applyAssetRiskStateGate(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            portfolioValues: portfolioValues,
            config: config,
            state: &state
        )
        weights = applyCurrencyCashSelector(
            to: weights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            config: config,
            state: state
        )
        return normalizedWeightMap(weights)
    }

    private static func applyPostTargetOverlays(
        to rawWeights: [String: Double],
        signalIndex: Int,
        signalDate: Date,
        pricesBySymbol: [String: [Double]],
        volatilityBySymbol: [String: [Double?]],
        portfolioValues: [Double]?,
        config: AdvancedRotationConfig
    ) -> [String: Double] {
        var weights = applyConfirmedEquityBreadthOverlay(
            to: rawWeights,
            signalIndex: signalIndex,
            pricesBySymbol: pricesBySymbol,
            volatilityBySymbol: volatilityBySymbol,
            config: config
        )
        weights = applyConfirmedAccelerationSatelliteOverlay(
            to: weights,
            signalIndex: signalIndex,
            signalDate: signalDate,
            pricesBySymbol: pricesBySymbol,
            config: config
        )
        weights = applyProfitLockBudget(
            to: weights,
            signalIndex: signalIndex,
            portfolioValues: portfolioValues,
            config: config
        )
        return normalizedWeightMap(weights)
    }

    private static func targetWeightItems(
        from weights: [String: Double],
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        volatilityBySymbol: [String: [Double?]],
        signalIndex: Int,
        config: AdvancedRotationConfig
    ) -> [AdvancedRotationTargetWeight] {
        weights.compactMap { item -> AdvancedRotationTargetWeight? in
            let symbol = item.key
            guard item.value > 0.0001,
                  symbols.contains(symbol),
                  !config.signalOnlySymbols.contains(symbol),
                  let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { return nil }
            return AdvancedRotationTargetWeight(
                symbol: symbol,
                weight: item.value,
                momentum: priceMomentum(values: prices, at: signalIndex, lookback: config.lookbackSessions) ?? 0,
                annualizedVolatility: volatilityBySymbol[symbol]?[signalIndex] ?? nil
            )
        }
    }

    private static func resolvedAdvancedRotationTargetWeights(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        signalIndex: Int,
        signalDate: Date,
        traceIndex: Int,
        config: AdvancedRotationConfig,
        metaTracesByMode: [AdvancedBacktestStrategyMode: AdvancedRotationSimulatedTrace]? = nil,
        engineRouterTracesByMode: [AdvancedBacktestStrategyMode: AdvancedRotationSimulatedTrace]? = nil,
        portfolioValues: [Double]? = nil
    ) -> [String: Double] {
        if let engineRouter = config.engineRouter,
           let engineRouterTracesByMode,
           let routerWeights = engineRouterTargetWeights(
            engineRouter: engineRouter,
            signalIndex: signalIndex,
            weightIndex: traceIndex,
            tracesByMode: engineRouterTracesByMode
           ) {
            return applyPostTargetOverlays(
                to: routerWeights,
                signalIndex: signalIndex,
                signalDate: signalDate,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                portfolioValues: portfolioValues,
                config: config
            )
            .filter { !config.signalOnlySymbols.contains($0.key) }
        }

        let baseWeights: [String: Double]
        if let metaSwitch = config.metaSwitch,
           let metaTracesByMode,
           let rawMetaWeights = metaRotationTargetWeights(
            metaSwitch: metaSwitch,
            stressIndex: signalIndex,
            weightIndex: traceIndex,
            tracesByMode: metaTracesByMode
           ) {
            baseWeights = applyGoldSatelliteOverlay(
                to: rawMetaWeights,
                signalIndex: signalIndex,
                signalDate: signalDate,
                pricesBySymbol: pricesBySymbol,
                portfolioValues: portfolioValues,
                config: config
            )
        } else {
            baseWeights = Dictionary(uniqueKeysWithValues: advancedRotationTargetWeights(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                signalDate: signalDate,
                config: config
            ).map { ($0.symbol, $0.weight) })
        }

        return applyPostTargetOverlays(
            to: baseWeights,
            signalIndex: signalIndex,
            signalDate: signalDate,
            pricesBySymbol: pricesBySymbol,
            volatilityBySymbol: volatilityBySymbol,
            portfolioValues: portfolioValues,
            config: config
        )
        .filter { !config.signalOnlySymbols.contains($0.key) }
    }

    private static func engineRouterTargetWeights(
        engineRouter: AdvancedRotationEngineRouter,
        signalIndex: Int,
        weightIndex: Int,
        tracesByMode: [AdvancedBacktestStrategyMode: AdvancedRotationSimulatedTrace]
    ) -> [String: Double]? {
        guard let currentTrace = tracesByMode[engineRouter.currentMode],
              let offensiveTrace = tracesByMode[engineRouter.offensiveMode],
              currentTrace.values.indices.contains(signalIndex),
              offensiveTrace.values.indices.contains(signalIndex),
              currentTrace.weightsByIndex.indices.contains(weightIndex),
              offensiveTrace.weightsByIndex.indices.contains(weightIndex) else { return nil }

        let currentWeights = currentTrace.weightsByIndex[weightIndex]
        let offensiveWeights = offensiveTrace.weightsByIndex[weightIndex]
        let currentReturn = portfolioRollingReturn(
            values: currentTrace.values,
            at: signalIndex,
            lookback: engineRouter.returnLookbackSessions
        )
        let offensiveReturn = portfolioRollingReturn(
            values: offensiveTrace.values,
            at: signalIndex,
            lookback: engineRouter.returnLookbackSessions
        )
        let offensiveDrawdown = portfolioRollingDrawdown(
            values: offensiveTrace.values,
            at: signalIndex,
            lookback: engineRouter.drawdownLookbackSessions
        )

        var routedWeights = currentWeights
        var isOffensiveBlend = false
        if let currentReturn,
           let offensiveReturn,
           offensiveReturn > currentReturn {
            if let offensiveDrawdown,
               offensiveDrawdown < -max(engineRouter.drawdownThreshold, 0) {
                routedWeights = blendedWeightMap(
                    currentWeights,
                    offensiveWeights,
                    firstShare: engineRouter.defensiveBlendCurrentShare
                )
            } else {
                routedWeights = blendedWeightMap(
                    offensiveWeights,
                    currentWeights,
                    firstShare: engineRouter.offensiveBlendShare
                )
                isOffensiveBlend = true
            }
        }

        if isOffensiveBlend,
           let currentVolatility = portfolioAnnualizedVolatility(
            values: currentTrace.values,
            at: signalIndex,
            lookback: engineRouter.volatilityLookbackSessions
           ),
           let offensiveVolatility = portfolioAnnualizedVolatility(
            values: offensiveTrace.values,
            at: signalIndex,
            lookback: engineRouter.volatilityLookbackSessions
           ),
           offensiveVolatility > currentVolatility,
           offensiveVolatility > 0 {
            let scale = min(max(currentVolatility / offensiveVolatility, 0), 1)
            routedWeights = routedWeights.mapValues { $0 * scale }
        }

        return normalizedWeightMap(routedWeights)
    }

    private static func dynamicSleeveSelectorWeight(
        selector: AdvancedRotationDynamicSleeveSelector,
        signalIndex: Int,
        satelliteValues: [Double],
        defensiveValues: [Double],
        strategyValues: [Double],
        previousWeight: Double
    ) -> Double {
        guard let satelliteReturn = portfolioRollingReturn(
            values: satelliteValues,
            at: signalIndex,
            lookback: selector.lookbackSessions
        ),
              let defensiveReturn = portfolioRollingReturn(
                values: defensiveValues,
                at: signalIndex,
                lookback: selector.lookbackSessions
              ),
              let satelliteDrawdown = portfolioRollingDrawdown(
                values: satelliteValues,
                at: signalIndex,
                lookback: selector.satelliteDrawdownLookbackSessions
              ) else { return previousWeight }

        let portfolioDrawdown = portfolioRollingDrawdown(
            values: strategyValues,
            at: strategyValues.count - 1,
            lookback: selector.portfolioDrawdownLookbackSessions
        ) ?? 0
        let lowWeight = min(max(selector.satelliteLowWeight, 0), 1)
        let highWeight = min(max(selector.satelliteHighWeight, lowWeight), 1)
        if portfolioDrawdown < -max(selector.portfolioDrawdownThreshold, 0)
            || satelliteDrawdown < -max(selector.satelliteDrawdownThreshold, 0) {
            return lowWeight
        }

        let midpoint = (highWeight + lowWeight) / 2
        if previousWeight >= midpoint {
            return satelliteReturn < defensiveReturn - selector.returnMargin ? lowWeight : highWeight
        }
        return satelliteReturn > defensiveReturn + selector.returnMargin ? highWeight : lowWeight
    }

    private static func dynamicSleeveSelectorTargetWeights(
        selector: AdvancedRotationDynamicSleeveSelector,
        signalIndex: Int,
        weightIndex: Int,
        tracesByMode: [AdvancedBacktestStrategyMode: AdvancedRotationSimulatedTrace],
        strategyValues: [Double],
        previousWeight: Double
    ) -> (weights: [String: Double], satelliteWeight: Double)? {
        guard let satelliteTrace = tracesByMode[selector.satelliteMode],
              let defensiveTrace = tracesByMode[selector.defensiveMode],
              satelliteTrace.values.indices.contains(signalIndex),
              defensiveTrace.values.indices.contains(signalIndex),
              satelliteTrace.weightsByIndex.indices.contains(weightIndex),
              defensiveTrace.weightsByIndex.indices.contains(weightIndex) else { return nil }

        let satelliteWeight = dynamicSleeveSelectorWeight(
            selector: selector,
            signalIndex: signalIndex,
            satelliteValues: satelliteTrace.values,
            defensiveValues: defensiveTrace.values,
            strategyValues: strategyValues,
            previousWeight: previousWeight
        )
        let weights = blendedWeightMap(
            satelliteTrace.weightsByIndex[weightIndex],
            defensiveTrace.weightsByIndex[weightIndex],
            firstShare: satelliteWeight
        )
        return (weights, satelliteWeight)
    }

    private static func metaRotationTargetWeights(
        metaSwitch: AdvancedRotationMetaSwitch,
        stressIndex: Int,
        weightIndex: Int,
        tracesByMode: [AdvancedBacktestStrategyMode: AdvancedRotationSimulatedTrace]
    ) -> [String: Double]? {
        guard let defaultTrace = tracesByMode[metaSwitch.defaultMode],
              let defensiveTrace = tracesByMode[metaSwitch.defensiveMode],
              defaultTrace.values.indices.contains(stressIndex),
              defensiveTrace.weightsByIndex.indices.contains(weightIndex),
              defaultTrace.weightsByIndex.indices.contains(weightIndex) else { return nil }

        let recentReturn = portfolioRollingReturn(
            values: defaultTrace.values,
            at: stressIndex,
            lookback: metaSwitch.lossLookbackSessions
        ) ?? 0
        let recentVolatility = portfolioAnnualizedVolatility(
            values: defaultTrace.values,
            at: stressIndex,
            lookback: metaSwitch.volatilityLookbackSessions
        ) ?? 0
        let recentDrawdown = portfolioRollingDrawdown(
            values: defaultTrace.values,
            at: stressIndex,
            lookback: max(metaSwitch.drawdownLookbackSessions, metaSwitch.lossLookbackSessions, metaSwitch.volatilityLookbackSessions)
        ) ?? 0

        let lossStress = recentReturn <= -max(metaSwitch.lossThreshold, 0)
            && recentDrawdown < -max(metaSwitch.lossDrawdownThreshold, 0)
        let volatilityStress = recentVolatility >= max(metaSwitch.volatilityThreshold, 0)
            && recentReturn < 0
            && recentDrawdown < -max(metaSwitch.volatilityDrawdownThreshold, 0)
        let chosenTrace = (lossStress || volatilityStress) ? defensiveTrace : defaultTrace
        return chosenTrace.weightsByIndex[weightIndex]
    }

    private static func metaEngineTraces(
        for metaSwitch: AdvancedRotationMetaSwitch,
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        initialCash: Double = 100_000,
        feeRate: Double = 0.01,
        slippageRate: Double = 0.0005
    ) -> [AdvancedBacktestStrategyMode: AdvancedRotationSimulatedTrace]? {
        guard let defaultConfig = advancedRotationConfig(for: metaSwitch.defaultMode),
              defaultConfig.metaSwitch == nil,
              let defensiveConfig = advancedRotationConfig(for: metaSwitch.defensiveMode),
              defensiveConfig.metaSwitch == nil else { return nil }
        return [
            metaSwitch.defaultMode: simulatedRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: defaultConfig
            ),
            metaSwitch.defensiveMode: simulatedRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: defensiveConfig
            ),
        ]
    }

    private static func engineRouterTraces(
        for engineRouter: AdvancedRotationEngineRouter,
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        initialCash: Double = 100_000,
        feeRate: Double = 0.01,
        slippageRate: Double = 0.0005
    ) -> [AdvancedBacktestStrategyMode: AdvancedRotationSimulatedTrace]? {
        guard let currentConfig = advancedRotationConfig(for: engineRouter.currentMode),
              currentConfig.engineRouter == nil,
              let offensiveConfig = advancedRotationConfig(for: engineRouter.offensiveMode),
              offensiveConfig.engineRouter == nil else { return nil }
        return [
            engineRouter.currentMode: simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: currentConfig,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            ),
            engineRouter.offensiveMode: simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: offensiveConfig,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            ),
        ]
    }

    private static func dynamicSleeveSelectorTraces(
        for selector: AdvancedRotationDynamicSleeveSelector,
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        initialCash: Double = 100_000,
        feeRate: Double = 0.01,
        slippageRate: Double = 0.0005
    ) -> [AdvancedBacktestStrategyMode: AdvancedRotationSimulatedTrace]? {
        guard let satelliteConfig = advancedRotationConfig(for: selector.satelliteMode),
              satelliteConfig.dynamicSleeveSelector == nil,
              let defensiveConfig = advancedRotationConfig(for: selector.defensiveMode),
              defensiveConfig.dynamicSleeveSelector == nil else { return nil }
        return [
            selector.satelliteMode: simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: satelliteConfig,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            ),
            selector.defensiveMode: simulatedFullRotationTrace(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                config: defensiveConfig,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            ),
        ]
    }

    private static func simulatedFullRotationTrace(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        commonDates: [Date],
        config: AdvancedRotationConfig,
        initialCash: Double = 100_000,
        feeRate: Double = 0.01,
        slippageRate: Double = 0.0005
    ) -> AdvancedRotationSimulatedTrace {
        let tradableSymbols = symbols.filter { !config.signalOnlySymbols.contains($0) }
        var weightsBySymbol: [String: Double] = [:]
        var unitsBySymbol: [String: Double] = Dictionary(uniqueKeysWithValues: tradableSymbols.map { ($0, 0.0) })
        var heldSymbols = Set<String>()
        var cash = max(initialCash, 0)
        var values: [Double] = [max(initialCash, 0)]
        var weightsByIndex: [[String: Double]] = [weightsBySymbol]
        let rebalanceSessions = max(config.rebalanceSessions, 1)
        var lastRebalanceIndex = Int.min / 2
        let band = max(config.rebalanceBand, 0)
        let normalizedFeeRate = max(feeRate, 0)
        let normalizedSlippageRate = max(slippageRate, 0)
        let metaTracesByMode = config.metaSwitch.flatMap { metaSwitch in
            metaEngineTraces(
                for: metaSwitch,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates
            )
        }
        let engineRouterTracesByMode = config.engineRouter.flatMap { engineRouter in
            engineRouterTraces(
                for: engineRouter,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            )
        }
        let dynamicSleeveTracesByMode = config.dynamicSleeveSelector.flatMap { selector in
            dynamicSleeveSelectorTraces(
                for: selector,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                initialCash: initialCash,
                feeRate: feeRate,
                slippageRate: slippageRate
            )
        }
        var dynamicSleeveWeight = config.dynamicSleeveSelector?.initialSatelliteWeight ?? 0.80
        var overlayState = AdvancedRotationOverlayState()

        func portfolioValue(at index: Int) -> Double {
            cash + tradableSymbols.reduce(0.0) { partial, symbol in
                partial + (unitsBySymbol[symbol] ?? 0) * (pricesBySymbol[symbol]?[index] ?? 0)
            }
        }

        func applyPortfolioGuard(to targetWeights: [String: Double], currentValue: Double) -> [String: Double] {
            guard let guardConfig = config.portfolioDrawdownGuard,
                  !targetWeights.isEmpty else { return targetWeights }
            let lookbackSessions = max(guardConfig.lookbackSessions, 1)
            var recentValues = Array(values.suffix(lookbackSessions))
            recentValues.append(currentValue)
            guard let recentPeak = recentValues.max(), recentPeak > 0 else { return targetWeights }
            let drawdownFromPeak = currentValue / recentPeak - 1
            guard drawdownFromPeak < -max(guardConfig.drawdownThreshold, 0) else { return targetWeights }
            let scale = min(max(guardConfig.scale, 0), 1)
            return targetWeights.mapValues { $0 * scale }
        }

        for index in commonDates.indices.dropFirst() {
            if cash > 0 {
                let interest = cash * CashYieldCNY.dailyReturn(on: commonDates[index - 1])
                if interest.isFinite, interest > 0 {
                    cash += interest
                }
            }

            let overlayRebalanceSessions = config.globalRepairStack.map { max($0.overlayRebalanceSessions, 1) }
            let shouldOverlayRebalance = overlayRebalanceSessions.map { index == 1 || index % $0 == 0 } ?? false
            let shouldBaseRebalance: Bool
            if config.rebalancesFromFirstSignal {
                shouldBaseRebalance = index > 0 && index - lastRebalanceIndex >= rebalanceSessions
            } else {
                shouldBaseRebalance = index == 1 || index % rebalanceSessions == 0
            }
            let shouldRebalance = shouldBaseRebalance || shouldOverlayRebalance

            if shouldRebalance {
                let signalIndex = index - 1
                let preRebalanceValue = portfolioValue(at: index)
                let baseWeights: [String: Double]
                if let selector = config.dynamicSleeveSelector,
                   let dynamicSleeveTracesByMode,
                   let routed = dynamicSleeveSelectorTargetWeights(
                    selector: selector,
                    signalIndex: signalIndex,
                    weightIndex: index,
                    tracesByMode: dynamicSleeveTracesByMode,
                    strategyValues: values,
                    previousWeight: dynamicSleeveWeight
                   ) {
                    dynamicSleeveWeight = routed.satelliteWeight
                    baseWeights = routed.weights
                } else {
                    baseWeights = resolvedAdvancedRotationTargetWeights(
                        symbols: symbols,
                        pricesBySymbol: pricesBySymbol,
                        maBySymbol: maBySymbol,
                        volatilityBySymbol: volatilityBySymbol,
                        signalIndex: signalIndex,
                        signalDate: commonDates[signalIndex],
                        traceIndex: index,
                        config: config,
                        metaTracesByMode: metaTracesByMode,
                        engineRouterTracesByMode: engineRouterTracesByMode,
                        portfolioValues: values
                    )
                }
                let rawWeights = applyAdvancedOverlayStack(
                    to: baseWeights,
                    signalIndex: signalIndex,
                    pricesBySymbol: pricesBySymbol,
                    config: config,
                    state: &overlayState,
                    refreshRepairOverlay: shouldOverlayRebalance,
                    portfolioValues: values
                )
                weightsBySymbol = config.metaSwitch == nil
                    ? applyPortfolioGuard(to: rawWeights, currentValue: preRebalanceValue)
                    : rawWeights
                let targetSymbols = Set(weightsBySymbol.keys)

                for symbol in heldSymbols.subtracting(targetSymbols) {
                    guard let price = pricesBySymbol[symbol]?[index],
                          let units = unitsBySymbol[symbol],
                          units > 0 else { continue }
                    let executionPrice = max(price * (1 - normalizedSlippageRate), 0)
                    cash += units * executionPrice * (1 - normalizedFeeRate)
                    unitsBySymbol[symbol] = 0
                }
                heldSymbols.formIntersection(targetSymbols)

                for symbol in targetSymbols.sorted() {
                    guard let targetWeight = weightsBySymbol[symbol],
                          let price = pricesBySymbol[symbol]?[index],
                          price > 0 else { continue }
                    let currentUnits = unitsBySymbol[symbol] ?? 0
                    let currentValue = currentUnits * price
                    let targetValue = preRebalanceValue * targetWeight
                    guard currentValue > targetValue * (1 + band) else { continue }
                    let unitsToSell = min(currentUnits, max(currentValue - targetValue, 0) / price)
                    guard unitsToSell > 0 else { continue }
                    let executionPrice = max(price * (1 - normalizedSlippageRate), 0)
                    cash += unitsToSell * executionPrice * (1 - normalizedFeeRate)
                    unitsBySymbol[symbol] = max(currentUnits - unitsToSell, 0)
                    if (unitsBySymbol[symbol] ?? 0) <= Double.leastNonzeroMagnitude {
                        heldSymbols.remove(symbol)
                    }
                }

                let totalValue = portfolioValue(at: index)
                for symbol in targetSymbols.sorted() {
                    guard let targetWeight = weightsBySymbol[symbol],
                          let price = pricesBySymbol[symbol]?[index],
                          price > 0 else { continue }
                    let currentValue = (unitsBySymbol[symbol] ?? 0) * price
                    let targetValue = totalValue * targetWeight
                    guard currentValue < targetValue * (1 - band) else { continue }
                    let amount = min(cash, max(targetValue - currentValue, 0))
                    guard amount > 0 else { continue }
                    let executionPrice = price * (1 + normalizedSlippageRate)
                    let boughtUnits = amount * (1 - normalizedFeeRate) / executionPrice
                    guard boughtUnits.isFinite, boughtUnits > 0 else { continue }
                    unitsBySymbol[symbol, default: 0] += boughtUnits
                    cash -= amount
                    heldSymbols.insert(symbol)
                }
                lastRebalanceIndex = index
            }

            let value = portfolioValue(at: index)
            values.append(value.isFinite && value > 0 ? value : (values.last ?? max(initialCash, 0)))
            weightsByIndex.append(weightsBySymbol)
        }

        return AdvancedRotationSimulatedTrace(values: values, weightsByIndex: weightsByIndex)
    }

    private static func multiPeriodMomentum(
        values: [Double],
        at index: Int,
        lookbacks: [Int],
        weights: [Double]
    ) -> Double? {
        guard !lookbacks.isEmpty else { return nil }
        var total = 0.0
        for (offset, lookback) in lookbacks.enumerated() {
            let weight = weights.indices.contains(offset) ? weights[offset] : 1
            guard let momentum = priceMomentum(values: values, at: index, lookback: lookback) else { return nil }
            total += momentum * weight
        }
        return total
    }

    private static func movingAverageValue(
        symbol: String,
        period: Int,
        at index: Int,
        pricesBySymbol: [String: [Double]]
    ) -> Double? {
        guard let prices = pricesBySymbol[symbol],
              prices.indices.contains(index) else { return nil }
        return movingAverage(values: prices, period: period)[index]
    }

    private static func canaryRegimeTargetWeights(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        volatilityBySymbol: [String: [Double?]],
        signalIndex: Int,
        regime: AdvancedRotationCanaryRegime,
        config: AdvancedRotationConfig
    ) -> [AdvancedRotationTargetWeight] {
        let availableSymbols = Set(symbols)
        let canaries = regime.canarySymbols.filter { availableSymbols.contains($0) }
        guard !canaries.isEmpty else { return [] }

        func multiMomentum(_ symbol: String) -> Double? {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            return multiPeriodMomentum(
                values: prices,
                at: signalIndex,
                lookbacks: regime.momentumLookbacks,
                weights: regime.momentumWeights
            )
        }

        func isAboveMovingAverage(_ symbol: String, period: Int) -> Bool {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex),
                  let movingAverage = movingAverageValue(
                    symbol: symbol,
                    period: period,
                    at: signalIndex,
                    pricesBySymbol: pricesBySymbol
                  ) else { return false }
            return prices[signalIndex] > movingAverage
        }

        let weakCanaryCount = canaries.reduce(0) { partial, symbol in
            let isWeak = (multiMomentum(symbol) ?? -Double.infinity) < regime.canaryMomentumThreshold
                || !isAboveMovingAverage(symbol, period: regime.canaryMovingAveragePeriod)
            return partial + (isWeak ? 1 : 0)
        }
        let riskOn = weakCanaryCount <= max(regime.weakAllowed, 0)
        var targetWeights: [String: Double] = [:]

        if riskOn {
            let ranked: [(score: Double, symbol: String)] = regime.offensiveSymbols.compactMap { symbol in
                guard availableSymbols.contains(symbol),
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let momentum = multiMomentum(symbol),
                      momentum > regime.assetMomentumThreshold,
                      isAboveMovingAverage(symbol, period: regime.assetMovingAveragePeriod) else { return nil }
                let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex] ?? nil
                if let annualizedVolatility,
                   annualizedVolatility >= regime.equityVolatilityCap {
                    return nil
                }
                let volatility = max(annualizedVolatility ?? 0.18, 0.05)
                return (momentum / volatility, symbol)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
                return lhs.score > rhs.score
            }

            let selected = Array(ranked.prefix(max(config.topCount, 1)))
            if !selected.isEmpty {
                let offensiveWeight = max(regime.offensiveWeight, 0)
                if regime.equalWeight {
                    let eachWeight = offensiveWeight / Double(selected.count)
                    for item in selected {
                        targetWeights[item.symbol] = eachWeight
                    }
                } else {
                    let inverseVolatilityWeights = selected.map { item -> (symbol: String, value: Double) in
                        let volatility = max(volatilityBySymbol[item.symbol]?[signalIndex] ?? 0.18, 0.05)
                        return (item.symbol, 1 / volatility)
                    }
                    let totalRawWeight = inverseVolatilityWeights.reduce(0.0) { $0 + $1.value }
                    if totalRawWeight > 0 {
                        for item in inverseVolatilityWeights {
                            targetWeights[item.symbol] = offensiveWeight * item.value / totalRawWeight
                        }
                    }
                }
            }

            if availableSymbols.contains(regime.defensiveSymbol),
               let defensiveMomentum = multiMomentum(regime.defensiveSymbol),
               defensiveMomentum > regime.defensiveMomentumThreshold,
               isAboveMovingAverage(regime.defensiveSymbol, period: regime.defensiveMovingAveragePeriod) {
                targetWeights[regime.defensiveSymbol, default: 0] += max(regime.defensiveBallastWeight, 0)
            }
        } else if availableSymbols.contains(regime.defensiveSymbol),
                  let defensiveMomentum = multiMomentum(regime.defensiveSymbol),
                  defensiveMomentum > regime.defensiveMomentumThreshold,
                  isAboveMovingAverage(regime.defensiveSymbol, period: regime.defensiveMovingAveragePeriod) {
            targetWeights[regime.defensiveSymbol] = max(regime.defensiveOnlyWeight, 0)
        }

        let grossExposure = targetWeights.reduce(0.0) { $0 + max($1.value, 0) }
        let maxExposure = min(max(config.maxExposure, 0), 1)
        if grossExposure > maxExposure, grossExposure > 0 {
            targetWeights = targetWeights.mapValues { max($0, 0) * maxExposure / grossExposure }
        }

        return targetWeights.compactMap { item -> AdvancedRotationTargetWeight? in
            guard item.value > 0.0001,
                  let prices = pricesBySymbol[item.key],
                  prices.indices.contains(signalIndex) else { return nil }
            return AdvancedRotationTargetWeight(
                symbol: item.key,
                weight: item.value,
                momentum: multiMomentum(item.key) ?? 0,
                annualizedVolatility: volatilityBySymbol[item.key]?[signalIndex] ?? nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.weight == rhs.weight { return lhs.symbol < rhs.symbol }
            return lhs.weight > rhs.weight
        }
    }

    private static func advancedRotationTargetWeights(
        symbols: [String],
        pricesBySymbol: [String: [Double]],
        maBySymbol: [String: [Double?]],
        volatilityBySymbol: [String: [Double?]],
        signalIndex: Int,
        signalDate: Date? = nil,
        config: AdvancedRotationConfig
    ) -> [AdvancedRotationTargetWeight] {
        guard signalIndex - config.lookbackSessions >= 0 else { return [] }
        if let canaryRegime = config.canaryRegime {
            return canaryRegimeTargetWeights(
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                signalIndex: signalIndex,
                regime: canaryRegime,
                config: config
            )
        }

        let baseSymbols = config.baseRotationSymbols.map { allowed in
            symbols.filter { allowed.contains($0) }
        } ?? symbols
        let ranked: [(score: Double, momentum: Double, symbol: String)] = baseSymbols.compactMap { symbol in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { return nil }
            let previousPrice = prices[signalIndex - config.lookbackSessions]
            guard previousPrice > 0 else { return nil }
            let momentum = prices[signalIndex] / previousPrice - 1
            var rankingScore = momentum

            switch config.signal {
            case .maMomentum:
                guard momentum > config.minMomentumThreshold,
                      let ma = maBySymbol[symbol]?[signalIndex],
                      prices[signalIndex] >= ma else { return nil }
            case .lowVolMomentum:
                guard momentum > config.minMomentumThreshold else { return nil }
                if let maxSignalAnnualVolatility = config.maxSignalAnnualVolatility {
                    guard let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex],
                          annualizedVolatility <= maxSignalAnnualVolatility else { return nil }
                }
            case .guardedDualMomentum:
                guard let secondaryLookbackSessions = config.secondaryLookbackSessions,
                      let secondaryMomentum = priceMomentum(values: prices, at: signalIndex, lookback: secondaryLookbackSessions),
                      let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex],
                      let drawdownLookback = config.signalDrawdownLookbackSessions,
                      let drawdownFromHigh = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: drawdownLookback) else { return nil }
                guard momentum > config.minMomentumThreshold,
                      secondaryMomentum > (config.secondaryMomentumThreshold ?? config.minMomentumThreshold) else { return nil }
                if let maxSignalAnnualVolatility = config.maxSignalAnnualVolatility {
                    guard annualizedVolatility <= maxSignalAnnualVolatility else { return nil }
                }
                if let maxSignalDrawdown = config.maxSignalDrawdown {
                    guard drawdownFromHigh >= -max(maxSignalDrawdown, 0) else { return nil }
                }

                let rsi = config.rsiLookbackSessions.flatMap { relativeStrengthIndex(values: prices, at: signalIndex, period: $0) }
                let donchianPosition = config.donchianLookbackSessions.flatMap { donchianRangePosition(values: prices, at: signalIndex, period: $0) }

                rankingScore = momentum * 1.2
                    + secondaryMomentum * 0.5
                    + max(drawdownFromHigh, -0.5) * 0.4
                    + (1.0 / max(annualizedVolatility, 0.01)) * 0.015
                if let rsi {
                    rankingScore += (1 - abs(rsi - 62) / 62) * 0.05
                }
                if let donchianPosition {
                    rankingScore += donchianPosition * 0.08
                }
                if symbol == "gold_cny" {
                    rankingScore += 0.03
                }
            case .drawdownReentry:
                guard let secondaryLookbackSessions = config.secondaryLookbackSessions,
                      let secondaryMomentum = priceMomentum(values: prices, at: signalIndex, lookback: secondaryLookbackSessions),
                      let annualizedVolatility = volatilityBySymbol[symbol]?[signalIndex],
                      let drawdownLookback = config.signalDrawdownLookbackSessions,
                      let drawdownFromHigh = rollingDrawdownFromHigh(values: prices, at: signalIndex, period: drawdownLookback) else { return nil }
                if let maxSignalDrawdown = config.maxSignalDrawdown {
                    guard drawdownFromHigh >= -max(maxSignalDrawdown, 0) else { return nil }
                }

                let rsi = config.rsiLookbackSessions.flatMap { relativeStrengthIndex(values: prices, at: signalIndex, period: $0) }
                let momentumPass = momentum > config.minMomentumThreshold
                let rsiPass = rsi.map { value in
                    let lower = config.minimumRSI ?? 0
                    return value >= lower
                } ?? false
                guard momentumPass || rsiPass else { return nil }

                let donchianPosition = config.donchianLookbackSessions.flatMap { donchianRangePosition(values: prices, at: signalIndex, period: $0) }

                rankingScore = momentum * 1.2
                    + secondaryMomentum * 0.5
                    + max(drawdownFromHigh, -0.5) * 0.4
                    + (1.0 / max(annualizedVolatility, 0.01)) * 0.015
                if let rsi {
                    rankingScore += (1 - abs(rsi - 62) / 62) * 0.05
                }
                if let donchianPosition {
                    rankingScore += donchianPosition * 0.08
                    if let minimumDonchianPosition = config.minimumDonchianPosition,
                       donchianPosition < minimumDonchianPosition {
                        rankingScore -= 0.03
                    }
                }
                if symbol == "gold_cny" {
                    rankingScore += 0.03
                }
            }

            return (rankingScore, momentum, symbol)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.symbol < rhs.symbol }
            return lhs.score > rhs.score
        }

        var baseWeights: [String: Double] = [:]
        if let fixedBaseWeightsBySymbol = config.fixedBaseWeightsBySymbol {
            let fixedCandidates = Array(ranked.prefix(max(config.topCount, 1)))
            for item in fixedCandidates {
                let fixedWeight = max(fixedBaseWeightsBySymbol[item.symbol] ?? 0, 0)
                if fixedWeight > 0 {
                    baseWeights[item.symbol] = fixedWeight
                }
            }
            let totalFixedWeight = baseWeights.reduce(0.0) { $0 + $1.value }
            guard totalFixedWeight > 0 else { return [] }
            if config.renormalizesFixedBaseWeights {
                baseWeights = baseWeights.mapValues { $0 / totalFixedWeight }
            }
        } else {
            let sortedCandidates: [(score: Double, momentum: Double, symbol: String)]
            if config.weighting == .lowVolMomentumInverseVolatility {
                sortedCandidates = ranked.sorted { lhs, rhs in
                    let lhsVolatility = max(volatilityBySymbol[lhs.symbol]?[signalIndex] ?? 9, 0.01)
                    let rhsVolatility = max(volatilityBySymbol[rhs.symbol]?[signalIndex] ?? 9, 0.01)
                    let lhsScore = lhs.momentum / lhsVolatility
                    let rhsScore = rhs.momentum / rhsVolatility
                    if lhsScore == rhsScore { return lhs.symbol < rhs.symbol }
                    return lhsScore > rhsScore
                }
            } else {
                sortedCandidates = ranked
            }

            let picks = Array(sortedCandidates.prefix(max(config.topCount, 1)))
            guard !picks.isEmpty else { return [] }

            switch config.weighting {
            case .winner:
                baseWeights[picks[0].symbol] = 1
            case .momentumInverseVolatility:
                var rawWeights: [(symbol: String, value: Double)] = []
                for pick in picks {
                    let annualizedVolatility = max(volatilityBySymbol[pick.symbol]?[signalIndex] ?? 9, 0.01)
                    rawWeights.append((pick.symbol, max(pick.momentum, 0.0001) / annualizedVolatility))
                }
                let totalRawWeight = rawWeights.reduce(0.0) { $0 + $1.value }
                guard totalRawWeight > 0 else { return [] }
                for rawWeight in rawWeights {
                    baseWeights[rawWeight.symbol] = rawWeight.value / totalRawWeight
                }
            case .lowVolMomentumInverseVolatility:
                var rawWeights: [(symbol: String, value: Double)] = []
                for pick in picks {
                    let annualizedVolatility = max(volatilityBySymbol[pick.symbol]?[signalIndex] ?? 9, 0.01)
                    rawWeights.append((pick.symbol, 1 / annualizedVolatility))
                }
                let totalRawWeight = rawWeights.reduce(0.0) { $0 + $1.value }
                guard totalRawWeight > 0 else { return [] }
                for rawWeight in rawWeights {
                    baseWeights[rawWeight.symbol] = rawWeight.value / totalRawWeight
                }
            case .coreSatelliteWinner:
                if let coreWeightsBySymbol = config.coreWeightsBySymbol {
                    for item in ranked where coreWeightsBySymbol[item.symbol] != nil {
                        let coreWeight = max(coreWeightsBySymbol[item.symbol] ?? 0, 0)
                        if coreWeight > 0 {
                            baseWeights[item.symbol] = coreWeight
                        }
                    }
                }

                let satelliteCandidates = ranked.filter { config.satelliteSymbols.contains($0.symbol) }
                if let satelliteWinner = satelliteCandidates.first {
                    let satelliteWeight = max(config.satelliteWeight, 0)
                    if satelliteWeight > 0 {
                        baseWeights[satelliteWinner.symbol, default: 0] += satelliteWeight
                    }
                }

                guard !baseWeights.isEmpty else { return [] }
            }
        }

        var exposure = min(max(config.maxExposure, 0), 1)
        if let targetAnnualVolatility = config.targetAnnualVolatility {
            let weightedVolatility: Double
            if config.weighting == .lowVolMomentumInverseVolatility {
                let squaredWeightedVolatility = baseWeights.reduce(0.0) { partial, item in
                    let symbol = item.key
                    let weight = item.value
                    let annualizedVolatility = max(volatilityBySymbol[symbol]?[signalIndex] ?? 9, 0.01)
                    return partial + pow(weight * annualizedVolatility, 2)
                }
                weightedVolatility = sqrt(squaredWeightedVolatility)
            } else {
                weightedVolatility = baseWeights.reduce(0.0) { partial, item in
                    let symbol = item.key
                    let weight = item.value
                    let annualizedVolatility = max(volatilityBySymbol[symbol]?[signalIndex] ?? 9, 0.01)
                    return partial + weight * annualizedVolatility
                }
            }
            exposure = min(exposure, targetAnnualVolatility / max(weightedVolatility, 0.01))
        }

        var finalWeights = baseWeights.mapValues { $0 * exposure }
        var didUseDecelerationLock = false

        func canRedeploy(to symbol: String) -> Bool {
            guard let redeployPrices = pricesBySymbol[symbol],
                  redeployPrices.indices.contains(signalIndex),
                  let redeployMA = movingAverage(values: redeployPrices, period: 60)[signalIndex],
                  let redeployMomentum = priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60) else { return false }
            return redeployPrices[signalIndex] >= redeployMA && redeployMomentum > -0.02
        }

        func capTotalExposure(maxExposure: Double, redeploySymbol: String?, redeployRatio: Double) {
            let currentExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
            let normalizedMaxExposure = min(max(maxExposure, 0), 1)
            guard currentExposure > normalizedMaxExposure, currentExposure > 0 else { return }
            let scale = normalizedMaxExposure / currentExposure
            var removedWeight = 0.0
            for item in finalWeights {
                let originalWeight = max(item.value, 0)
                let scaledWeight = originalWeight * scale
                finalWeights[item.key] = scaledWeight
                removedWeight += originalWeight - scaledWeight
            }
            if let redeploySymbol,
               canRedeploy(to: redeploySymbol) {
                finalWeights[redeploySymbol, default: 0] += removedWeight * min(max(redeployRatio, 0), 1)
            }
        }

        if let pairConfirmationGuard = config.pairConfirmationGuard {
            let isPairBroken = pairConfirmationGuard.peerBySymbol.contains { item in
                let symbol = item.key
                let peer = item.value
                guard (finalWeights[symbol] ?? 0) > 0,
                      let peerPrices = pricesBySymbol[peer],
                      peerPrices.indices.contains(signalIndex) else { return false }
                let peerMomentum = priceMomentum(
                    values: peerPrices,
                    at: signalIndex,
                    lookback: pairConfirmationGuard.peerMomentumLookbackSessions
                )
                let peerDrawdown = rollingDrawdownFromHigh(
                    values: peerPrices,
                    at: signalIndex,
                    period: pairConfirmationGuard.peerDrawdownLookbackSessions
                )
                return (peerMomentum ?? 0) < pairConfirmationGuard.peerMomentumThreshold
                    || (peerDrawdown ?? 0) <= -max(pairConfirmationGuard.peerDrawdownThreshold, 0)
            }
            if isPairBroken {
                capTotalExposure(
                    maxExposure: pairConfirmationGuard.maxExposure,
                    redeploySymbol: pairConfirmationGuard.redeploySymbol,
                    redeployRatio: pairConfirmationGuard.redeployRatio
                )
            }
        }

        if let overheatBrake = config.overheatBrake {
            let isOverheated = overheatBrake.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let heatMomentum = priceMomentum(values: prices, at: signalIndex, lookback: overheatBrake.momentumLookbackSessions),
                      let rsi = relativeStrengthIndex(values: prices, at: signalIndex, period: overheatBrake.rsiLookbackSessions),
                      let donchianPosition = donchianRangePosition(values: prices, at: signalIndex, period: overheatBrake.donchianLookbackSessions) else { return false }
                return heatMomentum > overheatBrake.momentumThreshold
                    && rsi > overheatBrake.rsiThreshold
                    && donchianPosition > overheatBrake.donchianPositionThreshold
            }

            if isOverheated {
                let currentExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
                let maxExposure = min(max(overheatBrake.maxExposure, 0), 1)
                if currentExposure > maxExposure, currentExposure > 0 {
                    let scale = maxExposure / currentExposure
                    var removedWeight = 0.0
                    for item in finalWeights {
                        let originalWeight = max(item.value, 0)
                        let scaledWeight = originalWeight * scale
                        finalWeights[item.key] = scaledWeight
                        removedWeight += originalWeight - scaledWeight
                    }

                    if let redeploySymbol = overheatBrake.redeploySymbol,
                       let redeployPrices = pricesBySymbol[redeploySymbol],
                       redeployPrices.indices.contains(signalIndex),
                       let redeployMA = movingAverage(values: redeployPrices, period: 60)[signalIndex],
                       let redeployMomentum = priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60),
                       redeployPrices[signalIndex] >= redeployMA,
                       redeployMomentum > -0.02 {
                        let redeployRatio = min(max(overheatBrake.redeployRatio, 0), 1)
                        finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                    }
                }
            }
        }

        if let decelerationLock = config.decelerationLock {
            let isDeceleratingAtHighZone = decelerationLock.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex),
                      let shortMomentum = priceMomentum(values: prices, at: signalIndex, lookback: decelerationLock.shortMomentumLookbackSessions),
                      let rsi = relativeStrengthIndex(values: prices, at: signalIndex, period: decelerationLock.rsiLookbackSessions),
                      let donchianPosition = donchianRangePosition(values: prices, at: signalIndex, period: decelerationLock.donchianLookbackSessions) else { return false }
                return donchianPosition > decelerationLock.donchianPositionThreshold
                    && rsi > decelerationLock.rsiThreshold
                    && shortMomentum < decelerationLock.shortMomentumUpperThreshold
            }

            if isDeceleratingAtHighZone {
                didUseDecelerationLock = true
                let currentExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
                let maxExposure = min(max(decelerationLock.maxExposure, 0), 1)
                if currentExposure > maxExposure, currentExposure > 0 {
                    let scale = maxExposure / currentExposure
                    var removedWeight = 0.0
                    for item in finalWeights {
                        let originalWeight = max(item.value, 0)
                        let scaledWeight = originalWeight * scale
                        finalWeights[item.key] = scaledWeight
                        removedWeight += originalWeight - scaledWeight
                    }

                    if let redeploySymbol = decelerationLock.redeploySymbol,
                       let redeployPrices = pricesBySymbol[redeploySymbol],
                       redeployPrices.indices.contains(signalIndex),
                       let redeployMA = movingAverage(values: redeployPrices, period: 60)[signalIndex],
                       let redeployMomentum = priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60),
                       redeployPrices[signalIndex] >= redeployMA,
                       redeployMomentum > -0.02 {
                        let redeployRatio = min(max(decelerationLock.redeployRatio, 0), 1)
                        finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                    }
                }
            }
        }

        if !didUseDecelerationLock, let shortWeaknessLock = config.shortWeaknessLock {
            let isShortWeaknessTriggered = shortWeaknessLock.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      let relativePrices = pricesBySymbol[shortWeaknessLock.relativeSymbol],
                      signalIndex - shortWeaknessLock.relativeLookbackSessions >= 0,
                      prices.indices.contains(signalIndex),
                      prices.indices.contains(signalIndex - shortWeaknessLock.relativeLookbackSessions),
                      relativePrices.indices.contains(signalIndex),
                      relativePrices.indices.contains(signalIndex - shortWeaknessLock.relativeLookbackSessions),
                      let shortMomentum = priceMomentum(values: prices, at: signalIndex, lookback: shortWeaknessLock.shortMomentumLookbackSessions) else { return false }

                let previousAssetPrice = prices[signalIndex - shortWeaknessLock.relativeLookbackSessions]
                let previousRelativePrice = relativePrices[signalIndex - shortWeaknessLock.relativeLookbackSessions]
                let currentAssetPrice = prices[signalIndex]
                let currentRelativePrice = relativePrices[signalIndex]
                guard previousAssetPrice > 0,
                      previousRelativePrice > 0,
                      currentAssetPrice > 0,
                      currentRelativePrice > 0 else { return false }

                let relativeMomentum = (currentAssetPrice / previousAssetPrice) / (currentRelativePrice / previousRelativePrice) - 1
                return shortMomentum < shortWeaknessLock.shortMomentumThreshold
                    && relativeMomentum < shortWeaknessLock.relativeMomentumThreshold
            }

            if isShortWeaknessTriggered {
                let currentExposure = finalWeights.reduce(0.0) { $0 + max($1.value, 0) }
                let maxExposure = min(max(shortWeaknessLock.maxExposure, 0), 1)
                if currentExposure > maxExposure, currentExposure > 0 {
                    let scale = maxExposure / currentExposure
                    var removedWeight = 0.0
                    for item in finalWeights {
                        let originalWeight = max(item.value, 0)
                        let scaledWeight = originalWeight * scale
                        finalWeights[item.key] = scaledWeight
                        removedWeight += originalWeight - scaledWeight
                    }

                    if let redeploySymbol = shortWeaknessLock.redeploySymbol,
                       let redeployPrices = pricesBySymbol[redeploySymbol],
                       redeployPrices.indices.contains(signalIndex),
                       let redeployMA = movingAverage(values: redeployPrices, period: 60)[signalIndex],
                       let redeployMomentum = priceMomentum(values: redeployPrices, at: signalIndex, lookback: 60),
                       redeployPrices[signalIndex] >= redeployMA,
                       redeployMomentum > -0.02 {
                        let redeployRatio = min(max(shortWeaknessLock.redeployRatio, 0), 1)
                        finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                    }
                }
            }
        }

        if let heldBreakdownLock = config.heldBreakdownLock {
            let isHeldBreakdownTriggered = heldBreakdownLock.triggerSymbols.contains { symbol in
                guard (finalWeights[symbol] ?? 0) > 0,
                      let prices = pricesBySymbol[symbol],
                      let relativePrices = pricesBySymbol[heldBreakdownLock.relativeSymbol],
                      prices.indices.contains(signalIndex),
                      relativePrices.indices.contains(signalIndex),
                      let donchianPosition = donchianRangePosition(
                        values: prices,
                        at: signalIndex,
                        period: heldBreakdownLock.donchianLookbackSessions
                      ),
                      donchianPosition > heldBreakdownLock.donchianPositionThreshold else { return false }

                var signalCount = 0
                if let drawdown = rollingDrawdownFromHigh(
                    values: prices,
                    at: signalIndex,
                    period: heldBreakdownLock.drawdownLookbackSessions
                ), drawdown <= -max(heldBreakdownLock.drawdownThreshold, 0) {
                    signalCount += 1
                }
                if let shortMomentum = priceMomentum(
                    values: prices,
                    at: signalIndex,
                    lookback: heldBreakdownLock.shortMomentumLookbackSessions
                ), shortMomentum < heldBreakdownLock.shortMomentumThreshold {
                    signalCount += 1
                }
                if let mediumMomentum = priceMomentum(
                    values: prices,
                    at: signalIndex,
                    lookback: heldBreakdownLock.mediumMomentumLookbackSessions
                ), mediumMomentum < heldBreakdownLock.mediumMomentumThreshold {
                    signalCount += 1
                }
                if signalIndex - heldBreakdownLock.relativeLookbackSessions >= 0,
                   prices.indices.contains(signalIndex - heldBreakdownLock.relativeLookbackSessions),
                   relativePrices.indices.contains(signalIndex - heldBreakdownLock.relativeLookbackSessions) {
                    let previousAssetPrice = prices[signalIndex - heldBreakdownLock.relativeLookbackSessions]
                    let previousRelativePrice = relativePrices[signalIndex - heldBreakdownLock.relativeLookbackSessions]
                    let currentAssetPrice = prices[signalIndex]
                    let currentRelativePrice = relativePrices[signalIndex]
                    if previousAssetPrice > 0,
                       previousRelativePrice > 0,
                       currentAssetPrice > 0,
                       currentRelativePrice > 0 {
                        let relativeMomentum = (currentAssetPrice / previousAssetPrice) / (currentRelativePrice / previousRelativePrice) - 1
                        if relativeMomentum < heldBreakdownLock.relativeMomentumThreshold {
                            signalCount += 1
                        }
                    }
                }

                return signalCount >= max(heldBreakdownLock.requiredSignals, 1)
            }
            if isHeldBreakdownTriggered {
                capTotalExposure(
                    maxExposure: heldBreakdownLock.maxExposure,
                    redeploySymbol: heldBreakdownLock.redeploySymbol,
                    redeployRatio: heldBreakdownLock.redeployRatio
                )
            }
        }

        if let fastCrashBrake = config.fastCrashBrake {
            let lookbackSessions = max(fastCrashBrake.lookbackSessions, 1)
            let isCrashTriggered = fastCrashBrake.triggerSymbols.contains { symbol in
                guard let prices = pricesBySymbol[symbol],
                      signalIndex - lookbackSessions >= 0,
                      prices.indices.contains(signalIndex),
                      prices.indices.contains(signalIndex - lookbackSessions) else { return false }
                let previousPrice = prices[signalIndex - lookbackSessions]
                guard previousPrice > 0 else { return false }
                let shortTermReturn = prices[signalIndex] / previousPrice - 1
                return shortTermReturn <= -max(fastCrashBrake.drawdownThreshold, 0)
            }

            if isCrashTriggered {
                let scale = min(max(fastCrashBrake.scale, 0), 1)
                var removedWeight = 0.0
                for symbol in fastCrashBrake.scaledSymbols {
                    let originalWeight = finalWeights[symbol] ?? 0
                    guard originalWeight > 0 else { continue }
                    let scaledWeight = originalWeight * scale
                    finalWeights[symbol] = scaledWeight
                    removedWeight += originalWeight - scaledWeight
                }

                if let redeploySymbol = fastCrashBrake.redeploySymbol,
                   ranked.contains(where: { $0.symbol == redeploySymbol }) {
                    let redeployRatio = min(max(fastCrashBrake.redeployRatio, 0), 1)
                    finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                }
            }
        }

        if let volatilityBrake = config.volatilityBrake,
           let triggerVolatility = volatilityBySymbol[volatilityBrake.triggerSymbol]?[signalIndex],
           triggerVolatility > volatilityBrake.threshold {
            let scale = min(max(volatilityBrake.scale, 0), 1)
            var removedWeight = 0.0
            for symbol in volatilityBrake.scaledSymbols {
                let originalWeight = finalWeights[symbol] ?? 0
                guard originalWeight > 0 else { continue }
                let scaledWeight = originalWeight * scale
                finalWeights[symbol] = scaledWeight
                removedWeight += originalWeight - scaledWeight
            }

            if let redeploySymbol = volatilityBrake.redeploySymbol,
               ranked.contains(where: { $0.symbol == redeploySymbol }) {
                let redeployRatio = min(max(volatilityBrake.redeployRatio, 0), 1)
                finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
            }
        }

        if let drawdownLadderBrake = config.drawdownLadderBrake {
            var shouldUseHardScale = false
            var shouldUseSoftScale = false
            for item in drawdownLadderBrake.triggerThresholdRatiosBySymbol {
                let symbol = item.key
                let thresholdRatio = max(item.value, 0.0001)
                guard let prices = pricesBySymbol[symbol],
                      prices.indices.contains(signalIndex) else { continue }
                let startIndex = max(0, signalIndex - max(drawdownLadderBrake.lookbackSessions, 1) + 1)
                guard startIndex <= signalIndex,
                      let recentHigh = prices[startIndex...signalIndex].max(),
                      recentHigh > 0 else { continue }
                let drawdownFromHigh = prices[signalIndex] / recentHigh - 1
                if drawdownFromHigh <= -drawdownLadderBrake.hardDrawdown * thresholdRatio {
                    shouldUseHardScale = true
                } else if drawdownFromHigh <= -drawdownLadderBrake.softDrawdown * thresholdRatio {
                    shouldUseSoftScale = true
                }
            }

            let scale: Double?
            if shouldUseHardScale {
                scale = drawdownLadderBrake.hardScale
            } else if shouldUseSoftScale {
                scale = drawdownLadderBrake.softScale
            } else {
                scale = nil
            }

            if let scale {
                let normalizedScale = min(max(scale, 0), 1)
                var removedWeight = 0.0
                for symbol in drawdownLadderBrake.scaledSymbols {
                    let originalWeight = finalWeights[symbol] ?? 0
                    guard originalWeight > 0 else { continue }
                    let scaledWeight = originalWeight * normalizedScale
                    finalWeights[symbol] = scaledWeight
                    removedWeight += originalWeight - scaledWeight
                }

                if let redeploySymbol = drawdownLadderBrake.redeploySymbol,
                   ranked.contains(where: { $0.symbol == redeploySymbol }) {
                    let redeployRatio = min(max(drawdownLadderBrake.redeployRatio, 0), 1)
                    finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
                }
            }
        }

        if let monthlyExposureBrake = config.monthlyExposureBrake,
           let signalDate,
           monthlyExposureBrake.months.contains(Calendar.current.component(.month, from: signalDate)) {
            let normalizedScale = min(max(monthlyExposureBrake.scale, 0), 1)
            var removedWeight = 0.0
            for symbol in monthlyExposureBrake.scaledSymbols {
                let originalWeight = finalWeights[symbol] ?? 0
                guard originalWeight > 0 else { continue }
                let scaledWeight = originalWeight * normalizedScale
                finalWeights[symbol] = scaledWeight
                removedWeight += originalWeight - scaledWeight
            }

            if let redeploySymbol = monthlyExposureBrake.redeploySymbol,
               ranked.contains(where: { $0.symbol == redeploySymbol }) {
                let redeployRatio = min(max(monthlyExposureBrake.redeployRatio, 0), 1)
                finalWeights[redeploySymbol, default: 0] += removedWeight * redeployRatio
            }
        }

        return finalWeights.compactMap { symbol, weight in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(signalIndex) else { return nil }
            let momentum = ranked.first(where: { $0.symbol == symbol })?.momentum
                ?? priceMomentum(values: prices, at: signalIndex, lookback: config.lookbackSessions)
                ?? 0
            return AdvancedRotationTargetWeight(
                symbol: symbol,
                weight: weight,
                momentum: momentum,
                annualizedVolatility: volatilityBySymbol[symbol]?[signalIndex] ?? nil
            )
        }
    }

    private static func runAdvancedRotation(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        config: AdvancedRotationConfig,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedBacktestReport? {
        let preparedSeries: [PreparedAdvancedSeries] = assetInputs.compactMap { input -> PreparedAdvancedSeries? in
            guard input.assetSeries != nil,
                  !input.assetOption.requiresHistoricalFX || input.fxSeries != nil else { return nil }
            return preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard preparedSeries.count >= 2 else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let normalizedFeeRate = max(settings.feeRate, 0) / 100
        let normalizedSlippageRate = max(settings.slippageRate, 0) / 100
        let normalizedRebalanceBand = max(config.rebalanceBand, 0)
        let normalizedRiskBudgetMultiplier = max(config.riskBudgetEnhancer?.multiplier ?? 1, 0)
        let normalizedFinancingAnnualRate = max(config.riskBudgetEnhancer?.annualFinancingRate ?? 0, 0)
        let allowsFinancedExposure = normalizedRiskBudgetMultiplier > 1.0001
        guard normalizedInitialCash > 0 else { return nil }

        let aligned = alignedRotationPriceSeries(
            from: preparedSeries,
            zeroFillBeforeFirstSymbols: config.zeroFillBeforeFirstSymbols
        )
        let commonDates = aligned.dates
        let pricesBySymbol = aligned.pricesBySymbol
        let optionBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, $0.assetOption) })
        let symbols = preparedSeries.map { $0.assetOption.symbol }
        let tradableSymbols = symbols.filter { !config.signalOnlySymbols.contains($0) }
        guard !tradableSymbols.isEmpty else { return nil }
        let simulationRange: ClosedRange<Int>
        if let dateBounds {
            guard let startIndex = commonDates.firstIndex(where: { $0 >= dateBounds.lowerBound }),
                  let endIndex = commonDates.lastIndex(where: { $0 <= dateBounds.upperBound }),
                  startIndex <= endIndex else { return nil }
            simulationRange = startIndex...endIndex
        } else {
            guard let startIndex = commonDates.indices.first,
                  let endIndex = commonDates.indices.last else { return nil }
            simulationRange = startIndex...endIndex
        }
        guard simulationRange.count > 1 else { return nil }
        let maxMAFilterPeriod = max(config.maFilterPeriodBySymbol?.values.max() ?? config.maFilterPeriod, config.maFilterPeriod)
        let fastCrashBrakeLookback = config.fastCrashBrake?.lookbackSessions ?? 0
        let overheatBrakeWarmup = max(
            config.overheatBrake?.momentumLookbackSessions ?? 0,
            config.overheatBrake?.rsiLookbackSessions ?? 0,
            config.overheatBrake?.donchianLookbackSessions ?? 0
        )
        let decelerationLockWarmup = max(
            config.decelerationLock?.shortMomentumLookbackSessions ?? 0,
            config.decelerationLock?.rsiLookbackSessions ?? 0,
            config.decelerationLock?.donchianLookbackSessions ?? 0
        )
        let shortWeaknessLockWarmup = max(
            config.shortWeaknessLock?.shortMomentumLookbackSessions ?? 0,
            config.shortWeaknessLock?.relativeLookbackSessions ?? 0
        )
        let pairConfirmationGuardWarmup = max(
            config.pairConfirmationGuard?.peerMomentumLookbackSessions ?? 0,
            config.pairConfirmationGuard?.peerDrawdownLookbackSessions ?? 0
        )
        let heldBreakdownLockWarmup = max(
            config.heldBreakdownLock?.drawdownLookbackSessions ?? 0,
            config.heldBreakdownLock?.shortMomentumLookbackSessions ?? 0,
            config.heldBreakdownLock?.mediumMomentumLookbackSessions ?? 0,
            config.heldBreakdownLock?.relativeLookbackSessions ?? 0,
            config.heldBreakdownLock?.donchianLookbackSessions ?? 0
        )
        let metaSwitchWarmup = max(
            config.metaSwitch?.lossLookbackSessions ?? 0,
            config.metaSwitch?.volatilityLookbackSessions ?? 0,
            config.metaSwitch?.drawdownLookbackSessions ?? 0
        )
        let overlayPortfolioBrakeWarmup = config.goldSatelliteOverlay?.portfolioEquityBrake?.lookbackSessions ?? 0
        let confirmedEquityBreadthWarmup = max(
            config.confirmedEquityBreadth?.shortMomentumLookbackSessions ?? 0,
            config.confirmedEquityBreadth?.longMomentumLookbackSessions ?? 0,
            config.confirmedEquityBreadth?.movingAveragePeriod ?? 0,
            config.confirmedEquityBreadth?.volatilityLookbackSessions ?? 0
        )
        let engineRouterWarmup = max(
            config.engineRouter?.returnLookbackSessions ?? 0,
            config.engineRouter?.drawdownLookbackSessions ?? 0,
            config.engineRouter?.volatilityLookbackSessions ?? 0
        )
        let confirmedAccelerationWarmup = config.confirmedAccelerationSatellite == nil ? 0 : 240
        let profitLockWarmup = max(
            config.profitLockBudget?.lookbackSessions ?? 0,
            config.profitLockBudget?.profitLookbackSessions ?? 0
        )
        let dynamicSleeveWarmup = max(
            config.dynamicSleeveSelector?.lookbackSessions ?? 0,
            config.dynamicSleeveSelector?.satelliteDrawdownLookbackSessions ?? 0,
            config.dynamicSleeveSelector?.portfolioDrawdownLookbackSessions ?? 0
        )
        let canaryRegimeWarmup = max(
            config.canaryRegime?.momentumLookbacks.max() ?? 0,
            config.canaryRegime?.canaryMovingAveragePeriod ?? 0,
            config.canaryRegime?.assetMovingAveragePeriod ?? 0,
            config.canaryRegime?.defensiveMovingAveragePeriod ?? 0
        )
        let extraIndicatorWarmup = [
            config.secondaryLookbackSessions ?? 0,
            config.signalDrawdownLookbackSessions ?? 0,
            config.rsiLookbackSessions ?? 0,
            config.donchianLookbackSessions ?? 0,
            overheatBrakeWarmup,
            decelerationLockWarmup,
            shortWeaknessLockWarmup,
            pairConfirmationGuardWarmup,
            heldBreakdownLockWarmup,
            config.portfolioDrawdownGuard?.lookbackSessions ?? 0,
            metaSwitchWarmup,
            overlayPortfolioBrakeWarmup,
            confirmedEquityBreadthWarmup,
            engineRouterWarmup,
            confirmedAccelerationWarmup,
            profitLockWarmup,
            dynamicSleeveWarmup,
            canaryRegimeWarmup,
            advancedOverlayWarmup(for: config),
        ].max() ?? 0
        let minimumWarmup = ([
            config.lookbackSessions,
            maxMAFilterPeriod,
            config.volatilityLookbackSessions,
            fastCrashBrakeLookback,
            extraIndicatorWarmup,
        ].max() ?? 0) + 1
        guard commonDates.count > minimumWarmup else { return nil }

        var maBySymbol: [String: [Double?]] = [:]
        var volatilityBySymbol: [String: [Double?]] = [:]
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol] else { return nil }
            let maFilterPeriod = config.maFilterPeriodBySymbol?[symbol] ?? config.maFilterPeriod
            maBySymbol[symbol] = movingAverage(values: prices, period: maFilterPeriod)
            volatilityBySymbol[symbol] = rollingAnnualizedVolatility(values: prices, period: config.volatilityLookbackSessions)
        }

        let metaTracesByMode = config.metaSwitch.flatMap { metaSwitch in
            metaEngineTraces(
                for: metaSwitch,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates
            )
        }
        if config.metaSwitch != nil, metaTracesByMode == nil {
            return nil
        }
        let engineRouterTracesByMode = config.engineRouter.flatMap { engineRouter in
            engineRouterTraces(
                for: engineRouter,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                initialCash: normalizedInitialCash,
                feeRate: normalizedFeeRate,
                slippageRate: normalizedSlippageRate
            )
        }
        if config.engineRouter != nil, engineRouterTracesByMode == nil {
            return nil
        }
        let dynamicSleeveTracesByMode = config.dynamicSleeveSelector.flatMap { selector in
            dynamicSleeveSelectorTraces(
                for: selector,
                symbols: symbols,
                pricesBySymbol: pricesBySymbol,
                maBySymbol: maBySymbol,
                volatilityBySymbol: volatilityBySymbol,
                commonDates: commonDates,
                initialCash: normalizedInitialCash,
                feeRate: normalizedFeeRate,
                slippageRate: normalizedSlippageRate
            )
        }
        if config.dynamicSleeveSelector != nil, dynamicSleeveTracesByMode == nil {
            return nil
        }

        var cash = normalizedInitialCash
        var unitsBySymbol: [String: Double] = Dictionary(uniqueKeysWithValues: tradableSymbols.map { ($0, 0.0) })
        var averageCostBySymbol: [String: Double] = Dictionary(uniqueKeysWithValues: tradableSymbols.map { ($0, 0.0) })
        var entryDateBySymbol: [String: Date] = [:]
        var heldSymbols = Set<String>()
        var points: [BacktestSeriesPoint] = []
        var benchmarkPoints: [BacktestSeriesPoint] = []
        var portfolioValuesByCommonIndex = Array(repeating: 0.0, count: commonDates.count)
        var trades: [AdvancedBacktestTrade] = []
        var exposureSum = 0.0
        var exposureSamples = 0
        var cashRatioSum = 0.0
        var cashRatioSamples = 0
        var cashInterestEarned = 0.0
        var cashAnnualRateSum = 0.0
        var cashAnnualRateSamples = 0
        var dynamicSleeveWeight = config.dynamicSleeveSelector?.initialSatelliteWeight ?? 0.80
        var overlayState = AdvancedRotationOverlayState()

        func portfolioValue(at index: Int) -> Double {
            cash + tradableSymbols.reduce(0.0) { partial, symbol in
                partial + (unitsBySymbol[symbol] ?? 0) * (pricesBySymbol[symbol]?[index] ?? 0)
            }
        }

        func targetWeights(
            at signalIndex: Int,
            traceIndex: Int,
            refreshRepairOverlay: Bool
        ) -> [String: Double] {
            let baseWeights: [String: Double]
            if let selector = config.dynamicSleeveSelector,
               let dynamicSleeveTracesByMode,
               let routed = dynamicSleeveSelectorTargetWeights(
                selector: selector,
                signalIndex: signalIndex,
                weightIndex: traceIndex,
                tracesByMode: dynamicSleeveTracesByMode,
                strategyValues: points.map(\.portfolioValue),
                previousWeight: dynamicSleeveWeight
               ) {
                dynamicSleeveWeight = routed.satelliteWeight
                baseWeights = routed.weights
            } else if config.engineRouter != nil,
                      let engineRouterTracesByMode {
                baseWeights = resolvedAdvancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    traceIndex: traceIndex,
                    config: config,
                    engineRouterTracesByMode: engineRouterTracesByMode,
                    portfolioValues: portfolioValuesByCommonIndex
                )
            } else if let metaSwitch = config.metaSwitch,
                      let metaTracesByMode,
                      let rawMetaWeights = metaRotationTargetWeights(
                metaSwitch: metaSwitch,
                stressIndex: signalIndex,
                weightIndex: traceIndex,
                tracesByMode: metaTracesByMode
              ) {
                let overlayWeights = applyGoldSatelliteOverlay(
                    to: rawMetaWeights,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    pricesBySymbol: pricesBySymbol,
                    portfolioValues: portfolioValuesByCommonIndex,
                    config: config
                )
                baseWeights = applyPostTargetOverlays(
                    to: overlayWeights,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    pricesBySymbol: pricesBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    portfolioValues: portfolioValuesByCommonIndex,
                    config: config
                )
                .filter { !config.signalOnlySymbols.contains($0.key) }
            } else {
                let rawWeights = Dictionary(uniqueKeysWithValues: advancedRotationTargetWeights(
                    symbols: symbols,
                    pricesBySymbol: pricesBySymbol,
                    maBySymbol: maBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    config: config
                )
                .filter { !config.signalOnlySymbols.contains($0.symbol) }
                .map { ($0.symbol, $0.weight) })
                baseWeights = applyPostTargetOverlays(
                    to: rawWeights,
                    signalIndex: signalIndex,
                    signalDate: commonDates[signalIndex],
                    pricesBySymbol: pricesBySymbol,
                    volatilityBySymbol: volatilityBySymbol,
                    portfolioValues: portfolioValuesByCommonIndex,
                    config: config
                )
                .filter { !config.signalOnlySymbols.contains($0.key) }
            }

            return applyAdvancedOverlayStack(
                to: baseWeights,
                signalIndex: signalIndex,
                pricesBySymbol: pricesBySymbol,
                config: config,
                state: &overlayState,
                refreshRepairOverlay: refreshRepairOverlay,
                portfolioValues: portfolioValuesByCommonIndex
            )
            .filter { !config.signalOnlySymbols.contains($0.key) }
        }

        func applyPortfolioDrawdownGuard(
            to targetWeights: [String: Double],
            currentValue: Double
        ) -> [String: Double] {
            guard let guardConfig = config.portfolioDrawdownGuard,
                  !targetWeights.isEmpty,
                  !points.isEmpty else { return targetWeights }
            let lookbackSessions = max(guardConfig.lookbackSessions, 1)
            var recentValues = points.suffix(lookbackSessions).map(\.portfolioValue)
            recentValues.append(currentValue)
            guard let recentPeak = recentValues.max(), recentPeak > 0 else { return targetWeights }
            let drawdownFromPeak = currentValue / recentPeak - 1
            guard drawdownFromPeak < -max(guardConfig.drawdownThreshold, 0) else { return targetWeights }
            let scale = min(max(guardConfig.scale, 0), 1)
            return targetWeights.mapValues { $0 * scale }
        }

        var lastRebalanceIndex = Int.min / 2
        let firstRebalanceIndex = max(simulationRange.lowerBound, 1)

        for index in simulationRange {
            let date = commonDates[index]

            if index > simulationRange.lowerBound {
                let annualCashRate = CashYieldCNY.annualRate(on: commonDates[index - 1])
                cashAnnualRateSum += annualCashRate
                cashAnnualRateSamples += 1
                if cash > 0 {
                    let cashInterest = cash * CashYieldCNY.dailyReturn(fromAnnualRate: annualCashRate)
                    if cashInterest.isFinite, cashInterest > 0 {
                        cash += cashInterest
                        cashInterestEarned += cashInterest
                    }
                } else if cash < 0, normalizedFinancingAnnualRate > 0 {
                    let financingCost = abs(cash) * CashYieldCNY.dailyReturn(fromAnnualRate: normalizedFinancingAnnualRate)
                    if financingCost.isFinite, financingCost > 0 {
                        cash -= financingCost
                    }
                }
            }

            let rebalanceSessions = max(config.rebalanceSessions, 1)
            let overlayRebalanceSessions = config.globalRepairStack.map { max($0.overlayRebalanceSessions, 1) }
            let shouldOverlayRebalance = overlayRebalanceSessions.map {
                index == firstRebalanceIndex || (index > 0 && index % $0 == 0)
            } ?? false
            let shouldBaseRebalance: Bool
            if config.rebalancesFromFirstSignal {
                shouldBaseRebalance = index == firstRebalanceIndex
                    || (index > 0 && index - lastRebalanceIndex >= rebalanceSessions)
            } else {
                shouldBaseRebalance = index == firstRebalanceIndex || (index > 0 && index % rebalanceSessions == 0)
            }
            let shouldRebalance = shouldBaseRebalance || shouldOverlayRebalance

            if shouldRebalance {
                let signalIndex = index - 1
                let preRebalanceValue = portfolioValue(at: index)
                let baseTargetWeights = signalIndex >= 0
                    ? targetWeights(
                        at: signalIndex,
                        traceIndex: index,
                        refreshRepairOverlay: shouldOverlayRebalance
                    )
                    : [:]
                let guardedTargetWeights = config.metaSwitch == nil
                    ? applyPortfolioDrawdownGuard(
                        to: baseTargetWeights,
                        currentValue: preRebalanceValue
                    )
                    : baseTargetWeights
                let targetWeights = normalizedRiskBudgetMultiplier == 1
                    ? guardedTargetWeights
                    : guardedTargetWeights.mapValues { $0 * normalizedRiskBudgetMultiplier }
                let targetSymbols = Set(targetWeights.keys)

                for symbol in heldSymbols.subtracting(targetSymbols) {
                    guard let price = pricesBySymbol[symbol]?[index],
                          let units = unitsBySymbol[symbol],
                          units > 0,
                          let option = optionBySymbol[symbol] else { continue }
                    let executionPrice = max(price * (1 - normalizedSlippageRate), 0)
                    let grossValue = units * executionPrice
                    let cashAmount = grossValue * (1 - normalizedFeeRate)
                    cash += cashAmount
                    unitsBySymbol[symbol] = 0
                    let averageCost = averageCostBySymbol[symbol] ?? 0
                    let realizedCostBasis = averageCost * units
                    let realizedProfit = cashAmount - realizedCostBasis
                    let realizedReturn = realizedCostBasis > 0 ? realizedProfit / realizedCostBasis : nil
                    let holdingDays = entryDateBySymbol[symbol].map { Calendar.current.dateComponents([.day], from: $0, to: date).day ?? 0 }
                    trades.append(.init(
                        assetSymbol: symbol,
                        assetTitle: option.title,
                        date: date,
                        action: .sell,
                        price: executionPrice,
                        cashAmount: cashAmount,
                        units: units,
                        reason: AppLocalization.string("轮动切换/空仓"),
                        realizedProfit: realizedProfit,
                        realizedReturn: realizedReturn,
                        holdingDays: holdingDays
                    ))
                    averageCostBySymbol[symbol] = 0
                    entryDateBySymbol[symbol] = nil
                }

                heldSymbols = heldSymbols.intersection(targetSymbols)

                for symbol in targetSymbols.sorted() {
                    guard let targetWeight = targetWeights[symbol],
                          let price = pricesBySymbol[symbol]?[index],
                          price > 0,
                          let currentUnits = unitsBySymbol[symbol],
                          currentUnits > 0,
                          let option = optionBySymbol[symbol] else { continue }
                    let currentValue = currentUnits * price
                    let targetValue = preRebalanceValue * targetWeight
                    let grossValueToSell = currentValue > targetValue * (1 + normalizedRebalanceBand)
                        ? Swift.max(currentValue - targetValue, 0.0)
                        : 0.0
                    guard grossValueToSell > 0 else { continue }
                    let unitsToSell = Swift.min(currentUnits, grossValueToSell / price)
                    guard unitsToSell > 0 else { continue }
                    let executionPrice = max(price * (1 - normalizedSlippageRate), 0)
                    let grossValue = unitsToSell * executionPrice
                    let cashAmount = grossValue * (1 - normalizedFeeRate)
                    cash += cashAmount
                    let remainingUnits = Swift.max(currentUnits - unitsToSell, 0)
                    unitsBySymbol[symbol] = remainingUnits
                    let averageCost = averageCostBySymbol[symbol] ?? 0
                    let realizedCostBasis = averageCost * unitsToSell
                    let realizedProfit = cashAmount - realizedCostBasis
                    let realizedReturn = realizedCostBasis > 0 ? realizedProfit / realizedCostBasis : nil
                    let holdingDays = entryDateBySymbol[symbol].map { Calendar.current.dateComponents([.day], from: $0, to: date).day ?? 0 }
                    trades.append(.init(
                        assetSymbol: symbol,
                        assetTitle: option.title,
                        date: date,
                        action: .sell,
                        price: executionPrice,
                        cashAmount: cashAmount,
                        units: unitsToSell,
                        reason: AppLocalization.string("轮动再平衡"),
                        realizedProfit: realizedProfit,
                        realizedReturn: realizedReturn,
                        holdingDays: holdingDays
                    ))
                    if remainingUnits <= Double.leastNonzeroMagnitude {
                        averageCostBySymbol[symbol] = 0
                        entryDateBySymbol[symbol] = nil
                        heldSymbols.remove(symbol)
                    }
                }

                let totalValue = portfolioValue(at: index)
                for symbol in targetSymbols.sorted() {
                    guard let targetWeight = targetWeights[symbol],
                          let price = pricesBySymbol[symbol]?[index],
                          price > 0,
                          let option = optionBySymbol[symbol] else { continue }
                    let currentValue = (unitsBySymbol[symbol] ?? 0) * price
                    let targetValue = totalValue * targetWeight
                    let targetGap = Swift.max(targetValue - currentValue, 0.0)
                    let amountToInvest = currentValue < targetValue * (1 - normalizedRebalanceBand)
                        ? (allowsFinancedExposure ? targetGap : Swift.min(cash, targetGap))
                        : 0.0
                    if amountToInvest > 0 {
                        let executionPrice = price * (1 + normalizedSlippageRate)
                        let invested = amountToInvest * (1 - normalizedFeeRate)
                        let units = executionPrice > 0 ? invested / executionPrice : 0
                        let previousUnits = unitsBySymbol[symbol] ?? 0
                        let previousCost = (averageCostBySymbol[symbol] ?? 0) * previousUnits
                        unitsBySymbol[symbol] = previousUnits + units
                        averageCostBySymbol[symbol] = (previousCost + amountToInvest) / Swift.max(previousUnits + units, Double.leastNonzeroMagnitude)
                        cash -= amountToInvest
                        heldSymbols.insert(symbol)
                        if entryDateBySymbol[symbol] == nil { entryDateBySymbol[symbol] = date }
                        trades.append(.init(
                            assetSymbol: symbol,
                            assetTitle: option.title,
                            date: date,
                            action: .buy,
                            price: executionPrice,
                            cashAmount: amountToInvest,
                            units: units,
                            reason: config.buyReason,
                            realizedProfit: nil,
                            realizedReturn: nil,
                            holdingDays: nil
                        ))
                    }
                }
                lastRebalanceIndex = index
            }

            let value = portfolioValue(at: index)
            points.append(.init(date: date, portfolioValue: value, sequence: points.count))
            portfolioValuesByCommonIndex[index] = value
            let investedValue = tradableSymbols.reduce(0.0) { partial, symbol in
                partial + (unitsBySymbol[symbol] ?? 0) * (pricesBySymbol[symbol]?[index] ?? 0)
            }
            exposureSum += value > 0 ? investedValue / value : 0
            exposureSamples += 1
            cashRatioSum += value > 0 ? min(max(cash / value, 0), 1) : 0
            cashRatioSamples += 1

            let benchmarkValue = tradableSymbols.reduce(0.0) { partial, symbol in
                guard let prices = pricesBySymbol[symbol],
                      prices.indices.contains(simulationRange.lowerBound),
                      prices.indices.contains(index) else { return partial }
                let firstPrice = prices[simulationRange.lowerBound]
                guard firstPrice > 0 else { return partial }
                return partial + normalizedInitialCash / Double(tradableSymbols.count) * prices[index] / firstPrice
            }
            benchmarkPoints.append(.init(date: date, portfolioValue: benchmarkValue, sequence: benchmarkPoints.count))
        }

        guard let last = points.last,
              let metrics = performanceMetrics(from: points) else { return nil }

        let perAssetBenchmarkSeries = tradableSymbols.compactMap { symbol -> AdvancedBacktestBenchmarkSeries? in
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(simulationRange.lowerBound),
                  prices.indices.contains(simulationRange.upperBound),
                  let option = optionBySymbol[symbol] else { return nil }
            let firstPrice = prices[simulationRange.lowerBound]
            guard firstPrice > 0 else { return nil }
            let seriesPoints = simulationRange.enumerated().map { sequence, index in
                BacktestSeriesPoint(
                    date: commonDates[index],
                    portfolioValue: normalizedInitialCash / Double(tradableSymbols.count) * prices[index] / firstPrice,
                    sequence: sequence
                )
            }
            return AdvancedBacktestBenchmarkSeries(id: symbol, title: option.title, points: seriesPoints)
        }

        let syntheticReport = AdvancedBacktestAssetReport(
            symbol: config.symbol,
            title: config.title,
            points: points,
            benchmarkPoints: benchmarkPoints,
            pricePoints: [],
            trades: trades,
            finalPortfolioValue: last.portfolioValue,
            finalCash: cash,
            finalUnits: unitsBySymbol.values.reduce(0, +),
            exposureRatio: exposureSamples > 0 ? exposureSum / Double(exposureSamples) : 0
        )
        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: cashInterestEarned,
            averageCashRatio: cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0,
            averageAnnualRate: cashAnnualRateSamples > 0 ? cashAnnualRateSum / Double(cashAnnualRateSamples) : 0
        )
        let riskSignalSummary = MarketRiskSignalHistory.summary(
            dates: Array(commonDates[simulationRange]),
            pricesBySymbol: pricesBySymbol.mapValues { Array($0[simulationRange]) }
        )

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: benchmarkPoints,
            benchmarkSeries: perAssetBenchmarkSeries,
            trades: trades.sorted { lhs, rhs in lhs.date < rhs.date },
            assetReports: [syntheticReport],
            finalPortfolioValue: last.portfolioValue,
            finalCash: cash,
            finalUnits: unitsBySymbol.values.reduce(0, +),
            totalReturn: metrics.totalReturn,
            annualizedReturn: metrics.annualizedReturn,
            maxDrawdown: metrics.maxDrawdown,
            annualizedVolatility: metrics.annualizedVolatility,
            sharpeRatio: metrics.sharpeRatio,
            cashYieldSummary: cashYieldSummary,
            riskSignalSummary: riskSignalSummary
        )
    }

    private static func alignedRotationPriceSeries(
        from preparedSeries: [PreparedAdvancedSeries],
        zeroFillBeforeFirstSymbols: Set<String> = []
    ) -> (dates: [Date], pricesBySymbol: [String: [Double]]) {
        let allDates = Set(preparedSeries.flatMap { $0.pricePoints.map(\.date) }).sorted()
        var indices = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, 0) })
        var latestPrices: [String: Double] = [:]
        var latestPriceDates: [String: Date] = [:]
        var outputDates: [Date] = []
        var pricesBySymbol = Dictionary(uniqueKeysWithValues: preparedSeries.map { ($0.assetOption.symbol, [Double]()) })

        for date in allDates {
            for series in preparedSeries {
                let symbol = series.assetOption.symbol
                var index = indices[symbol] ?? 0
                while index < series.pricePoints.count && series.pricePoints[index].date <= date {
                    latestPrices[symbol] = series.pricePoints[index].cnyPrice
                    latestPriceDates[symbol] = series.pricePoints[index].date
                    index += 1
                }
                indices[symbol] = index
            }

            guard preparedSeries.allSatisfy({ series in
                let symbol = series.assetOption.symbol
                guard latestPrices[symbol] != nil,
                      let latestPriceDate = latestPriceDates[symbol] else {
                    return zeroFillBeforeFirstSymbols.contains(symbol)
                }
                let staleDays = historicalSeriesCalendar.dateComponents([.day], from: latestPriceDate, to: date).day ?? Int.max
                return staleDays <= maxForwardFillCalendarDays
            }) else { continue }
            outputDates.append(date)
            for series in preparedSeries {
                let symbol = series.assetOption.symbol
                pricesBySymbol[symbol, default: []].append(latestPrices[symbol] ?? 0)
            }
        }

        return (outputDates, pricesBySymbol)
    }

    private static func runAdvancedStrategies(
        preparedSeries: [PreparedAdvancedSeries],
        initialCash: Double,
        tradeAmount: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        settings: AdvancedBacktestRiskSettings
    ) -> AdvancedBacktestReport? {
        guard !preparedSeries.isEmpty else { return nil }

        let normalizedInitialCash = max(initialCash, 0)
        let perAssetInitialCash = normalizedInitialCash / Double(preparedSeries.count)
        guard perAssetInitialCash > 0 else { return nil }

        let reports = preparedSeries.compactMap { series in
            runAdvancedStrategy(
                preparedSeries: series,
                initialCash: perAssetInitialCash,
                tradeAmount: tradeAmount,
                buyRule: buyRule,
                sellRule: sellRule,
                settings: settings
            )
        }
        guard !reports.isEmpty else { return nil }
        if reports.count == 1, let report = reports.first { return report }

        let allDates = Set(reports.flatMap { $0.points.map(\.date) }).sorted()
        guard !allDates.isEmpty else { return nil }

        var valueByReportIndex = Array(repeating: perAssetInitialCash, count: reports.count)
        var benchmarkValueByReportIndex = Array(repeating: perAssetInitialCash, count: reports.count)
        var cursors = Array(repeating: 0, count: reports.count)
        var benchmarkCursors = Array(repeating: 0, count: reports.count)
        var combinedPoints: [BacktestSeriesPoint] = []
        var combinedBenchmarkPoints: [BacktestSeriesPoint] = []
        combinedPoints.reserveCapacity(allDates.count)
        combinedBenchmarkPoints.reserveCapacity(allDates.count)

        for date in allDates {
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
            }

            let totalValue = valueByReportIndex.reduce(0, +)
            let totalBenchmarkValue = benchmarkValueByReportIndex.reduce(0, +)
            combinedPoints.append(BacktestSeriesPoint(date: date, portfolioValue: totalValue, sequence: combinedPoints.count))
            combinedBenchmarkPoints.append(BacktestSeriesPoint(date: date, portfolioValue: totalBenchmarkValue, sequence: combinedBenchmarkPoints.count))
        }

        guard let last = combinedPoints.last,
              let metrics = performanceMetrics(from: combinedPoints) else { return nil }

        let assetReports = reports.flatMap(\.assetReports)
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
            riskSignalSummary: nil
        )
    }

    private static func scoreAdvancedReport(_ report: AdvancedBacktestReport) -> Double {
        let annualized = report.annualizedReturn ?? report.totalReturn
        let sharpe = report.sharpeRatio ?? 0
        let excess = report.excessReturn ?? 0
        let tradePenalty = report.trades.count < 2 ? 0.35 : 0

        var validationAdjustment = 0.0
        if report.points.count >= 90 {
            let validationCount = min(max(report.points.count / 3, 60), report.points.count - 1)
            let validationPoints = Array(report.points.suffix(validationCount))
            if let validationMetrics = performanceMetrics(from: validationPoints) {
                let recentReturn = validationMetrics.totalReturn
                let recentDrawdown = validationMetrics.maxDrawdown
                validationAdjustment += max(recentReturn, 0) * 0.18
                validationAdjustment -= max(-recentReturn, 0) * 0.65
                validationAdjustment -= max(recentDrawdown - report.maxDrawdown, 0) * 0.35
            }
        }

        return annualized * 1.25
            + max(excess, 0) * 0.45
            + sharpe * 0.18
            + validationAdjustment
            - report.maxDrawdown * 1.2
            - tradePenalty
    }

    static func optimizeAdvancedStrategy(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?,
        initialCash: Double,
        baseSettings: AdvancedBacktestRiskSettings,
        limit: Int = 3
    ) -> [AdvancedBacktestCandidate] {
        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return [] }
        guard let preparedSeries = preparedAdvancedSeries(assetSeries: assetSeries, assetOption: assetOption, fxSeries: fxSeries) else { return [] }

        let maxCandidateCount = max(limit, 1)
        let buyDirections: [AdvancedBacktestSignalDirection] = [
            .alwaysBuy,
            .consecutiveDown,
            .priceAboveMA20,
            .priceAboveMA60,
            .priceCrossesAboveMA20,
            .priceCrossesAboveBollMiddle,
            .touchesBollLower,
            .ma20CrossesAboveMA60
        ]
        let sellDirections: [AdvancedBacktestSignalDirection] = [
            .neverSell,
            .consecutiveUp,
            .priceBelowMA20,
            .priceBelowMA60,
            .priceCrossesBelowMA20,
            .priceCrossesBelowBollMiddle,
            .touchesBollUpper,
            .ma20CrossesBelowMA60
        ]
        let dayThresholds = [2, 3, 5]
        let tradeAmounts = [
            normalizedInitialCash * 0.05,
            normalizedInitialCash * 0.10,
            normalizedInitialCash * 0.20
        ]
        let maxPositionRatios = Array(Set([baseSettings.maxPositionRatio, 35, 50, 70, 100]))
            .filter { $0 > 0 }
            .sorted()

        var topCandidates: [AdvancedBacktestCandidate] = []
        func retainIfTopCandidate(_ candidate: AdvancedBacktestCandidate) {
            if topCandidates.count < maxCandidateCount {
                topCandidates.append(candidate)
                topCandidates.sort { $0.score > $1.score }
                return
            }

            guard let weakestCandidate = topCandidates.last,
                  candidate.score > weakestCandidate.score else { return }
            topCandidates.removeLast()
            topCandidates.append(candidate)
            topCandidates.sort { $0.score > $1.score }
        }

        for buyDirection in buyDirections {
            for sellDirection in sellDirections {
                for buyDays in dayThresholds {
                    for sellDays in dayThresholds {
                        for tradeAmount in tradeAmounts {
                            for maxPositionRatio in maxPositionRatios {
                                if Task.isCancelled { return topCandidates }

                                var settings = baseSettings
                                settings.maxPositionRatio = maxPositionRatio
                                let buyRule = AdvancedBacktestRule(direction: buyDirection, days: buyDirection.usesDayThreshold ? buyDays : 1)
                                let sellRule = AdvancedBacktestRule(direction: sellDirection, days: sellDirection.usesDayThreshold ? sellDays : 1)
                                guard let report = runAdvancedStrategy(
                                    preparedSeries: preparedSeries,
                                    initialCash: normalizedInitialCash,
                                    tradeAmount: tradeAmount,
                                    buyRule: buyRule,
                                    sellRule: sellRule,
                                    settings: settings
                                ), report.points.count > 20 else { continue }
                                retainIfTopCandidate(
                                    AdvancedBacktestCandidate(
                                        buyRule: buyRule,
                                        sellRule: sellRule,
                                        tradeAmount: tradeAmount,
                                        settings: settings,
                                        report: report,
                                        comparisonSeries: AdvancedBacktestPresentation.comparisonSeries(from: report),
                                        score: scoreAdvancedReport(report)
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        return topCandidates
    }

    static func optimizeAdvancedStrategies(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        baseSettings: AdvancedBacktestRiskSettings,
        limit: Int = 3
    ) -> [AdvancedBacktestCandidate] {
        let normalizedInitialCash = max(initialCash, 0)
        guard normalizedInitialCash > 0 else { return [] }

        let validInputs = assetInputs.filter { input in
            input.assetSeries != nil && (!input.assetOption.requiresHistoricalFX || input.fxSeries != nil)
        }
        guard !validInputs.isEmpty else { return [] }
        let preparedSeries = validInputs.compactMap { input in
            preparedAdvancedSeries(assetSeries: input.assetSeries, assetOption: input.assetOption, fxSeries: input.fxSeries)
        }
        guard !preparedSeries.isEmpty else { return [] }

        let maxCandidateCount = max(limit, 1)
        let buyDirections: [AdvancedBacktestSignalDirection] = [
            .alwaysBuy,
            .consecutiveDown,
            .priceAboveMA20,
            .priceAboveMA60,
            .priceCrossesAboveMA20,
            .priceCrossesAboveBollMiddle,
            .touchesBollLower,
            .ma20CrossesAboveMA60
        ]
        let sellDirections: [AdvancedBacktestSignalDirection] = [
            .neverSell,
            .consecutiveUp,
            .priceBelowMA20,
            .priceBelowMA60,
            .priceCrossesBelowMA20,
            .priceCrossesBelowBollMiddle,
            .touchesBollUpper,
            .ma20CrossesBelowMA60
        ]
        let dayThresholds = [2, 3, 5]
        let tradeAmounts = [
            normalizedInitialCash * 0.05,
            normalizedInitialCash * 0.10,
            normalizedInitialCash * 0.20
        ]
        let maxPositionRatios = Array(Set([baseSettings.maxPositionRatio, 35, 50, 70, 100]))
            .filter { $0 > 0 }
            .sorted()

        var topCandidates: [AdvancedBacktestCandidate] = []
        func retainIfTopCandidate(_ candidate: AdvancedBacktestCandidate) {
            if topCandidates.count < maxCandidateCount {
                topCandidates.append(candidate)
                topCandidates.sort { $0.score > $1.score }
                return
            }

            guard let weakestCandidate = topCandidates.last,
                  candidate.score > weakestCandidate.score else { return }
            topCandidates.removeLast()
            topCandidates.append(candidate)
            topCandidates.sort { $0.score > $1.score }
        }

        for buyDirection in buyDirections {
            for sellDirection in sellDirections {
                for buyDays in dayThresholds {
                    for sellDays in dayThresholds {
                        for tradeAmount in tradeAmounts {
                            for maxPositionRatio in maxPositionRatios {
                                if Task.isCancelled { return topCandidates }

                                var settings = baseSettings
                                settings.maxPositionRatio = maxPositionRatio
                                let buyRule = AdvancedBacktestRule(direction: buyDirection, days: buyDirection.usesDayThreshold ? buyDays : 1)
                                let sellRule = AdvancedBacktestRule(direction: sellDirection, days: sellDirection.usesDayThreshold ? sellDays : 1)
                                guard let report = runAdvancedStrategies(
                                    preparedSeries: preparedSeries,
                                    initialCash: normalizedInitialCash,
                                    tradeAmount: tradeAmount,
                                    buyRule: buyRule,
                                    sellRule: sellRule,
                                    settings: settings
                                ), report.points.count > 20 else { continue }
                                retainIfTopCandidate(
                                    AdvancedBacktestCandidate(
                                        buyRule: buyRule,
                                        sellRule: sellRule,
                                        tradeAmount: tradeAmount,
                                        settings: settings,
                                        report: report,
                                        comparisonSeries: AdvancedBacktestPresentation.comparisonSeries(from: report),
                                        score: scoreAdvancedReport(report)
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        return topCandidates
    }

    private static func rollingAnnualizedVolatility(values: [Double], period: Int) -> [Double?] {
        guard period > 1, values.count > 1 else { return Array(repeating: nil, count: values.count) }

        var logReturns = Array<Double>(repeating: 0, count: values.count)
        for index in values.indices.dropFirst() {
            let previous = values[index - 1]
            let current = values[index]
            logReturns[index] = previous > 0 && current > 0 ? log(current / previous) : 0
        }

        var result = Array<Double?>(repeating: nil, count: values.count)
        var rollingSum = 0.0
        var rollingSquaredSum = 0.0

        for index in logReturns.indices {
            let value = logReturns[index]
            rollingSum += value
            rollingSquaredSum += value * value

            if index >= period {
                let removed = logReturns[index - period]
                rollingSum -= removed
                rollingSquaredSum -= removed * removed
            }

            if index >= period {
                let mean = rollingSum / Double(period)
                let variance = max((rollingSquaredSum / Double(period)) - (mean * mean), 0)
                result[index] = sqrt(variance) * sqrt(252)
            }
        }

        return result
    }

    private static func movingAverage(values: [Double], period: Int) -> [Double?] {
        guard period > 0, !values.isEmpty else { return Array(repeating: nil, count: values.count) }

        var result = Array<Double?>(repeating: nil, count: values.count)
        var rollingSum = 0.0

        for index in values.indices {
            rollingSum += values[index]
            if index >= period {
                rollingSum -= values[index - period]
            }
            if index >= period - 1 {
                result[index] = rollingSum / Double(period)
            }
        }

        return result
    }

    private static func priceMomentum(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index),
              values.indices.contains(index - lookback) else { return nil }
        let previous = values[index - lookback]
        guard previous > 0 else { return nil }
        return values[index] / previous - 1
    }

    private static func rollingDrawdownFromHigh(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index - period + 1 >= 0 else { return nil }
        let startIndex = index - period + 1
        guard let peak = values[startIndex...index].max(), peak > 0 else { return nil }
        return values[index] / peak - 1
    }

    private static func relativeStrengthIndex(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index >= period,
              values.count > period else { return nil }

        var averageGain = 0.0
        var averageLoss = 0.0
        for cursor in 1...period {
            let previous = values[cursor - 1]
            let change = previous > 0 ? values[cursor] / previous - 1 : 0
            averageGain += max(change, 0)
            averageLoss += max(-change, 0)
        }
        averageGain /= Double(period)
        averageLoss /= Double(period)

        if index > period {
            for cursor in (period + 1)...index {
                let previous = values[cursor - 1]
                let change = previous > 0 ? values[cursor] / previous - 1 : 0
                let gain = max(change, 0)
                let loss = max(-change, 0)
                averageGain = (averageGain * Double(period - 1) + gain) / Double(period)
                averageLoss = (averageLoss * Double(period - 1) + loss) / Double(period)
            }
        }

        if averageLoss == 0 { return 100 }
        let relativeStrength = averageGain / averageLoss
        return 100 - 100 / (1 + relativeStrength)
    }

    private static func donchianRangePosition(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index - period + 1 >= 0 else { return nil }
        let startIndex = index - period + 1
        guard let high = values[startIndex...index].max(),
              let low = values[startIndex...index].min() else { return nil }
        return (values[index] - low) / max(high - low, 1e-12)
    }

    private static func bollingerBands(values: [Double], period: Int, multiplier: Double) -> [(middle: Double, lower: Double, upper: Double)?] {
        guard period > 0, !values.isEmpty else { return Array(repeating: nil, count: values.count) }

        var result = Array<(middle: Double, lower: Double, upper: Double)?>(repeating: nil, count: values.count)
        var rollingSum = 0.0
        var rollingSquaredSum = 0.0

        for index in values.indices {
            let value = values[index]
            rollingSum += value
            rollingSquaredSum += value * value

            if index >= period {
                let removed = values[index - period]
                rollingSum -= removed
                rollingSquaredSum -= removed * removed
            }

            if index >= period - 1 {
                let mean = rollingSum / Double(period)
                let variance = max((rollingSquaredSum / Double(period)) - (mean * mean), 0)
                let deviation = sqrt(variance)
                result[index] = (
                    middle: mean,
                    lower: mean - multiplier * deviation,
                    upper: mean + multiplier * deviation
                )
            }
        }

        return result
    }

    private static func advancedRuleTriggered(
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

    static func availableDateBounds(for seriesList: [PublicHistorySeries]) -> ClosedRange<Date>? {
        BacktestSeriesAlignment.availableDateBounds(for: seriesList)
    }

    fileprivate static func historicalSeriesDateStatic(from text: String) -> Date? {
        BacktestSeriesAlignment.historicalSeriesDate(from: text)
    }

    private static let historicalSeriesCalendar = BacktestSeriesAlignment.historicalSeriesCalendar

    private static let maxForwardFillCalendarDays = BacktestSeriesAlignment.maxForwardFillCalendarDays

    private static func makeHistoricalLookup(from series: PublicHistorySeries?) -> HistoricalLookup? {
        BacktestSeriesAlignment.makeHistoricalLookup(from: series)
    }

    private static func cnyPrice(
        for point: HistoricalPricePoint,
        assetOption: BacktestAssetOption,
        fxLookup: HistoricalLookup?
    ) -> Double? {
        BacktestFXConverter.cnyPrice(for: point, assetOption: assetOption, fxLookup: fxLookup)
    }
}
