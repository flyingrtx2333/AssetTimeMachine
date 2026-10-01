import Foundation

nonisolated enum RotationParameters {
    static func recentLossVolatilityMetaConfig(
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
        ohlcRiskOverlay: AdvancedRotationOHLCRiskOverlay? = nil,
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
            ohlcRiskOverlay: ohlcRiskOverlay,
            goldPanicLock: goldPanicLock,
            riskEfficiencyGovernor: riskEfficiencyGovernor,
            canaryRiskBrake: canaryRiskBrake,
            riskBudgetEnhancer: riskBudgetEnhancer,
            rebalanceBand: rebalanceBand,
            buyReason: buyReason ?? BacktestText.string("近期亏损波动元策略建仓")
        )
        if confirmedAccelerationSatellite != nil || dynamicSleeveSelector != nil {
            config.zeroFillBeforeFirstSymbols.formUnion(["chinext"])
        }
        if globalRepairStack != nil || ohlcRiskOverlay != nil {
            config.zeroFillBeforeFirstSymbols.formUnion([
                "dowjones", "hsi", "nikkei", "shenzhen_component", "chinext", "oil_wti_cny", "usd_cash",
            ])
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
        if let variant = BacktestRunScope.parameters.ohlcRiskOverlayVariant {
            switch variant {
            case "balanced":
                config.ohlcRiskOverlay = ohlcRiskOverlayBalancedConfig()
            case "risk_first":
                config.ohlcRiskOverlay = ohlcRiskOverlayRiskFirstConfig()
            default:
                break
            }
            if config.ohlcRiskOverlay != nil {
                config.zeroFillBeforeFirstSymbols.formUnion([
                    "dowjones", "hsi", "nikkei", "shenzhen_component", "chinext", "oil_wti_cny", "usd_cash",
                ])
            }
        }
        return config
    }

    static func researchOverrideDouble(_ key: String, default defaultValue: Double) -> Double {
        switch key {
        case "ATM_ASSET_RISK_LOW_SCALE":
            if let value = BacktestRunScope.parameters.assetRiskLowScale, value.isFinite {
                return value
            }
        case "ATM_ASSET_RISK_MULTIPLIER":
            if let value = BacktestRunScope.parameters.assetRiskMultiplier, value.isFinite {
                return value
            }
        case "ATM_SHARPE_LOW_SCALE":
            if let value = BacktestRunScope.parameters.sharpeLowScale, value.isFinite {
                return value
            }
        case "ATM_SHARPE_MULTIPLIER":
            if let value = BacktestRunScope.parameters.sharpeMultiplier, value.isFinite {
                return value
            }
        default:
            break
        }
        return defaultValue
    }

    static func dynamicSleeveSelectorConfig() -> AdvancedRotationDynamicSleeveSelector {
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

    static func contagionRepairStack() -> AdvancedRotationGlobalRepairStack {
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

    static func contagionRepairStack061() -> AdvancedRotationGlobalRepairStack {
        .init(
            repairSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext"],
            globalSymbols: ["hsi", "nikkei", "oil_wti_cny"],
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
            globalPerAssetCapBySymbol: ["oil_wti_cny": 0.04],
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
                globalCheckSymbols: ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "hsi", "nikkei"],
                cooldownSessions: 42,
                equityScale: 0.45,
                globalOverlayScale: 0,
                redeployGoldRatio: 0,
                releaseMode: "us_repair",
                triggerMode: "cluster"
            )
        )
    }

    static func currencyCashSelectorConfig(
        lookbackSessions: Int = 40,
        movingAveragePeriod: Int = 80
    ) -> AdvancedRotationCurrencyCashSelector {
        .init(
            symbol: "usd_cash",
            mode: "idle_hurdle",
            lookbackSessions: lookbackSessions,
            movingAveragePeriod: movingAveragePeriod,
            cap: 1.0,
            cnyCashHurdleScale: 1.0
        )
    }

    static func ohlcRiskOverlayBalancedConfig() -> AdvancedRotationOHLCRiskOverlay {
        .init(
            usSymbols: ["nasdaq", "sp500", "dowjones"],
            chinaSymbols: ["csi300", "shanghai_composite", "shenzhen_component", "chinext"],
            otherEquitySymbols: ["hsi", "nikkei"],
            minClusterScore: 6,
            minClusterWeak: 1,
            cooldownSessions: 42,
            usScale: 0.75,
            chinaScale: 0.65,
            otherEquityScale: 0.50,
            redeployGoldRatio: 0.25,
            releaseHealthyCount: 4
        )
    }

    static func ohlcRiskOverlayRiskFirstConfig() -> AdvancedRotationOHLCRiskOverlay {
        .init(
            usSymbols: ["nasdaq", "sp500", "dowjones"],
            chinaSymbols: ["csi300", "shanghai_composite", "shenzhen_component", "chinext"],
            otherEquitySymbols: ["hsi", "nikkei"],
            minClusterScore: 6,
            minClusterWeak: 1,
            cooldownSessions: 42,
            usScale: 0.65,
            chinaScale: 0.50,
            otherEquityScale: 0.25,
            redeployGoldRatio: 0.25,
            releaseHealthyCount: 4
        )
    }

    static func goldPanicLockConfig() -> AdvancedRotationGoldPanicLock {
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

    static func riskEfficiencyGovernorConfig() -> AdvancedRotationRiskEfficiencyGovernor {
        .init(
            mode: "weak_momentum",
            volatilityLookbackSessions: 20,
            triggerVolatility: 0.13,
            targetVolatility: 0.08,
            momentumLookbackSessions: 40,
            momentumThreshold: 0.015
        )
    }

    static func advancedRotationConfig(for mode: AdvancedBacktestStrategyMode) -> AdvancedRotationConfig? {
        switch mode {
        case .goldNasdaqDualTrendBarbell,
             .convexCrashHedgeComposite,
             .onlineStrategyAllocator,
             .riskContributionReallocation,
             .riskContributionRegimeRouter,
             .riskContributionRecoveryRouter,
             .riskContributionCashConfidenceRouter,
             .riskContributionCashConfidenceLowNoise,
             .recentVolatilityManagedIdleCash,
             .recentPairSpreadZ252Shift25,
             .recentGoldEquityRelativeZ252Shift25,
             .nfciDualCoreV1,
             .nfciDualCoreSimplifiedV11,
             .nfciDualCoreSimplifiedV11QualRole:
            return nil
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
                buyReason: BacktestText.string("极稳轮动建仓")
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
                buyReason: BacktestText.string("稳健轮动建仓")
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
                buyReason: BacktestText.string("低回撤轮动建仓")
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
                buyReason: BacktestText.string("均衡轮动建仓")
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
                buyReason: BacktestText.string("增强轮动建仓")
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
                buyReason: BacktestText.string("长期低回撤趋势建仓")
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
                buyReason: BacktestText.string("长期增强低回撤趋势建仓")
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
                    ? BacktestText.string("九月风险闸门趋势建仓")
                    : BacktestText.string("稳健回撤阶梯趋势建仓")
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
                buyReason: BacktestText.string("核心黄金趋势卫星建仓")
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
                buyReason: BacktestText.string("长期趋势配置建仓")
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
                buyReason: BacktestText.string("长期低波动动量建仓")
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
                buyReason: BacktestText.string("稳健低波动动量建仓")
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
                buyReason: BacktestText.string("A股过热不追高动量建仓")
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
                buyReason: BacktestText.string("高位短弱双守门动量建仓")
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
                buyReason: BacktestText.string("配对确认双守门动量建仓")
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
                buyReason: BacktestText.string("持有中破位锁盈防守建仓")
            )
        case .recentLossVolatilityMetaMomentum:
            return recentLossVolatilityMetaConfig(mode: mode)
        case .coreGoldSatelliteConservativeMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_conservative_momentum",
                coreScale: 0.95,
                goldSatelliteWeight: 0.10,
                buyReason: BacktestText.string("核心动量+黄金卫星保守建仓")
            )
        case .coreGoldSatelliteBalancedMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_balanced_momentum",
                coreScale: 0.975,
                goldSatelliteWeight: 0.10,
                buyReason: BacktestText.string("核心动量+黄金卫星平衡建仓")
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
                buyReason: BacktestText.string("核心动量+黄金卫星满核心建仓")
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
                buyReason: BacktestText.string("热度上限元策略建仓")
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
                buyReason: BacktestText.string("黄金交接保护建仓")
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
                buyReason: BacktestText.string("权益宽度进攻引擎建仓")
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
                buyReason: BacktestText.string("单向控波元策略建仓")
            )
        case .coreGoldSatelliteEquityCurveStateGateMomentum:
            let offensiveShare = BacktestRunScope.parameters.equityCurveOffensiveShare ?? BacktestResearchParameterDefaults.frozenV1.equityCurveOffensiveShare!
            let defensiveShare = BacktestRunScope.parameters.equityCurveDefensiveShare ?? BacktestResearchParameterDefaults.frozenV1.equityCurveDefensiveShare!
            let lowScale = BacktestRunScope.parameters.equityCurveLowScale ?? BacktestResearchParameterDefaults.frozenV1.equityCurveLowScale!
            let enterDrawdown = BacktestRunScope.parameters.equityCurveEnterDrawdown ?? BacktestResearchParameterDefaults.frozenV1.equityCurveEnterDrawdown!
            let exitReturn = BacktestRunScope.parameters.equityCurveExitReturn ?? BacktestResearchParameterDefaults.frozenV1.equityCurveExitReturn!
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
                    offensiveBlendShare: offensiveShare,
                    defensiveBlendCurrentShare: defensiveShare
                ),
                equityCurveStateGate: .init(
                    lookbackSessions: 90,
                    enterReturnThreshold: 0,
                    enterDrawdownThreshold: enterDrawdown,
                    exitReturnThreshold: exitReturn,
                    exitDrawdownThreshold: 0.03,
                    lowRiskScale: lowScale
                ),
                rebalanceBand: 0.08,
                buyReason: BacktestText.string("均衡配置建仓")
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
                buyReason: BacktestText.string("高夏普状态机建仓")
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
                buyReason: BacktestText.string("收益回撤门状态机建仓")
            )
        case .coreGoldSatelliteRiskBudgetStateGateMomentum:
            let riskBudgetLowScale = BacktestRunScope.parameters.riskBudgetLowScale ?? BacktestResearchParameterDefaults.frozenV1.riskBudgetLowScale!
            let riskBudgetMultiplier = BacktestRunScope.parameters.riskBudgetMultiplier ?? BacktestResearchParameterDefaults.frozenV1.riskBudgetMultiplier!
            let riskBudgetDefensiveShare = BacktestRunScope.parameters.riskBudgetDefensiveShare ?? BacktestResearchParameterDefaults.frozenV1.riskBudgetDefensiveShare!
            let riskBudgetVolatilityScaleFloor = BacktestRunScope.parameters.riskBudgetVolatilityScaleFloor ?? BacktestResearchParameterDefaults.frozenV1.riskBudgetVolatilityScaleFloor!
            let riskBudgetReturnLookbackSessions = BacktestRunScope.parameters.riskBudgetReturnLookbackSessions ?? BacktestResearchParameterDefaults.frozenV1.riskBudgetReturnLookbackSessions!
            let riskBudgetRebalanceBand = BacktestRunScope.parameters.riskBudgetRebalanceBand ?? BacktestResearchParameterDefaults.frozenV1.riskBudgetRebalanceBand!
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
                    returnLookbackSessions: riskBudgetReturnLookbackSessions,
                    drawdownLookbackSessions: 120,
                    drawdownThreshold: 0.08,
                    volatilityLookbackSessions: 240,
                    offensiveBlendShare: 1.0,
                    defensiveBlendCurrentShare: riskBudgetDefensiveShare,
                    volatilityScaleFloor: riskBudgetVolatilityScaleFloor
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
                rebalanceBand: riskBudgetRebalanceBand,
                buyReason: BacktestText.string("进取配置建仓")
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
                buyReason: BacktestText.string("确认加速进攻袖套建仓")
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
                buyReason: BacktestText.string("防守配置建仓")
            )
        case .coreGoldSatelliteDynamicSleeveMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_dynamic_sleeve_momentum",
                dynamicSleeveSelector: dynamicSleeveSelectorConfig(),
                buyReason: BacktestText.string("动态袖套夏普策略建仓")
            )
        case .coreGoldSatelliteContagionRepairMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_contagion_repair_momentum",
                dynamicSleeveSelector: dynamicSleeveSelectorConfig(),
                globalRepairStack: contagionRepairStack(),
                buyReason: BacktestText.string("全球修复传染控制建仓")
            )
        case .coreGoldSatelliteCurrencyCashMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_currency_cash_momentum",
                dynamicSleeveSelector: dynamicSleeveSelectorConfig(),
                globalRepairStack: contagionRepairStack(),
                currencyCashSelector: currencyCashSelectorConfig(),
                buyReason: BacktestText.string("美元现金修复策略建仓")
            )
        case .coreGoldSatelliteGoldPanicLockMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_gold_panic_lock_momentum",
                dynamicSleeveSelector: dynamicSleeveSelectorConfig(),
                globalRepairStack: contagionRepairStack(),
                currencyCashSelector: currencyCashSelectorConfig(),
                goldPanicLock: goldPanicLockConfig(),
                buyReason: BacktestText.string("黄金恐慌锁盈策略建仓")
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
                buyReason: BacktestText.string("风险效率增强策略建仓")
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
                buyReason: BacktestText.string("月度热度上限元建仓")
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
                buyReason: BacktestText.string("增强热度上限元建仓")
            )
        case .coreGoldSatelliteAggressiveMomentum:
            return recentLossVolatilityMetaConfig(
                mode: mode,
                symbol: "core_gold_satellite_aggressive_momentum",
                coreScale: 0.975,
                goldSatelliteWeight: 0.15,
                buyReason: BacktestText.string("核心动量+黄金卫星进攻建仓")
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
                buyReason: BacktestText.string("双金丝雀动量防守建仓")
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
                buyReason: BacktestText.string("回撤再入场动量建仓")
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
                buyReason: BacktestText.string("金纳低回撤轮动建仓")
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
                buyReason: BacktestText.string("金纳组合调度建仓")
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
                buyReason: BacktestText.string("强势控波轮动建仓")
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
                buyReason: BacktestText.string("20日强势轮动")
            )
        case .ruleBased:
            return nil
        }
    }

    enum AdvancedRotationWeighting: Encodable {
        case winner
        case momentumInverseVolatility
        case lowVolMomentumInverseVolatility
        case coreSatelliteWinner
    }

    enum AdvancedRotationSignal: Encodable {
        case maMomentum
        case lowVolMomentum
        case guardedDualMomentum
        case drawdownReentry
    }

    struct AdvancedRotationConfig: Encodable {
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
        var ohlcRiskOverlay: AdvancedRotationOHLCRiskOverlay? = nil
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

    struct AdvancedRotationRiskBudgetEnhancer: Encodable {
        let multiplier: Double
        let annualFinancingRate: Double
    }

    struct AdvancedRotationCanaryRiskBrake: Encodable {
        let symbols: [String]
        let momentumLookbacks: [Int]
        let momentumWeights: [Double]
        let weakAllowed: Int
        let movingAveragePeriod: Int
        let momentumThreshold: Double
        let scale: Double
        let redeployGoldRatio: Double
    }

    struct AdvancedRotationGlobalRepairStack: Encodable {
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
        var globalPerAssetCapBySymbol: [String: Double] = [:]
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

    struct AdvancedRotationContagionControl: Encodable {
        let chinaHkSymbols: [String]
        let globalCheckSymbols: [String]
        let cooldownSessions: Int
        let equityScale: Double
        let globalOverlayScale: Double
        let redeployGoldRatio: Double
        let releaseMode: String
        let triggerMode: String
    }

    struct AdvancedRotationCurrencyCashSelector: Encodable {
        let symbol: String
        let mode: String
        let lookbackSessions: Int
        let movingAveragePeriod: Int
        let cap: Double
        let cnyCashHurdleScale: Double
    }

    struct AdvancedRotationOHLCRiskOverlay: Encodable {
        let usSymbols: [String]
        let chinaSymbols: [String]
        let otherEquitySymbols: [String]
        let minClusterScore: Int
        let minClusterWeak: Int
        let cooldownSessions: Int
        let usScale: Double
        let chinaScale: Double
        let otherEquityScale: Double
        let redeployGoldRatio: Double
        let releaseHealthyCount: Int
    }

    struct AdvancedRotationOHLCBar: Encodable {
        let date: Date
        let open: Double
        let high: Double
        let low: Double
        let close: Double
    }

    struct AdvancedRotationOHLCRiskFeature: Encodable {
        let score: Int
    }

    struct AdvancedRotationGoldPanicLock: Encodable {
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

    struct AdvancedRotationRiskEfficiencyGovernor: Encodable {
        let mode: String
        let volatilityLookbackSessions: Int
        let triggerVolatility: Double
        let targetVolatility: Double
        let momentumLookbackSessions: Int
        let momentumThreshold: Double
    }

    struct AdvancedRotationConfirmedEquityBreadth: Encodable {
        let equitySymbols: [String]
        let minConfirmedCount: Int
        let shortMomentumLookbackSessions: Int
        let longMomentumLookbackSessions: Int
        let movingAveragePeriod: Int
        let volatilityLookbackSessions: Int
        let maxTotalExposure: Double
    }

    struct AdvancedRotationEngineRouter: Encodable {
        let currentMode: AdvancedBacktestStrategyMode
        let offensiveMode: AdvancedBacktestStrategyMode
        let returnLookbackSessions: Int
        let drawdownLookbackSessions: Int
        let drawdownThreshold: Double
        let volatilityLookbackSessions: Int
        let offensiveBlendShare: Double
        let defensiveBlendCurrentShare: Double
        let volatilityScaleFloor: Double

        init(
            currentMode: AdvancedBacktestStrategyMode,
            offensiveMode: AdvancedBacktestStrategyMode,
            returnLookbackSessions: Int,
            drawdownLookbackSessions: Int,
            drawdownThreshold: Double,
            volatilityLookbackSessions: Int,
            offensiveBlendShare: Double,
            defensiveBlendCurrentShare: Double,
            volatilityScaleFloor: Double = 0
        ) {
            self.currentMode = currentMode
            self.offensiveMode = offensiveMode
            self.returnLookbackSessions = returnLookbackSessions
            self.drawdownLookbackSessions = drawdownLookbackSessions
            self.drawdownThreshold = drawdownThreshold
            self.volatilityLookbackSessions = volatilityLookbackSessions
            self.offensiveBlendShare = offensiveBlendShare
            self.defensiveBlendCurrentShare = defensiveBlendCurrentShare
            self.volatilityScaleFloor = volatilityScaleFloor
        }
    }

    struct AdvancedRotationConfirmedAccelerationSatellite: Encodable {
        let extraSymbols: [String]
        let usMarketSymbols: [String]
        let chinaMarketSymbols: [String]
        let chinaExtraSymbols: Set<String>
        let cap: Double
        let perAssetCap: Double
        let topCount: Int
        let weakMonths: Set<Int>
    }

    struct AdvancedRotationProfitLockBudget: Encodable {
        let lookbackSessions: Int
        let softDrawdown: Double
        let hardDrawdown: Double
        let minScale: Double
        let profitLookbackSessions: Int
        let profitThreshold: Double
        let shallowDrawdownThreshold: Double
        let profitScale: Double
    }

    struct AdvancedRotationEquityCurveStateGate: Encodable {
        let lookbackSessions: Int
        let enterReturnThreshold: Double
        let enterDrawdownThreshold: Double
        let exitReturnThreshold: Double
        let exitDrawdownThreshold: Double
        let lowRiskScale: Double
    }

    struct AdvancedRotationAssetRiskStateGate: Encodable {
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

    struct AdvancedRotationDynamicSleeveSelector: Encodable {
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

    struct AdvancedRotationCanaryRegime: Encodable {
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

    struct AdvancedRotationOverheatBrake: Encodable {
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

    struct AdvancedRotationDecelerationLock: Encodable {
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

    struct AdvancedRotationShortWeaknessLock: Encodable {
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

    struct AdvancedRotationPairConfirmationGuard: Encodable {
        let peerBySymbol: [String: String]
        let peerMomentumLookbackSessions: Int
        let peerMomentumThreshold: Double
        let peerDrawdownLookbackSessions: Int
        let peerDrawdownThreshold: Double
        let maxExposure: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    struct AdvancedRotationHeldBreakdownLock: Encodable {
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

    struct AdvancedRotationGoldSatelliteOverlay: Encodable {
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

    struct AdvancedRotationSingleAssetExposureCap: Encodable {
        let symbols: [String]
        let maxWeight: Double
    }

    struct AdvancedRotationConfirmedExcessRotation: Encodable {
        let candidateSymbols: [String]
        let equitySymbols: [String]
        let maxAdd: Double
        let momentumLookbackSessions: Int
        let movingAveragePeriod: Int
        let volatilityLookbackSessions: Int
        let minimumMomentum: Double
        let volatilityFloor: Double
    }

    struct AdvancedRotationDiversificationCredit: Encodable {
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

    struct AdvancedRotationGoldRolloverCap: Encodable {
        let symbol: String
        let longMomentumLookbackSessions: Int
        let longMomentumThreshold: Double
        let shortMomentumLookbackSessions: Int
        let shortMomentumThreshold: Double
        let maxWeight: Double
    }

    struct AdvancedRotationGoldRolloverConfirmedHandoff: Encodable {
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

    struct AdvancedRotationOverlayPortfolioEquityBrake: Encodable {
        let lookbackSessions: Int
        let drawdownThreshold: Double
        let equitySymbols: [String]
        let equityScale: Double
    }

    struct AdvancedRotationWeakMonthEquityBrake: Encodable {
        let months: Set<Int>
        let equitySymbols: [String]
        let momentumLookbackSessions: Int
        let momentumThreshold: Double
        let maxEquityExposure: Double
    }

    struct AdvancedRotationMetaSwitch: Encodable {
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

    struct AdvancedRotationPortfolioDrawdownGuard: Encodable {
        let lookbackSessions: Int
        let drawdownThreshold: Double
        let scale: Double
    }

    struct AdvancedRotationVolatilityBrake: Encodable {
        let triggerSymbol: String
        let threshold: Double
        let scaledSymbols: [String]
        let scale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    struct AdvancedRotationFastCrashBrake: Encodable {
        let triggerSymbols: [String]
        let lookbackSessions: Int
        let drawdownThreshold: Double
        let scaledSymbols: [String]
        let scale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    struct AdvancedRotationDrawdownLadderBrake: Encodable {
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

    struct AdvancedRotationMonthlyExposureBrake: Encodable {
        let months: Set<Int>
        let scaledSymbols: [String]
        let scale: Double
        let redeploySymbol: String?
        let redeployRatio: Double
    }

    static func advancedOverlayWarmup(for config: AdvancedRotationConfig) -> Int {
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
        let ohlcRiskWarmup = config.ohlcRiskOverlay == nil ? 0 : 120
        return max(repairWarmup, currencyWarmup, goldPanicWarmup, governorWarmup, equityCurveStateWarmup, assetRiskWarmup, ohlcRiskWarmup)
    }
}
