import Foundation

@frozen public enum AdvancedBacktestSignalDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case alwaysBuy
    case neverSell
    case consecutiveDown
    case consecutiveUp
    case priceAboveMA20
    case priceBelowMA20
    case priceAboveMA60
    case priceBelowMA60
    case priceCrossesAboveMA20
    case priceCrossesBelowMA20
    case ma20CrossesAboveMA60
    case ma20CrossesBelowMA60
    case priceCrossesAboveBollMiddle
    case priceCrossesBelowBollMiddle
    case touchesBollLower
    case touchesBollUpper

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .alwaysBuy:
            return BacktestText.string("持续买入")
        case .neverSell:
            return BacktestText.string("不主动卖出")
        case .consecutiveDown:
            return BacktestText.string("连续下跌")
        case .consecutiveUp:
            return BacktestText.string("连续上涨")
        case .priceAboveMA20:
            return BacktestText.string("价格高于 MA20")
        case .priceBelowMA20:
            return BacktestText.string("价格低于 MA20")
        case .priceAboveMA60:
            return BacktestText.string("价格高于 MA60")
        case .priceBelowMA60:
            return BacktestText.string("价格低于 MA60")
        case .priceCrossesAboveMA20:
            return BacktestText.string("价格上穿 MA20")
        case .priceCrossesBelowMA20:
            return BacktestText.string("价格下穿 MA20")
        case .ma20CrossesAboveMA60:
            return BacktestText.string("MA20 上穿 MA60")
        case .ma20CrossesBelowMA60:
            return BacktestText.string("MA20 下穿 MA60")
        case .priceCrossesAboveBollMiddle:
            return BacktestText.string("价格上穿 BOLL 中轨")
        case .priceCrossesBelowBollMiddle:
            return BacktestText.string("价格下穿 BOLL 中轨")
        case .touchesBollLower:
            return BacktestText.string("跌破/触及 BOLL 下轨")
        case .touchesBollUpper:
            return BacktestText.string("突破/触及 BOLL 上轨")
        }
    }

    public var shortTitle: String {
        switch self {
        case .alwaysBuy:
            return BacktestText.string("持续买")
        case .neverSell:
            return BacktestText.string("持有")
        case .consecutiveDown:
            return BacktestText.string("跌")
        case .consecutiveUp:
            return BacktestText.string("涨")
        case .priceAboveMA20:
            return BacktestText.string("高于MA20")
        case .priceBelowMA20:
            return BacktestText.string("低于MA20")
        case .priceAboveMA60:
            return BacktestText.string("高于MA60")
        case .priceBelowMA60:
            return BacktestText.string("低于MA60")
        case .priceCrossesAboveMA20:
            return BacktestText.string("价上穿MA20")
        case .priceCrossesBelowMA20:
            return BacktestText.string("价下穿MA20")
        case .ma20CrossesAboveMA60:
            return BacktestText.string("MA金叉")
        case .ma20CrossesBelowMA60:
            return BacktestText.string("MA死叉")
        case .priceCrossesAboveBollMiddle:
            return BacktestText.string("上穿BOLL中轨")
        case .priceCrossesBelowBollMiddle:
            return BacktestText.string("下穿BOLL中轨")
        case .touchesBollLower:
            return BacktestText.string("BOLL下轨")
        case .touchesBollUpper:
            return BacktestText.string("BOLL上轨")
        }
    }

    nonisolated public var usesDayThreshold: Bool {
        switch self {
        case .consecutiveDown, .consecutiveUp:
            return true
        case .alwaysBuy,
             .neverSell,
             .priceAboveMA20,
             .priceBelowMA20,
             .priceAboveMA60,
             .priceBelowMA60,
             .priceCrossesAboveMA20,
             .priceCrossesBelowMA20,
             .ma20CrossesAboveMA60,
             .ma20CrossesBelowMA60,
             .priceCrossesAboveBollMiddle,
             .priceCrossesBelowBollMiddle,
             .touchesBollLower,
             .touchesBollUpper:
            return false
        }
    }

    nonisolated public var isBuySignalOption: Bool {
        switch self {
        case .alwaysBuy,
             .consecutiveDown,
             .priceAboveMA20,
             .priceAboveMA60,
             .priceCrossesAboveMA20,
             .ma20CrossesAboveMA60,
             .priceCrossesAboveBollMiddle,
             .touchesBollLower:
            return true
        case .neverSell,
             .consecutiveUp,
             .priceBelowMA20,
             .priceBelowMA60,
             .priceCrossesBelowMA20,
             .ma20CrossesBelowMA60,
             .priceCrossesBelowBollMiddle,
             .touchesBollUpper:
            return false
        }
    }

    nonisolated public var isSellSignalOption: Bool {
        switch self {
        case .neverSell,
             .consecutiveUp,
             .priceBelowMA20,
             .priceBelowMA60,
             .priceCrossesBelowMA20,
             .ma20CrossesBelowMA60,
             .priceCrossesBelowBollMiddle,
             .touchesBollUpper:
            return true
        case .alwaysBuy,
             .consecutiveDown,
             .priceAboveMA20,
             .priceAboveMA60,
             .priceCrossesAboveMA20,
             .ma20CrossesAboveMA60,
             .priceCrossesAboveBollMiddle,
             .touchesBollLower:
            return false
        }
    }
}


@frozen public enum AdvancedBacktestTradeAction: String {
    case buy
    case sell

    public var title: String {
        switch self {
        case .buy:
            return BacktestText.string("买入")
        case .sell:
            return BacktestText.string("卖出")
        }
    }


}


public struct AdvancedBacktestRule: Codable, Sendable {
    public var direction: AdvancedBacktestSignalDirection
    public var days: Int
    public init(
        direction: AdvancedBacktestSignalDirection,
        days: Int
    ) {
        self.direction = direction
        self.days = days
    }
}


nonisolated public struct BacktestNFCIPoint: Codable, Equatable, Sendable {
    public let releaseDate: String
    public let referenceDate: String
    public let availableAt: Date?
    public let value: Double
    public init(
        releaseDate: String,
        referenceDate: String,
        availableAt: Date?,
        value: Double
    ) {
        self.releaseDate = releaseDate
        self.referenceDate = referenceDate
        self.availableAt = availableAt
        self.value = value
    }
}


nonisolated public struct BacktestNFCIAsOfData: Codable, Equatable, Sendable {
    public let source: String
    public let credit: [BacktestNFCIPoint]
    public let leverage: [BacktestNFCIPoint]

    public var isReadyForC3L3: Bool {
        credit.count >= 9 && leverage.count >= 5
    }
    public init(
        source: String,
        credit: [BacktestNFCIPoint],
        leverage: [BacktestNFCIPoint]
    ) {
        self.source = source
        self.credit = credit
        self.leverage = leverage
    }
}


@frozen public enum AdvancedBacktestStrategyMode: String, Codable, CaseIterable, Sendable {
    case ruleBased
    case ultraDefensiveRotation
    case defensiveRotation
    case lowDrawdownRotation
    case balancedRotation
    case enhancedRotation
    case longTermDefensiveTrend
    case longTermEnhancedLowDrawdownTrend
    case steadyDrawdownLadderTrend
    case septemberGuardLadderTrend
    case longTermGrowthTrend
    case longTermLowVolMomentum
    case robustLowVolMomentum
    case overheatGuardMomentum
    case highZoneDecelerationMomentum
    case pairConfirmDoubleGuardMomentum
    case tailBreakdownLockMomentum
    case recentLossVolatilityMetaMomentum
    case coreGoldSatelliteConservativeMomentum
    case coreGoldSatelliteBalancedMomentum
    case coreGoldSatelliteFullMomentum
    case coreGoldSatelliteHeatCappedMomentum
    case coreGoldSatelliteGoldHandoffMomentum
    case coreGoldSatelliteEquityBreadthMomentum
    case coreGoldSatelliteOneWayVolManagedMomentum
    case coreGoldSatelliteEquityCurveStateGateMomentum
    case coreGoldSatelliteSharpeStateGateMomentum
    case coreGoldSatelliteAssetRiskGateMomentum
    case coreGoldSatelliteRiskBudgetStateGateMomentum
    case coreGoldSatelliteConfirmedAccelerationMomentum
    case coreGoldSatelliteProfitLockMomentum
    case coreGoldSatelliteDynamicSleeveMomentum
    case coreGoldSatelliteContagionRepairMomentum
    case coreGoldSatelliteCurrencyCashMomentum
    case coreGoldSatelliteGoldPanicLockMomentum
    case coreGoldSatelliteRiskEfficiencyMomentum
    case coreGoldSatelliteMonthlyHeatCappedMomentum
    case coreGoldSatelliteConfirmedExcessMomentum
    case coreGoldSatelliteAggressiveMomentum
    case canaryMomentumDefense
    case drawdownReentryMomentum
    case goldCoreTrendSatellite
    case goldNasdaqSteadyRotation
    case goldNasdaqPortfolioScheduler
    case goldNasdaqDualTrendBarbell
    case convexCrashHedgeComposite
    case onlineStrategyAllocator
    case riskContributionReallocation
    case riskContributionRegimeRouter
    case riskContributionRecoveryRouter
    case riskContributionCashConfidenceRouter
    case riskContributionCashConfidenceLowNoise
    case recentVolatilityManagedIdleCash
    case recentPairSpreadZ252Shift25
    case recentGoldEquityRelativeZ252Shift25
    case nfciDualCoreV1
    case nfciDualCoreSimplifiedV11
    case nfciDualCoreSimplifiedV11QualRole
    case strongVolControlledRotation
    case momentumRotation

    public var title: String {
        switch self {
        case .ruleBased:
            return BacktestText.string("自定义策略")
        case .ultraDefensiveRotation:
            return BacktestText.string("极稳轮动")
        case .defensiveRotation:
            return BacktestText.string("稳健轮动")
        case .lowDrawdownRotation:
            return BacktestText.string("低回撤轮动")
        case .balancedRotation:
            return BacktestText.string("均衡轮动")
        case .enhancedRotation:
            return BacktestText.string("增强轮动")
        case .longTermDefensiveTrend:
            return BacktestText.string("长期低回撤趋势")
        case .longTermEnhancedLowDrawdownTrend:
            return BacktestText.string("长期增强低回撤趋势")
        case .steadyDrawdownLadderTrend:
            return BacktestText.string("稳健回撤阶梯趋势")
        case .septemberGuardLadderTrend:
            return BacktestText.string("九月风险闸门趋势")
        case .longTermGrowthTrend:
            return BacktestText.string("长期趋势配置")
        case .longTermLowVolMomentum:
            return BacktestText.string("长期低波动动量")
        case .robustLowVolMomentum:
            return BacktestText.string("稳健低波动动量")
        case .overheatGuardMomentum:
            return BacktestText.string("A股过热不追高动量")
        case .highZoneDecelerationMomentum:
            return BacktestText.string("高位短弱双守门动量")
        case .pairConfirmDoubleGuardMomentum:
            return BacktestText.string("配对确认双守门动量")
        case .tailBreakdownLockMomentum:
            return BacktestText.string("持有中破位锁盈防守")
        case .recentLossVolatilityMetaMomentum:
            return BacktestText.string("近期亏损波动元策略")
        case .coreGoldSatelliteConservativeMomentum:
            return BacktestText.string("核心动量+黄金卫星（保守）")
        case .coreGoldSatelliteBalancedMomentum:
            return BacktestText.string("核心动量+黄金卫星（平衡）")
        case .coreGoldSatelliteFullMomentum:
            return BacktestText.string("核心动量+黄金卫星（满核心）")
        case .coreGoldSatelliteHeatCappedMomentum:
            return BacktestText.string("热度上限元策略")
        case .coreGoldSatelliteGoldHandoffMomentum:
            return BacktestText.string("黄金交接保护")
        case .coreGoldSatelliteEquityBreadthMomentum:
            return BacktestText.string("权益宽度进攻引擎")
        case .coreGoldSatelliteOneWayVolManagedMomentum:
            return BacktestText.string("单向控波元策略")
        case .coreGoldSatelliteEquityCurveStateGateMomentum:
            return BacktestText.string("均衡配置")
        case .coreGoldSatelliteSharpeStateGateMomentum:
            return BacktestText.string("高夏普状态机")
        case .coreGoldSatelliteAssetRiskGateMomentum:
            return BacktestText.string("收益回撤门状态机")
        case .coreGoldSatelliteRiskBudgetStateGateMomentum:
            return BacktestText.string("进取配置")
        case .coreGoldSatelliteConfirmedAccelerationMomentum:
            return BacktestText.string("确认加速进攻袖套")
        case .coreGoldSatelliteProfitLockMomentum:
            return BacktestText.string("防守配置")
        case .coreGoldSatelliteDynamicSleeveMomentum:
            return BacktestText.string("动态袖套夏普策略")
        case .coreGoldSatelliteContagionRepairMomentum:
            return BacktestText.string("全球修复传染控制")
        case .coreGoldSatelliteCurrencyCashMomentum:
            return BacktestText.string("美元现金修复策略")
        case .coreGoldSatelliteGoldPanicLockMomentum:
            return BacktestText.string("黄金恐慌锁盈策略")
        case .coreGoldSatelliteRiskEfficiencyMomentum:
            return BacktestText.string("风险效率增强策略")
        case .coreGoldSatelliteMonthlyHeatCappedMomentum:
            return BacktestText.string("月度热度上限元")
        case .coreGoldSatelliteConfirmedExcessMomentum:
            return BacktestText.string("增强热度上限元")
        case .coreGoldSatelliteAggressiveMomentum:
            return BacktestText.string("核心动量+黄金卫星（进攻）")
        case .canaryMomentumDefense:
            return BacktestText.string("双金丝雀动量防守")
        case .drawdownReentryMomentum:
            return BacktestText.string("回撤再入场动量")
        case .goldCoreTrendSatellite:
            return BacktestText.string("核心黄金趋势卫星")
        case .goldNasdaqSteadyRotation:
            return BacktestText.string("金纳低回撤轮动")
        case .goldNasdaqPortfolioScheduler:
            return BacktestText.string("金纳组合调度")
        case .goldNasdaqDualTrendBarbell:
            return BacktestText.string("金纳双趋势")
        case .convexCrashHedgeComposite:
            return BacktestText.string("凸性极速空头组合")
        case .onlineStrategyAllocator:
            return BacktestText.string("在线策略分配器")
        case .riskContributionReallocation:
            return BacktestText.string("风险贡献再分配")
        case .riskContributionRegimeRouter:
            return BacktestText.string("双引擎制度路由")
        case .riskContributionRecoveryRouter:
            return BacktestText.string("双引擎水下恢复")
        case .riskContributionCashConfidenceRouter:
            return BacktestText.string("无融资置信度恢复")
        case .riskContributionCashConfidenceLowNoise:
            return BacktestText.string("低噪增强")
        case .recentVolatilityManagedIdleCash:
            return BacktestText.string("近期研究·闲置现金控波部署")
        case .recentPairSpreadZ252Shift25:
            return BacktestText.string("近期研究·跨市场配对回归")
        case .recentGoldEquityRelativeZ252Shift25:
            return BacktestText.string("近期研究·黄金权益相对回归")
        case .nfciDualCoreV1:
            return BacktestText.string("NFCI 双核心（前瞻）")
        case .nfciDualCoreSimplifiedV11:
            return BacktestText.string("NFCI 双核心·简化（前瞻）")
        case .nfciDualCoreSimplifiedV11QualRole:
            return BacktestText.string("NFCI 双核心·质量增强（研究）")
        case .strongVolControlledRotation:
            return BacktestText.string("强势控波轮动")
        case .momentumRotation:
            return BacktestText.string("高风险强势轮动")
        }
    }

    public var detail: String {
        switch self {
        case .ruleBased:
            return BacktestText.string("按买入/卖出条件独立回测每个资产")
        case .ultraDefensiveRotation:
            return BacktestText.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动6%，最高投入35%")
        case .defensiveRotation:
            return BacktestText.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动8%，最高投入55%")
        case .lowDrawdownRotation:
            return BacktestText.string("40日强弱排序，每20个交易日在合格资产里分散持有，按动量/波动加权，目标波动10%，最多投入65%")
        case .balancedRotation:
            return BacktestText.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动12%，最高投入75%")
        case .enhancedRotation:
            return BacktestText.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动12%，最高投入90%")
        case .longTermDefensiveTrend:
            return BacktestText.string("2001年以来优选：黄金65%、标普15.7%、纳指19.3%，需站上MA200且120日动量为正；每20个交易日再平衡，目标波动8.5%")
        case .longTermEnhancedLowDrawdownTrend:
            return BacktestText.string("长期增强候选：黄金73%、标普1%、纳指26%，需站上MA220且120日动量为正；目标波动9.5%，纳指波动过热时自动降权益仓。")
        case .steadyDrawdownLadderTrend:
            return BacktestText.string("更重视持有体验：黄金73%、标普1%、纳指26%，需站上MA220且120日动量为正；权益从180日高点回撤超过6%/12%时分级降仓，优先转向黄金或现金。")
        case .septemberGuardLadderTrend:
            return BacktestText.string("在稳健回撤阶梯趋势上叠加九月风险闸门：9月仅保留25%权益仓，砍掉的权益优先转向趋势有效的黄金；目标是降低近期独立区间最大回撤。")
        case .longTermGrowthTrend:
            return BacktestText.string("2001年以来进取候选：黄金50%、标普15%、纳指35%，需站上MA220且120日动量为正；每20个交易日再平衡，目标波动11%")
        case .longTermLowVolMomentum:
            return BacktestText.string("非均线长期候选：黄金、纳指、标普、沪深300、上证综指中筛选240日动量为正且波动较低的资产；每60个交易日再平衡，目标波动10.5%")
        case .robustLowVolMomentum:
            return BacktestText.string("新搜索候选：黄金、标普、纳指中筛选180日动量为正且30日年化波动低于18%的资产；按低波动分散，每40个交易日再平衡，目标波动7.5%，最高仓位55%")
        case .overheatGuardMomentum:
            return BacktestText.string("收益优先候选：黄金、纳指、标普、沪深300、上证综指中只拿最强资产；当A股泡沫式加速时不追满仓，主仓降到保护仓位并优先让黄金承接。")
        case .highZoneDecelerationMomentum:
            return BacktestText.string("突破候选：沿用最强资产动量框架，但新增双守门；高位动量钝化时先锁盈，若风险资产20日转弱且相对黄金明显落后，则把风险预算降到现金防守。")
        case .pairConfirmDoubleGuardMomentum:
            return BacktestText.string("稳健增强候选：保留高位短弱双守门主体，但美股/A股持仓需要同组兄弟指数确认；若兄弟指数已明显走弱，先把总仓位压到60%，优先转向黄金或现金。")
        case .tailBreakdownLockMomentum:
            return BacktestText.string("防守发动机：保留双守门动量主体，并在持有期间检查高位破位、短动量转弱和相对黄金落后；多项风险同时出现时先锁盈降仓。")
        case .recentLossVolatilityMetaMomentum:
            return BacktestText.string("综合冠军候选：平时跟随高位短弱双守门动量；当该策略自身近期亏损和波动同时放大时，短期转入持有中破位锁盈防守发动机，恢复后再进攻。")
        case .coreGoldSatelliteConservativeMomentum:
            return BacktestText.string("稳健增强候选：以近期亏损波动元策略为核心，只使用95%核心仓位；当黄金90日动量为正、站上120日均线且60日跑赢标普时，挂10%黄金卫星；2月权益走弱时压低权益仓位。")
        case .coreGoldSatelliteBalancedMomentum:
            return BacktestText.string("推荐候选：以近期亏损波动元策略为核心，核心仓位提升到97.5%；黄金趋势和相对强度同时有效时挂10%黄金卫星，兼顾收益和9%左右回撤控制。")
        case .coreGoldSatelliteFullMomentum:
            return BacktestText.string("新冠军候选：近期亏损波动元策略保持满核心，黄金趋势和相对强度有效时挂10%黄金卫星；总仓位封顶85%，并用二月弱权益刹车和净值轻刹车控制回撤。")
        case .coreGoldSatelliteHeatCappedMomentum:
            return BacktestText.string("上架候选：以近期亏损波动元策略为核心，黄金趋势和相对强度有效时挂10%黄金卫星；组合总仓位封顶85%，单个权益指数最多64%，并保留二月弱势刹车和净值轻刹车。")
        case .coreGoldSatelliteGoldHandoffMomentum:
            return BacktestText.string("新逻辑候选：沿用热度上限元框架；当黄金短线转弱时先把黄金单仓压到45%，若美股趋势仍确认，则把释放的风险预算交接给更强的纳指或标普，否则留现金。")
        case .coreGoldSatelliteEquityBreadthMomentum:
            return BacktestText.string("内部进攻引擎：在黄金交接保护基础上，把空余风险预算分配给趋势确认的权益指数，用于元策略对照，不单独推荐。")
        case .coreGoldSatelliteOneWayVolManagedMomentum:
            return BacktestText.string("新夏普冠军：以黄金交接保护为防守引擎、权益宽度为进攻引擎；当进攻引擎领先但自身波动高于防守引擎时，只降仓不加仓，剩余留现金。")
        case .coreGoldSatelliteEquityCurveStateGateMomentum:
            return BacktestText.string("App-only状态机候选：以单向控波双引擎为基础；当策略自身近90日收益转弱或回撤扩大时，把风险预算降到70%，恢复后再打开。")
        case .coreGoldSatelliteSharpeStateGateMomentum:
            return BacktestText.string("高夏普候选：以双引擎路由和黄金分散信用为基础；当策略自身75日收益转弱或回撤扩大时，把风险预算降到45%，只有75日收益重新转强后再打开。")
        case .coreGoldSatelliteAssetRiskGateMomentum:
            return BacktestText.string("收益回撤候选：以权益曲线状态机为底层，把低风险档位压到73%，并在A股泡沫后破位时清掉对应A股袖套；目标是在10%左右年化下把最大回撤压进10%以内。")
        case .coreGoldSatelliteRiskBudgetStateGateMomentum:
            return BacktestText.string("长期宽度风险预算：用约420个交易日比较黄金交接与权益宽度引擎；进攻引擎波动更高时至少保留50%目标仓位，风险转弱时保留50%防守组合。全程无融资，并按8%权重偏离阈值再平衡，以适应1%交易费。")
        case .coreGoldSatelliteConfirmedAccelerationMomentum:
            return BacktestText.string("内部进攻袖套：在单向控波基础上，只用空余预算承接确认加速且波动收缩的道指、深成指或创业板。")
        case .coreGoldSatelliteProfitLockMomentum:
            return BacktestText.string("内部防守袖套：在单向控波基础上，根据组合自身回撤和快速上涨后的锁盈状态平滑降低风险预算。")
        case .coreGoldSatelliteDynamicSleeveMomentum:
            return BacktestText.string("高夏普候选：在确认加速进攻袖套和锁盈防守袖套之间做315日相对收益迟滞切换；高档95%、低档25%，全程无融资。")
        case .coreGoldSatelliteContagionRepairMomentum:
            return BacktestText.string("新高收益线：以动态袖套为核心，空闲预算只在回撤修复确认时承接恒生/日经等全球修复机会；A/H股泡沫回落和全球宽度转弱时临时压低权益仓。")
        case .coreGoldSatelliteCurrencyCashMomentum:
            return BacktestText.string("在全球修复传染控制基础上，空闲预算不只留人民币现金；当美元现金趋势优于现金门槛时，使用美元现金承接闲置仓位，全程不融资。")
        case .coreGoldSatelliteGoldPanicLockMomentum:
            return BacktestText.string("在美元现金修复策略上加入黄金恐慌溢价锁：黄金短期暴冲后转弱时临时降低黄金仓，释放预算交给现金选择器，降低2003式黄金回吐。")
        case .coreGoldSatelliteRiskEfficiencyMomentum:
            return BacktestText.string("当前高夏普候选：叠加传染控制、美元现金、黄金恐慌锁盈，并在目标组合波动偏高且动量质量不足时稀疏降风险。")
        case .coreGoldSatelliteMonthlyHeatCappedMomentum:
            return BacktestText.string("月度候选：沿用热度上限元策略框架，但约每30个交易日检查一次；单权益上限提高到72%，保留黄金卫星、二月弱势刹车和净值轻刹车，追求更平滑的全周期回撤。")
        case .coreGoldSatelliteConfirmedExcessMomentum:
            return BacktestText.string("增强候选：沿用热度上限元框架，单权益超出上限的风险预算不直接闲置；优先转给趋势和相对强度有效的黄金，否则转给动量为正、站上MA120且波动较低的确认资产。")
        case .coreGoldSatelliteAggressiveMomentum:
            return BacktestText.string("进取候选：核心仍为近期亏损波动元策略，核心仓位97.5%，黄金卫星提高到15%；历史收益更高，但最大回撤更接近10%。")
        case .canaryMomentumDefense:
            return BacktestText.string("2002年以来候选：纳指+标普做金丝雀，20/60/120/240日动量判断风险环境；进攻选强势权益前2并保留黄金底仓，转弱时只留黄金或现金防守。")
        case .drawdownReentryMomentum:
            return BacktestText.string("收益优先候选：黄金作防守底仓，纳指/标普/A股指数只在90日回撤可控且动量或RSI重新转强时入场；每40个交易日再平衡，目标波动7.5%，最高仓位65%。")
        case .goldCoreTrendSatellite:
            return BacktestText.string("黄金作为防守核心，纳指/标普只做趋势卫星；黄金看MA120，权益看MA250，每20个交易日再平衡，目标波动9.5%。")
        case .goldNasdaqSteadyRotation:
            return BacktestText.string("黄金/纳指双资产择强：近20日涨幅需超过2%，且站上MA250；每40个交易日切到更强资产，目标波动8%，最高投入90%")
        case .goldNasdaqPortfolioScheduler:
            return BacktestText.string("资产只在纳指、黄金、现金之间调度；参考多年美股压力信号控制风险。纳指/黄金按趋势和强弱给目标仓位，压力升温时自动降低纳指、提高黄金或现金。")
        case .goldNasdaqDualTrendBarbell:
            return BacktestText.string("独立双资产逻辑：黄金基准55%、纳指基准45%，两边分别用MA200和126/252日动量判断强势、震荡或弱势；约每63个交易日复核，震荡时保留大部分仓位，明确弱势时降到小仓位并让剩余资金留现金。全程无融资，按1%交易费验证。")
        case .convexCrashHedgeComposite:
            return BacktestText.string("研究型收益优先组合：35%高夏普状态机、26%进取风险预算、39%双趋势金纳在目标权重层融合并放大1.5倍；另配置3%严格T−1的美股/A股极速空头危机袖套。总风险封顶110%，超出现金按5%年化融资，按1%交易费与0.05%滑点统一成交。空头袖套为指数反向收益模型，不代表可直接购买的单一产品。")
        case .onlineStrategyAllocator:
            return BacktestText.string("研究型低回撤组合：在进取风险预算、高夏普状态机、稳健锁盈防守和双趋势金纳之间，每63个交易日根据过去504日的收益、波动和最大回撤重新分配；采用75%惯性并限制单条逻辑最高约70%，全程无融资，按1%交易费统一成交。")
        case .riskContributionReallocation:
            return BacktestText.string("研究型综合增强组合：先按40%高夏普状态机、25%进取风险预算、35%双趋势金纳生成目标仓位，并按底层仓位共识使用1.00/1.20/1.40倍风险档。每42个交易日估计最多126日协方差；当单一资产风险贡献超过65%时，将60%目标权重按低波动与低正相关方向重新分配。当美股既有仓位至少10%、目标拟一次增加10%至20%，且纳指与标普近5日动量同时转负时，仅执行新增仓位的60%。当A股目标一次减少至少15%、美股目标拟增加5%至10%，且纳指或标普近5日动量至少一个未转正时，仅执行美股新增仓位的50%，避免区域风险退出后立即把风险转移到美股。总风险封顶110%，负现金按5%年化融资，目标权重变化超过8%才成交，统一计入1%交易费与0.05%滑点。")
        case .riskContributionRegimeRouter:
            return BacktestText.string("质变型实验策略：同时运行稳健风险贡献引擎与进攻风险贡献引擎。每63个交易日只用T−1数据比较两者过去252日净值；进攻引擎领先至少2.5%且站上自身63日均值时切换进攻，落后3%或跌破均值3%时切回稳健。历史固定数据中仅发生3次制度切换，总风险封顶120%，负现金按5%年化融资，目标变化超过8%才成交，统一计入1%交易费与0.05%滑点。")
        case .riskContributionRecoveryRouter:
            return BacktestText.string("在双引擎制度路由上加入快速上涨桥接与长水下恢复袖套：进攻状态在自身28日净值向上、回撤不超过1.5%，且纳指或标普站上MA120并保持60日正动量时放大至1.082倍；稳健状态遇到跨市场广度回升时，短暂向进攻引擎桥接18.5%。当基础净值水下至少60个交易日且回撤达到5%，纳指或标普站上MA100并保持60日正动量时，使用最多15%的闲置现金建立恢复袖套；每60个交易日复核，每个水下周期最多进入2次，退出后冷却180个交易日，双指数3日同时下跌3%时快速退出。总风险封顶120%，全部信号严格使用T−1数据，并统一计入1%交易费、0.05%滑点与5%年化融资成本。")
        case .riskContributionCashConfidenceRouter:
            return BacktestText.string("当前无融资夏普冠军：保留15%快速桥接和最高20.75%的恢复袖套；高波动时自动收缩至19%，并按95日动量、下行波动与趋势效率在纳指/标普间分配。恢复袖套在双指数3日同时下跌5%时退出，退出后冷却150日。领导资产切换继续使用Beta(2,2)兑现率校准；非清仓减仓且基础净值距252日高点不足4%时，按总仓位下降与总换手冲击保留最多25%的缓冲，广泛减仓时分散到本次卖出资产。全部信号严格使用T−1数据，总仓位封顶100%，现金不得为负，统一计入1%交易费与0.05%滑点。")
        case .riskContributionCashConfidenceLowNoise:
            return BacktestText.string("严格无杠杆增强策略：沿用置信度恢复底层和20.75%恢复袖套，以100%总仓硬上限运行；关闭历史上冗余的宽度微刹车与成熟纳指刹车，在低波且趋势确认时更充分使用闲置现金。领导资产保持不变且总风险变化不超过2%时，按组合波动采用20%/30%/50%的分级换手过滤；黄金领导且60日组合波动达到12%时恢复更快调仓。近峰减仓执行80%，并保留5%的A股退出哨兵。全部信号严格使用T−1数据，禁止融资和负现金，统一计入1%交易费与0.05%滑点。")
        case .recentVolatilityManagedIdleCash:
            return BacktestText.string("近期窗口探索策略（未通过正式验证、非推荐）：在低噪增强的产品化持仓上，以严格T−1的63个交易日组合波动估计为依据，只把闲置现金部署到10%目标波动，不降低原风险仓，不加杠杆；每日复核，手续费和滑点采用你的设置。")
        case .recentPairSpreadZ252Shift25:
            return BacktestText.string("近期窗口探索策略（未通过正式验证、非推荐）：在低噪增强上，以严格T−1的ONEQ/SPY和510300/510210各252日对数比率Z分数做均值回归；超过±1时在对应配对内转移总权重的25%，保持配对总仓不变；每日复核。")
        case .recentGoldEquityRelativeZ252Shift25:
            return BacktestText.string("近期窗口探索策略（未通过正式验证、非推荐）：比较黄金与当时已上市权益产品篮子的严格T−1相对价格，按252日Z分数在超过±1时转移黄金与权益合计仓位的25%；总仓不变、不融资、不做空，每日复核。")
        case .nfciDualCoreV1:
            return BacktestText.string("前瞻观察中的冻结策略 V1：50% 低噪增强+C3/L3 与 50% 无融资置信度恢复+C3/L3+1.30×风险预算在目标仓位层等权融合；NFCI Credit 采用8次发布变化≤-0.03，Leverage采用4次发布变化≤-0.03，仅使用服务器 first-seen/initial-release 点时数据。总仓位≤100%，不融资、不做空，25%偏离带统一成交。用户手续费只影响成交，不改变策略目标。")
        case .nfciDualCoreSimplifiedV11:
            return BacktestText.string("简化冻结前瞻候选：保持 DualCore 50/50 与 NFCI C3/L3 不变，高收益核心把美股/中国特例倍率折叠为统一1.22，删除A股5%退出哨兵，并把高收益核心交易带从24.4%圆整为25%。稳健核心仍为无融资置信度恢复+C3/L3+1.30×风险预算。总仓位≤100%，不融资、不做空；用户手续费只影响成交，不改变策略目标。")
        case .nfciDualCoreSimplifiedV11QualRole:
            return BacktestText.string("研究实验策略：完整保留 V11 的 NFCI 信号、目标仓位与调仓事件，仅把标普500投资角色替换为 QUAL 美国质量因子 ETF。它相对原 S&P 价格指数回测曾表现更好，但进一步使用同口径 SPY 总收益控制审计后，2万次成对区块Bootstrap仅得到 P(CAGR>SPY)=75.19%、P(Sharpe>SPY)=83.95%，未通过冻结的90%门槛，累计DSR也未达到95%。因此仅供策略研究与对比，不代表已验证优于宽基。总仓位≤100%，不融资、不做空。")
        case .strongVolControlledRotation:
            return BacktestText.string("20日强弱排序，每20个交易日持有最强资产；目标波动12%，最高投入90%")
        case .momentumRotation:
            return BacktestText.string("20日强弱排序，每20个交易日切到最强资产，需站上MA60，否则空仓；收益弹性高，但历史最大回撤显著高于其他精选策略。")
        }
    }

    nonisolated public var isRotation: Bool {
        self != .ruleBased
    }

    nonisolated public var defaultFeeRatePercent: Double {
        switch self {
        case .recentVolatilityManagedIdleCash,
             .recentPairSpreadZ252Shift25,
             .recentGoldEquityRelativeZ252Shift25:
            return 0.025
        default:
            return BacktestCoreDefaults.advancedFeeRatePercent
        }
    }

    nonisolated public var defaultSlippageRatePercent: Double {
        switch self {
        case .recentVolatilityManagedIdleCash,
             .recentPairSpreadZ252Shift25,
             .recentGoldEquityRelativeZ252Shift25:
            return 0
        default:
            return BacktestCoreDefaults.advancedSlippageRatePercent
        }
    }

    nonisolated public var requiredSignalAssetSymbols: [String] {
        switch self {
        case .recentLossVolatilityMetaMomentum,
             .coreGoldSatelliteConservativeMomentum,
             .coreGoldSatelliteBalancedMomentum,
             .coreGoldSatelliteFullMomentum,
             .coreGoldSatelliteHeatCappedMomentum,
             .coreGoldSatelliteGoldHandoffMomentum,
             .coreGoldSatelliteEquityBreadthMomentum,
             .coreGoldSatelliteOneWayVolManagedMomentum,
             .coreGoldSatelliteEquityCurveStateGateMomentum,
             .coreGoldSatelliteSharpeStateGateMomentum,
             .coreGoldSatelliteAssetRiskGateMomentum,
             .coreGoldSatelliteRiskBudgetStateGateMomentum,
             .coreGoldSatelliteConfirmedAccelerationMomentum,
             .coreGoldSatelliteProfitLockMomentum,
             .coreGoldSatelliteDynamicSleeveMomentum,
             .coreGoldSatelliteContagionRepairMomentum,
             .coreGoldSatelliteCurrencyCashMomentum,
             .coreGoldSatelliteGoldPanicLockMomentum,
             .coreGoldSatelliteRiskEfficiencyMomentum,
             .coreGoldSatelliteMonthlyHeatCappedMomentum,
             .coreGoldSatelliteConfirmedExcessMomentum,
             .coreGoldSatelliteAggressiveMomentum:
            switch self {
            case .coreGoldSatelliteContagionRepairMomentum:
                return ["gold_cny", "nasdaq", "sp500", "dowjones", "hsi", "csi300", "shanghai_composite", "shenzhen_component", "chinext"]
            case .coreGoldSatelliteCurrencyCashMomentum,
                 .coreGoldSatelliteGoldPanicLockMomentum,
                 .coreGoldSatelliteRiskEfficiencyMomentum:
                return ["gold_cny", "nasdaq", "sp500", "dowjones", "hsi", "nikkei", "csi300", "shanghai_composite", "shenzhen_component", "chinext", "oil_wti_cny", "usd_cash"]
            case .coreGoldSatelliteConfirmedAccelerationMomentum,
                 .coreGoldSatelliteDynamicSleeveMomentum:
                return ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext"]
            default:
                return ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
            }
        case .goldNasdaqPortfolioScheduler:
            return ["sp500"]
        case .goldNasdaqDualTrendBarbell:
            return ["gold_cny", "nasdaq"]
        case .convexCrashHedgeComposite:
            return ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component"]
        case .onlineStrategyAllocator,
             .riskContributionReallocation,
             .riskContributionRegimeRouter,
             .riskContributionRecoveryRouter,
             .riskContributionCashConfidenceRouter,
             .riskContributionCashConfidenceLowNoise,
             .nfciDualCoreV1,
             .nfciDualCoreSimplifiedV11:
            return ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
        case .recentVolatilityManagedIdleCash,
             .recentPairSpreadZ252Shift25,
             .recentGoldEquityRelativeZ252Shift25:
            return ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
        case .nfciDualCoreSimplifiedV11QualRole:
            return ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite", "qual"]
        default:
            return []
        }
    }

    nonisolated public var dateBoundaryAssetSymbols: Set<String>? {
        switch self {
        case .riskContributionReallocation,
             .riskContributionRegimeRouter,
             .riskContributionRecoveryRouter,
             .riskContributionCashConfidenceRouter,
             .riskContributionCashConfidenceLowNoise,
             .nfciDualCoreV1,
             .nfciDualCoreSimplifiedV11,
             .nfciDualCoreSimplifiedV11QualRole,
             .recentVolatilityManagedIdleCash,
             .recentPairSpreadZ252Shift25,
             .recentGoldEquityRelativeZ252Shift25:
            return ["gold_cny", "nasdaq"]
        case .convexCrashHedgeComposite,
             .onlineStrategyAllocator,
             .coreGoldSatelliteConfirmedAccelerationMomentum,
             .coreGoldSatelliteDynamicSleeveMomentum,
             .coreGoldSatelliteContagionRepairMomentum,
             .coreGoldSatelliteCurrencyCashMomentum,
             .coreGoldSatelliteGoldPanicLockMomentum,
             .coreGoldSatelliteRiskEfficiencyMomentum:
            return ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
        default:
            return nil
        }
    }

    nonisolated public var requiresNFCIAsOf: Bool {
        self == .nfciDualCoreV1
            || self == .nfciDualCoreSimplifiedV11
            || self == .nfciDualCoreSimplifiedV11QualRole
    }
}


public struct AdvancedBacktestTrade: Identifiable {
    public let id = UUID()
    public let assetSymbol: String
    public let assetTitle: String
    public let date: Date
    public let action: AdvancedBacktestTradeAction
    public let price: Double
    public let cashAmount: Double
    public let units: Double
    public let reason: String
    public let realizedProfit: Double?
    public let realizedReturn: Double?
    public let holdingDays: Int?
    public init(
        assetSymbol: String,
        assetTitle: String,
        date: Date,
        action: AdvancedBacktestTradeAction,
        price: Double,
        cashAmount: Double,
        units: Double,
        reason: String,
        realizedProfit: Double?,
        realizedReturn: Double?,
        holdingDays: Int?
    ) {
        self.assetSymbol = assetSymbol
        self.assetTitle = assetTitle
        self.date = date
        self.action = action
        self.price = price
        self.cashAmount = cashAmount
        self.units = units
        self.reason = reason
        self.realizedProfit = realizedProfit
        self.realizedReturn = realizedReturn
        self.holdingDays = holdingDays
    }
}


public struct AdvancedBacktestPricePoint: Identifiable {
    public let date: Date
    public let price: Double
    public let sequence: Int

    public var id: Int { sequence }
    public init(
        date: Date,
        price: Double,
        sequence: Int
    ) {
        self.date = date
        self.price = price
        self.sequence = sequence
    }
}


public struct AdvancedBacktestAssetReport: Identifiable {
    public let symbol: String
    public let title: String
    public let points: [BacktestSeriesPoint]
    public let benchmarkPoints: [BacktestSeriesPoint]
    public let pricePoints: [AdvancedBacktestPricePoint]
    public let trades: [AdvancedBacktestTrade]
    public let finalPortfolioValue: Double
    public let finalCash: Double
    public let finalUnits: Double
    public let exposureRatio: Double
    public let buyCount: Int
    public let sellCount: Int

    nonisolated public init(
        symbol: String,
        title: String,
        points: [BacktestSeriesPoint],
        benchmarkPoints: [BacktestSeriesPoint],
        pricePoints: [AdvancedBacktestPricePoint],
        trades: [AdvancedBacktestTrade],
        finalPortfolioValue: Double,
        finalCash: Double,
        finalUnits: Double,
        exposureRatio: Double
    ) {
        self.symbol = symbol
        self.title = title
        self.points = points
        self.benchmarkPoints = benchmarkPoints
        self.pricePoints = pricePoints
        self.trades = trades
        self.finalPortfolioValue = finalPortfolioValue
        self.finalCash = finalCash
        self.finalUnits = finalUnits
        self.exposureRatio = exposureRatio

        var buyCount = 0
        var sellCount = 0
        for trade in trades {
            switch trade.action {
            case .buy:
                buyCount += 1
            case .sell:
                sellCount += 1
            }
        }
        self.buyCount = buyCount
        self.sellCount = sellCount
    }

    public var id: String { symbol }
}


public struct AdvancedBacktestBenchmarkSeries: Identifiable {
    public let id: String
    public let title: String
    public let points: [BacktestSeriesPoint]
    public init(
        id: String,
        title: String,
        points: [BacktestSeriesPoint]
    ) {
        self.id = id
        self.title = title
        self.points = points
    }
}


public struct BacktestExposurePoint: Identifiable, Sendable {
    public let date: Date
    public let ratio: Double
    public let sequence: Int

    nonisolated public var id: Int { sequence }
    public init(
        date: Date,
        ratio: Double,
        sequence: Int
    ) {
        self.date = date
        self.ratio = ratio
        self.sequence = sequence
    }
}


public struct BacktestAssetExposureSeries: Identifiable, Sendable {
    public let symbol: String
    public let title: String
    public let points: [BacktestExposurePoint]

    nonisolated public var id: String { symbol }
    public init(
        symbol: String,
        title: String,
        points: [BacktestExposurePoint]
    ) {
        self.symbol = symbol
        self.title = title
        self.points = points
    }
}


public enum BacktestExposureSampling {
    public static let assetSeriesMaxCount = 280

    nonisolated public static func sampled(
        _ points: [BacktestExposurePoint],
        maxCount: Int = 360
    ) -> [BacktestExposurePoint] {
        guard points.count > maxCount, maxCount >= 4 else { return points }

        let interiorCount = points.count - 2
        let bucketCount = max((maxCount - 2) / 2, 1)
        let bucketSize = Int(ceil(Double(interiorCount) / Double(bucketCount)))
        var output: [BacktestExposurePoint] = [points[0]]
        output.reserveCapacity(maxCount)

        var lowerBound = 1
        while lowerBound < points.count - 1 {
            let upperBound = min(lowerBound + bucketSize, points.count - 1)
            let bucket = points[lowerBound..<upperBound]
            guard let minimum = bucket.min(by: { $0.ratio < $1.ratio }),
                  let maximum = bucket.max(by: { $0.ratio < $1.ratio }) else { break }
            if minimum.date <= maximum.date {
                output.append(minimum)
                if maximum.sequence != minimum.sequence { output.append(maximum) }
            } else {
                output.append(maximum)
                if maximum.sequence != minimum.sequence { output.append(minimum) }
            }
            lowerBound = upperBound
        }

        if let last = points.last, output.last?.date != last.date {
            output.append(last)
        }
        return output.enumerated().map { sequence, point in
            BacktestExposurePoint(date: point.date, ratio: point.ratio, sequence: sequence)
        }
    }
}


public struct CashYieldRatePoint: Identifiable {
    public let date: Date
    public let annualRate: Double

    public var id: Date { date }
    public init(
        date: Date,
        annualRate: Double
    ) {
        self.date = date
        self.annualRate = annualRate
    }
}


public struct CashYieldSummary {
    public let title: String
    public let source: String
    public let sourceDetail: String
    public let startDate: Date?
    public let endDate: Date?
    public let latestRateDate: Date?
    public let latestAnnualRate: Double
    public let averageAnnualRate: Double
    public let averageCashRatio: Double
    public let totalCashInterest: Double
    public let ratePoints: [CashYieldRatePoint]
    public init(
        title: String,
        source: String,
        sourceDetail: String,
        startDate: Date?,
        endDate: Date?,
        latestRateDate: Date?,
        latestAnnualRate: Double,
        averageAnnualRate: Double,
        averageCashRatio: Double,
        totalCashInterest: Double,
        ratePoints: [CashYieldRatePoint]
    ) {
        self.title = title
        self.source = source
        self.sourceDetail = sourceDetail
        self.startDate = startDate
        self.endDate = endDate
        self.latestRateDate = latestRateDate
        self.latestAnnualRate = latestAnnualRate
        self.averageAnnualRate = averageAnnualRate
        self.averageCashRatio = averageCashRatio
        self.totalCashInterest = totalCashInterest
        self.ratePoints = ratePoints
    }
}


@frozen public enum MarketRiskSignalLevel: String {
    case calm
    case watch
    case stress
    case shock

    public var title: String {
        switch self {
        case .calm:
            return BacktestText.string("平稳")
        case .watch:
            return BacktestText.string("观察")
        case .stress:
            return BacktestText.string("压力")
        case .shock:
            return BacktestText.string("冲击")
        }
    }


}


public struct MarketRiskSignalPoint: Identifiable {
    public let date: Date
    public let score: Double
    public let level: MarketRiskSignalLevel
    public let sourceTitle: String
    public let shortReturn: Double?
    public let monthlyReturn: Double?
    public let drawdownFromHigh: Double?
    public let annualizedVolatility: Double?

    public var id: Date { date }
    public init(
        date: Date,
        score: Double,
        level: MarketRiskSignalLevel,
        sourceTitle: String,
        shortReturn: Double?,
        monthlyReturn: Double?,
        drawdownFromHigh: Double?,
        annualizedVolatility: Double?
    ) {
        self.date = date
        self.score = score
        self.level = level
        self.sourceTitle = sourceTitle
        self.shortReturn = shortReturn
        self.monthlyReturn = monthlyReturn
        self.drawdownFromHigh = drawdownFromHigh
        self.annualizedVolatility = annualizedVolatility
    }
}


public struct MarketRiskSignalSummary {
    public let title: String
    public let source: String
    public let sourceDetail: String
    public let startDate: Date?
    public let endDate: Date?
    public let latestPoint: MarketRiskSignalPoint?
    public let averageScore: Double
    public let stressSessionRatio: Double
    public let signalPoints: [MarketRiskSignalPoint]
    public var statisticsPoints: [MarketRiskSignalPoint]? = nil
    public init(
        title: String,
        source: String,
        sourceDetail: String,
        startDate: Date?,
        endDate: Date?,
        latestPoint: MarketRiskSignalPoint?,
        averageScore: Double,
        stressSessionRatio: Double,
        signalPoints: [MarketRiskSignalPoint],
        statisticsPoints: [MarketRiskSignalPoint]? = nil
    ) {
        self.title = title
        self.source = source
        self.sourceDetail = sourceDetail
        self.startDate = startDate
        self.endDate = endDate
        self.latestPoint = latestPoint
        self.averageScore = averageScore
        self.stressSessionRatio = stressSessionRatio
        self.signalPoints = signalPoints
        self.statisticsPoints = statisticsPoints
    }
}


public enum CashYieldCNY {
    public static var title: String { BacktestText.string("人民币活期存款基准利率") }
    public static var source: String { BacktestText.string("中国人民银行 · 金融机构人民币存款基准利率") }
    public static var sourceDetail: String { BacktestText.string("回测中未投入资产的现金仓按历史活期存款基准利率日化计息；实际银行、货币基金或现金管理产品收益可能不同。") }
    private static let tradingDaysPerYear = 252.0
    private static let calendarDaysPerYear = 365.25
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    public static let ratePoints: [CashYieldRatePoint] = [
        .init(date: date(1990, 4, 15), annualRate: 0.0288),
        .init(date: date(1990, 8, 21), annualRate: 0.0216),
        .init(date: date(1991, 4, 21), annualRate: 0.0180),
        .init(date: date(1993, 5, 15), annualRate: 0.0216),
        .init(date: date(1993, 7, 11), annualRate: 0.0315),
        .init(date: date(1996, 5, 1), annualRate: 0.0297),
        .init(date: date(1996, 8, 23), annualRate: 0.0198),
        .init(date: date(1997, 10, 23), annualRate: 0.0171),
        .init(date: date(1998, 3, 25), annualRate: 0.0171),
        .init(date: date(1998, 7, 1), annualRate: 0.0144),
        .init(date: date(1998, 12, 7), annualRate: 0.0144),
        .init(date: date(1999, 6, 10), annualRate: 0.0099),
        .init(date: date(2002, 2, 21), annualRate: 0.0072),
        .init(date: date(2004, 10, 29), annualRate: 0.0072),
        .init(date: date(2006, 8, 19), annualRate: 0.0072),
        .init(date: date(2007, 3, 18), annualRate: 0.0072),
        .init(date: date(2007, 5, 19), annualRate: 0.0072),
        .init(date: date(2007, 7, 21), annualRate: 0.0081),
        .init(date: date(2007, 8, 22), annualRate: 0.0081),
        .init(date: date(2007, 9, 15), annualRate: 0.0081),
        .init(date: date(2007, 12, 21), annualRate: 0.0072),
        .init(date: date(2008, 10, 9), annualRate: 0.0072),
        .init(date: date(2008, 10, 30), annualRate: 0.0072),
        .init(date: date(2008, 11, 27), annualRate: 0.0036),
        .init(date: date(2008, 12, 23), annualRate: 0.0036),
        .init(date: date(2010, 10, 20), annualRate: 0.0036),
        .init(date: date(2010, 12, 26), annualRate: 0.0036),
        .init(date: date(2011, 2, 9), annualRate: 0.0040),
        .init(date: date(2011, 4, 6), annualRate: 0.0050),
        .init(date: date(2011, 7, 7), annualRate: 0.0050),
        .init(date: date(2012, 6, 8), annualRate: 0.0040),
        .init(date: date(2012, 7, 6), annualRate: 0.0035),
        .init(date: date(2015, 3, 1), annualRate: 0.0035),
        .init(date: date(2015, 5, 11), annualRate: 0.0035),
        .init(date: date(2015, 6, 28), annualRate: 0.0035),
        .init(date: date(2015, 8, 26), annualRate: 0.0035),
        .init(date: date(2015, 10, 24), annualRate: 0.0035),
    ]

    public static func annualRate(on date: Date) -> Double {
        let day = calendar.startOfDay(for: date)
        var effectiveRate = ratePoints.first?.annualRate ?? 0
        for point in ratePoints {
            if point.date <= day {
                effectiveRate = point.annualRate
            } else {
                break
            }
        }
        return effectiveRate
    }

    public static func dailyReturn(on date: Date) -> Double {
        dailyReturn(fromAnnualRate: annualRate(on: date))
    }

    public static func dailyReturn(fromAnnualRate annualRate: Double) -> Double {
        max(annualRate, 0) / tradingDaysPerYear
    }

    /// Calendar-time cash accrual between two portfolio observations.
    ///
    /// A multi-market union can contain about 260 observations per year and its
    /// gaps are not uniformly one day. Accruing `annualRate / 252` once per row
    /// therefore makes cash yield depend on the shape of the strategy calendar.
    public static func periodReturn(from startDate: Date, to endDate: Date) -> Double {
        guard endDate > startDate else { return 0 }
        var cursor = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        var factor = 1.0
        while cursor < end {
            factor *= 1 + max(annualRate(on: cursor), 0) / calendarDaysPerYear
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return max(factor - 1, 0)
    }

    public static func periodReturn(
        fromAnnualRate annualRate: Double,
        from startDate: Date,
        to endDate: Date
    ) -> Double {
        guard endDate > startDate else { return 0 }
        let dayCount = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: startDate),
            to: calendar.startOfDay(for: endDate)
        ).day ?? 0
        guard dayCount > 0 else { return 0 }
        return pow(1 + max(annualRate, 0) / calendarDaysPerYear, Double(dayCount)) - 1
    }

    public static func averageAnnualRate(across dates: [Date]) -> Double {
        guard !dates.isEmpty else { return 0 }
        return dates.reduce(0) { $0 + annualRate(on: $1) } / Double(dates.count)
    }

    public static func summary(
        startDate: Date?,
        endDate: Date?,
        totalCashInterest: Double,
        averageCashRatio: Double,
        averageAnnualRate: Double
    ) -> CashYieldSummary {
        let latestDate = endDate ?? Date()
        let latestPoint = ratePoints.last(where: { $0.date <= latestDate }) ?? ratePoints.last
        return CashYieldSummary(
            title: title,
            source: source,
            sourceDetail: sourceDetail,
            startDate: startDate,
            endDate: endDate,
            latestRateDate: latestPoint?.date,
            latestAnnualRate: latestPoint?.annualRate ?? 0,
            averageAnnualRate: averageAnnualRate,
            averageCashRatio: averageCashRatio,
            totalCashInterest: totalCashInterest,
            ratePoints: applicableRatePoints(startDate: startDate, endDate: endDate)
        )
    }

    private static func applicableRatePoints(startDate: Date?, endDate: Date?) -> [CashYieldRatePoint] {
        guard let startDate, let endDate else { return ratePoints }
        let start = calendar.startOfDay(for: min(startDate, endDate))
        let end = calendar.startOfDay(for: max(startDate, endDate))
        var points = ratePoints.filter { $0.date >= start && $0.date <= end }
        if let activeAtStart = ratePoints.last(where: { $0.date <= start }),
           !points.contains(where: { calendar.isDate($0.date, inSameDayAs: activeAtStart.date) }) {
            points.insert(activeAtStart, at: 0)
        }
        return points
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}


public enum MarketRiskSignalHistory {
    public static var title: String { BacktestText.string("美股压力信号") }
    public static var source: String { BacktestText.string("标普500/纳指历史价格 · 仅作风控信号") }
    public static var sourceDetail: String { BacktestText.string("该信号使用标普500优先、纳指备用的多年历史价格，综合短期跌幅、月度跌幅、阶段回撤和波动升温，给组合调度提供风险温度；它不是可买卖持仓，也不改变可见资产范围。") }

    public static func summary(
        dates: [Date],
        pricesBySymbol: [String: [Double]],
        preferredSymbol: String = "sp500",
        fallbackSymbol: String = "nasdaq"
    ) -> MarketRiskSignalSummary? {
        guard let sourceSymbol = pricesBySymbol[preferredSymbol] != nil ? preferredSymbol : (pricesBySymbol[fallbackSymbol] != nil ? fallbackSymbol : nil),
              let prices = pricesBySymbol[sourceSymbol],
              dates.count == prices.count,
              prices.count > 65 else { return nil }

        let sourceTitle = marketRiskSourceTitle(for: sourceSymbol)
        var points: [MarketRiskSignalPoint] = []
        points.reserveCapacity(max(prices.count - 60, 0))

        for index in prices.indices where index >= 60 {
            let shortReturn = priceReturn(prices, index: index, lookback: 5)
            let monthlyReturn = priceReturn(prices, index: index, lookback: 21)
            let drawdown = rollingDrawdown(prices, index: index, lookback: 63)
            let annualizedVolatility = rollingAnnualizedVolatility(prices, index: index, lookback: 20)
            let score = riskScore(
                shortReturn: shortReturn,
                monthlyReturn: monthlyReturn,
                drawdownFromHigh: drawdown,
                annualizedVolatility: annualizedVolatility
            )
            points.append(
                MarketRiskSignalPoint(
                    date: dates[index],
                    score: score,
                    level: level(for: score),
                    sourceTitle: sourceTitle,
                    shortReturn: shortReturn,
                    monthlyReturn: monthlyReturn,
                    drawdownFromHigh: drawdown,
                    annualizedVolatility: annualizedVolatility
                )
            )
        }

        guard !points.isEmpty else { return nil }
        let averageScore = points.reduce(0) { $0 + $1.score } / Double(points.count)
        let stressCount = points.filter { $0.level == .stress || $0.level == .shock }.count
        return MarketRiskSignalSummary(
            title: title,
            source: source,
            sourceDetail: BacktestText.format("%@。当前采用%@作为压力源。", sourceDetail, sourceTitle),
            startDate: points.first?.date,
            endDate: points.last?.date,
            latestPoint: points.last,
            averageScore: averageScore,
            stressSessionRatio: Double(stressCount) / Double(points.count),
            signalPoints: downsample(points, maxCount: 360),
            statisticsPoints: points
        )
    }

    public static func latestLevel(
        dates: [Date],
        pricesBySymbol: [String: [Double]],
        signalIndex: Int,
        preferredSymbol: String = "sp500",
        fallbackSymbol: String = "nasdaq"
    ) -> MarketRiskSignalLevel? {
        guard let sourceSymbol = pricesBySymbol[preferredSymbol] != nil ? preferredSymbol : (pricesBySymbol[fallbackSymbol] != nil ? fallbackSymbol : nil),
              let prices = pricesBySymbol[sourceSymbol],
              prices.indices.contains(signalIndex),
              signalIndex >= 60 else { return nil }
        let score = riskScore(
            shortReturn: priceReturn(prices, index: signalIndex, lookback: 5),
            monthlyReturn: priceReturn(prices, index: signalIndex, lookback: 21),
            drawdownFromHigh: rollingDrawdown(prices, index: signalIndex, lookback: 63),
            annualizedVolatility: rollingAnnualizedVolatility(prices, index: signalIndex, lookback: 20)
        )
        return level(for: score)
    }

    private static func marketRiskSourceTitle(for symbol: String) -> String {
        switch symbol {
        case "sp500": return BacktestText.string("标普500")
        case "nasdaq": return BacktestText.string("纳指")
        default: return symbol.uppercased()
        }
    }

    private static func priceReturn(_ values: [Double], index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index),
              values.indices.contains(index - lookback),
              values[index - lookback] > 0 else { return nil }
        return values[index] / values[index - lookback] - 1
    }

    private static func rollingDrawdown(_ values: [Double], index: Int, lookback: Int) -> Double? {
        guard lookback > 1, values.indices.contains(index) else { return nil }
        let start = max(0, index - lookback + 1)
        guard let high = values[start...index].max(), high > 0 else { return nil }
        return values[index] / high - 1
    }

    private static func rollingAnnualizedVolatility(_ values: [Double], index: Int, lookback: Int) -> Double? {
        guard lookback > 1,
              values.indices.contains(index),
              index - lookback + 1 > 0 else { return nil }
        let start = index - lookback + 1
        let returns = (start...index).compactMap { current -> Double? in
            guard values.indices.contains(current - 1),
                  values[current - 1] > 0,
                  values[current] > 0 else { return nil }
            return log(values[current] / values[current - 1])
        }
        guard returns.count >= lookback / 2 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count)
        return sqrt(max(variance, 0)) * sqrt(252)
    }

    private static func riskScore(
        shortReturn: Double?,
        monthlyReturn: Double?,
        drawdownFromHigh: Double?,
        annualizedVolatility: Double?
    ) -> Double {
        var score = 0.0
        if let shortReturn {
            if shortReturn < -0.065 { score += 32 }
            else if shortReturn < -0.040 { score += 20 }
            else if shortReturn < -0.020 { score += 10 }
        }
        if let monthlyReturn {
            if monthlyReturn < -0.120 { score += 34 }
            else if monthlyReturn < -0.080 { score += 24 }
            else if monthlyReturn < -0.045 { score += 13 }
        }
        if let drawdownFromHigh {
            if drawdownFromHigh < -0.180 { score += 25 }
            else if drawdownFromHigh < -0.120 { score += 17 }
            else if drawdownFromHigh < -0.070 { score += 9 }
        }
        if let annualizedVolatility {
            if annualizedVolatility > 0.38 { score += 18 }
            else if annualizedVolatility > 0.28 { score += 11 }
            else if annualizedVolatility > 0.22 { score += 6 }
        }
        return min(max(score, 0), 100)
    }

    private static func level(for score: Double) -> MarketRiskSignalLevel {
        switch score {
        case 75...:
            return .shock
        case 50..<75:
            return .stress
        case 25..<50:
            return .watch
        default:
            return .calm
        }
    }

    private static func downsample(_ points: [MarketRiskSignalPoint], maxCount: Int) -> [MarketRiskSignalPoint] {
        guard points.count > maxCount, maxCount > 0 else { return points }
        let stride = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [MarketRiskSignalPoint] = []
        sampled.reserveCapacity(maxCount)
        for index in 0..<maxCount {
            let sourceIndex = min(points.count - 1, Int((Double(index) * stride).rounded()))
            sampled.append(points[sourceIndex])
        }
        return sampled
    }
}


public struct AdvancedBacktestReport {
    public let points: [BacktestSeriesPoint]
    public let benchmarkPoints: [BacktestSeriesPoint]
    public let benchmarkSeries: [AdvancedBacktestBenchmarkSeries]
    public let trades: [AdvancedBacktestTrade]
    public let assetReports: [AdvancedBacktestAssetReport]
    public let finalPortfolioValue: Double
    public let finalCash: Double
    public let finalUnits: Double
    public let totalReturn: Double
    public let annualizedReturn: Double?
    public let maxDrawdown: Double
    public let annualizedVolatility: Double?
    public let sharpeRatio: Double?
    public let cashYieldSummary: CashYieldSummary
    public let riskSignalSummary: MarketRiskSignalSummary?
    public let exposurePoints: [BacktestExposurePoint]
    public let assetExposureSeries: [BacktestAssetExposureSeries]
    private let exactAverageExposureRatio: Double?

    nonisolated public init(
        points: [BacktestSeriesPoint],
        benchmarkPoints: [BacktestSeriesPoint],
        benchmarkSeries: [AdvancedBacktestBenchmarkSeries],
        trades: [AdvancedBacktestTrade],
        assetReports: [AdvancedBacktestAssetReport],
        finalPortfolioValue: Double,
        finalCash: Double,
        finalUnits: Double,
        totalReturn: Double,
        annualizedReturn: Double?,
        maxDrawdown: Double,
        annualizedVolatility: Double?,
        sharpeRatio: Double?,
        cashYieldSummary: CashYieldSummary,
        riskSignalSummary: MarketRiskSignalSummary?,
        exposurePoints: [BacktestExposurePoint] = [],
        assetExposureSeries: [BacktestAssetExposureSeries] = [],
        averageExposureRatio: Double? = nil
    ) {
        self.points = points
        self.benchmarkPoints = benchmarkPoints
        self.benchmarkSeries = benchmarkSeries
        self.trades = trades
        self.assetReports = assetReports
        self.finalPortfolioValue = finalPortfolioValue
        self.finalCash = finalCash
        self.finalUnits = finalUnits
        self.totalReturn = totalReturn
        self.annualizedReturn = annualizedReturn
        self.maxDrawdown = maxDrawdown
        self.annualizedVolatility = annualizedVolatility
        self.sharpeRatio = sharpeRatio
        self.cashYieldSummary = cashYieldSummary
        self.riskSignalSummary = riskSignalSummary
        self.exposurePoints = exposurePoints
        self.assetExposureSeries = assetExposureSeries
        self.exactAverageExposureRatio = averageExposureRatio
    }

    public var initialPortfolioValue: Double {
        points.first?.portfolioValue ?? 0
    }

    public var profitLoss: Double {
        finalPortfolioValue - initialPortfolioValue
    }

    public var benchmarkTotalReturn: Double? {
        guard let first = benchmarkPoints.first,
              let last = benchmarkPoints.last,
              first.portfolioValue > 0 else { return nil }
        return (last.portfolioValue / first.portfolioValue) - 1
    }

    public var excessReturn: Double? {
        benchmarkTotalReturn.map { totalReturn - $0 }
    }

    public var calmarRatio: Double? {
        guard maxDrawdown > 0 else { return nil }
        return (annualizedReturn ?? totalReturn) / maxDrawdown
    }

    public var averageExposureRatio: Double {
        if let exactAverageExposureRatio {
            return exactAverageExposureRatio
        }
        if !exposurePoints.isEmpty {
            return exposurePoints.reduce(0) { $0 + $1.ratio } / Double(exposurePoints.count)
        }
        guard !assetReports.isEmpty else { return 0 }
        return assetReports.reduce(0) { $0 + $1.exposureRatio } / Double(assetReports.count)
    }

    public var averageCashRatio: Double {
        cashYieldSummary.averageCashRatio
    }

    public var buyCount: Int {
        trades.filter { $0.action == .buy }.count
    }

    public var sellCount: Int {
        trades.filter { $0.action == .sell }.count
    }

    public var completedTradeCount: Int {
        trades.filter { $0.action == .sell && $0.realizedProfit != nil }.count
    }

    public var winningTradeCount: Int {
        trades.filter { $0.action == .sell && ($0.realizedProfit ?? 0) > 0 }.count
    }

    public var winRate: Double? {
        let completedCount = completedTradeCount
        guard completedCount > 0 else { return nil }
        return Double(winningTradeCount) / Double(completedCount)
    }
}


public struct StrategyRebalanceAllocation: Identifiable, Sendable {
    public let symbol: String
    public let title: String
    public let targetWeight: Double
    public let momentum: Double?
    public let annualizedVolatility: Double?

    public var id: String { symbol }
    public init(
        symbol: String,
        title: String,
        targetWeight: Double,
        momentum: Double?,
        annualizedVolatility: Double?
    ) {
        self.symbol = symbol
        self.title = title
        self.targetWeight = targetWeight
        self.momentum = momentum
        self.annualizedVolatility = annualizedVolatility
    }
}


public struct StrategyRebalanceAdvice: Sendable {
    public let strategyTitle: String
    public let asOfDate: Date
    public let lookbackSessions: Int
    public let rebalanceSessions: Int
    public let targetAnnualVolatility: Double?
    public let allocations: [StrategyRebalanceAllocation]
    public var signalReason: String? = nil
    public var nextReviewDate: Date? = nil

    public var totalTargetWeight: Double {
        allocations.reduce(0) { $0 + $1.targetWeight }
    }

    public var cashWeight: Double {
        max(0, 1 - totalTargetWeight)
    }

    public var isCashDefense: Bool {
        allocations.isEmpty || totalTargetWeight <= 0.0001
    }
    public init(
        strategyTitle: String,
        asOfDate: Date,
        lookbackSessions: Int,
        rebalanceSessions: Int,
        targetAnnualVolatility: Double?,
        allocations: [StrategyRebalanceAllocation],
        signalReason: String? = nil,
        nextReviewDate: Date? = nil
    ) {
        self.strategyTitle = strategyTitle
        self.asOfDate = asOfDate
        self.lookbackSessions = lookbackSessions
        self.rebalanceSessions = rebalanceSessions
        self.targetAnnualVolatility = targetAnnualVolatility
        self.allocations = allocations
        self.signalReason = signalReason
        self.nextReviewDate = nextReviewDate
    }
}


public struct AdvancedBacktestRiskSettings: Codable, Sendable {
    public var feeRate: Double
    public var slippageRate: Double
    public var maxPositionRatio: Double
    public var cooldownDays: Int
    public var stopLossRatio: Double
    public var takeProfitRatio: Double
    public init(
        feeRate: Double,
        slippageRate: Double,
        maxPositionRatio: Double,
        cooldownDays: Int,
        stopLossRatio: Double,
        takeProfitRatio: Double
    ) {
        self.feeRate = feeRate
        self.slippageRate = slippageRate
        self.maxPositionRatio = maxPositionRatio
        self.cooldownDays = cooldownDays
        self.stopLossRatio = stopLossRatio
        self.takeProfitRatio = takeProfitRatio
    }
}


public struct AdvancedBacktestStrategyTemplate: Identifiable, Sendable {
    public let id: String
    public var mode: AdvancedBacktestStrategyMode = .ruleBased
    public var selectedAssetSymbols: [String]? = nil
    public let categoryLocalizationKey: String
    public let titleLocalizationKey: String
    public let annualizedReturn: Double
    public let maxDrawdown: Double
    public let sharpeRatio: Double
    public let buyRule: AdvancedBacktestRule
    public let sellRule: AdvancedBacktestRule
    public let tradeAmountRatio: Double
    public let maxPositionRatio: Double
    public let cooldownDays: Int
    public let stopLossRatio: Double
    public let takeProfitRatio: Double

    public var category: String { BacktestText.string(categoryLocalizationKey) }
    public var title: String { BacktestText.string(titleLocalizationKey) }

    public var subtitle: String {
        if annualizedReturn == 0, maxDrawdown == 0, sharpeRatio == 0 {
            return ""
        }
        return BacktestText.format(
            "年化约%@ 最大回撤约%@ 夏普约%.2f",
            annualizedReturn.backtestPercentString(maxFractionDigits: 1),
            maxDrawdown.backtestPercentString(maxFractionDigits: 1),
            sharpeRatio
        )
    }

    public static let all: [AdvancedBacktestStrategyTemplate] = [
        .init(
            id: "core-gold-satellite-heat-capped-momentum",
            mode: .coreGoldSatelliteHeatCappedMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "高级策略",
            titleLocalizationKey: "热度上限元策略",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 85,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-gold-handoff-momentum",
            mode: .coreGoldSatelliteGoldHandoffMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "高级策略",
            titleLocalizationKey: "黄金交接保护",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 85,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-one-way-vol-managed-momentum",
            mode: .coreGoldSatelliteOneWayVolManagedMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "高级策略",
            titleLocalizationKey: "单向控波元策略",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-equity-curve-state-gate-momentum",
            mode: .coreGoldSatelliteEquityCurveStateGateMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "精选策略",
            titleLocalizationKey: "均衡配置",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-sharpe-state-gate-momentum",
            mode: .coreGoldSatelliteSharpeStateGateMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "高级策略",
            titleLocalizationKey: "高夏普状态机",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-asset-risk-gate-momentum",
            mode: .coreGoldSatelliteAssetRiskGateMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "高级策略",
            titleLocalizationKey: "收益回撤门状态机",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-risk-budget-state-gate-momentum",
            mode: .coreGoldSatelliteRiskBudgetStateGateMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "精选策略",
            titleLocalizationKey: "进取配置",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 225,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-confirmed-acceleration-momentum",
            mode: .coreGoldSatelliteConfirmedAccelerationMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext"],
            categoryLocalizationKey: "高级策略",
            titleLocalizationKey: "确认加速进攻袖套",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-profit-lock-momentum",
            mode: .coreGoldSatelliteProfitLockMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "精选策略",
            titleLocalizationKey: "防守配置",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-dynamic-sleeve-momentum",
            mode: .coreGoldSatelliteDynamicSleeveMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext"],
            categoryLocalizationKey: "高级策略",
            titleLocalizationKey: "动态袖套夏普策略",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-monthly-heat-capped-momentum",
            mode: .coreGoldSatelliteMonthlyHeatCappedMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "高级策略",
            titleLocalizationKey: "月度热度上限元",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 85,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "core-gold-satellite-confirmed-excess-momentum",
            mode: .coreGoldSatelliteConfirmedExcessMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "高级策略",
            titleLocalizationKey: "增强热度上限元",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 85,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "convex-crash-hedge-composite",
            mode: .convexCrashHedgeComposite,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component"],
            categoryLocalizationKey: "实验策略",
            titleLocalizationKey: "凸性极速空头组合",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 110,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "risk-contribution-reallocation",
            mode: .riskContributionReallocation,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "实验策略",
            titleLocalizationKey: "风险贡献再分配",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 110,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "risk-contribution-regime-router",
            mode: .riskContributionRegimeRouter,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "实验策略",
            titleLocalizationKey: "双引擎制度路由",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 120,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "risk-contribution-recovery-router",
            mode: .riskContributionRecoveryRouter,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "实验策略",
            titleLocalizationKey: "双引擎水下恢复",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 120,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "risk-contribution-cash-confidence-router",
            mode: .riskContributionCashConfidenceRouter,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "高级策略",
            titleLocalizationKey: "无融资置信度恢复",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "risk-contribution-cash-confidence-low-noise",
            mode: .riskContributionCashConfidenceLowNoise,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "精选策略",
            titleLocalizationKey: "低噪增强",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "recent-volatility-managed-idle-cash",
            mode: .recentVolatilityManagedIdleCash,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "近期研究（探索）",
            titleLocalizationKey: "近期研究·闲置现金控波部署",
            annualizedReturn: 0, maxDrawdown: 0, sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1, maxPositionRatio: 100, cooldownDays: 0,
            stopLossRatio: 0, takeProfitRatio: 0
        ),
        .init(
            id: "recent-pair-spread-z252-shift25",
            mode: .recentPairSpreadZ252Shift25,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "近期研究（探索）",
            titleLocalizationKey: "近期研究·跨市场配对回归",
            annualizedReturn: 0, maxDrawdown: 0, sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1, maxPositionRatio: 100, cooldownDays: 0,
            stopLossRatio: 0, takeProfitRatio: 0
        ),
        .init(
            id: "recent-gold-equity-relative-z252-shift25",
            mode: .recentGoldEquityRelativeZ252Shift25,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "近期研究（探索）",
            titleLocalizationKey: "近期研究·黄金权益相对回归",
            annualizedReturn: 0, maxDrawdown: 0, sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1, maxPositionRatio: 100, cooldownDays: 0,
            stopLossRatio: 0, takeProfitRatio: 0
        ),
        .init(
            id: "nfci-dual-core-v1",
            mode: .nfciDualCoreV1,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "前瞻策略",
            titleLocalizationKey: "NFCI 双核心（前瞻）",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "nfci-dual-core-v11",
            mode: .nfciDualCoreSimplifiedV11,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "精选策略",
            titleLocalizationKey: "NFCI 双核心·简化（前瞻）",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "nfci-dual-core-v11-qual-role",
            mode: .nfciDualCoreSimplifiedV11QualRole,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite", "qual"],
            categoryLocalizationKey: "实验策略",
            titleLocalizationKey: "NFCI 双核心·质量增强（研究）",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "gold-nasdaq-dual-trend-barbell",
            mode: .goldNasdaqDualTrendBarbell,
            selectedAssetSymbols: ["gold_cny", "nasdaq"],
            categoryLocalizationKey: "精选策略",
            titleLocalizationKey: "金纳双趋势",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "long-term-growth-trend",
            mode: .longTermGrowthTrend,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500"],
            categoryLocalizationKey: "独立策略",
            titleLocalizationKey: "长期趋势配置",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "canary-momentum-defense",
            mode: .canaryMomentumDefense,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite", "shenzhen_component", "chinext"],
            categoryLocalizationKey: "独立策略",
            titleLocalizationKey: "双金丝雀动量防守",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "momentum-rotation",
            mode: .momentumRotation,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            categoryLocalizationKey: "高风险策略",
            titleLocalizationKey: "高风险强势轮动",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-ma20-trend",
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "20日趋势",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceCrossesAboveMA20, days: 1),
            sellRule: .init(direction: .priceCrossesBelowMA20, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-ma60-trend",
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "60日趋势",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-ma-golden-cross",
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "均线交叉",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .ma20CrossesAboveMA60, days: 1),
            sellRule: .init(direction: .ma20CrossesBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-boll-mean-reversion",
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "布林反转",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .touchesBollLower, days: 1),
            sellRule: .init(direction: .priceCrossesAboveBollMiddle, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-buy-and-hold",
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "买入持有",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .alwaysBuy, days: 1),
            sellRule: .init(direction: .neverSell, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-ma20-hold",
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "MA20 趋势",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA20, days: 1),
            sellRule: .init(direction: .priceBelowMA20, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-boll-breakout",
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "布林突破",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .touchesBollUpper, days: 1),
            sellRule: .init(direction: .priceCrossesBelowBollMiddle, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-three-day-reversal",
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "三日反转",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .consecutiveDown, days: 3),
            sellRule: .init(direction: .consecutiveUp, days: 3),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-gold-trend",
            selectedAssetSymbols: ["gold_cny"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "黄金趋势",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-us-trend",
            selectedAssetSymbols: ["nasdaq", "sp500"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "美股趋势",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-china-trend",
            selectedAssetSymbols: ["csi300", "shanghai_composite"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "A股趋势",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-gold-nasdaq-hold",
            selectedAssetSymbols: ["gold_cny", "nasdaq"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "金纳持有",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .alwaysBuy, days: 1),
            sellRule: .init(direction: .neverSell, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        ),
        .init(
            id: "basic-three-day-trend",
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300"],
            categoryLocalizationKey: "基础策略",
            titleLocalizationKey: "三日趋势",
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .consecutiveUp, days: 3),
            sellRule: .init(direction: .consecutiveDown, days: 3),
            tradeAmountRatio: 1,
            maxPositionRatio: 100,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        )
    ]

    public static let productCatalog = BacktestProductStrategyCatalog.templates(from: all)
    public init(
        id: String,
        mode: AdvancedBacktestStrategyMode = .ruleBased,
        selectedAssetSymbols: [String]? = nil,
        categoryLocalizationKey: String,
        titleLocalizationKey: String,
        annualizedReturn: Double,
        maxDrawdown: Double,
        sharpeRatio: Double,
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        tradeAmountRatio: Double,
        maxPositionRatio: Double,
        cooldownDays: Int,
        stopLossRatio: Double,
        takeProfitRatio: Double
    ) {
        self.id = id
        self.mode = mode
        self.selectedAssetSymbols = selectedAssetSymbols
        self.categoryLocalizationKey = categoryLocalizationKey
        self.titleLocalizationKey = titleLocalizationKey
        self.annualizedReturn = annualizedReturn
        self.maxDrawdown = maxDrawdown
        self.sharpeRatio = sharpeRatio
        self.buyRule = buyRule
        self.sellRule = sellRule
        self.tradeAmountRatio = tradeAmountRatio
        self.maxPositionRatio = maxPositionRatio
        self.cooldownDays = cooldownDays
        self.stopLossRatio = stopLossRatio
        self.takeProfitRatio = takeProfitRatio
    }
}

/// The single source of truth for strategies shipped in the App. Research and diagnostic
/// templates remain available through `AdvancedBacktestStrategyTemplate.all`, while every
/// product-facing surface (library, reminders and daily advice) consumes this ordered registry.

public enum BacktestProductStrategyCatalog {
    public static let curatedTemplateIDs = [
        "gold-nasdaq-dual-trend-barbell",
        "nfci-dual-core-v11",
        "core-gold-satellite-equity-curve-state-gate-momentum",
        "core-gold-satellite-risk-budget-state-gate-momentum",
        "core-gold-satellite-profit-lock-momentum",
        "risk-contribution-cash-confidence-low-noise",
    ]

    public static let experimentalTemplateIDs: [String] = [
        "nfci-dual-core-v11-qual-role",
        "recent-volatility-managed-idle-cash",
        "recent-pair-spread-z252-shift25",
        "recent-gold-equity-relative-z252-shift25",
    ]

    public static let basicTemplateIDs = [
        "basic-buy-and-hold",
        "basic-gold-nasdaq-hold",
        "basic-gold-trend",
        "basic-us-trend",
        "basic-china-trend",
        "basic-ma60-trend",
        "basic-ma20-trend",
        "basic-ma20-hold",
        "basic-ma-golden-cross",
        "basic-boll-breakout",
        "basic-three-day-trend",
        "basic-boll-mean-reversion",
        "basic-three-day-reversal",
    ]

    public static let templateIDs = curatedTemplateIDs + experimentalTemplateIDs + basicTemplateIDs

    public static func isCuratedTemplateID(_ id: String) -> Bool {
        curatedTemplateIDs.contains(id)
    }

    public static func isExperimentalTemplateID(_ id: String) -> Bool {
        experimentalTemplateIDs.contains(id)
    }

    public static func isBasicTemplateID(_ id: String) -> Bool {
        basicTemplateIDs.contains(id)
    }

    public static func templates(
        from inventory: [AdvancedBacktestStrategyTemplate]
    ) -> [AdvancedBacktestStrategyTemplate] {
        let issues = validationIssues(in: inventory)
        assert(issues.isEmpty, issues.joined(separator: "\n"))

        let templatesByID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        return templateIDs.compactMap { templatesByID[$0] }
    }

    public static func validationIssues(
        in inventory: [AdvancedBacktestStrategyTemplate] = AdvancedBacktestStrategyTemplate.all
    ) -> [String] {
        var issues: [String] = []
        let inventoryIDs = inventory.map(\.id)
        let duplicatedInventoryIDs = duplicatedValues(inventoryIDs)
        if !duplicatedInventoryIDs.isEmpty {
            issues.append("Duplicate strategy template IDs: \(duplicatedInventoryIDs.joined(separator: ", "))")
        }

        let duplicatedProductIDs = duplicatedValues(templateIDs)
        if !duplicatedProductIDs.isEmpty {
            issues.append("Duplicate product strategy IDs: \(duplicatedProductIDs.joined(separator: ", "))")
        }

        let availableIDs = Set(inventoryIDs)
        let missingProductIDs = templateIDs.filter { !availableIDs.contains($0) }
        if !missingProductIDs.isEmpty {
            issues.append("Missing product strategy templates: \(missingProductIDs.joined(separator: ", "))")
        }
        return issues
    }

    private static func duplicatedValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for value in values where !seen.insert(value).inserted {
            duplicates.insert(value)
        }
        return duplicates.sorted()
    }
}


public struct BacktestReport {
    public let points: [BacktestSeriesPoint]
    public let totalReturn: Double
    public let annualizedReturn: Double?
    public let maxDrawdown: Double
    public let maxDrawdownRecoveryDays: Int?
    public let annualizedVolatility: Double?
    public let sharpeRatio: Double?
    public init(
        points: [BacktestSeriesPoint],
        totalReturn: Double,
        annualizedReturn: Double?,
        maxDrawdown: Double,
        maxDrawdownRecoveryDays: Int?,
        annualizedVolatility: Double?,
        sharpeRatio: Double?
    ) {
        self.points = points
        self.totalReturn = totalReturn
        self.annualizedReturn = annualizedReturn
        self.maxDrawdown = maxDrawdown
        self.maxDrawdownRecoveryDays = maxDrawdownRecoveryDays
        self.annualizedVolatility = annualizedVolatility
        self.sharpeRatio = sharpeRatio
    }
}


public struct DCABacktestReport {
    public let points: [BacktestSeriesPoint]
    public let totalInvested: Double
    public let finalPortfolioValue: Double
    public let profitLoss: Double
    public let totalReturn: Double
    public let annualizedReturn: Double?
    public let maxDrawdown: Double
    public let annualizedVolatility: Double?
    public let sharpeRatio: Double?
    public let contributionCount: Int
    public let totalUnits: Double
    public init(
        points: [BacktestSeriesPoint],
        totalInvested: Double,
        finalPortfolioValue: Double,
        profitLoss: Double,
        totalReturn: Double,
        annualizedReturn: Double?,
        maxDrawdown: Double,
        annualizedVolatility: Double?,
        sharpeRatio: Double?,
        contributionCount: Int,
        totalUnits: Double
    ) {
        self.points = points
        self.totalInvested = totalInvested
        self.finalPortfolioValue = finalPortfolioValue
        self.profitLoss = profitLoss
        self.totalReturn = totalReturn
        self.annualizedReturn = annualizedReturn
        self.maxDrawdown = maxDrawdown
        self.annualizedVolatility = annualizedVolatility
        self.sharpeRatio = sharpeRatio
        self.contributionCount = contributionCount
        self.totalUnits = totalUnits
    }
}


nonisolated public enum BacktestAssetSymbol {
    public static func normalized(_ symbol: String) -> String {
        switch symbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gold":
            return "gold_cny"
        case "nasdaq_composite", "nasdaq":
            return "nasdaq"
        case "hang_seng", "hsi":
            return "hsi"
        case "nikkei225", "nikkei":
            return "nikkei"
        case "oil_wti", "oil_wti_cny", "wti":
            return "oil_wti_cny"
        case "dow_jones", "dowjones":
            return "dowjones"
        case "cn_10y", "china_10y", "china_10y_yield", "cgb_10y", "cn_10y_yield":
            return "cn_10y_yield"
        case "us10y", "us_10y", "treasury_10y", "us_treasury_10y", "us_10y_yield":
            return "us_10y_yield"
        case "us2y", "us_2y", "us_2y_yield":
            return "us_2y_yield"
        case "us3m", "us_3m", "us_3m_yield":
            return "us_3m_yield"
        case let normalized:
            return normalized
        }
    }
}


public struct BacktestPerformanceMetrics {
    public let totalReturn: Double
    public let annualizedReturn: Double?
    public let maxDrawdown: Double
    public let annualizedVolatility: Double?
    public let sharpeRatio: Double?
    public init(
        totalReturn: Double,
        annualizedReturn: Double?,
        maxDrawdown: Double,
        annualizedVolatility: Double?,
        sharpeRatio: Double?
    ) {
        self.totalReturn = totalReturn
        self.annualizedReturn = annualizedReturn
        self.maxDrawdown = maxDrawdown
        self.annualizedVolatility = annualizedVolatility
        self.sharpeRatio = sharpeRatio
    }
}


public struct BacktestInstrument: Identifiable, Sendable {
    public let symbol: String
    public let title: String
    public let requiresHistoricalFX: Bool
    public let historicalFXSymbol: String?
    public let category: String
    public let iconName: String
    public let currency: String
    public let unit: String
    public let logoURL: String?
    public let logoSource: String?

    public var id: String { symbol }

    public init(
        symbol: String,
        title: String,
        requiresHistoricalFX: Bool,
        historicalFXSymbol: String?,
        category: String = "other",
        iconName: String = "chart.line.uptrend.xyaxis",
        currency: String = "CNY",
        unit: String = "",
        logoURL: String? = nil,
        logoSource: String? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.requiresHistoricalFX = requiresHistoricalFX
        self.historicalFXSymbol = historicalFXSymbol
        self.category = category
        self.iconName = iconName
        self.currency = currency
        self.unit = unit
        self.logoURL = logoURL
        self.logoSource = logoSource
    }

}


public struct BacktestCoreCandidate: Identifiable {
    public let id = UUID()
    public let buyRule: AdvancedBacktestRule
    public let sellRule: AdvancedBacktestRule
    public let tradeAmount: Double
    public let settings: AdvancedBacktestRiskSettings
    public let report: AdvancedBacktestReport
    public let score: Double

    public var title: String {
        "\(buyRule.direction.shortTitle) / \(sellRule.direction.shortTitle)"
    }
    public init(
        buyRule: AdvancedBacktestRule,
        sellRule: AdvancedBacktestRule,
        tradeAmount: Double,
        settings: AdvancedBacktestRiskSettings,
        report: AdvancedBacktestReport,
        score: Double
    ) {
        self.buyRule = buyRule
        self.sellRule = sellRule
        self.tradeAmount = tradeAmount
        self.settings = settings
        self.report = report
        self.score = score
    }
}


public enum BacktestCoreDefaults {
    /// Current product execution fee, expressed as a percentage: 2.5 bps = 0.025% per side.
    nonisolated public static let advancedFeeRatePercent: Double = 0.025
    nonisolated public static let advancedSlippageRatePercent: Double = 0.05
    public static let cashWeight: Double = 50
    public static let goldWeight: Double = 25
    public static let dcaAssetSymbol = "gold_cny"
    public static let dcaContributionAmount: Double = 1000
    public static let dcaIntervalDays = 30
    public static var indexOptions: [BacktestInstrument] { [
        .init(symbol: "sp500", title: BacktestText.string("标普500"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "nasdaq", title: BacktestText.string("纳指"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "dowjones", title: BacktestText.string("道指"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "hsi", title: BacktestText.string("恒生"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "csi300", title: BacktestText.string("沪深300"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "shanghai_composite", title: BacktestText.string("上证综指"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "shenzhen_component", title: BacktestText.string("深成指"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "chinext", title: BacktestText.string("创业板"), requiresHistoricalFX: false, historicalFXSymbol: nil),
    ] }
    public static let indexWeights: [String: Double] = {
        Dictionary(uniqueKeysWithValues: indexOptions.map { option in
            (option.symbol, option.symbol == "nasdaq" ? 25 : 0)
        })
    }()
    public static var dcaAssetOptions: [BacktestInstrument] { [
        .init(symbol: "gold_cny", title: BacktestText.string("黄金"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "sp500", title: BacktestText.string("标普500"), requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "nasdaq", title: BacktestText.string("纳指"), requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "dowjones", title: BacktestText.string("道指"), requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "hsi", title: BacktestText.string("恒生"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "csi300", title: BacktestText.string("沪深300"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "shanghai_composite", title: BacktestText.string("上证综指"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "shenzhen_component", title: BacktestText.string("深成指"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "chinext", title: BacktestText.string("创业板"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "nikkei", title: BacktestText.string("日经225"), requiresHistoricalFX: false, historicalFXSymbol: nil),
    ] }
    public static var internalStrategyAssetOptions: [BacktestInstrument] { [
        .init(symbol: "usd_cash", title: BacktestText.string("美元现金"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "oil_wti_cny", title: BacktestText.string("WTI原油"), requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "qual", title: BacktestText.string("QUAL美国质量因子"), requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny", category: "etf", iconName: "chart.line.uptrend.xyaxis", currency: "USD", unit: "share"),
        .init(symbol: "money511990_cny", title: BacktestText.string("511990货币基金"), requiresHistoricalFX: false, historicalFXSymbol: nil, category: "etf", iconName: "banknote", currency: "CNY", unit: "share"),
        .init(symbol: "spy_tr", title: BacktestText.string("SPY标普500ETF"), requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny", category: "etf", iconName: "chart.line.uptrend.xyaxis", currency: "USD", unit: "share"),
        .init(symbol: "oneq_tr", title: BacktestText.string("ONEQ纳斯达克ETF"), requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny", category: "etf", iconName: "chart.line.uptrend.xyaxis", currency: "USD", unit: "share"),
        .init(symbol: "etf510210_cny", title: BacktestText.string("510210上证综指ETF"), requiresHistoricalFX: false, historicalFXSymbol: nil, category: "etf", iconName: "chart.line.uptrend.xyaxis", currency: "CNY", unit: "share"),
        .init(symbol: "etf510300_cny", title: BacktestText.string("510300沪深300ETF"), requiresHistoricalFX: false, historicalFXSymbol: nil, category: "etf", iconName: "chart.line.uptrend.xyaxis", currency: "CNY", unit: "share"),
    ] }
    public static var strategyAssetOptions: [BacktestInstrument] { dcaAssetOptions + internalStrategyAssetOptions }


}


public enum BacktestCoreStrategyDefaults {
    public static let defaultTemplateID = "core-gold-satellite-equity-curve-state-gate-momentum"
    public static let recommendedTemplateID = "gold-nasdaq-dual-trend-barbell"

    public static var eligibleTemplates: [AdvancedBacktestStrategyTemplate] {
        AdvancedBacktestStrategyTemplate.productCatalog
    }

    public static func migratedTemplateID(_ id: String) -> String {
        switch id {
        case "risk-contribution-cash-confidence-router":
            return recommendedTemplateID
        case "online-strategy-allocator",
             "consensus-scale-defense",
             "convex-crash-hedge-composite",
             "risk-contribution-reallocation",
             "risk-contribution-regime-router",
             "risk-contribution-recovery-router":
            return defaultTemplateID
        default:
            return id
        }
    }

    public static func template(for id: String) -> AdvancedBacktestStrategyTemplate? {
        let migratedID = migratedTemplateID(id)
        return eligibleTemplates.first { $0.id == migratedID }
            ?? eligibleTemplates.first { $0.id == defaultTemplateID }
            ?? eligibleTemplates.first
    }

    public static func pickerTitle(for template: AdvancedBacktestStrategyTemplate) -> String {
        guard BacktestProductStrategyCatalog.isCuratedTemplateID(template.id) else {
            return template.title
        }
        var badges = [BacktestText.string("精选")]
        if template.id == recommendedTemplateID {
            badges.append(BacktestText.string("推荐"))
        }
        return "\(template.title) · \(badges.joined(separator: " · "))"
    }

    public static func assetOptions(for template: AdvancedBacktestStrategyTemplate) -> [BacktestInstrument] {
        var selectedSymbols = Set(template.selectedAssetSymbols ?? BacktestCoreDefaults.dcaAssetOptions.map(\.symbol))
        selectedSymbols.formUnion(template.mode.requiredSignalAssetSymbols)
        let options = BacktestCoreDefaults.strategyAssetOptions.filter { selectedSymbols.contains($0.symbol) }
        return options.isEmpty ? BacktestCoreDefaults.dcaAssetOptions : options
    }

    public static func historySymbols(for template: AdvancedBacktestStrategyTemplate) -> Set<String> {
        historySymbols(for: assetOptions(for: template))
    }

    public static func historySymbols(for assetOptions: [BacktestInstrument]) -> Set<String> {
        Set(assetOptions.flatMap { option -> [String] in
            var symbols = [option.symbol]
            if let fxSymbol = option.historicalFXSymbol {
                symbols.append(fxSymbol)
            }
            if option.symbol == "usd_cash" {
                symbols.append("usd_per_cny")
            }
            return symbols
        })
    }
}
