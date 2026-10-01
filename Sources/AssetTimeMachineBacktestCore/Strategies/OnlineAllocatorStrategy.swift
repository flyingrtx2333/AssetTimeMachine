import Foundation

nonisolated enum OnlineAllocatorStrategy {
    static func runOnlineStrategyAllocatorWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil
    ) -> ResearchTargetStrategyRun? {
        let modes: [AdvancedBacktestStrategyMode] = [
            .coreGoldSatelliteRiskBudgetStateGateMomentum,
            .coreGoldSatelliteSharpeStateGateMomentum,
            .coreGoldSatelliteProfitLockMomentum,
            .goldNasdaqDualTrendBarbell,
        ]
        let requiredSymbols = Set(modes.flatMap(\.requiredSignalAssetSymbols))
        let simulationInputs = assetInputs.filter { requiredSymbols.contains($0.assetOption.symbol) }

        var targetMaps: [AdvancedBacktestStrategyMode: [String: [String: Double]]] = [:]
        var valueMaps: [AdvancedBacktestStrategyMode: [String: Double]] = [:]
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
            valueMaps[mode] = Dictionary(uniqueKeysWithValues: run.report.points.map {
                ($0.date.backtestDateString, $0.portfolioValue)
            })
        }

        let lookback = 504
        let temperature = 1.0
        let inertia = 0.75
        let config = ResearchTargetStrategyConfig(
            symbol: "online_strategy_allocator",
            title: BacktestText.string("在线策略分配器"),
            warmupSessions: lookback,
            rebalanceSessions: 1,
            rebalanceBand: 0.08,
            maxGrossExposure: 1.0,
            allowsFinancedExposure: false,
            financingAnnualRate: 0,
            buyReason: BacktestText.string("在线策略分配调仓")
        )

        var alignedValues: [AdvancedBacktestStrategyMode: [Double?]] = [:]
        var latestTargets: [AdvancedBacktestStrategyMode: [String: Double]] = [:]
        var allocatorShares = Dictionary(uniqueKeysWithValues: modes.map { ($0, 1.0 / Double(modes.count)) })
        var pendingWeights: [String: Double] = [:]
        var previousWeights: [String: Double] = [:]
        var lastAllocationIndex = -10_000

        return TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: simulationInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            rebalanceDecision: { index, signalIndex, data in
                guard signalIndex >= lookback,
                      data.dates.indices.contains(index),
                      data.dates.indices.contains(signalIndex) else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                if alignedValues.isEmpty {
                    for mode in modes {
                        let map = valueMaps[mode] ?? [:]
                        var lastValue: Double?
                        var values: [Double?] = []
                        values.reserveCapacity(data.dates.count)
                        for date in data.dates {
                            if let value = map[date.backtestDateString] { lastValue = value }
                            values.append(lastValue)
                        }
                        alignedValues[mode] = values
                    }
                }

                let executionKey = data.dates[index].backtestDateString
                var underlyingTargetChanged = false
                for mode in modes {
                    if let weights = targetMaps[mode]?[executionKey] {
                        let oldWeights = latestTargets[mode] ?? [:]
                        let symbols = Set(oldWeights.keys).union(weights.keys)
                        let difference = symbols.reduce(0.0) {
                            $0 + abs((oldWeights[$1] ?? 0) - (weights[$1] ?? 0))
                        }
                        if difference > 0.0000001 { underlyingTargetChanged = true }
                        latestTargets[mode] = weights
                    }
                }
                guard latestTargets.count == modes.count else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                if lastAllocationIndex < 0 || signalIndex - lastAllocationIndex >= 63 {
                    var rawScores: [AdvancedBacktestStrategyMode: Double] = [:]
                    for mode in modes {
                        guard let values = alignedValues[mode],
                              let current = values[signalIndex],
                              let start = values[signalIndex - lookback],
                              start > 0 else {
                            rawScores[mode] = -5
                            continue
                        }
                        let totalReturn = current / start - 1
                        var dailyReturns: [Double] = []
                        var peak = start
                        var maxDrawdown = 0.0
                        for cursor in (signalIndex - lookback + 1)...signalIndex {
                            guard let previous = values[cursor - 1],
                                  let value = values[cursor],
                                  previous > 0 else { continue }
                            dailyReturns.append(value / previous - 1)
                            peak = max(peak, value)
                            if peak > 0 { maxDrawdown = max(maxDrawdown, 1 - value / peak) }
                        }
                        let mean = dailyReturns.isEmpty ? 0 : dailyReturns.reduce(0, +) / Double(dailyReturns.count)
                        let variance = dailyReturns.count > 1
                            ? dailyReturns.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(dailyReturns.count - 1)
                            : 0
                        let annualVolatility = sqrt(max(variance, 0)) * sqrt(252)
                        let annualReturn = pow(max(1 + totalReturn, 0.0001), 252 / Double(lookback)) - 1
                        let quality = annualReturn / max(annualVolatility, 0.03)
                            + 0.35 * annualReturn
                            - 2.0 * maxDrawdown
                        rawScores[mode] = min(max(quality, -3), 3)
                    }

                    let maxScore = rawScores.values.max() ?? 0
                    var exponentials: [AdvancedBacktestStrategyMode: Double] = [:]
                    for mode in modes {
                        exponentials[mode] = exp(((rawScores[mode] ?? -3) - maxScore) / temperature)
                    }
                    let totalExp = exponentials.values.reduce(0, +)
                    var newShares: [AdvancedBacktestStrategyMode: Double] = [:]
                    for mode in modes {
                        let softmaxShare = totalExp > 0
                            ? (exponentials[mode] ?? 0) / totalExp
                            : 1.0 / Double(modes.count)
                        newShares[mode] = min(
                            inertia * (allocatorShares[mode] ?? 0) + (1 - inertia) * softmaxShare,
                            0.70
                        )
                    }
                    let shareTotal = newShares.values.reduce(0, +)
                    if shareTotal > 0 { newShares = newShares.mapValues { $0 / shareTotal } }
                    allocatorShares = newShares
                    lastAllocationIndex = signalIndex
                    underlyingTargetChanged = true
                }

                guard underlyingTargetChanged else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }
                var target: [String: Double] = [:]
                for mode in modes {
                    let share = allocatorShares[mode] ?? 0
                    for (symbol, weight) in latestTargets[mode] ?? [:] {
                        target[symbol, default: 0] += share * weight
                    }
                }
                let gross = target.values.reduce(0, +)
                if gross > 1, gross > 0 { target = target.mapValues { $0 / gross } }
                let symbols = Set(previousWeights.keys).union(target.keys)
                let difference = symbols.reduce(0.0) {
                    $0 + abs((previousWeights[$1] ?? 0) - (target[$1] ?? 0))
                }
                pendingWeights = target
                let shouldRebalance = previousWeights.isEmpty ? !target.isEmpty : difference > 0.0000001
                if shouldRebalance { previousWeights = target }
                return BacktestRebalanceDecision(shouldRebalance: shouldRebalance, refreshOverlay: false)
            },
            targetWeights: { _, _ in pendingWeights }
        )
    }
}
