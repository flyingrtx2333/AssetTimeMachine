import Foundation

nonisolated enum CashConfidenceStrategy {
    struct OnlineLeadershipTrial {
        let resolveIndex: Int
        let targetLeader: String
        let priorLeader: String
        let startPrices: [String: Double]
    }

    enum CashConfidenceProfile {
        case classic
        case lowNoiseNoLeverage
        case lowNoiseSimplifiedV11
    }

    static func runRiskContributionCashConfidenceRouterWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        dateBounds: ClosedRange<Date>? = nil,
        profile: CashConfidenceProfile = .classic
    ) -> ResearchTargetStrategyRun? {
        let isLowNoise = profile == .lowNoiseNoLeverage || profile == .lowNoiseSimplifiedV11
        let isSimplifiedV11 = profile == .lowNoiseSimplifiedV11
        let usesLowNoiseResearchOverrides = profile == .lowNoiseNoLeverage
        // Cash-confidence profiles are frozen strategies. Their internal shadow engines
        // must keep the calibration costs used during research; user-entered execution
        // costs belong only to the final simulation and must never change the target path.
        let frozenDecisionFeeRatePercent = CashConfidenceFrozenParameters.frozenV1.frozenDecisionFeeRatePercent
        let frozenDecisionSlippageRatePercent = CashConfidenceFrozenParameters.frozenV1.frozenDecisionSlippageRatePercent
        let decisionSettings = AdvancedBacktestRiskSettings(
            feeRate: frozenDecisionFeeRatePercent,
            slippageRate: frozenDecisionSlippageRatePercent,
            maxPositionRatio: settings.maxPositionRatio,
            cooldownDays: settings.cooldownDays,
            stopLossRatio: settings.stopLossRatio,
            takeProfitRatio: settings.takeProfitRatio
        )

        guard let baseRun = RiskContributionStrategy.runRiskContributionRecoveryRouterWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: decisionSettings,
            dateBounds: dateBounds,
            growthStateScale: 1.05,
            fastBridgeRatio: 0.15,
            sleeveCap: 0.2075,
            recoveryQualityConfig: .cashConfidenceAdaptive,
            recoveryCooldownSessions: 150,
            recoveryFastBreakThreshold: -0.05
        ) else { return nil }

        let baseTargets = Dictionary(uniqueKeysWithValues: baseRun.dailyStates.map {
            ($0.date.backtestDateString, $0.targetWeights)
        })
        let baseValues = Dictionary(uniqueKeysWithValues: baseRun.report.points.map {
            ($0.date.backtestDateString, $0.portfolioValue)
        })
        let equitySymbols = ["nasdaq", "sp500", "csi300", "shanghai_composite"]
        let tradeBand: Double
        if isSimplifiedV11 {
            tradeBand = 0.25
        } else if usesLowNoiseResearchOverrides {
            tradeBand = BacktestRunScope.parameters.lowNoiseTradeBand ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseTradeBand!
        } else {
            tradeBand = 0.20
        }
        let grossCap = CashConfidenceFrozenParameters.frozenV1.grossCap
        let lowConfidenceChinaGrossMaximum = CashConfidenceFrozenParameters.frozenV1.lowConfidenceChinaGrossMaximum
        let matureNasdaqGrossMinimum = CashConfidenceFrozenParameters.frozenV1.matureNasdaqGrossMinimum
        let matureNasdaqMinimumWeight = CashConfidenceFrozenParameters.frozenV1.matureNasdaqMinimumWeight
        let matureNasdaqMAPeriod = CashConfidenceFrozenParameters.frozenV1.matureNasdaqMAPeriod
        let matureNasdaqScale = CashConfidenceFrozenParameters.frozenV1.matureNasdaqScale
        let matureOtherAssetScale = CashConfidenceFrozenParameters.frozenV1.matureOtherAssetScale
        let residualNasdaqGrossMaximum = CashConfidenceFrozenParameters.frozenV1.residualNasdaqGrossMaximum
        let residualNasdaqMinimumWeight = CashConfidenceFrozenParameters.frozenV1.residualNasdaqMinimumWeight
        let leadershipEvaluationSessions = CashConfidenceFrozenParameters.frozenV1.leadershipEvaluationSessions
        let leadershipPriorEvidence = CashConfidenceFrozenParameters.frozenV1.leadershipPriorEvidence
        let minimumLeadershipMigration = CashConfidenceFrozenParameters.frozenV1.minimumLeadershipMigration
        let nearPeakDeRiskExecutionFraction: Double
        let broadUnwindTurnoverThreshold: Double
        if isSimplifiedV11 {
            nearPeakDeRiskExecutionFraction = 0.80
            broadUnwindTurnoverThreshold = 0.40
        } else if usesLowNoiseResearchOverrides {
            nearPeakDeRiskExecutionFraction = BacktestRunScope.parameters.lowNoiseNearPeakExecutionFraction ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseNearPeakExecutionFraction!
            broadUnwindTurnoverThreshold = BacktestRunScope.parameters.lowNoiseBroadUnwindTurnoverThreshold ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseBroadUnwindTurnoverThreshold!
        } else {
            nearPeakDeRiskExecutionFraction = 0.875
            broadUnwindTurnoverThreshold = 0.60
        }
        let nearPeakDeRiskDrawdownThreshold = CashConfidenceFrozenParameters.frozenV1.nearPeakDeRiskDrawdownThreshold
        let nearPeakDeRiskMaximumRetention = CashConfidenceFrozenParameters.frozenV1.nearPeakDeRiskMaximumRetention
        let disableNearPeakBuffer = usesLowNoiseResearchOverrides
            && (BacktestRunScope.parameters.lowNoiseDisableNearPeakBuffer ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseDisableNearPeakBuffer!)
        let disableExitSentinel = isSimplifiedV11
            || (usesLowNoiseResearchOverrides && (BacktestRunScope.parameters.lowNoiseDisableExitSentinel ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseDisableExitSentinel!))
        let disableDynamicTurnoverSuppression = usesLowNoiseResearchOverrides
            && (BacktestRunScope.parameters.lowNoiseDisableDynamicTurnoverSuppression ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseDisableDynamicTurnoverSuppression!)
        let config = ResearchTargetStrategyConfig(
            symbol: isSimplifiedV11
                ? "risk_contribution_cash_confidence_low_noise_simplified_v11"
                : (isLowNoise ? "risk_contribution_cash_confidence_low_noise" : "risk_contribution_cash_confidence_router"),
            title: BacktestText.string(isLowNoise ? "低噪增强" : "无融资置信度恢复"),
            warmupSessions: 21,
            rebalanceSessions: 1,
            rebalanceBand: tradeBand,
            tradeToBandBoundary: usesLowNoiseResearchOverrides
                ? (BacktestRunScope.parameters.lowNoiseTradeToBandBoundary ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseTradeToBandBoundary!)
                : false,
            maxGrossExposure: grossCap,
            allowsFinancedExposure: false,
            financingAnnualRate: 0,
            buyReason: BacktestText.string(isLowNoise ? "低噪增强调仓" : "无融资置信度恢复调仓")
        )

        var alignedBaseValues: [Double?] = []
        var latestBaseTarget: [String: Double] = [:]
        var pendingWeights: [String: Double] = [:]
        var previousWeights: [String: Double] = [:]
        var currentAdjustment = 1.0
        var leadershipTrials: [OnlineLeadershipTrial] = []
        var leadershipSuccesses: [String: Double] = [:]
        var leadershipFailures: [String: Double] = [:]

        func leaderName(_ weights: [String: Double]) -> String {
            let gold = weights["gold_cny"] ?? 0
            let nasdaq = weights["nasdaq"] ?? 0
            let sp500 = weights["sp500"] ?? 0
            let china = (weights["csi300"] ?? 0)
                + (weights["shanghai_composite"] ?? 0)
            let gross = gold + nasdaq + sp500 + china
            guard gross >= 0.05 else { return "cash" }
            if gold >= nasdaq, gold >= sp500, gold >= china { return "gold" }
            if nasdaq >= sp500, nasdaq >= china { return "nasdaq" }
            if sp500 >= china { return "sp500" }
            return "china"
        }

        func capturedPrices(
            pricesBySymbol: [String: [Double]],
            at index: Int
        ) -> [String: Double] {
            var result: [String: Double] = [:]
            for symbol in ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"] {
                if let prices = pricesBySymbol[symbol], prices.indices.contains(index) {
                    result[symbol] = prices[index]
                }
            }
            return result
        }

        func leaderReturn(
            _ leader: String,
            startPrices: [String: Double],
            pricesBySymbol: [String: [Double]],
            at index: Int
        ) -> Double? {
            func assetReturn(_ symbol: String) -> Double? {
                guard let start = startPrices[symbol], start > 0,
                      let prices = pricesBySymbol[symbol], prices.indices.contains(index) else {
                    return nil
                }
                return prices[index] / start - 1
            }
            switch leader {
            case "gold": return assetReturn("gold_cny")
            case "nasdaq": return assetReturn("nasdaq")
            case "sp500": return assetReturn("sp500")
            case "china":
                guard let csi = assetReturn("csi300"),
                      let shanghai = assetReturn("shanghai_composite") else { return nil }
                return 0.5 * (csi + shanghai)
            default: return 0
            }
        }

        return TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            rebalanceDecision: { index, signalIndex, data in
                guard data.dates.indices.contains(index),
                      data.dates.indices.contains(signalIndex),
                      signalIndex >= 20 else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                if alignedBaseValues.isEmpty {
                    var lastValue: Double?
                    for date in data.dates {
                        if let value = baseValues[date.backtestDateString] {
                            lastValue = value
                        }
                        alignedBaseValues.append(lastValue)
                    }
                }

                let executionKey = data.dates[index].backtestDateString
                var baseTargetChanged = false
                if let weights = baseTargets[executionKey], !weights.isEmpty {
                    baseTargetChanged = WeightMath.absoluteWeightDifference(latestBaseTarget, weights) > 0.0000001
                    latestBaseTarget = weights
                }
                guard !latestBaseTarget.isEmpty else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                if baseTargetChanged || previousWeights.isEmpty {
                    let baseGross = WeightMath.positiveWeightSum(latestBaseTarget)
                    let grossScale: Double
                    if baseGross < 0.20 {
                        grossScale = 0
                    } else if baseGross < 0.60 {
                        grossScale = 1
                    } else if baseGross < 0.80 {
                        grossScale = 0.65
                    } else {
                        grossScale = 1
                    }

                    var positiveBreadth10 = 0
                    var positiveBreadth20 = 0
                    var breadthValid = true
                    for symbol in equitySymbols {
                        guard let prices = data.pricesBySymbol[symbol],
                              prices.indices.contains(signalIndex),
                              prices[signalIndex - 10] > 0,
                              prices[signalIndex - 20] > 0 else {
                            breadthValid = false
                            break
                        }
                        if prices[signalIndex] / prices[signalIndex - 10] - 1 > 0 {
                            positiveBreadth10 += 1
                        }
                        if prices[signalIndex] / prices[signalIndex - 20] - 1 > 0 {
                            positiveBreadth20 += 1
                        }
                    }

                    var baseVolatility60 = Double.infinity
                    if signalIndex >= 60 {
                        var returns: [Double] = []
                        for cursor in (signalIndex - 59)...signalIndex {
                            guard cursor > 0,
                                  let previous = alignedBaseValues[cursor - 1],
                                  let current = alignedBaseValues[cursor],
                                  previous > 0 else { continue }
                            returns.append(current / previous - 1)
                        }
                        if returns.count > 1 {
                            let mean = returns.reduce(0, +) / Double(returns.count)
                            let variance = returns.reduce(0.0) {
                                $0 + pow($1 - mean, 2)
                            } / Double(returns.count - 1)
                            baseVolatility60 = sqrt(max(variance, 0)) * sqrt(252)
                        }
                    }

                    let lowVolatilityBreadthThrust = breadthValid
                        && positiveBreadth10 == 3
                        && baseGross >= 0.80
                        && baseVolatility60 < 0.08
                    let breadthScale: Double
                    if breadthValid, positiveBreadth20 == 1 {
                        breadthScale = 0.70
                    } else if lowVolatilityBreadthThrust {
                        breadthScale = 1.30
                    } else {
                        breadthScale = 1
                    }

                    let currentBaseValue = alignedBaseValues[signalIndex] ?? 0
                    let peakStart = max(0, signalIndex - 251)
                    let peakValue = alignedBaseValues[peakStart...signalIndex]
                        .compactMap { $0 }
                        .max() ?? currentBaseValue
                    let drawdown = peakValue > 0
                        ? max(1 - currentBaseValue / peakValue, 0)
                        : 0
                    let inValley = baseGross < 1
                        && drawdown >= 0.025
                        && drawdown < 0.051
                    let valleyScale = inValley ? 0.60 : 1
                    currentAdjustment = grossScale * breadthScale * valleyScale
                }

                pendingWeights = latestBaseTarget.mapValues { $0 * currentAdjustment }

                let adjustedGross = WeightMath.positiveWeightSum(pendingWeights)
                let adjustedChinaWeight = (pendingWeights["csi300"] ?? 0)
                    + (pendingWeights["shanghai_composite"] ?? 0)
                let adjustedChinaDominant = adjustedChinaWeight >= max(
                    pendingWeights["gold_cny"] ?? 0,
                    pendingWeights["nasdaq"] ?? 0,
                    pendingWeights["sp500"] ?? 0
                )
                if adjustedGross >= 0.20,
                   adjustedGross <= lowConfidenceChinaGrossMaximum,
                   adjustedChinaWeight >= 0.05,
                   adjustedChinaDominant {
                    pendingWeights["csi300"] = 0
                    pendingWeights["shanghai_composite"] = 0
                }

                if let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                   nasdaqPrices.indices.contains(signalIndex),
                   signalIndex >= matureNasdaqMAPeriod,
                   let nasdaqMA = PortfolioIndicators.movingAverageAt(
                    values: nasdaqPrices,
                    at: signalIndex,
                    period: matureNasdaqMAPeriod
                   ) {
                    let matureGross = WeightMath.positiveWeightSum(pendingWeights)
                    let nasdaqWeight = pendingWeights["nasdaq"] ?? 0
                    let chinaWeight = (pendingWeights["csi300"] ?? 0)
                        + (pendingWeights["shanghai_composite"] ?? 0)
                    let nasdaqDominant = nasdaqWeight >= max(
                        pendingWeights["gold_cny"] ?? 0,
                        pendingWeights["sp500"] ?? 0,
                        chinaWeight
                    )
                    if !isLowNoise,
                       matureGross >= matureNasdaqGrossMinimum,
                       nasdaqWeight >= matureNasdaqMinimumWeight,
                       nasdaqDominant,
                       nasdaqPrices[signalIndex] >= nasdaqMA {
                        pendingWeights = pendingWeights.mapValues {
                            $0 * matureOtherAssetScale
                        }
                        pendingWeights["nasdaq"] = nasdaqWeight * matureNasdaqScale
                    }
                }

                let residualGross = WeightMath.positiveWeightSum(pendingWeights)
                let residualNasdaqWeight = pendingWeights["nasdaq"] ?? 0
                let residualChinaWeight = (pendingWeights["csi300"] ?? 0)
                    + (pendingWeights["shanghai_composite"] ?? 0)
                let residualNasdaqDominant = residualNasdaqWeight >= max(
                    pendingWeights["gold_cny"] ?? 0,
                    pendingWeights["sp500"] ?? 0,
                    residualChinaWeight
                )
                if !isLowNoise,
                   residualGross > 0,
                   residualGross <= residualNasdaqGrossMaximum,
                   residualNasdaqWeight >= residualNasdaqMinimumWeight,
                   residualNasdaqDominant {
                    pendingWeights["nasdaq"] = 0
                }

                let positiveBreadthCount: (Int) -> Int? = { lookback in
                    guard lookback > 0, signalIndex >= lookback else { return nil }
                    var count = 0
                    for symbol in equitySymbols {
                        guard let prices = data.pricesBySymbol[symbol],
                              prices.indices.contains(signalIndex),
                              prices[signalIndex - lookback] > 0 else {
                            return nil
                        }
                        if prices[signalIndex] / prices[signalIndex - lookback] - 1 > 0 {
                            count += 1
                        }
                    }
                    return count
                }

                let stateGross = WeightMath.positiveWeightSum(pendingWeights)
                let stateChinaWeight = (pendingWeights["csi300"] ?? 0)
                    + (pendingWeights["shanghai_composite"] ?? 0)
                let stateGoldWeight = pendingWeights["gold_cny"] ?? 0
                let stateNasdaqWeight = pendingWeights["nasdaq"] ?? 0
                let goldDominant = stateGoldWeight >= max(
                    stateNasdaqWeight,
                    pendingWeights["sp500"] ?? 0,
                    stateChinaWeight
                )
                if stateGross >= 0.30,
                   stateGross < 0.40,
                   goldDominant {
                    pendingWeights = pendingWeights.mapValues { $0 * 0.45 }
                }

                let postGoldGross = WeightMath.positiveWeightSum(pendingWeights)
                let postGoldChinaWeight = (pendingWeights["csi300"] ?? 0)
                    + (pendingWeights["shanghai_composite"] ?? 0)
                let postGoldNasdaqWeight = pendingWeights["nasdaq"] ?? 0
                let nasdaqDominant = postGoldNasdaqWeight >= max(
                    pendingWeights["gold_cny"] ?? 0,
                    pendingWeights["sp500"] ?? 0,
                    postGoldChinaWeight
                )
                if postGoldGross >= 0.50,
                   postGoldGross < 0.60,
                   nasdaqDominant {
                    pendingWeights = pendingWeights.mapValues { $0 * 0.0 }
                }

                if !isLowNoise, positiveBreadthCount(40) == 1 {
                    pendingWeights = pendingWeights.mapValues { $0 * 0.91 }
                }
                if !isLowNoise, positiveBreadthCount(10) == 4 {
                    pendingWeights = pendingWeights.mapValues { $0 * 0.90 }
                }
                if !isLowNoise, positiveBreadthCount(20) == 1 {
                    pendingWeights = pendingWeights.mapValues { $0 * 0.94 }
                }

                if !previousWeights.isEmpty {
                    let holdGross = WeightMath.positiveWeightSum(pendingWeights)
                    let holdGold = pendingWeights["gold_cny"] ?? 0
                    let holdNasdaq = pendingWeights["nasdaq"] ?? 0
                    let holdSP500 = pendingWeights["sp500"] ?? 0
                    let holdChina = (pendingWeights["csi300"] ?? 0)
                        + (pendingWeights["shanghai_composite"] ?? 0)
                    let holdGoldDominant = holdGold >= max(
                        holdNasdaq,
                        holdSP500,
                        holdChina
                    )
                    if holdGross >= 0.10,
                       holdGross < 0.18,
                       holdGoldDominant {
                        pendingWeights = previousWeights
                    }
                }

                if !previousWeights.isEmpty {
                    let holdGross = WeightMath.positiveWeightSum(pendingWeights)
                    let holdGold = pendingWeights["gold_cny"] ?? 0
                    let holdNasdaq = pendingWeights["nasdaq"] ?? 0
                    let holdSP500 = pendingWeights["sp500"] ?? 0
                    let holdChina = (pendingWeights["csi300"] ?? 0)
                        + (pendingWeights["shanghai_composite"] ?? 0)
                    let holdNasdaqDominant = holdNasdaq >= max(
                        holdGold,
                        holdSP500,
                        holdChina
                    )
                    if holdGross >= 0.18,
                       holdGross < 0.23,
                       holdNasdaqDominant {
                        pendingWeights = previousWeights
                    }
                }

                if !previousWeights.isEmpty,
                   [5, 6, 7, 9, 10].contains(where: {
                       positiveBreadthCount($0) == 1
                   }) {
                    pendingWeights = previousWeights
                }

                let preHoldGross = WeightMath.positiveWeightSum(pendingWeights)
                if preHoldGross >= 0.05,
                   preHoldGross < 0.06,
                   !previousWeights.isEmpty {
                    pendingWeights = previousWeights
                }

                let preFloorGross = WeightMath.positiveWeightSum(pendingWeights)
                if preFloorGross > 0, preFloorGross < 0.03 {
                    pendingWeights = [:]
                }

                var unresolvedLeadershipTrials: [OnlineLeadershipTrial] = []
                for trial in leadershipTrials {
                    if trial.resolveIndex <= signalIndex,
                       let targetReturn = leaderReturn(
                        trial.targetLeader,
                        startPrices: trial.startPrices,
                        pricesBySymbol: data.pricesBySymbol,
                        at: signalIndex
                       ),
                       let priorReturn = leaderReturn(
                        trial.priorLeader,
                        startPrices: trial.startPrices,
                        pricesBySymbol: data.pricesBySymbol,
                        at: signalIndex
                       ) {
                        if targetReturn > priorReturn {
                            leadershipSuccesses[trial.targetLeader, default: 0] += 1
                        } else {
                            leadershipFailures[trial.targetLeader, default: 0] += 1
                        }
                    } else {
                        unresolvedLeadershipTrials.append(trial)
                    }
                }
                leadershipTrials = unresolvedLeadershipTrials

                if !previousWeights.isEmpty {
                    let priorLeader = leaderName(previousWeights)
                    let targetLeader = leaderName(pendingWeights)
                    let priorGross = WeightMath.positiveWeightSum(previousWeights)
                    let targetGross = WeightMath.positiveWeightSum(pendingWeights)
                    if baseTargetChanged,
                       targetLeader != priorLeader,
                       targetLeader != "cash",
                       priorLeader != "cash",
                       targetGross >= priorGross - 0.000001 {
                        let successes = leadershipSuccesses[targetLeader, default: 0]
                        let failures = leadershipFailures[targetLeader, default: 0]
                        let posteriorMean = (leadershipPriorEvidence + successes)
                            / (2 * leadershipPriorEvidence + successes + failures)
                        let leadershipEdge = min(max(2 * posteriorMean - 1, 0), 1)
                        let migration = minimumLeadershipMigration
                            + (1 - minimumLeadershipMigration) * leadershipEdge
                        let originalTarget = pendingWeights
                        let symbols = Set(previousWeights.keys)
                            .union(originalTarget.keys)
                            .sorted()
                        pendingWeights = Dictionary(uniqueKeysWithValues: symbols.map { symbol in
                            let prior = previousWeights[symbol] ?? 0
                            let target = originalTarget[symbol] ?? 0
                            return (symbol, prior + migration * (target - prior))
                        })
                        leadershipTrials.append(
                            OnlineLeadershipTrial(
                                resolveIndex: signalIndex + leadershipEvaluationSessions,
                                targetLeader: targetLeader,
                                priorLeader: priorLeader,
                                startPrices: capturedPrices(
                                    pricesBySymbol: data.pricesBySymbol,
                                    at: signalIndex
                                )
                            )
                        )
                    }
                }

                if !previousWeights.isEmpty,
                   !disableNearPeakBuffer {
                    let priorGross = WeightMath.positiveWeightSum(previousWeights)
                    let targetGross = WeightMath.positiveWeightSum(pendingWeights)
                    if targetGross >= 0.05,
                       targetGross < priorGross - 0.02,
                       alignedBaseValues.indices.contains(signalIndex),
                       let currentBaseValue = alignedBaseValues[signalIndex],
                       currentBaseValue > 0 {
                        let peakStart = max(0, signalIndex - 251)
                        let peakValue = alignedBaseValues[peakStart...signalIndex]
                            .compactMap { $0 }
                            .max() ?? currentBaseValue
                        let baseDrawdown = peakValue > 0
                            ? max(1 - currentBaseValue / peakValue, 0)
                            : 0
                        if baseDrawdown < nearPeakDeRiskDrawdownThreshold {
                            let executionSymbols = Set(previousWeights.keys)
                                .union(pendingWeights.keys)
                            let executionTurnover = WeightMath.absoluteWeightDifference(
                                pendingWeights,
                                previousWeights
                            )
                            let grossDrop = max(priorGross - targetGross, 0)
                            let baseRetention = 1 - nearPeakDeRiskExecutionFraction
                            let grossSeverity = max(grossDrop / 0.20, 0)
                            let turnoverSeverity = max(executionTurnover / 0.40, 0)
                            let retention = min(
                                nearPeakDeRiskMaximumRetention,
                                baseRetention * max(grossSeverity, turnoverSeverity)
                            )
                            let retainedGross = grossDrop * retention
                            if retainedGross > 0 {
                                var bufferWeights: [String: Double] = [:]
                                if executionTurnover >= broadUnwindTurnoverThreshold {
                                    let sales = Dictionary(uniqueKeysWithValues: executionSymbols.sorted().compactMap { symbol -> (String, Double)? in
                                        let sale = max(
                                            (previousWeights[symbol] ?? 0)
                                                - (pendingWeights[symbol] ?? 0),
                                            0
                                        )
                                        return sale > 0 ? (symbol, sale) : nil
                                    })
                                    let totalSales = WeightMath.positiveWeightSum(sales)
                                    let effectiveRetainedGross = min(retainedGross, totalSales)
                                    if effectiveRetainedGross > 0, totalSales > 0 {
                                        let priorLeader = leaderName(previousWeights)
                                        let leaderSymbols: Set<String> = priorLeader == "china"
                                            ? ["csi300", "shanghai_composite"]
                                            : [priorLeader]
                                        let leaderSales = sales.filter { leaderSymbols.contains($0.key) }
                                        let leaderSaleTotal = WeightMath.positiveWeightSum(leaderSales)
                                        let leaderAllocation = min(
                                            effectiveRetainedGross,
                                            leaderSaleTotal
                                        )
                                        if leaderAllocation > 0, leaderSaleTotal > 0 {
                                            for symbol in leaderSales.keys.sorted() {
                                                let sale = leaderSales[symbol] ?? 0
                                                bufferWeights[symbol] = leaderAllocation
                                                    * sale / leaderSaleTotal
                                            }
                                        }
                                        let remainingAllocation = effectiveRetainedGross
                                            - leaderAllocation
                                        let otherSales = sales.filter { !leaderSymbols.contains($0.key) }
                                        let otherSaleTotal = WeightMath.positiveWeightSum(otherSales)
                                        if remainingAllocation > 0, otherSaleTotal > 0 {
                                            for symbol in otherSales.keys.sorted() {
                                                let sale = otherSales[symbol] ?? 0
                                                bufferWeights[symbol, default: 0] += remainingAllocation
                                                    * sale / otherSaleTotal
                                            }
                                        }
                                    }
                                } else {
                                    let priorLeader = leaderName(previousWeights)
                                    switch priorLeader {
                                    case "china":
                                        let priorCSI = previousWeights["csi300"] ?? 0
                                        let priorShanghai = previousWeights["shanghai_composite"] ?? 0
                                        let priorChina = priorCSI + priorShanghai
                                        if priorChina > 0 {
                                            bufferWeights["csi300"] = retainedGross * priorCSI / priorChina
                                            bufferWeights["shanghai_composite"] = retainedGross
                                                * priorShanghai / priorChina
                                        }
                                    case "cash":
                                        break
                                    default:
                                        bufferWeights[priorLeader] = retainedGross
                                    }
                                }
                                for symbol in bufferWeights.keys.sorted() {
                                    let weight = bufferWeights[symbol] ?? 0
                                    guard weight > 0 else { continue }
                                    pendingWeights[symbol, default: 0] += weight
                                }
                            }
                        }
                    }
                }

                if isLowNoise,
                   !disableExitSentinel,
                   baseTargetChanged,
                   !previousWeights.isEmpty,
                   WeightMath.positiveWeightSum(pendingWeights) < 0.05 {
                    let priorGross = WeightMath.positiveWeightSum(previousWeights)
                    let priorLeader = leaderName(previousWeights)
                    if priorGross >= 0.40,
                       priorLeader == "china",
                       signalIndex >= 60,
                       let currentBaseValue = alignedBaseValues[signalIndex],
                       currentBaseValue > 0 {
                        let peakStart = max(0, signalIndex - 251)
                        let peakValue = alignedBaseValues[peakStart...signalIndex]
                            .compactMap { $0 }
                            .max() ?? currentBaseValue
                        let baseDrawdown = peakValue > 0
                            ? max(1 - currentBaseValue / peakValue, 0)
                            : 0
                        var recentReturns: [Double] = []
                        for cursor in (signalIndex - 59)...signalIndex {
                            guard cursor > 0,
                                  let priorValue = alignedBaseValues[cursor - 1],
                                  let value = alignedBaseValues[cursor],
                                  priorValue > 0 else { continue }
                            recentReturns.append(value / priorValue - 1)
                        }
                        let recentVolatility: Double = {
                            guard recentReturns.count > 1 else { return 0 }
                            let mean = recentReturns.reduce(0, +) / Double(recentReturns.count)
                            let variance = recentReturns.reduce(0.0) {
                                $0 + pow($1 - mean, 2)
                            } / Double(recentReturns.count - 1)
                            return sqrt(max(variance, 0)) * sqrt(252)
                        }()
                        if baseDrawdown < 0.02,
                           recentVolatility >= 0.06,
                           recentVolatility < 0.08 {
                            let priorCSI = previousWeights["csi300"] ?? 0
                            let priorShanghai = previousWeights["shanghai_composite"] ?? 0
                            let priorChina = priorCSI + priorShanghai
                            if priorChina > 0 {
                                let sentinelGross = min(0.05, priorGross)
                                pendingWeights["csi300"] = sentinelGross * priorCSI / priorChina
                                pendingWeights["shanghai_composite"] = sentinelGross * priorShanghai / priorChina
                            }
                        }
                    }
                }

                if isLowNoise {
                    let lowNoiseVolatilityTarget = usesLowNoiseResearchOverrides
                        ? (BacktestRunScope.parameters.lowNoiseVolatilityTarget ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseVolatilityTarget!)
                        : 0.09
                    let lowNoiseVolatilityScaleCap = usesLowNoiseResearchOverrides
                        ? (BacktestRunScope.parameters.lowNoiseVolatilityScaleCap ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseVolatilityScaleCap!)
                        : 1.15
                    let useSqrtVolRiskBudget = usesLowNoiseResearchOverrides
                        && (BacktestRunScope.parameters.lowNoiseUseSqrtVolRiskBudget ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseUseSqrtVolRiskBudget!)
                    let useGeometricHeadroomRiskBudget = usesLowNoiseResearchOverrides
                        && (BacktestRunScope.parameters.lowNoiseUseGeometricHeadroomRiskBudget ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseUseGeometricHeadroomRiskBudget!)
                    let lowNoiseActiveReturnScale = usesLowNoiseResearchOverrides
                        ? (BacktestRunScope.parameters.lowNoiseActiveReturnScale ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseActiveReturnScale!)
                        : 1.22
                    let lowNoiseChinaActiveReturnScale = isSimplifiedV11
                        ? 1.22
                        : (BacktestRunScope.parameters.lowNoiseChinaActiveReturnScale ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseChinaActiveReturnScale!)
                    let lowNoiseConfirmedUSActiveReturnScale = isSimplifiedV11
                        ? 1.22
                        : (BacktestRunScope.parameters.lowNoiseConfirmedUSActiveReturnScale ?? BacktestResearchParameterDefaults.frozenV1.lowNoiseConfirmedUSActiveReturnScale!)
                    var lowNoiseGross = WeightMath.positiveWeightSum(pendingWeights)
                    if lowNoiseGross > grossCap, lowNoiseGross > 0 {
                        pendingWeights = pendingWeights.mapValues { $0 * grossCap / lowNoiseGross }
                        lowNoiseGross = grossCap
                    }

                    let calmRiskLeader = leaderName(pendingWeights)
                    if calmRiskLeader != "gold",
                       lowNoiseGross >= 0.20,
                       lowNoiseGross < grossCap,
                       signalIndex >= 200,
                       let nasdaqPrices = data.pricesBySymbol["nasdaq"],
                       let sp500Prices = data.pricesBySymbol["sp500"],
                       nasdaqPrices.indices.contains(signalIndex),
                       sp500Prices.indices.contains(signalIndex),
                       let nasdaqMA200 = PortfolioIndicators.movingAverageAt(values: nasdaqPrices, at: signalIndex, period: 200),
                       let sp500MA200 = PortfolioIndicators.movingAverageAt(values: sp500Prices, at: signalIndex, period: 200),
                       let nasdaqMomentum126 = TechnicalIndicators.priceMomentum(values: nasdaqPrices, at: signalIndex, lookback: 126),
                       let sp500Momentum126 = TechnicalIndicators.priceMomentum(values: sp500Prices, at: signalIndex, lookback: 126),
                       nasdaqPrices[signalIndex] >= nasdaqMA200,
                       sp500Prices[signalIndex] >= sp500MA200,
                       nasdaqMomentum126 > 0,
                       sp500Momentum126 > 0 {
                        let baseValue = alignedBaseValues[signalIndex] ?? 0
                        let peakStart = max(0, signalIndex - 251)
                        let basePeak = alignedBaseValues[peakStart...signalIndex]
                            .compactMap { $0 }
                            .max() ?? baseValue
                        let baseDrawdown = basePeak > 0 ? max(1 - baseValue / basePeak, 0) : 0
                        if baseDrawdown <= 0.03 {
                            var riskReturns: [Double] = []
                            for cursor in (signalIndex - 62)...signalIndex {
                                var dailyReturn = 0.0
                                var valid = true
                                for symbol in pendingWeights.keys.sorted() {
                                    let weight = pendingWeights[symbol] ?? 0
                                    guard weight > 0 else { continue }
                                    guard let prices = data.pricesBySymbol[symbol],
                                          prices.indices.contains(cursor),
                                          cursor > 0,
                                          prices[cursor - 1] > 0 else {
                                        valid = false
                                        break
                                    }
                                    dailyReturn += weight * (prices[cursor] / prices[cursor - 1] - 1)
                                }
                                if valid { riskReturns.append(dailyReturn) }
                            }
                            if riskReturns.count > 1 {
                                let mean = riskReturns.reduce(0, +) / Double(riskReturns.count)
                                let variance = riskReturns.reduce(0.0) {
                                    $0 + pow($1 - mean, 2)
                                } / Double(riskReturns.count - 1)
                                let forecastVolatility = sqrt(max(variance, 0)) * sqrt(252)
                                var shortVolatility = forecastVolatility
                                if riskReturns.count >= 20 {
                                    let shortReturns = Array(riskReturns.suffix(20))
                                    let shortMean = shortReturns.reduce(0, +) / Double(shortReturns.count)
                                    let shortVariance = shortReturns.reduce(0.0) {
                                        $0 + pow($1 - shortMean, 2)
                                    } / Double(shortReturns.count - 1)
                                    shortVolatility = sqrt(max(shortVariance, 0)) * sqrt(252)
                                }
                                if forecastVolatility > 0,
                                   forecastVolatility < lowNoiseVolatilityTarget,
                                   shortVolatility <= forecastVolatility {
                                    let scale: Double
                                    if useGeometricHeadroomRiskBudget {
                                        scale = sqrt(grossCap / lowNoiseGross)
                                    } else if useSqrtVolRiskBudget {
                                        scale = min(
                                            sqrt(lowNoiseVolatilityTarget / forecastVolatility),
                                            grossCap / lowNoiseGross
                                        )
                                    } else {
                                        scale = min(
                                            lowNoiseVolatilityTarget / forecastVolatility,
                                            grossCap / lowNoiseGross,
                                            lowNoiseVolatilityScaleCap
                                        )
                                    }
                                    let targetGross = lowNoiseGross * scale
                                    let extraGross = max(targetGross - lowNoiseGross, 0)
                                    if extraGross > 0, calmRiskLeader == "nasdaq" {
                                        pendingWeights["nasdaq", default: 0] += extraGross
                                    } else {
                                        pendingWeights = pendingWeights.mapValues { $0 * scale }
                                    }
                                    lowNoiseGross = WeightMath.positiveWeightSum(pendingWeights)
                                }
                            }
                        }
                    }

                    let activeReturnLeader = leaderName(pendingWeights)
                    let useAlternativeRiskBudget = useSqrtVolRiskBudget || useGeometricHeadroomRiskBudget
                    var activeReturnScale = useAlternativeRiskBudget
                        ? 1.0
                        : (activeReturnLeader == "china"
                            ? lowNoiseChinaActiveReturnScale
                            : lowNoiseActiveReturnScale)
                    if !useAlternativeRiskBudget,
                       ["nasdaq", "sp500"].contains(activeReturnLeader),
                       let leaderPrices = data.pricesBySymbol[activeReturnLeader],
                       leaderPrices.indices.contains(signalIndex),
                       signalIndex >= 63,
                       let leaderMomentum63 = TechnicalIndicators.priceMomentum(values: leaderPrices, at: signalIndex, lookback: 63),
                       let leaderVolatility20 = PortfolioIndicators.annualizedVolatilityAt(values: leaderPrices, at: signalIndex, lookback: 20),
                       let leaderVolatility63 = PortfolioIndicators.annualizedVolatilityAt(values: leaderPrices, at: signalIndex, lookback: 63),
                       leaderMomentum63 > 0,
                       leaderVolatility20 <= leaderVolatility63 {
                        activeReturnScale = lowNoiseConfirmedUSActiveReturnScale
                    }
                    if abs(activeReturnScale - 1) > 0.000001 {
                        pendingWeights = pendingWeights.mapValues { max($0 * activeReturnScale, 0) }
                        lowNoiseGross = WeightMath.positiveWeightSum(pendingWeights)
                        if lowNoiseGross > grossCap, lowNoiseGross > 0 {
                            pendingWeights = pendingWeights.mapValues { $0 * grossCap / lowNoiseGross }
                        }
                    }
                }

                let gross = WeightMath.positiveWeightSum(pendingWeights)
                if gross > grossCap, gross > 0 {
                    pendingWeights = pendingWeights.mapValues { $0 * grossCap / gross }
                }
                let difference = WeightMath.absoluteWeightDifference(previousWeights, pendingWeights)
                var suppressLowNoiseReweight = false
                if isLowNoise,
                   !disableDynamicTurnoverSuppression,
                   !previousWeights.isEmpty {
                    let priorGross = WeightMath.positiveWeightSum(previousWeights)
                    let targetGross = WeightMath.positiveWeightSum(pendingWeights)
                    let priorLeader = leaderName(previousWeights)
                    let targetLeader = leaderName(pendingWeights)
                    if priorLeader == targetLeader,
                       targetLeader != "cash",
                       abs(targetGross - priorGross) <= 0.02 {
                        var portfolioVolatility = 0.0
                        if signalIndex >= 60 {
                            var returns: [Double] = []
                            for cursor in (signalIndex - 59)...signalIndex {
                                guard cursor > 0 else { continue }
                                var dailyReturn = 0.0
                                var valid = true
                                for symbol in previousWeights.keys.sorted() {
                                    let weight = previousWeights[symbol] ?? 0
                                    guard weight > 0 else { continue }
                                    guard let prices = data.pricesBySymbol[symbol],
                                          prices.indices.contains(cursor),
                                          prices[cursor - 1] > 0 else {
                                        valid = false
                                        break
                                    }
                                    dailyReturn += weight * (prices[cursor] / prices[cursor - 1] - 1)
                                }
                                if valid { returns.append(dailyReturn) }
                            }
                            if returns.count > 1 {
                                let mean = returns.reduce(0, +) / Double(returns.count)
                                let variance = returns.reduce(0.0) {
                                    $0 + pow($1 - mean, 2)
                                } / Double(returns.count - 1)
                                portfolioVolatility = sqrt(max(variance, 0)) * sqrt(252)
                            }
                        }
                        let goldExtremeOverride = targetLeader == "gold" && portfolioVolatility >= 0.12
                        let turnoverLimit: Double
                        if portfolioVolatility >= 0.08, !goldExtremeOverride {
                            turnoverLimit = 0.50
                        } else if portfolioVolatility >= 0.06 {
                            turnoverLimit = 0.30
                        } else {
                            turnoverLimit = 0.20
                        }
                        suppressLowNoiseReweight = difference < turnoverLimit
                    }
                }
                let shouldRebalance = previousWeights.isEmpty
                    ? !pendingWeights.isEmpty
                    : (!suppressLowNoiseReweight && (baseTargetChanged || difference > tradeBand))
                if shouldRebalance {
                    previousWeights = pendingWeights
                }
                return BacktestRebalanceDecision(
                    shouldRebalance: shouldRebalance,
                    refreshOverlay: false
                )
            },
            targetWeights: { _, _ in pendingWeights }
        )
    }
}
