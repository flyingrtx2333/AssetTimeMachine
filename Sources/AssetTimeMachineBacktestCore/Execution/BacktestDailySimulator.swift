import Foundation

nonisolated public enum BacktestDailySimulator {
    public static func run(
        frame: MarketDataFrame,
        execution: BacktestExecutionConfig,
        provider: StrategyTargetProvider,
        rebalanceDecision: (Int, Int) -> BacktestRebalanceDecision,
        contextualRebalanceDecision: ((StrategyTargetContext) -> BacktestRebalanceDecision)? = nil,
        didExecuteTarget: ((Int) -> Void)? = nil
    ) -> BacktestDailySimulationResult? {
        guard execution.initialCash > 0,
              frame.simulationRange.count > 1,
              !frame.tradableSymbols.isEmpty else { return nil }

        var cash = execution.initialCash
        var unitsBySymbol = Dictionary(uniqueKeysWithValues: frame.tradableSymbols.map { ($0, 0.0) })
        var averageCostBySymbol = Dictionary(uniqueKeysWithValues: frame.tradableSymbols.map { ($0, 0.0) })
        var entryDateBySymbol: [String: Date] = [:]
        var heldSymbols = Set<String>()
        var points: [BacktestSeriesPoint] = []
        var benchmarkPoints: [BacktestSeriesPoint] = []
        var trades: [AdvancedBacktestTrade] = []
        var dailyStates: [BacktestDailyState] = []
        var currentTargetWeights: [String: Double] = [:]
        var pendingTargetWeights: [String: Double]?
        var portfolioValuesByIndex = Array(repeating: 0.0, count: frame.dates.count)
        var exposureSum = 0.0
        var exposureSamples = 0
        var cashRatioSum = 0.0
        var cashRatioSamples = 0
        var cashInterestEarned = 0.0
        var cashAnnualRateSum = 0.0
        var cashAnnualRateSamples = 0
        let benchmarkEntryIndexBySymbol: [String: Int] = Dictionary(uniqueKeysWithValues: frame.tradableSymbols.compactMap { symbol in
            guard let entryIndex = frame.simulationRange.first(where: { index in
                (frame.pricesBySymbol[symbol]?[index] ?? 0) > 0
                    && frame.observedBySymbol[symbol]?[index] == true
            }) else { return nil }
            return (symbol, entryIndex)
        })

        func portfolioValue(at index: Int) -> Double {
            cash + frame.tradableSymbols.reduce(0.0) { partial, symbol in
                partial + (unitsBySymbol[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?[index] ?? 0)
            }
        }

        for index in frame.simulationRange {
            guard !Task.isCancelled else { return nil }
            let date = frame.dates[index]

            if index > frame.simulationRange.lowerBound {
                let previousDate = frame.dates[index - 1]
                let annualCashRate = CashYieldCNY.annualRate(on: previousDate)
                cashAnnualRateSum += annualCashRate
                cashAnnualRateSamples += 1
                if cash > 0 {
                    let cashInterest = cash * CashYieldCNY.periodReturn(from: previousDate, to: date)
                    if cashInterest.isFinite, cashInterest > 0 {
                        cash += cashInterest
                        cashInterestEarned += cashInterest
                    }
                } else if cash < 0, execution.financingAnnualRate > 0 {
                    let financingCost = abs(cash) * CashYieldCNY.periodReturn(
                        fromAnnualRate: execution.financingAnnualRate,
                        from: previousDate,
                        to: date
                    )
                    if financingCost.isFinite, financingCost > 0 {
                        cash -= financingCost
                    }
                }
            }

            let signalIndex = index - 1
            let preRebalanceValue = portfolioValue(at: index)
            let signalPortfolioValue = points.last?.portfolioValue ?? preRebalanceValue
            let signalDate = signalIndex >= 0 && frame.dates.indices.contains(signalIndex)
                ? frame.dates[signalIndex]
                : date
            let decisionContext = StrategyTargetContext(
                index: index,
                signalIndex: signalIndex,
                date: date,
                signalDate: signalDate,
                signalPortfolioValue: signalPortfolioValue,
                points: points,
                portfolioValuesByIndex: portfolioValuesByIndex,
                refreshOverlay: false
            )
            // Observe every eligible signal, including one-shot updates while
            // an earlier target waits for a quote or settlement.
            let decision = contextualRebalanceDecision?(decisionContext)
                ?? rebalanceDecision(index, signalIndex)
            if decision.shouldRebalance {
                let targetWeights: [String: Double]
                if signalIndex >= 0, frame.dates.indices.contains(signalIndex) {
                    targetWeights = provider.targetWeights(
                        StrategyTargetContext(
                            index: index,
                            signalIndex: signalIndex,
                            date: date,
                            signalDate: signalDate,
                            signalPortfolioValue: signalPortfolioValue,
                            points: points,
                            portfolioValuesByIndex: portfolioValuesByIndex,
                            refreshOverlay: decision.refreshOverlay
                        )
                    )
                } else {
                    targetWeights = [:]
                }
                currentTargetWeights = targetWeights
                pendingTargetWeights = targetWeights
            }

            if let targetWeights = pendingTargetWeights {
                let targetSymbols = Set(targetWeights.keys)
                let executionSymbols = heldSymbols.union(targetSymbols)
                let canExecuteTarget = executionSymbols.allSatisfy { symbol in
                    frame.observedBySymbol[symbol]?[index] == true
                        && (frame.pricesBySymbol[symbol]?[index] ?? 0) > 0
                }

                if canExecuteTarget {

                // Snapshot settled cash before today's sales. Sale proceeds
                // stay in NAV but cannot fund purchases until a later session.
                var settledBuyBudget = Swift.max(cash, 0)
                var hasSettlementDeferredBuy = false

                for symbol in heldSymbols.subtracting(targetSymbols).sorted() {
                    guard let price = frame.pricesBySymbol[symbol]?[index],
                          let units = unitsBySymbol[symbol],
                          units > 0,
                          let option = frame.optionBySymbol[symbol] else { continue }
                    let executionPrice = max(price * (1 - execution.slippageRate), 0)
                    let grossValue = units * executionPrice
                    let cashAmount = grossValue * (1 - execution.feeRate)
                    cash += cashAmount
                    unitsBySymbol[symbol] = 0
                    let averageCost = averageCostBySymbol[symbol] ?? 0
                    let realizedCostBasis = averageCost * units
                    let realizedProfit = cashAmount - realizedCostBasis
                    let realizedReturn = realizedCostBasis > 0 ? realizedProfit / realizedCostBasis : nil
                    let holdingDays = entryDateBySymbol[symbol].map { BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents([.day], from: $0, to: date).day ?? 0 }
                    trades.append(.init(
                        assetSymbol: symbol,
                        assetTitle: option.title,
                        date: date,
                        action: .sell,
                        price: executionPrice,
                        cashAmount: cashAmount,
                        units: units,
                        reason: BacktestText.string("轮动切换/空仓"),
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
                          let price = frame.pricesBySymbol[symbol]?[index],
                          price > 0,
                          let currentUnits = unitsBySymbol[symbol],
                          currentUnits > 0,
                          let option = frame.optionBySymbol[symbol] else { continue }
                    let currentValue = currentUnits * price
                    let targetValue = preRebalanceValue * targetWeight
                    let upperBoundaryValue = targetValue * (1 + execution.rebalanceBand)
                    let grossValueToSell: Double
                    if currentValue > upperBoundaryValue {
                        grossValueToSell = execution.tradeToBandBoundary
                            ? Swift.max(currentValue - upperBoundaryValue, 0.0)
                            : Swift.max(currentValue - targetValue, 0.0)
                    } else {
                        grossValueToSell = 0.0
                    }
                    guard grossValueToSell > 0 else { continue }
                    let unitsToSell = Swift.min(currentUnits, grossValueToSell / price)
                    guard unitsToSell > 0 else { continue }
                    let executionPrice = max(price * (1 - execution.slippageRate), 0)
                    let grossValue = unitsToSell * executionPrice
                    let cashAmount = grossValue * (1 - execution.feeRate)
                    cash += cashAmount
                    let remainingUnits = Swift.max(currentUnits - unitsToSell, 0)
                    unitsBySymbol[symbol] = remainingUnits
                    let averageCost = averageCostBySymbol[symbol] ?? 0
                    let realizedCostBasis = averageCost * unitsToSell
                    let realizedProfit = cashAmount - realizedCostBasis
                    let realizedReturn = realizedCostBasis > 0 ? realizedProfit / realizedCostBasis : nil
                    let holdingDays = entryDateBySymbol[symbol].map { BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents([.day], from: $0, to: date).day ?? 0 }
                    trades.append(.init(
                        assetSymbol: symbol,
                        assetTitle: option.title,
                        date: date,
                        action: .sell,
                        price: executionPrice,
                        cashAmount: cashAmount,
                        units: unitsToSell,
                        reason: BacktestText.string("轮动再平衡"),
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

                // Previously settled cash remains usable even if today's
                // marked holdings trigger another small sale.
                let totalValue = portfolioValue(at: index)
                for symbol in targetSymbols.sorted() {
                    guard let targetWeight = targetWeights[symbol],
                          let price = frame.pricesBySymbol[symbol]?[index],
                          price > 0,
                          let option = frame.optionBySymbol[symbol] else { continue }
                    let currentValue = (unitsBySymbol[symbol] ?? 0) * price
                    let targetValue = totalValue * targetWeight
                    let targetGap = Swift.max(targetValue - currentValue, 0.0)
                    let lowerBoundaryValue = targetValue * (1 - execution.rebalanceBand)
                    let desiredGap: Double
                    if currentValue <= 0.0001 {
                        // New positions enter at the requested target. Boundary trading only
                        // smooths rebalances of an existing position.
                        desiredGap = targetGap
                    } else if currentValue < lowerBoundaryValue {
                        desiredGap = execution.tradeToBandBoundary
                            ? Swift.max(lowerBoundaryValue - currentValue, 0.0)
                            : targetGap
                    } else {
                        desiredGap = 0.0
                    }
                    let availableBudget = Swift.min(Swift.max(cash, 0), settledBuyBudget)
                    if !execution.allowsFinancedExposure,
                       desiredGap > availableBudget + 0.0001,
                       cash > availableBudget + 0.0001 {
                        hasSettlementDeferredBuy = true
                    }
                    let amountToInvest = execution.allowsFinancedExposure
                        ? desiredGap
                        : Swift.min(availableBudget, desiredGap)
                    if amountToInvest > 0 {
                        let executionPrice = price * (1 + execution.slippageRate)
                        let invested = amountToInvest * (1 - execution.feeRate)
                        let units = executionPrice > 0 ? invested / executionPrice : 0
                        let previousUnits = unitsBySymbol[symbol] ?? 0
                        let previousCost = (averageCostBySymbol[symbol] ?? 0) * previousUnits
                        unitsBySymbol[symbol] = previousUnits + units
                        averageCostBySymbol[symbol] = (previousCost + amountToInvest) / Swift.max(previousUnits + units, Double.leastNonzeroMagnitude)
                        cash -= amountToInvest
                        settledBuyBudget = Swift.max(settledBuyBudget - amountToInvest, 0)
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
                            reason: execution.buyReason,
                            realizedProfit: nil,
                            realizedReturn: nil,
                            holdingDays: nil
                        ))
                    }
                }
                if !hasSettlementDeferredBuy {
                    pendingTargetWeights = nil
                    didExecuteTarget?(index)
                }
                }
            }

            let value = portfolioValue(at: index)
            points.append(.init(date: date, portfolioValue: value, sequence: points.count))
            portfolioValuesByIndex[index] = value
            var holdingsBySymbol: [String: Double] = [:]
            for symbol in frame.tradableSymbols {
                let holdingValue = (unitsBySymbol[symbol] ?? 0) * (frame.pricesBySymbol[symbol]?[index] ?? 0)
                if holdingValue > 0.0001 {
                    holdingsBySymbol[symbol] = holdingValue
                }
            }
            let investedValue = holdingsBySymbol.values.reduce(0, +)
            dailyStates.append(BacktestDailyState(
                date: date,
                targetWeights: currentTargetWeights,
                cash: cash,
                holdingsBySymbol: holdingsBySymbol,
                portfolioValue: value
            ))
            exposureSum += value > 0 ? investedValue / value : 0
            exposureSamples += 1
            cashRatioSum += value > 0 ? min(max(cash / value, 0), 1) : 0
            cashRatioSamples += 1

            let benchmarkValue = frame.tradableSymbols.reduce(0.0) { partial, symbol in
                let allocation = execution.initialCash / Double(frame.tradableSymbols.count)
                guard let entryIndex = benchmarkEntryIndexBySymbol[symbol],
                      entryIndex <= index,
                      let prices = frame.pricesBySymbol[symbol],
                      prices.indices.contains(entryIndex),
                      prices.indices.contains(index),
                      prices[entryIndex] > 0 else {
                    // Reserve this sleeve as cash until the asset has a genuine
                    // first observation instead of dropping it from the benchmark.
                    return partial + allocation
                }
                return partial + allocation * prices[index] / prices[entryIndex]
            }
            benchmarkPoints.append(.init(date: date, portfolioValue: benchmarkValue, sequence: benchmarkPoints.count))
        }

        let cashYieldSummary = CashYieldCNY.summary(
            startDate: points.first?.date,
            endDate: points.last?.date,
            totalCashInterest: cashInterestEarned,
            averageCashRatio: cashRatioSamples > 0 ? cashRatioSum / Double(cashRatioSamples) : 0,
            averageAnnualRate: cashAnnualRateSamples > 0 ? cashAnnualRateSum / Double(cashAnnualRateSamples) : 0
        )
        return BacktestDailySimulationResult(
            points: points,
            benchmarkPoints: benchmarkPoints,
            trades: trades.sorted { lhs, rhs in lhs.date < rhs.date },
            finalCash: cash,
            finalUnits: unitsBySymbol.values.reduce(0, +),
            exposureRatio: exposureSamples > 0 ? exposureSum / Double(exposureSamples) : 0,
            cashYieldSummary: cashYieldSummary,
            portfolioValuesByIndex: portfolioValuesByIndex,
            dailyStates: dailyStates
        )
    }
}


