import Foundation

nonisolated enum NFCICoreStrategy {
    private static let parameters = NFCIFrozenParameters.frozenV1
    static func nfciReleaseChange(
        points: [BacktestNFCIPoint],
        signalDate: String,
        lookbackReleases: Int
    ) -> Double? {
        guard lookbackReleases > 0,
              let signalDay = BacktestSeriesAlignment.historicalSeriesDate(from: signalDate),
              let signalCutoff = BacktestSeriesAlignment.historicalSeriesCalendar.date(
                  byAdding: .day,
                  value: 1,
                  to: signalDay
              ) else { return nil }
        let sorted = points
            .compactMap { point -> (point: BacktestNFCIPoint, releaseDay: Date)? in
                guard let releaseDay = BacktestSeriesAlignment.historicalSeriesDate(from: point.releaseDate),
                      releaseDay <= signalDay else { return nil }
                guard let availableAt = point.availableAt else {
                    // Legacy research fixtures contain first-release observations
                    // without intraday timestamps. They remain explicitly supported.
                    return (point, releaseDay)
                }
                return availableAt < signalCutoff ? (point, releaseDay) : nil
            }
            .sorted { $0.releaseDay < $1.releaseDay }
        guard sorted.count > lookbackReleases else { return nil }
        let latestIndex = sorted.index(before: sorted.endIndex)
        return sorted[latestIndex].point.value
            - sorted[latestIndex - lookbackReleases].point.value
    }

    static func runNFCIC3L3SleeveWithTrace(
        baseRun: ResearchTargetStrategyRun,
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        creditPoints: [BacktestNFCIPoint],
        leveragePoints: [BacktestNFCIPoint],
        riskScale: Double,
        rebalanceBand: Double,
        symbol: String,
        title: String,
        dateBounds: ClosedRange<Date>?,
        baseDecisionTradeDates: Set<String>? = nil
    ) -> ResearchTargetStrategyRun? {
        let baseTargets = Dictionary(uniqueKeysWithValues: baseRun.dailyStates.map {
            ($0.date.backtestDateString, $0.targetWeights)
        })
        let eligibleTradeDates = baseDecisionTradeDates
            ?? Set(baseRun.report.trades.map { $0.date.backtestDateString })
        let usSymbols: Set<String> = ["nasdaq", "sp500"]
        let config = ResearchTargetStrategyConfig(
            symbol: symbol,
            title: title,
            warmupSessions: parameters.warmupSessions,
            rebalanceSessions: parameters.rebalanceSessions,
            rebalanceBand: rebalanceBand,
            maxGrossExposure: parameters.grossCap,
            allowsFinancedExposure: false,
            financingAnnualRate: 0,
            buyReason: title
        )
        var previousBaseTarget: [String: Double] = [:]
        var pendingTarget: [String: Double] = [:]

        return TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            rebalanceDecision: { index, signalIndex, data in
                guard data.dates.indices.contains(index),
                      data.dates.indices.contains(signalIndex) else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }
                let executionKey = data.dates[index].backtestDateString
                guard eligibleTradeDates.contains(executionKey),
                      var target = baseTargets[executionKey] else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }

                let prior = previousBaseTarget
                previousBaseTarget = target
                if !prior.isEmpty {
                    let signalKey = data.dates[signalIndex].backtestDateString
                    let creditTriggered = nfciReleaseChange(
                        points: creditPoints,
                        signalDate: signalKey,
                        lookbackReleases: parameters.creditLookbackReleases
                    ).map { $0 <= parameters.releaseChangeThreshold } ?? false
                    let leverageTriggered = nfciReleaseChange(
                        points: leveragePoints,
                        signalDate: signalKey,
                        lookbackReleases: parameters.leverageLookbackReleases
                    ).map { $0 <= parameters.releaseChangeThreshold } ?? false

                    let priorGross = prior.values.reduce(0, +)
                    let proposedGross = target.values.reduce(0, +)
                    let priorUS = prior.reduce(0.0) { partial, item in
                        partial + (usSymbols.contains(item.key) ? item.value : 0)
                    }
                    let proposedUS = target.reduce(0.0) { partial, item in
                        partial + (usSymbols.contains(item.key) ? item.value : 0)
                    }
                    let usDecrease = priorUS - proposedUS
                    let grossDecrease = priorGross - proposedGross
                    var extras: [String: Double] = [:]

                    if creditTriggered || leverageTriggered {
                        if usDecrease >= parameters.usDecreaseThreshold, grossDecrease >= parameters.grossDecreaseWithUS {
                            let retention = creditTriggered && leverageTriggered ? parameters.bothTriggerRetention : parameters.singleTriggerRetention
                            for assetSymbol in usSymbols {
                                let reduction = max((prior[assetSymbol] ?? 0) - (target[assetSymbol] ?? 0), 0)
                                if reduction > 0 {
                                    extras[assetSymbol] = retention * reduction
                                }
                            }
                        } else if grossDecrease >= parameters.grossDecreaseThreshold {
                            for (assetSymbol, priorWeight) in prior {
                                let reduction = max(priorWeight - (target[assetSymbol] ?? 0), 0)
                                if reduction > 0 {
                                    extras[assetSymbol] = reduction
                                }
                            }
                        }
                    }

                    let desiredExtra = extras.values.reduce(0, +)
                    if desiredExtra > 0 {
                        let availableCash = max(1.0 - proposedGross, 0)
                        let extraScale = min(1.0, availableCash / desiredExtra)
                        for (assetSymbol, extra) in extras {
                            target[assetSymbol, default: 0] += extra * extraScale
                        }
                    }
                }

                target = target.mapValues { max($0, 0) * riskScale }
                let gross = target.values.reduce(0, +)
                if gross > 1, gross > 0 {
                    target = target.mapValues { $0 / gross }
                }
                pendingTarget = target
                return BacktestRebalanceDecision(shouldRebalance: true, refreshOverlay: false)
            },
            targetWeights: { _, _ in pendingTarget }
        )
    }

    enum NFCIDualCoreProfile {
        case v1
        case simplifiedV11
    }

    static func runNFCIDualCoreV1WithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        nfciAsOf: BacktestNFCIAsOfData,
        dateBounds: ClosedRange<Date>? = nil,
        profile: NFCIDualCoreProfile = .v1
    ) -> AdvancedRotationStrategyRun? {
        guard nfciAsOf.isReadyForC3L3 else { return nil }
        let isSimplifiedV11 = profile == .simplifiedV11
        let highReturnProfile: CashConfidenceStrategy.CashConfidenceProfile = isSimplifiedV11
            ? .lowNoiseSimplifiedV11
            : .lowNoiseNoLeverage
        let highCoreBand = isSimplifiedV11
            ? parameters.simplifiedHighCoreBand
            : (BacktestRunScope.parameters.nfciDualCoreHighCoreBand ?? BacktestResearchParameterDefaults.frozenV1.nfciDualCoreHighCoreBand!)
        let highCoreSymbol = isSimplifiedV11
            ? "nfci_dual_core_v11_high_return"
            : "nfci_dual_core_v1_high_return"
        let finalSymbol = isSimplifiedV11 ? "nfci_dual_core_v11" : "nfci_dual_core_v1"
        let finalTitle = BacktestText.string(isSimplifiedV11
            ? "NFCI 双核心·简化（前瞻）"
            : "NFCI 双核心（前瞻）")

        guard let lowNoiseBase = CashConfidenceStrategy.runRiskContributionCashConfidenceRouterWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            dateBounds: dateBounds,
            profile: highReturnProfile
        ), let cashConfidenceBase = CashConfidenceStrategy.runRiskContributionCashConfidenceRouterWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            dateBounds: dateBounds
        ) else { return nil }

        let frozenDecisionSettings = AdvancedBacktestRiskSettings(
            feeRate: CashConfidenceFrozenParameters.frozenV1.frozenDecisionFeeRatePercent,
            slippageRate: CashConfidenceFrozenParameters.frozenV1.frozenDecisionSlippageRatePercent,
            maxPositionRatio: settings.maxPositionRatio,
            cooldownDays: settings.cooldownDays,
            stopLossRatio: settings.stopLossRatio,
            takeProfitRatio: settings.takeProfitRatio
        )
        let lowNoiseDecisionRun: ResearchTargetStrategyRun
        let cashConfidenceDecisionRun: ResearchTargetStrategyRun
        if abs(settings.feeRate - CashConfidenceFrozenParameters.frozenV1.frozenDecisionFeeRatePercent) < 0.0000001,
           abs(settings.slippageRate - CashConfidenceFrozenParameters.frozenV1.frozenDecisionSlippageRatePercent) < 0.0000001 {
            lowNoiseDecisionRun = lowNoiseBase
            cashConfidenceDecisionRun = cashConfidenceBase
        } else {
            guard let frozenLowNoise = CashConfidenceStrategy.runRiskContributionCashConfidenceRouterWithTrace(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: frozenDecisionSettings,
                dateBounds: dateBounds,
                profile: highReturnProfile
            ), let frozenCashConfidence = CashConfidenceStrategy.runRiskContributionCashConfidenceRouterWithTrace(
                assetInputs: assetInputs,
                initialCash: initialCash,
                settings: frozenDecisionSettings,
                dateBounds: dateBounds
            ) else { return nil }
            lowNoiseDecisionRun = frozenLowNoise
            cashConfidenceDecisionRun = frozenCashConfidence
        }
        let lowNoiseDecisionTradeDates = Set(lowNoiseDecisionRun.report.trades.map { $0.date.backtestDateString })
        let cashConfidenceDecisionTradeDates = Set(cashConfidenceDecisionRun.report.trades.map { $0.date.backtestDateString })

        guard let highReturnCore = runNFCIC3L3SleeveWithTrace(
            baseRun: lowNoiseBase,
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            creditPoints: nfciAsOf.credit,
            leveragePoints: nfciAsOf.leverage,
            riskScale: parameters.highRiskScale,
            rebalanceBand: highCoreBand,
            symbol: highCoreSymbol,
            title: BacktestText.string("NFCI 双核心·高收益核心"),
            dateBounds: dateBounds,
            baseDecisionTradeDates: lowNoiseDecisionTradeDates
        ), let balancedCore = runNFCIC3L3SleeveWithTrace(
            baseRun: cashConfidenceBase,
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            creditPoints: nfciAsOf.credit,
            leveragePoints: nfciAsOf.leverage,
            riskScale: parameters.balancedRiskScale,
            rebalanceBand: parameters.balancedRebalanceBand,
            symbol: "nfci_dual_core_v1_balanced",
            title: BacktestText.string("NFCI 双核心·稳健核心"),
            dateBounds: dateBounds,
            baseDecisionTradeDates: cashConfidenceDecisionTradeDates
        ) else { return nil }

        let highTargets = Dictionary(uniqueKeysWithValues: highReturnCore.dailyStates.map {
            ($0.date.backtestDateString, $0.targetWeights)
        })
        let balancedTargets = Dictionary(uniqueKeysWithValues: balancedCore.dailyStates.map {
            ($0.date.backtestDateString, $0.targetWeights)
        })
        let commonKeys = Set(highTargets.keys).intersection(balancedTargets.keys)
        var blendedTargets: [String: [String: Double]] = [:]
        blendedTargets.reserveCapacity(commonKeys.count)
        for key in commonKeys {
            guard let high = highTargets[key], let balanced = balancedTargets[key] else { continue }
            let symbols = Set(high.keys).union(balanced.keys)
            var target: [String: Double] = [:]
            for assetSymbol in symbols {
                target[assetSymbol] = parameters.highCoreShare * (high[assetSymbol] ?? 0) + parameters.balancedCoreShare * (balanced[assetSymbol] ?? 0)
            }
            let gross = target.values.reduce(0, +)
            if gross > 1, gross > 0 {
                target = target.mapValues { $0 / gross }
            }
            blendedTargets[key] = target
        }
        guard !blendedTargets.isEmpty else { return nil }

        let config = ResearchTargetStrategyConfig(
            symbol: finalSymbol,
            title: finalTitle,
            warmupSessions: parameters.warmupSessions,
            rebalanceSessions: parameters.rebalanceSessions,
            rebalanceBand: parameters.finalRebalanceBand,
            maxGrossExposure: parameters.grossCap,
            allowsFinancedExposure: false,
            financingAnnualRate: 0,
            buyReason: BacktestText.string("NFCI 双核心调仓")
        )
        var previousTarget: [String: Double] = [:]
        var pendingTarget: [String: Double] = [:]
        func targetDifference(_ lhs: [String: Double], _ rhs: [String: Double]) -> Double {
            Set(lhs.keys).union(rhs.keys).reduce(0.0) { partial, assetSymbol in
                partial + abs((lhs[assetSymbol] ?? 0) - (rhs[assetSymbol] ?? 0))
            }
        }

        guard let finalRun = TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: assetInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            rebalanceDecision: { index, _, data in
                guard data.dates.indices.contains(index) else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }
                let key = data.dates[index].backtestDateString
                guard let target = blendedTargets[key] else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }
                let changed = previousTarget.isEmpty || targetDifference(previousTarget, target) > 0.0000001
                pendingTarget = target
                if changed {
                    previousTarget = target
                }
                return BacktestRebalanceDecision(shouldRebalance: changed, refreshOverlay: false)
            },
            targetWeights: { _, _ in pendingTarget }
        ) else { return nil }

        return AdvancedRotationStrategyRun(report: finalRun.report, dailyStates: finalRun.dailyStates)
    }

    static func runNFCIDualCoreSimplifiedV11QualRoleWithTrace(
        assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)],
        initialCash: Double,
        settings: AdvancedBacktestRiskSettings,
        nfciAsOf: BacktestNFCIAsOfData,
        dateBounds: ClosedRange<Date>? = nil
    ) -> AdvancedRotationStrategyRun? {
        let normalizedQUAL = "qual"
        guard let qualInput = assetInputs.first(where: { BacktestAssetSymbol.normalized($0.assetOption.symbol) == normalizedQUAL }),
              let qualSeries = qualInput.assetSeries else { return nil }
        let baseInputs = assetInputs.filter { BacktestAssetSymbol.normalized($0.assetOption.symbol) != normalizedQUAL }
        guard let originalSP500Input = baseInputs.first(where: { BacktestAssetSymbol.normalized($0.assetOption.symbol) == "sp500" }),
              let originalSP500 = originalSP500Input.assetSeries else { return nil }

        func hybridQUALRoleSeries() -> PublicHistorySeries? {
            guard originalSP500.dates.count == originalSP500.prices.count,
                  qualSeries.dates.count == qualSeries.prices.count,
                  !originalSP500.dates.isEmpty,
                  qualSeries.dates.count >= 2 else { return nil }
            let style = zip(qualSeries.dates, qualSeries.prices)
                .filter { $0.1.isFinite && $0.1 > 0 }
                .sorted { $0.0 < $1.0 }
            guard style.count >= 2 else { return nil }
            let substitutionStart = parameters.qualSubstitutionStart
            var styleIndex = 0
            var lastStylePrice: Double?
            var previousAlignedStylePrice: Double?
            var previousHybrid: Double?
            var prices: [Double] = []
            prices.reserveCapacity(originalSP500.prices.count)

            for (date, originalPrice) in zip(originalSP500.dates, originalSP500.prices) {
                guard originalPrice.isFinite, originalPrice > 0 else { return nil }
                while styleIndex < style.count, style[styleIndex].0 <= date {
                    lastStylePrice = style[styleIndex].1
                    styleIndex += 1
                }
                let nextPrice: Double
                if date < substitutionStart {
                    nextPrice = originalPrice
                } else {
                    guard let priorHybrid = previousHybrid,
                          let currentStylePrice = lastStylePrice,
                          let priorStylePrice = previousAlignedStylePrice,
                          priorStylePrice > 0 else { return nil }
                    let ratio = currentStylePrice / priorStylePrice
                    guard ratio.isFinite, ratio > 0 else { return nil }
                    nextPrice = priorHybrid * ratio
                }
                prices.append(nextPrice)
                previousHybrid = nextPrice
                if let lastStylePrice {
                    previousAlignedStylePrice = lastStylePrice
                }
            }

            return PublicHistorySeries(
                symbol: originalSP500.symbol,
                category: originalSP500.category,
                label: BacktestText.string("QUAL美国质量因子"),
                currency: originalSP500.currency,
                unit: originalSP500.unit,
                source: "V11 signal path + QUAL adjusted-close realized-return role",
                dates: originalSP500.dates,
                prices: prices,
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

        guard let hybridSP500 = hybridQUALRoleSeries() else { return nil }
        let qualRoleOption = BacktestInstrument(
            symbol: originalSP500Input.assetOption.symbol,
            title: BacktestText.string("QUAL美国质量因子"),
            requiresHistoricalFX: originalSP500Input.assetOption.requiresHistoricalFX,
            historicalFXSymbol: originalSP500Input.assetOption.historicalFXSymbol,
            category: "etf",
            iconName: "chart.line.uptrend.xyaxis",
            currency: "USD",
            unit: "share"
        )
        let candidateInputs = baseInputs.map { input in
            if BacktestAssetSymbol.normalized(input.assetOption.symbol) == "sp500" {
                return (assetSeries: Optional(hybridSP500), assetOption: qualRoleOption, fxSeries: input.fxSeries)
            }
            return input
        }

        guard let source = runNFCIDualCoreV1WithTrace(
            assetInputs: baseInputs,
            initialCash: initialCash,
            settings: settings,
            nfciAsOf: nfciAsOf,
            dateBounds: dateBounds,
            profile: .simplifiedV11
        ) else { return nil }

        let frozenSettings = AdvancedBacktestRiskSettings(
            feeRate: CashConfidenceFrozenParameters.frozenV1.frozenDecisionFeeRatePercent,
            slippageRate: CashConfidenceFrozenParameters.frozenV1.frozenDecisionSlippageRatePercent,
            maxPositionRatio: settings.maxPositionRatio,
            cooldownDays: settings.cooldownDays,
            stopLossRatio: settings.stopLossRatio,
            takeProfitRatio: settings.takeProfitRatio
        )
        let decisionSource: AdvancedRotationStrategyRun
        if abs(settings.feeRate - CashConfidenceFrozenParameters.frozenV1.frozenDecisionFeeRatePercent) < 0.0000001,
           abs(settings.slippageRate - CashConfidenceFrozenParameters.frozenV1.frozenDecisionSlippageRatePercent) < 0.0000001 {
            decisionSource = source
        } else {
            guard let frozenSource = runNFCIDualCoreV1WithTrace(
                assetInputs: baseInputs,
                initialCash: initialCash,
                settings: frozenSettings,
                nfciAsOf: nfciAsOf,
                dateBounds: dateBounds,
                profile: .simplifiedV11
            ) else { return nil }
            decisionSource = frozenSource
        }
        let sourceTargets = Dictionary(uniqueKeysWithValues: decisionSource.dailyStates.map {
            ($0.date.backtestDateString, $0.targetWeights)
        })
        let sourceTradeDates = Set(decisionSource.report.trades.map { $0.date.backtestDateString })
        let config = ResearchTargetStrategyConfig(
            symbol: "nfci_dual_core_v11_qual_role",
            title: BacktestText.string("NFCI 双核心·质量增强（研究）"),
            warmupSessions: parameters.warmupSessions,
            rebalanceSessions: parameters.rebalanceSessions,
            rebalanceBand: parameters.finalRebalanceBand,
            maxGrossExposure: parameters.grossCap,
            allowsFinancedExposure: false,
            financingAnnualRate: 0,
            buyReason: BacktestText.string("V11 质量因子角色调仓")
        )
        var pendingTarget: [String: Double] = [:]
        guard let candidate = TargetProviderBacktest.runResearchTargetProviderStrategyWithTrace(
            assetInputs: candidateInputs,
            initialCash: initialCash,
            settings: settings,
            config: config,
            dateBounds: dateBounds,
            rebalanceDecision: { index, _, data in
                guard data.dates.indices.contains(index) else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }
                let key = data.dates[index].backtestDateString
                guard sourceTradeDates.contains(key), let target = sourceTargets[key] else {
                    return BacktestRebalanceDecision(shouldRebalance: false, refreshOverlay: false)
                }
                pendingTarget = target
                return BacktestRebalanceDecision(shouldRebalance: true, refreshOverlay: false)
            },
            targetWeights: { _, _ in pendingTarget }
        ) else { return nil }
        return AdvancedRotationStrategyRun(report: candidate.report, dailyStates: candidate.dailyStates)
    }
}
