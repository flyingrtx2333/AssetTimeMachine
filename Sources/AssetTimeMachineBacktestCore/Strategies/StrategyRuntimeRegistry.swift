import Foundation

/// Registry dispatch is shared by the App facade, public compute, daily advice and research.
nonisolated enum StrategyRuntimeRegistry {
    struct Input {
        let assetInputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestInstrument, fxSeries: PublicHistorySeries?)]
        let initialCash: Double
        let settings: AdvancedBacktestRiskSettings
        let nfciAsOf: BacktestNFCIAsOfData?
        let dateBounds: ClosedRange<Date>?
    }
    typealias Factory = (Input) -> AdvancedRotationStrategyRun?
    static let specialized: [AdvancedBacktestStrategyMode: Factory] = [
        .riskContributionCashConfidenceLowNoise: { input in
            guard let run = CashConfidenceStrategy.runRiskContributionCashConfidenceRouterWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, dateBounds: input.dateBounds, profile: .lowNoiseNoLeverage) else { return nil }
            return AdvancedRotationStrategyRun(report: run.report, dailyStates: run.dailyStates)
        },
        .riskContributionCashConfidenceRouter: { input in
            guard let run = CashConfidenceStrategy.runRiskContributionCashConfidenceRouterWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, dateBounds: input.dateBounds) else { return nil }
            return AdvancedRotationStrategyRun(report: run.report, dailyStates: run.dailyStates)
        },
        .riskContributionRecoveryRouter: { input in
            guard let run = RiskContributionStrategy.runRiskContributionRecoveryRouterWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, dateBounds: input.dateBounds) else { return nil }
            return AdvancedRotationStrategyRun(report: run.report, dailyStates: run.dailyStates)
        },
        .riskContributionRegimeRouter: { input in
            guard let run = RegimeRouterStrategy.runRiskContributionRegimeRouterWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, dateBounds: input.dateBounds) else { return nil }
            return AdvancedRotationStrategyRun(report: run.report, dailyStates: run.dailyStates)
        },
        .riskContributionReallocation: { input in
            guard let run = RiskContributionStrategy.runRiskContributionReallocationWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, dateBounds: input.dateBounds) else { return nil }
            return AdvancedRotationStrategyRun(report: run.report, dailyStates: run.dailyStates)
        },
        .onlineStrategyAllocator: { input in
            guard let run = OnlineAllocatorStrategy.runOnlineStrategyAllocatorWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, dateBounds: input.dateBounds) else { return nil }
            return AdvancedRotationStrategyRun(report: run.report, dailyStates: run.dailyStates)
        },
        .convexCrashHedgeComposite: { input in
            guard let run = CrashHedgeStrategy.runConvexCrashHedgeCompositeWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, dateBounds: input.dateBounds) else { return nil }
            return AdvancedRotationStrategyRun(report: run.report, dailyStates: run.dailyStates)
        },
        .goldNasdaqDualTrendBarbell: { input in
            guard let run = GoldNasdaqBarbellStrategy.runGoldNasdaqDualTrendBarbellWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, dateBounds: input.dateBounds) else { return nil }
            return AdvancedRotationStrategyRun(report: run.report, dailyStates: run.dailyStates)
        },
        .recentVolatilityManagedIdleCash: { input in
            RecentWindowStrategies.runRecentWindowOverlayStrategyWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, mode: .recentVolatilityManagedIdleCash, dateBounds: input.dateBounds)
        },
        .recentPairSpreadZ252Shift25: { input in
            RecentWindowStrategies.runRecentWindowOverlayStrategyWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, mode: .recentPairSpreadZ252Shift25, dateBounds: input.dateBounds)
        },
        .recentGoldEquityRelativeZ252Shift25: { input in
            RecentWindowStrategies.runRecentWindowOverlayStrategyWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, mode: .recentGoldEquityRelativeZ252Shift25, dateBounds: input.dateBounds)
        },
        .nfciDualCoreV1: { input in
            guard let macro = input.nfciAsOf else { return nil }
            return NFCICoreStrategy.runNFCIDualCoreV1WithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, nfciAsOf: macro, dateBounds: input.dateBounds, profile: .v1)
        },
        .nfciDualCoreSimplifiedV11: { input in
            guard let macro = input.nfciAsOf else { return nil }
            return NFCICoreStrategy.runNFCIDualCoreV1WithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, nfciAsOf: macro, dateBounds: input.dateBounds, profile: .simplifiedV11)
        },
        .nfciDualCoreSimplifiedV11QualRole: { input in
            guard let macro = input.nfciAsOf else { return nil }
            return NFCICoreStrategy.runNFCIDualCoreSimplifiedV11QualRoleWithTrace(assetInputs: input.assetInputs, initialCash: input.initialCash, settings: input.settings, nfciAsOf: macro, dateBounds: input.dateBounds)
        },
    ]
    static let factories: [AdvancedBacktestStrategyMode: Factory] = {
        var result = specialized
        for mode in AdvancedBacktestStrategyMode.allCases where result[mode] == nil {
            result[mode] = { input in
                guard let parameters = RotationParameters.advancedRotationConfig(for: mode) else { return nil }
                return RotationStrategy.runAdvancedRotationWithTrace(assetInputs: input.assetInputs,
                    initialCash: input.initialCash, settings: input.settings, config: parameters, dateBounds: input.dateBounds)
            }
        }
        return result
    }()
    static func run(mode: AdvancedBacktestStrategyMode, input: Input) -> AdvancedRotationStrategyRun? {
        factories[mode]?(input)
    }
}
