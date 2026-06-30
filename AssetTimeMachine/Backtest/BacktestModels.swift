import Foundation
import SwiftUI

enum BacktestMode: String, CaseIterable, Identifiable {
    case allocation
    case dca

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allocation:
            return AppLocalization.string("配置回测")
        case .dca:
            return AppLocalization.string("定投回测")
        }
    }
}

enum BacktestPage: String, CaseIterable, Identifiable {
    case home
    case standard
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return AppLocalization.string("量化")
        case .standard:
            return AppLocalization.string("基础回测")
        case .advanced:
            return AppLocalization.string("策略回测")
        }
    }
}

enum BacktestTopTab: String, CaseIterable, Identifiable {
    case allocation
    case dca
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allocation:
            return AppLocalization.string("配置")
        case .dca:
            return AppLocalization.string("定投")
        case .advanced:
            return AppLocalization.string("高级")
        }
    }
}

enum AdvancedBacktestSignalDirection: String, CaseIterable, Identifiable {
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysBuy:
            return AppLocalization.string("持续买入")
        case .neverSell:
            return AppLocalization.string("不主动卖出")
        case .consecutiveDown:
            return AppLocalization.string("连续下跌")
        case .consecutiveUp:
            return AppLocalization.string("连续上涨")
        case .priceAboveMA20:
            return AppLocalization.string("价格高于 MA20")
        case .priceBelowMA20:
            return AppLocalization.string("价格低于 MA20")
        case .priceAboveMA60:
            return AppLocalization.string("价格高于 MA60")
        case .priceBelowMA60:
            return AppLocalization.string("价格低于 MA60")
        case .priceCrossesAboveMA20:
            return AppLocalization.string("价格上穿 MA20")
        case .priceCrossesBelowMA20:
            return AppLocalization.string("价格下穿 MA20")
        case .ma20CrossesAboveMA60:
            return AppLocalization.string("MA20 上穿 MA60")
        case .ma20CrossesBelowMA60:
            return AppLocalization.string("MA20 下穿 MA60")
        case .priceCrossesAboveBollMiddle:
            return AppLocalization.string("价格上穿 BOLL 中轨")
        case .priceCrossesBelowBollMiddle:
            return AppLocalization.string("价格下穿 BOLL 中轨")
        case .touchesBollLower:
            return AppLocalization.string("跌破/触及 BOLL 下轨")
        case .touchesBollUpper:
            return AppLocalization.string("突破/触及 BOLL 上轨")
        }
    }

    var shortTitle: String {
        switch self {
        case .alwaysBuy:
            return AppLocalization.string("持续买")
        case .neverSell:
            return AppLocalization.string("持有")
        case .consecutiveDown:
            return AppLocalization.string("跌")
        case .consecutiveUp:
            return AppLocalization.string("涨")
        case .priceAboveMA20:
            return AppLocalization.string("高于MA20")
        case .priceBelowMA20:
            return AppLocalization.string("低于MA20")
        case .priceAboveMA60:
            return AppLocalization.string("高于MA60")
        case .priceBelowMA60:
            return AppLocalization.string("低于MA60")
        case .priceCrossesAboveMA20:
            return AppLocalization.string("价上穿MA20")
        case .priceCrossesBelowMA20:
            return AppLocalization.string("价下穿MA20")
        case .ma20CrossesAboveMA60:
            return AppLocalization.string("MA金叉")
        case .ma20CrossesBelowMA60:
            return AppLocalization.string("MA死叉")
        case .priceCrossesAboveBollMiddle:
            return AppLocalization.string("上穿BOLL中轨")
        case .priceCrossesBelowBollMiddle:
            return AppLocalization.string("下穿BOLL中轨")
        case .touchesBollLower:
            return AppLocalization.string("BOLL下轨")
        case .touchesBollUpper:
            return AppLocalization.string("BOLL上轨")
        }
    }

    nonisolated var usesDayThreshold: Bool {
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

    nonisolated var isBuySignalOption: Bool {
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

    nonisolated var isSellSignalOption: Bool {
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

enum AdvancedBacktestTradeAction: String {
    case buy
    case sell

    var title: String {
        switch self {
        case .buy:
            return AppLocalization.string("买入")
        case .sell:
            return AppLocalization.string("卖出")
        }
    }

    var accent: Color {
        switch self {
        case .buy:
            return AssetTheme.accentRed
        case .sell:
            return AssetTheme.accentBlue
        }
    }
}

struct AdvancedBacktestRule {
    var direction: AdvancedBacktestSignalDirection
    var days: Int
}

enum AdvancedBacktestStrategyMode: String, Codable {
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
    case strongVolControlledRotation
    case momentumRotation

    var title: String {
        switch self {
        case .ruleBased:
            return AppLocalization.string("自定义策略")
        case .ultraDefensiveRotation:
            return AppLocalization.string("极稳轮动")
        case .defensiveRotation:
            return AppLocalization.string("稳健轮动")
        case .lowDrawdownRotation:
            return AppLocalization.string("低回撤轮动")
        case .balancedRotation:
            return AppLocalization.string("均衡轮动")
        case .enhancedRotation:
            return AppLocalization.string("增强轮动")
        case .longTermDefensiveTrend:
            return AppLocalization.string("长期低回撤趋势")
        case .longTermEnhancedLowDrawdownTrend:
            return AppLocalization.string("长期增强低回撤趋势")
        case .steadyDrawdownLadderTrend:
            return AppLocalization.string("稳健回撤阶梯趋势")
        case .septemberGuardLadderTrend:
            return AppLocalization.string("九月风险闸门趋势")
        case .longTermGrowthTrend:
            return AppLocalization.string("长期进取趋势")
        case .longTermLowVolMomentum:
            return AppLocalization.string("长期低波动动量")
        case .robustLowVolMomentum:
            return AppLocalization.string("稳健低波动动量")
        case .overheatGuardMomentum:
            return AppLocalization.string("A股过热不追高动量")
        case .highZoneDecelerationMomentum:
            return AppLocalization.string("高位短弱双守门动量")
        case .pairConfirmDoubleGuardMomentum:
            return AppLocalization.string("配对确认双守门动量")
        case .tailBreakdownLockMomentum:
            return AppLocalization.string("持有中破位锁盈防守")
        case .recentLossVolatilityMetaMomentum:
            return AppLocalization.string("近期亏损波动元策略")
        case .coreGoldSatelliteConservativeMomentum:
            return AppLocalization.string("核心动量+黄金卫星（保守）")
        case .coreGoldSatelliteBalancedMomentum:
            return AppLocalization.string("核心动量+黄金卫星（平衡）")
        case .coreGoldSatelliteFullMomentum:
            return AppLocalization.string("核心动量+黄金卫星（满核心）")
        case .coreGoldSatelliteHeatCappedMomentum:
            return AppLocalization.string("热度上限元策略")
        case .coreGoldSatelliteGoldHandoffMomentum:
            return AppLocalization.string("黄金交接保护")
        case .coreGoldSatelliteEquityBreadthMomentum:
            return AppLocalization.string("权益宽度进攻引擎")
        case .coreGoldSatelliteOneWayVolManagedMomentum:
            return AppLocalization.string("单向控波元策略")
        case .coreGoldSatelliteEquityCurveStateGateMomentum:
            return AppLocalization.string("权益曲线状态机")
        case .coreGoldSatelliteSharpeStateGateMomentum:
            return AppLocalization.string("高夏普状态机")
        case .coreGoldSatelliteRiskBudgetStateGateMomentum:
            return AppLocalization.string("风险预算状态机")
        case .coreGoldSatelliteConfirmedAccelerationMomentum:
            return AppLocalization.string("确认加速进攻袖套")
        case .coreGoldSatelliteProfitLockMomentum:
            return AppLocalization.string("锁盈防守袖套")
        case .coreGoldSatelliteDynamicSleeveMomentum:
            return AppLocalization.string("动态袖套夏普策略")
        case .coreGoldSatelliteContagionRepairMomentum:
            return AppLocalization.string("全球修复传染控制")
        case .coreGoldSatelliteCurrencyCashMomentum:
            return AppLocalization.string("美元现金修复策略")
        case .coreGoldSatelliteGoldPanicLockMomentum:
            return AppLocalization.string("黄金恐慌锁盈策略")
        case .coreGoldSatelliteRiskEfficiencyMomentum:
            return AppLocalization.string("风险效率增强策略")
        case .coreGoldSatelliteMonthlyHeatCappedMomentum:
            return AppLocalization.string("月度热度上限元")
        case .coreGoldSatelliteConfirmedExcessMomentum:
            return AppLocalization.string("增强热度上限元")
        case .coreGoldSatelliteAggressiveMomentum:
            return AppLocalization.string("核心动量+黄金卫星（进攻）")
        case .canaryMomentumDefense:
            return AppLocalization.string("双金丝雀动量防守")
        case .drawdownReentryMomentum:
            return AppLocalization.string("回撤再入场动量")
        case .goldCoreTrendSatellite:
            return AppLocalization.string("核心黄金趋势卫星")
        case .goldNasdaqSteadyRotation:
            return AppLocalization.string("金纳低回撤轮动")
        case .goldNasdaqPortfolioScheduler:
            return AppLocalization.string("金纳组合调度")
        case .strongVolControlledRotation:
            return AppLocalization.string("强势控波轮动")
        case .momentumRotation:
            return AppLocalization.string("强势轮动")
        }
    }

    var detail: String {
        switch self {
        case .ruleBased:
            return AppLocalization.string("按买入/卖出条件独立回测每个资产")
        case .ultraDefensiveRotation:
            return AppLocalization.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动6%，最高投入35%")
        case .defensiveRotation:
            return AppLocalization.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动8%，最高投入55%")
        case .lowDrawdownRotation:
            return AppLocalization.string("40日强弱排序，每20个交易日在合格资产里分散持有，按动量/波动加权，目标波动10%，最多投入65%")
        case .balancedRotation:
            return AppLocalization.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动12%，最高投入75%")
        case .enhancedRotation:
            return AppLocalization.string("40日强弱排序，每20个交易日调仓，最多持有3个合格资产；目标波动12%，最高投入90%")
        case .longTermDefensiveTrend:
            return AppLocalization.string("2001年以来优选：黄金65%、标普15.7%、纳指19.3%，需站上MA200且120日动量为正；每20个交易日再平衡，目标波动8.5%")
        case .longTermEnhancedLowDrawdownTrend:
            return AppLocalization.string("长期增强候选：黄金73%、标普1%、纳指26%，需站上MA220且120日动量为正；目标波动9.5%，纳指波动过热时自动降权益仓。")
        case .steadyDrawdownLadderTrend:
            return AppLocalization.string("更重视持有体验：黄金73%、标普1%、纳指26%，需站上MA220且120日动量为正；权益从180日高点回撤超过6%/12%时分级降仓，优先转向黄金或现金。")
        case .septemberGuardLadderTrend:
            return AppLocalization.string("在稳健回撤阶梯趋势上叠加九月风险闸门：9月仅保留25%权益仓，砍掉的权益优先转向趋势有效的黄金；目标是降低近期独立区间最大回撤。")
        case .longTermGrowthTrend:
            return AppLocalization.string("2001年以来进取候选：黄金50%、标普15%、纳指35%，需站上MA220且120日动量为正；每20个交易日再平衡，目标波动11%")
        case .longTermLowVolMomentum:
            return AppLocalization.string("非均线长期候选：黄金、纳指、标普、沪深300、上证综指中筛选240日动量为正且波动较低的资产；每60个交易日再平衡，目标波动10.5%")
        case .robustLowVolMomentum:
            return AppLocalization.string("新搜索候选：黄金、标普、纳指中筛选180日动量为正且30日年化波动低于18%的资产；按低波动分散，每40个交易日再平衡，目标波动7.5%，最高仓位55%")
        case .overheatGuardMomentum:
            return AppLocalization.string("收益优先候选：黄金、纳指、标普、沪深300、上证综指中只拿最强资产；当A股泡沫式加速时不追满仓，主仓降到保护仓位并优先让黄金承接。")
        case .highZoneDecelerationMomentum:
            return AppLocalization.string("突破候选：沿用最强资产动量框架，但新增双守门；高位动量钝化时先锁盈，若风险资产20日转弱且相对黄金明显落后，则把风险预算降到现金防守。")
        case .pairConfirmDoubleGuardMomentum:
            return AppLocalization.string("稳健增强候选：保留高位短弱双守门主体，但美股/A股持仓需要同组兄弟指数确认；若兄弟指数已明显走弱，先把总仓位压到60%，优先转向黄金或现金。")
        case .tailBreakdownLockMomentum:
            return AppLocalization.string("防守发动机：保留双守门动量主体，并在持有期间检查高位破位、短动量转弱和相对黄金落后；多项风险同时出现时先锁盈降仓。")
        case .recentLossVolatilityMetaMomentum:
            return AppLocalization.string("综合冠军候选：平时跟随高位短弱双守门动量；当该策略自身近期亏损和波动同时放大时，短期转入持有中破位锁盈防守发动机，恢复后再进攻。")
        case .coreGoldSatelliteConservativeMomentum:
            return AppLocalization.string("稳健增强候选：以近期亏损波动元策略为核心，只使用95%核心仓位；当黄金90日动量为正、站上120日均线且60日跑赢标普时，挂10%黄金卫星；2月权益走弱时压低权益仓位。")
        case .coreGoldSatelliteBalancedMomentum:
            return AppLocalization.string("推荐候选：以近期亏损波动元策略为核心，核心仓位提升到97.5%；黄金趋势和相对强度同时有效时挂10%黄金卫星，兼顾收益和9%左右回撤控制。")
        case .coreGoldSatelliteFullMomentum:
            return AppLocalization.string("新冠军候选：近期亏损波动元策略保持满核心，黄金趋势和相对强度有效时挂10%黄金卫星；总仓位封顶85%，并用二月弱权益刹车和净值轻刹车控制回撤。")
        case .coreGoldSatelliteHeatCappedMomentum:
            return AppLocalization.string("上架候选：以近期亏损波动元策略为核心，黄金趋势和相对强度有效时挂10%黄金卫星；组合总仓位封顶85%，单个权益指数最多64%，并保留二月弱势刹车和净值轻刹车。")
        case .coreGoldSatelliteGoldHandoffMomentum:
            return AppLocalization.string("新逻辑候选：沿用热度上限元框架；当黄金短线转弱时先把黄金单仓压到45%，若美股趋势仍确认，则把释放的风险预算交接给更强的纳指或标普，否则留现金。")
        case .coreGoldSatelliteEquityBreadthMomentum:
            return AppLocalization.string("内部进攻引擎：在黄金交接保护基础上，把空余风险预算分配给趋势确认的权益指数，用于元策略对照，不单独推荐。")
        case .coreGoldSatelliteOneWayVolManagedMomentum:
            return AppLocalization.string("新夏普冠军：以黄金交接保护为防守引擎、权益宽度为进攻引擎；当进攻引擎领先但自身波动高于防守引擎时，只降仓不加仓，剩余留现金。")
        case .coreGoldSatelliteEquityCurveStateGateMomentum:
            return AppLocalization.string("App-only状态机候选：以单向控波双引擎为基础；当策略自身近90日收益转弱或回撤扩大时，把风险预算降到70%，恢复后再打开。")
        case .coreGoldSatelliteSharpeStateGateMomentum:
            return AppLocalization.string("高夏普候选：以双引擎路由和黄金分散信用为基础；当策略自身75日收益转弱或回撤扩大时，把风险预算降到45%，只有75日收益重新转强后再打开。")
        case .coreGoldSatelliteRiskBudgetStateGateMomentum:
            return AppLocalization.string("进取候选：以高夏普状态机为底层信号，每日按融资成本计提风险预算，目标是用明确融资假设冲击15%以上年化；属于高级风险预算策略。")
        case .coreGoldSatelliteConfirmedAccelerationMomentum:
            return AppLocalization.string("内部进攻袖套：在单向控波基础上，只用空余预算承接确认加速且波动收缩的道指、深成指或创业板。")
        case .coreGoldSatelliteProfitLockMomentum:
            return AppLocalization.string("内部防守袖套：在单向控波基础上，根据组合自身回撤和快速上涨后的锁盈状态平滑降低风险预算。")
        case .coreGoldSatelliteDynamicSleeveMomentum:
            return AppLocalization.string("高夏普候选：在确认加速进攻袖套和锁盈防守袖套之间做315日相对收益迟滞切换；高档95%、低档25%，全程无融资。")
        case .coreGoldSatelliteContagionRepairMomentum:
            return AppLocalization.string("新高收益线：以动态袖套为核心，空闲预算只在回撤修复确认时承接恒生/日经等全球修复机会；A/H股泡沫回落和全球宽度转弱时临时压低权益仓。")
        case .coreGoldSatelliteCurrencyCashMomentum:
            return AppLocalization.string("在全球修复传染控制基础上，空闲预算不只留人民币现金；当美元现金趋势优于现金门槛时，使用美元现金承接闲置仓位，全程不融资。")
        case .coreGoldSatelliteGoldPanicLockMomentum:
            return AppLocalization.string("在美元现金修复策略上加入黄金恐慌溢价锁：黄金短期暴冲后转弱时临时降低黄金仓，释放预算交给现金选择器，降低2003式黄金回吐。")
        case .coreGoldSatelliteRiskEfficiencyMomentum:
            return AppLocalization.string("当前高夏普候选：叠加传染控制、美元现金、黄金恐慌锁盈，并在目标组合波动偏高且动量质量不足时稀疏降风险。")
        case .coreGoldSatelliteMonthlyHeatCappedMomentum:
            return AppLocalization.string("月度候选：沿用热度上限元策略框架，但约每30个交易日检查一次；单权益上限提高到72%，保留黄金卫星、二月弱势刹车和净值轻刹车，追求更平滑的全周期回撤。")
        case .coreGoldSatelliteConfirmedExcessMomentum:
            return AppLocalization.string("增强候选：沿用热度上限元框架，单权益超出上限的风险预算不直接闲置；优先转给趋势和相对强度有效的黄金，否则转给动量为正、站上MA120且波动较低的确认资产。")
        case .coreGoldSatelliteAggressiveMomentum:
            return AppLocalization.string("进取候选：核心仍为近期亏损波动元策略，核心仓位97.5%，黄金卫星提高到15%；历史收益更高，但最大回撤更接近10%。")
        case .canaryMomentumDefense:
            return AppLocalization.string("2002年以来候选：纳指+标普做金丝雀，20/60/120/240日动量判断风险环境；进攻选强势权益前2并保留黄金底仓，转弱时只留黄金或现金防守。")
        case .drawdownReentryMomentum:
            return AppLocalization.string("收益优先候选：黄金作防守底仓，纳指/标普/A股指数只在90日回撤可控且动量或RSI重新转强时入场；每40个交易日再平衡，目标波动7.5%，最高仓位65%。")
        case .goldCoreTrendSatellite:
            return AppLocalization.string("黄金作为防守核心，纳指/标普只做趋势卫星；黄金看MA120，权益看MA250，每20个交易日再平衡，目标波动9.5%。")
        case .goldNasdaqSteadyRotation:
            return AppLocalization.string("黄金/纳指双资产择强：近20日涨幅需超过2%，且站上MA250；每40个交易日切到更强资产，目标波动8%，最高投入90%")
        case .goldNasdaqPortfolioScheduler:
            return AppLocalization.string("资产只在纳指、黄金、现金之间调度；参考多年美股压力信号控制风险。纳指/黄金按趋势和强弱给目标仓位，压力升温时自动降低纳指、提高黄金或现金。")
        case .strongVolControlledRotation:
            return AppLocalization.string("20日强弱排序，每20个交易日持有最强资产；目标波动12%，最高投入90%")
        case .momentumRotation:
            return AppLocalization.string("20日强弱排序，每20个交易日切到最强资产，需站上MA60，否则空仓")
        }
    }

    var ruleSummary: String {
        switch self {
        case .ruleBased:
            return AppLocalization.string("买卖条件")
        case .ultraDefensiveRotation:
            return AppLocalization.string("40日强弱 · 目标波动6% · 最高仓位35%")
        case .defensiveRotation:
            return AppLocalization.string("40日强弱 · 目标波动8% · 最高仓位55%")
        case .lowDrawdownRotation:
            return AppLocalization.string("40日强弱 · 目标波动10% · 最高仓位65%")
        case .balancedRotation:
            return AppLocalization.string("40日强弱 · 目标波动12% · 最高仓位75%")
        case .enhancedRotation:
            return AppLocalization.string("40日强弱 · 目标波动12% · 最高仓位90%")
        case .longTermDefensiveTrend:
            return AppLocalization.string("黄金65% · MA200 · 目标波动8.5%")
        case .longTermEnhancedLowDrawdownTrend:
            return AppLocalization.string("黄金73% · MA220 · 目标波动9.5% · 波动刹车")
        case .steadyDrawdownLadderTrend:
            return AppLocalization.string("黄金73% · MA220 · 目标波动8.5% · 回撤阶梯")
        case .septemberGuardLadderTrend:
            return AppLocalization.string("回撤阶梯 · 9月权益25% · 黄金承接")
        case .longTermGrowthTrend:
            return AppLocalization.string("黄金50% · MA220 · 目标波动11%")
        case .longTermLowVolMomentum:
            return AppLocalization.string("240日动量 · 波动<18% · 目标波动10.5%")
        case .robustLowVolMomentum:
            return AppLocalization.string("180日动量 · 波动<18% · 目标波动7.5%")
        case .overheatGuardMomentum:
            return AppLocalization.string("Top1动量 · A股过热降仓 · 目标波动11%")
        case .highZoneDecelerationMomentum:
            return AppLocalization.string("高位钝化 · 短弱接管 · 目标波动11%")
        case .pairConfirmDoubleGuardMomentum:
            return AppLocalization.string("同组确认 · 双守门 · 最大仓位75%")
        case .tailBreakdownLockMomentum:
            return AppLocalization.string("持有破位锁盈 · 防守发动机 · 目标波动11%")
        case .recentLossVolatilityMetaMomentum:
            return AppLocalization.string("亏损+波动切防守 · 恢复后进攻")
        case .coreGoldSatelliteConservativeMomentum:
            return AppLocalization.string("核心95% · 黄金卫星10% · 实时回测")
        case .coreGoldSatelliteBalancedMomentum:
            return AppLocalization.string("核心97.5% · 黄金卫星10% · 平衡推荐")
        case .coreGoldSatelliteFullMomentum:
            return AppLocalization.string("核心100% · 黄金卫星10% · 净值轻刹车")
        case .coreGoldSatelliteHeatCappedMomentum:
            return AppLocalization.string("单权益64% · 黄金卫星10% · 总仓85%")
        case .coreGoldSatelliteGoldHandoffMomentum:
            return AppLocalization.string("黄金45%保护 · 美股确认交接 · 回撤<10%")
        case .coreGoldSatelliteEquityBreadthMomentum:
            return AppLocalization.string("黄金交接 · 权益宽度 · 进攻引擎")
        case .coreGoldSatelliteOneWayVolManagedMomentum:
            return AppLocalization.string("双引擎路由 · 只降不升 · 实时回测")
        case .coreGoldSatelliteEquityCurveStateGateMomentum:
            return AppLocalization.string("双引擎路由 · 权益曲线状态机 · 70%低风险")
        case .coreGoldSatelliteSharpeStateGateMomentum:
            return AppLocalization.string("双引擎路由 · 高夏普状态门 · 45%低风险")
        case .coreGoldSatelliteRiskBudgetStateGateMomentum:
            return AppLocalization.string("高夏普底层 · 2.05x预算 · 融资3%")
        case .coreGoldSatelliteConfirmedAccelerationMomentum:
            return AppLocalization.string("确认加速 · 额外权益 · 进攻袖套")
        case .coreGoldSatelliteProfitLockMomentum:
            return AppLocalization.string("组合回撤预算 · 快涨锁盈 · 防守袖套")
        case .coreGoldSatelliteDynamicSleeveMomentum:
            return AppLocalization.string("315日迟滞切换 · 高95/低25 · 实时回测")
        case .coreGoldSatelliteContagionRepairMomentum:
            return AppLocalization.string("全球修复 · 传染控制 · 实时回测")
        case .coreGoldSatelliteCurrencyCashMomentum:
            return AppLocalization.string("闲置美元现金 · 现金选择 · 实时回测")
        case .coreGoldSatelliteGoldPanicLockMomentum:
            return AppLocalization.string("黄金恐慌锁盈 · 释放现金 · 实时回测")
        case .coreGoldSatelliteRiskEfficiencyMomentum:
            return AppLocalization.string("风险效率闸门 · 波动降档 · 实时回测")
        case .coreGoldSatelliteMonthlyHeatCappedMomentum:
            return AppLocalization.string("30日调仓 · 单权益72% · 总仓85%")
        case .coreGoldSatelliteConfirmedExcessMomentum:
            return AppLocalization.string("单权益64% · 超额确认轮动 · 总仓85%")
        case .coreGoldSatelliteAggressiveMomentum:
            return AppLocalization.string("核心97.5% · 黄金卫星15% · 进取收益")
        case .canaryMomentumDefense:
            return AppLocalization.string("双金丝雀 · 前2强势 · 黄金/现金防守")
        case .drawdownReentryMomentum:
            return AppLocalization.string("回撤<8% · 动量/RSI再入场 · 目标波动7.5%")
        case .goldCoreTrendSatellite:
            return AppLocalization.string("黄金核心35% · 权益卫星55% · 分线过滤")
        case .goldNasdaqSteadyRotation:
            return AppLocalization.string("黄金/纳指 · 20日强弱 · MA250 · 目标波动8%")
        case .goldNasdaqPortfolioScheduler:
            return AppLocalization.string("纳指/黄金/现金 · 组合调度 · 风险信号")
        case .strongVolControlledRotation:
            return AppLocalization.string("20日强弱 · 单一强势 · 目标波动12%")
        case .momentumRotation:
            return AppLocalization.string("20日强弱 · 每20交易日 · MA60过滤 · 空仓")
        }
    }

    nonisolated var isRotation: Bool {
        self != .ruleBased
    }

    nonisolated var requiredSignalAssetSymbols: [String] {
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
                return ["gold_cny", "nasdaq", "sp500", "dowjones", "hsi", "nikkei", "csi300", "shanghai_composite", "shenzhen_component", "chinext"]
            case .coreGoldSatelliteCurrencyCashMomentum,
                 .coreGoldSatelliteGoldPanicLockMomentum,
                 .coreGoldSatelliteRiskEfficiencyMomentum:
                return ["gold_cny", "nasdaq", "sp500", "dowjones", "hsi", "nikkei", "csi300", "shanghai_composite", "shenzhen_component", "chinext", "usd_cash"]
            case .coreGoldSatelliteConfirmedAccelerationMomentum,
                 .coreGoldSatelliteDynamicSleeveMomentum:
                return ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext"]
            default:
                return ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
            }
        case .goldNasdaqPortfolioScheduler:
            return ["sp500"]
        default:
            return []
        }
    }

    nonisolated var dateBoundaryAssetSymbols: Set<String>? {
        switch self {
        case .coreGoldSatelliteConfirmedAccelerationMomentum,
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
}

struct AdvancedBacktestTrade: Identifiable {
    let id = UUID()
    let assetSymbol: String
    let assetTitle: String
    let date: Date
    let action: AdvancedBacktestTradeAction
    let price: Double
    let cashAmount: Double
    let units: Double
    let reason: String
    let realizedProfit: Double?
    let realizedReturn: Double?
    let holdingDays: Int?
}

struct AdvancedBacktestPricePoint: Identifiable {
    let date: Date
    let price: Double
    let sequence: Int

    var id: Int { sequence }
}

struct AdvancedBacktestAssetReport: Identifiable {
    let symbol: String
    let title: String
    let points: [BacktestSeriesPoint]
    let benchmarkPoints: [BacktestSeriesPoint]
    let pricePoints: [AdvancedBacktestPricePoint]
    let trades: [AdvancedBacktestTrade]
    let finalPortfolioValue: Double
    let finalCash: Double
    let finalUnits: Double
    let exposureRatio: Double

    var id: String { symbol }
}

struct AdvancedBacktestBenchmarkSeries: Identifiable {
    let id: String
    let title: String
    let points: [BacktestSeriesPoint]
}

struct CashYieldRatePoint: Identifiable {
    let date: Date
    let annualRate: Double

    var id: Date { date }
}

struct CashYieldSummary {
    let title: String
    let source: String
    let sourceDetail: String
    let startDate: Date?
    let endDate: Date?
    let latestRateDate: Date?
    let latestAnnualRate: Double
    let averageAnnualRate: Double
    let averageCashRatio: Double
    let totalCashInterest: Double
    let ratePoints: [CashYieldRatePoint]
}

enum MarketRiskSignalLevel: String {
    case calm
    case watch
    case stress
    case shock

    var title: String {
        switch self {
        case .calm:
            return AppLocalization.string("平稳")
        case .watch:
            return AppLocalization.string("观察")
        case .stress:
            return AppLocalization.string("压力")
        case .shock:
            return AppLocalization.string("冲击")
        }
    }

    var accent: Color {
        switch self {
        case .calm:
            return AssetTheme.positive
        case .watch:
            return AssetTheme.gold
        case .stress:
            return AssetTheme.accentOrange
        case .shock:
            return AssetTheme.negative
        }
    }
}

struct MarketRiskSignalPoint: Identifiable {
    let date: Date
    let score: Double
    let level: MarketRiskSignalLevel
    let sourceTitle: String
    let shortReturn: Double?
    let monthlyReturn: Double?
    let drawdownFromHigh: Double?
    let annualizedVolatility: Double?

    var id: Date { date }
}

struct MarketRiskSignalSummary {
    let title: String
    let source: String
    let sourceDetail: String
    let startDate: Date?
    let endDate: Date?
    let latestPoint: MarketRiskSignalPoint?
    let averageScore: Double
    let stressSessionRatio: Double
    let signalPoints: [MarketRiskSignalPoint]
}

enum CashYieldCNY {
    static let title = AppLocalization.string("人民币活期存款基准利率")
    static let source = AppLocalization.string("中国人民银行 · 金融机构人民币存款基准利率")
    static let sourceDetail = AppLocalization.string("回测中未投入资产的现金仓按历史活期存款基准利率日化计息；实际银行、货币基金或现金管理产品收益可能不同。")
    private static let tradingDaysPerYear = 252.0
    private static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    static let ratePoints: [CashYieldRatePoint] = [
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

    static func annualRate(on date: Date) -> Double {
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

    static func dailyReturn(on date: Date) -> Double {
        dailyReturn(fromAnnualRate: annualRate(on: date))
    }

    static func dailyReturn(fromAnnualRate annualRate: Double) -> Double {
        max(annualRate, 0) / tradingDaysPerYear
    }

    static func averageAnnualRate(across dates: [Date]) -> Double {
        guard !dates.isEmpty else { return 0 }
        return dates.reduce(0) { $0 + annualRate(on: $1) } / Double(dates.count)
    }

    static func summary(
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

enum MarketRiskSignalHistory {
    static let title = AppLocalization.string("美股压力信号")
    static let source = AppLocalization.string("标普500/纳指历史价格 · 仅作风控信号")
    static let sourceDetail = AppLocalization.string("该信号使用标普500优先、纳指备用的多年历史价格，综合短期跌幅、月度跌幅、阶段回撤和波动升温，给组合调度提供风险温度；它不是可买卖持仓，也不改变可见资产范围。")

    static func summary(
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
            sourceDetail: AppLocalization.format("%@。当前采用%@作为压力源。", sourceDetail, sourceTitle),
            startDate: points.first?.date,
            endDate: points.last?.date,
            latestPoint: points.last,
            averageScore: averageScore,
            stressSessionRatio: Double(stressCount) / Double(points.count),
            signalPoints: downsample(points, maxCount: 360)
        )
    }

    static func latestLevel(
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
        case "sp500": return AppLocalization.string("标普500")
        case "nasdaq": return AppLocalization.string("纳指")
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

struct AdvancedBacktestReport {
    let points: [BacktestSeriesPoint]
    let benchmarkPoints: [BacktestSeriesPoint]
    let benchmarkSeries: [AdvancedBacktestBenchmarkSeries]
    let trades: [AdvancedBacktestTrade]
    let assetReports: [AdvancedBacktestAssetReport]
    let finalPortfolioValue: Double
    let finalCash: Double
    let finalUnits: Double
    let totalReturn: Double
    let annualizedReturn: Double?
    let maxDrawdown: Double
    let annualizedVolatility: Double?
    let sharpeRatio: Double?
    let cashYieldSummary: CashYieldSummary
    let riskSignalSummary: MarketRiskSignalSummary?

    var initialPortfolioValue: Double {
        points.first?.portfolioValue ?? 0
    }

    var profitLoss: Double {
        finalPortfolioValue - initialPortfolioValue
    }

    var benchmarkTotalReturn: Double? {
        guard let first = benchmarkPoints.first,
              let last = benchmarkPoints.last,
              first.portfolioValue > 0 else { return nil }
        return (last.portfolioValue / first.portfolioValue) - 1
    }

    var excessReturn: Double? {
        benchmarkTotalReturn.map { totalReturn - $0 }
    }

    var calmarRatio: Double? {
        guard maxDrawdown > 0 else { return nil }
        return (annualizedReturn ?? totalReturn) / maxDrawdown
    }

    var averageExposureRatio: Double {
        guard !assetReports.isEmpty else { return 0 }
        return assetReports.reduce(0) { $0 + $1.exposureRatio } / Double(assetReports.count)
    }

    var averageCashRatio: Double {
        cashYieldSummary.averageCashRatio
    }

    var buyCount: Int {
        trades.filter { $0.action == .buy }.count
    }

    var sellCount: Int {
        trades.filter { $0.action == .sell }.count
    }

    var completedTradeCount: Int {
        trades.filter { $0.action == .sell && $0.realizedProfit != nil }.count
    }

    var winningTradeCount: Int {
        trades.filter { $0.action == .sell && ($0.realizedProfit ?? 0) > 0 }.count
    }

    var winRate: Double? {
        let completedCount = completedTradeCount
        guard completedCount > 0 else { return nil }
        return Double(winningTradeCount) / Double(completedCount)
    }
}

struct StrategyRebalanceAllocation: Identifiable, Sendable {
    let symbol: String
    let title: String
    let targetWeight: Double
    let momentum: Double
    let annualizedVolatility: Double?

    var id: String { symbol }
}

struct StrategyRebalanceAdvice: Sendable {
    let strategyTitle: String
    let asOfDate: Date
    let lookbackSessions: Int
    let rebalanceSessions: Int
    let targetAnnualVolatility: Double?
    let allocations: [StrategyRebalanceAllocation]

    var totalTargetWeight: Double {
        allocations.reduce(0) { $0 + $1.targetWeight }
    }

    var cashWeight: Double {
        max(0, 1 - totalTargetWeight)
    }

    var isCashDefense: Bool {
        allocations.isEmpty || totalTargetWeight <= 0.0001
    }
}

enum StrategyRebalanceActionKind {
    case buy
    case sell
    case hold
    case missingRecord
    case targetOnly

    var title: String {
        switch self {
        case .buy:
            return AppLocalization.string("买入")
        case .sell:
            return AppLocalization.string("卖出")
        case .hold:
            return AppLocalization.string("保持")
        case .missingRecord:
            return AppLocalization.string("未记录")
        case .targetOnly:
            return AppLocalization.string("目标")
        }
    }

    var accent: Color {
        switch self {
        case .buy:
            return AssetTheme.positive
        case .sell:
            return AssetTheme.negative
        case .hold, .targetOnly:
            return AssetTheme.textSecondary
        case .missingRecord:
            return AssetTheme.accentOrange
        }
    }
}

struct StrategyHoldingMatch {
    let amount: Double
    let itemNames: [String]

    var isMatched: Bool { !itemNames.isEmpty }
}

struct StrategyRebalanceAction: Identifiable {
    let symbol: String
    let title: String
    let currentAmount: Double?
    let currentWeight: Double?
    let targetWeight: Double
    let targetAmount: Double?
    let deltaAmount: Double?
    let investmentBase: Double?
    let matchedItemNames: [String]
    let kind: StrategyRebalanceActionKind
    let momentum: Double?
    let annualizedVolatility: Double?

    var id: String { symbol }

    var isMatched: Bool { !matchedItemNames.isEmpty }

    func detailText(lookbackSessions: Int) -> String {
        let currentText = currentWeight.map { AppLocalization.format("当前 %@", $0.percentString(maxFractionDigits: 1)) }
            ?? (isMatched ? AppLocalization.string("当前 --") : AppLocalization.string("未记录"))
        let targetText = AppLocalization.format("目标 %@", targetWeight.percentString(maxFractionDigits: 1))
        let signalText: String
        if let momentum {
            signalText = AppLocalization.format(" · %d日动量 %@", lookbackSessions, momentum.percentString(maxFractionDigits: 1))
        } else {
            signalText = ""
        }
        return "\(currentText) · \(targetText)\(signalText)"
    }

    var amountText: String {
        switch kind {
        case .buy, .sell:
            return (abs(deltaAmount ?? 0)).currencyString()
        case .missingRecord:
            if let targetAmount {
                return AppLocalization.format("需 %@", targetAmount.currencyString())
            }
            return targetWeight.percentString(maxFractionDigits: 1)
        case .hold:
            return AppLocalization.string("偏离小")
        case .targetOnly:
            return targetWeight.percentString(maxFractionDigits: 1)
        }
    }
}

enum StrategyRebalanceActionBuilder {
    static func actions(
        for advice: StrategyRebalanceAdvice,
        snapshot: AssetSnapshot?,
        selectedAssetOptions: [BacktestAssetOption],
        allAssetOptions: [BacktestAssetOption]
    ) -> [StrategyRebalanceAction] {
        let targetAllocationsBySymbol = Dictionary(uniqueKeysWithValues: advice.allocations.map { ($0.symbol, $0) })
        let orderedSymbols = orderedStrategySymbols(for: advice, selectedAssetOptions: selectedAssetOptions)

        guard let snapshot else {
            return advice.allocations.map { allocation in
                targetOnlyAction(allocation: allocation)
            }
        }

        let matchesBySymbol = Dictionary(uniqueKeysWithValues: orderedSymbols.map { symbol in
            (symbol, strategyHoldingMatch(for: symbol, in: snapshot))
        })
        let investmentBase = strategyInvestmentBase(in: snapshot, matches: Array(matchesBySymbol.values))
        guard investmentBase > 0 else {
            return advice.allocations.map { allocation in
                targetOnlyAction(allocation: allocation)
            }
        }

        let minimumTradeAmount = max(investmentBase * 0.01, 500)
        return orderedSymbols.compactMap { symbol -> StrategyRebalanceAction? in
            let allocation = targetAllocationsBySymbol[symbol]
            let targetWeight = allocation?.targetWeight ?? 0
            let match = matchesBySymbol[symbol] ?? StrategyHoldingMatch(amount: 0, itemNames: [])
            let currentAmount = match.amount
            let targetAmount = investmentBase * targetWeight
            let deltaAmount = targetAmount - currentAmount

            guard targetWeight > 0.0001 || currentAmount > minimumTradeAmount else { return nil }

            let kind: StrategyRebalanceActionKind
            if !match.isMatched, targetWeight > 0.0001 {
                kind = .missingRecord
            } else if deltaAmount > minimumTradeAmount {
                kind = .buy
            } else if deltaAmount < -minimumTradeAmount {
                kind = .sell
            } else {
                kind = .hold
            }

            return StrategyRebalanceAction(
                symbol: symbol,
                title: allocation?.title ?? strategyTitle(for: symbol, allAssetOptions: allAssetOptions),
                currentAmount: currentAmount,
                currentWeight: currentAmount / investmentBase,
                targetWeight: targetWeight,
                targetAmount: targetAmount,
                deltaAmount: deltaAmount,
                investmentBase: investmentBase,
                matchedItemNames: match.itemNames,
                kind: kind,
                momentum: allocation?.momentum,
                annualizedVolatility: allocation?.annualizedVolatility
            )
        }
        .sorted { lhs, rhs in
            if lhs.kind == .hold && rhs.kind != .hold { return false }
            if lhs.kind != .hold && rhs.kind == .hold { return true }
            if lhs.targetWeight != rhs.targetWeight { return lhs.targetWeight > rhs.targetWeight }
            return abs(lhs.deltaAmount ?? 0) > abs(rhs.deltaAmount ?? 0)
        }
    }

    private static func targetOnlyAction(allocation: StrategyRebalanceAllocation) -> StrategyRebalanceAction {
        StrategyRebalanceAction(
            symbol: allocation.symbol,
            title: allocation.title,
            currentAmount: nil,
            currentWeight: nil,
            targetWeight: allocation.targetWeight,
            targetAmount: nil,
            deltaAmount: nil,
            investmentBase: nil,
            matchedItemNames: [],
            kind: .targetOnly,
            momentum: allocation.momentum,
            annualizedVolatility: allocation.annualizedVolatility
        )
    }

    private static func orderedStrategySymbols(
        for advice: StrategyRebalanceAdvice,
        selectedAssetOptions: [BacktestAssetOption]
    ) -> [String] {
        var seen = Set<String>()
        var symbols: [String] = []
        for symbol in selectedAssetOptions.map(\.symbol) + advice.allocations.map(\.symbol) {
            guard !seen.contains(symbol) else { continue }
            seen.insert(symbol)
            symbols.append(symbol)
        }
        return symbols
    }

    private static func strategyInvestmentBase(in snapshot: AssetSnapshot, matches: [StrategyHoldingMatch]) -> Double {
        let financialAmount = snapshot.entries.reduce(0.0) { partial, entry in
            guard entry.resolvedAmount > 0,
                  (entry.item?.category?.group ?? .financial) == .financial else { return partial }
            return partial + entry.resolvedAmount
        }
        let matchedAmount = matches.reduce(0.0) { $0 + $1.amount }
        return max(financialAmount, matchedAmount)
    }

    private static func strategyHoldingMatch(for symbol: String, in snapshot: AssetSnapshot) -> StrategyHoldingMatch {
        let matchedEntries = snapshot.entries.filter { entry in
            guard entry.resolvedAmount > 0,
                  let item = entry.item,
                  (item.category?.group ?? .financial) != .liability else { return false }
            return itemMatchesStrategySymbol(item, symbol: symbol)
        }
        let amount = matchedEntries.reduce(0.0) { $0 + $1.resolvedAmount }
        let itemNames = Array(Set(matchedEntries.compactMap { $0.item?.name })).sorted()
        return StrategyHoldingMatch(amount: amount, itemNames: itemNames)
    }

    private static func itemMatchesStrategySymbol(_ item: AssetItem, symbol: String) -> Bool {
        if symbol == "gold_cny", item.resolvedAutoPricedAssetKind == .gold {
            return true
        }

        let searchText = "\(item.name) \(item.note)"
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        return strategyKeywords(for: symbol).contains { keyword in
            searchText.contains(keyword)
        }
    }

    private static func strategyKeywords(for symbol: String) -> [String] {
        switch symbol {
        case "gold_cny":
            return ["黄金", "gold", "au9999", "au99", "金"]
        case "nasdaq":
            return ["纳指", "纳斯达克", "nasdaq", "qqq", "ndx"]
        case "sp500":
            return ["标普500", "标普 500", "s&p500", "s&p 500", "sp500", "spy", "voo"]
        case "dowjones":
            return ["道指", "道琼斯", "dowjones", "dow jones", "djia", "dia"]
        case "hsi":
            return ["恒生", "恒生指数", "hang seng", "hsi", "2800"]
        case "nikkei":
            return ["日经", "日经225", "nikkei", "nikkei225", "1321"]
        case "csi300":
            return ["沪深300", "沪深 300", "csi300", "hs300"]
        case "shanghai_composite":
            return ["上证综指", "上证指数", "上证", "shanghai composite", "shanghai_composite", "000001"]
        case "shenzhen_component":
            return ["深证成指", "深成指", "shenzhen component", "shenzhen_component", "399001"]
        case "chinext":
            return ["创业板", "创业板指", "chinext", "399006"]
        case "usd_cash":
            return ["美元现金", "美元", "usd", "us dollar", "dollar"]
        default:
            return [symbol.lowercased()]
        }
    }

    private static func strategyTitle(for symbol: String, allAssetOptions: [BacktestAssetOption]) -> String {
        allAssetOptions.first(where: { $0.symbol == symbol })?.title ?? symbol
    }
}

struct AdvancedBacktestComputationResult {
    let report: AdvancedBacktestReport?
    let rebalanceAdvice: StrategyRebalanceAdvice?
}

struct AdvancedBacktestRiskSettings {
    var feeRate: Double
    var slippageRate: Double
    var maxPositionRatio: Double
    var cooldownDays: Int
    var stopLossRatio: Double
    var takeProfitRatio: Double
}

struct AdvancedBacktestCandidate: Identifiable {
    let id = UUID()
    let buyRule: AdvancedBacktestRule
    let sellRule: AdvancedBacktestRule
    let tradeAmount: Double
    let settings: AdvancedBacktestRiskSettings
    let report: AdvancedBacktestReport
    let score: Double

    var title: String {
        "\(buyRule.direction.shortTitle) / \(sellRule.direction.shortTitle)"
    }
}

struct AdvancedBacktestStrategyTemplate: Identifiable {
    let id: String
    var mode: AdvancedBacktestStrategyMode = .ruleBased
    var selectedAssetSymbols: [String]? = nil
    let category: String
    let title: String
    let annualizedReturn: Double
    let maxDrawdown: Double
    let sharpeRatio: Double
    let buyRule: AdvancedBacktestRule
    let sellRule: AdvancedBacktestRule
    let tradeAmountRatio: Double
    let maxPositionRatio: Double
    let cooldownDays: Int
    let stopLossRatio: Double
    let takeProfitRatio: Double

    var subtitle: String {
        if annualizedReturn == 0, maxDrawdown == 0, sharpeRatio == 0 {
            return ""
        }
        return AppLocalization.format(
            "年化约%@ 最大回撤约%@ 夏普约%.2f",
            annualizedReturn.percentString(maxFractionDigits: 1),
            maxDrawdown.percentString(maxFractionDigits: 1),
            sharpeRatio
        )
    }

    static let all: [AdvancedBacktestStrategyTemplate] = [
        .init(
            id: "basic-ma20-trend",
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300"],
            category: AppLocalization.string("基础策略"),
            title: AppLocalization.string("MA20趋势"),
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
            category: AppLocalization.string("基础策略"),
            title: AppLocalization.string("MA60趋势"),
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
            category: AppLocalization.string("基础策略"),
            title: AppLocalization.string("MA金叉死叉"),
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
            category: AppLocalization.string("基础策略"),
            title: AppLocalization.string("BOLL下轨反弹"),
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
            id: "core-gold-satellite-heat-capped-momentum",
            mode: .coreGoldSatelliteHeatCappedMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"],
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("热度上限元策略"),
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
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("黄金交接保护"),
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
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("单向控波元策略"),
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
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("权益曲线状态机"),
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
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("高夏普状态机"),
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
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("风险预算状态机"),
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
            id: "core-gold-satellite-dynamic-sleeve-momentum",
            mode: .coreGoldSatelliteDynamicSleeveMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext"],
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("动态袖套夏普策略"),
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
            id: "core-gold-satellite-contagion-repair-momentum",
            mode: .coreGoldSatelliteContagionRepairMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "hsi", "nikkei", "csi300", "shanghai_composite", "shenzhen_component", "chinext"],
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("全球修复传染控制"),
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
            id: "core-gold-satellite-currency-cash-momentum",
            mode: .coreGoldSatelliteCurrencyCashMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "hsi", "nikkei", "csi300", "shanghai_composite", "shenzhen_component", "chinext", "usd_cash"],
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("美元现金修复策略"),
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
            id: "core-gold-satellite-gold-panic-lock-momentum",
            mode: .coreGoldSatelliteGoldPanicLockMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "hsi", "nikkei", "csi300", "shanghai_composite", "shenzhen_component", "chinext", "usd_cash"],
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("黄金恐慌锁盈策略"),
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
            id: "core-gold-satellite-risk-efficiency-momentum",
            mode: .coreGoldSatelliteRiskEfficiencyMomentum,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "hsi", "nikkei", "csi300", "shanghai_composite", "shenzhen_component", "chinext", "usd_cash"],
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("风险效率增强策略"),
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
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("月度热度上限元"),
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
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("增强热度上限元"),
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
            id: "canary-momentum-defense",
            mode: .canaryMomentumDefense,
            selectedAssetSymbols: ["gold_cny", "nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite"],
            category: AppLocalization.string("高级策略"),
            title: AppLocalization.string("双金丝雀动量防守"),
            annualizedReturn: 0,
            maxDrawdown: 0,
            sharpeRatio: 0,
            buyRule: .init(direction: .priceAboveMA60, days: 1),
            sellRule: .init(direction: .priceBelowMA60, days: 1),
            tradeAmountRatio: 1,
            maxPositionRatio: 95,
            cooldownDays: 0,
            stopLossRatio: 0,
            takeProfitRatio: 0
        )
    ]
}

struct BacktestReport {
    let points: [BacktestSeriesPoint]
    let totalReturn: Double
    let annualizedReturn: Double?
    let maxDrawdown: Double
    let maxDrawdownRecoveryDays: Int?
    let annualizedVolatility: Double?
    let sharpeRatio: Double?
}

struct DCABacktestReport {
    let points: [BacktestSeriesPoint]
    let totalInvested: Double
    let finalPortfolioValue: Double
    let profitLoss: Double
    let totalReturn: Double
    let annualizedReturn: Double?
    let maxDrawdown: Double
    let annualizedVolatility: Double?
    let sharpeRatio: Double?
    let contributionCount: Int
    let totalUnits: Double
}

enum BacktestRecordKind: String, Codable, CaseIterable {
    case allocation
    case dca
    case advanced

    var title: String {
        switch self {
        case .allocation:
            return AppLocalization.string("配置回测")
        case .dca:
            return AppLocalization.string("定投回测")
        case .advanced:
            return AppLocalization.string("策略回测")
        }
    }

    var entryIconName: String {
        switch self {
        case .allocation:
            return "chart.pie.fill"
        case .dca:
            return "calendar.badge.plus"
        case .advanced:
            return "slider.horizontal.3"
        }
    }


    var chartValueStyle: BacktestChartValueStyle {
        switch self {
        case .allocation:
            return .multiple
        case .dca, .advanced:
            return .currency(code: "CNY")
        }
    }
}

struct BacktestRecordPointPayload: Codable {
    let date: Date
    let value: Double
    let sequence: Int

    init(date: Date, value: Double, sequence: Int) {
        self.date = date
        self.value = value
        self.sequence = sequence
    }

    init(point: BacktestSeriesPoint, sequence: Int) {
        self.date = point.date
        self.value = point.portfolioValue
        self.sequence = sequence
    }

    var seriesPoint: BacktestSeriesPoint {
        BacktestSeriesPoint(date: date, portfolioValue: value, sequence: sequence)
    }
}

struct BacktestRecordAdvancedPricePayload: Codable, Identifiable {
    let date: Date
    let price: Double
    let sequence: Int

    var id: Int { sequence }

    var pricePoint: AdvancedBacktestPricePoint {
        AdvancedBacktestPricePoint(date: date, price: price, sequence: sequence)
    }
}

struct BacktestRecordAdvancedTradePayload: Codable, Identifiable {
    let assetSymbol: String
    let assetTitle: String
    let date: Date
    let actionRawValue: String
    let price: Double
    let cashAmount: Double
    let units: Double
    let reason: String?
    let realizedProfit: Double?
    let realizedReturn: Double?
    let holdingDays: Int?
    let sequence: Int

    var id: String { "\(assetSymbol)-\(actionRawValue)-\(date.timeIntervalSinceReferenceDate)-\(sequence)" }

    var action: AdvancedBacktestTradeAction {
        AdvancedBacktestTradeAction(rawValue: actionRawValue) ?? .buy
    }

    init(
        assetSymbol: String,
        assetTitle: String,
        date: Date,
        actionRawValue: String,
        price: Double,
        cashAmount: Double,
        units: Double,
        reason: String? = nil,
        realizedProfit: Double? = nil,
        realizedReturn: Double? = nil,
        holdingDays: Int? = nil,
        sequence: Int
    ) {
        self.assetSymbol = assetSymbol
        self.assetTitle = assetTitle
        self.date = date
        self.actionRawValue = actionRawValue
        self.price = price
        self.cashAmount = cashAmount
        self.units = units
        self.reason = reason
        self.realizedProfit = realizedProfit
        self.realizedReturn = realizedReturn
        self.holdingDays = holdingDays
        self.sequence = sequence
    }

    init(trade: AdvancedBacktestTrade, sequence: Int) {
        self.assetSymbol = trade.assetSymbol
        self.assetTitle = trade.assetTitle
        self.date = trade.date
        self.actionRawValue = trade.action.rawValue
        self.price = trade.price
        self.cashAmount = trade.cashAmount
        self.units = trade.units
        self.reason = trade.reason
        self.realizedProfit = trade.realizedProfit
        self.realizedReturn = trade.realizedReturn
        self.holdingDays = trade.holdingDays
        self.sequence = sequence
    }

    var advancedTrade: AdvancedBacktestTrade {
        AdvancedBacktestTrade(
            assetSymbol: assetSymbol,
            assetTitle: assetTitle,
            date: date,
            action: action,
            price: price,
            cashAmount: cashAmount,
            units: units,
            reason: reason ?? "",
            realizedProfit: realizedProfit,
            realizedReturn: realizedReturn,
            holdingDays: holdingDays
        )
    }
}

struct BacktestRecordAdvancedAssetChartPayload: Codable, Identifiable {
    let symbol: String
    let title: String
    let pricePoints: [BacktestRecordAdvancedPricePayload]
    let benchmarkPoints: [BacktestRecordPointPayload]?
    let trades: [BacktestRecordAdvancedTradePayload]
    var finalPortfolioValue: Double? = nil
    var finalCash: Double? = nil
    var finalUnits: Double? = nil
    var exposureRatio: Double? = nil

    var id: String { symbol }

    var decodedBenchmarkPoints: [BacktestSeriesPoint] {
        (benchmarkPoints ?? [])
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
    }
}

struct BacktestRecordAdvancedBenchmarkSeriesPayload: Codable, Identifiable {
    let id: String
    let title: String
    let points: [BacktestRecordPointPayload]

    var decodedPoints: [BacktestSeriesPoint] {
        points
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
    }
}

struct BacktestRecordCashYieldRatePointPayload: Codable {
    let date: Date
    let annualRate: Double

    init(point: CashYieldRatePoint) {
        date = point.date
        annualRate = point.annualRate
    }

    var ratePoint: CashYieldRatePoint {
        CashYieldRatePoint(date: date, annualRate: annualRate)
    }
}

struct BacktestRecordCashYieldSummaryPayload: Codable {
    let title: String
    let source: String
    let sourceDetail: String
    let startDate: Date?
    let endDate: Date?
    let latestRateDate: Date?
    let latestAnnualRate: Double
    let averageAnnualRate: Double
    let averageCashRatio: Double
    let totalCashInterest: Double
    let ratePoints: [BacktestRecordCashYieldRatePointPayload]

    init(summary: CashYieldSummary, maxRatePointCount: Int = 60) {
        title = summary.title
        source = summary.source
        sourceDetail = summary.sourceDetail
        startDate = summary.startDate
        endDate = summary.endDate
        latestRateDate = summary.latestRateDate
        latestAnnualRate = summary.latestAnnualRate
        averageAnnualRate = summary.averageAnnualRate
        averageCashRatio = summary.averageCashRatio
        totalCashInterest = summary.totalCashInterest
        let sampledPoints = evenlySampledItems(summary.ratePoints, maxCount: maxRatePointCount)
        ratePoints = sampledPoints.map(BacktestRecordCashYieldRatePointPayload.init(point:))
    }

    var cashYieldSummary: CashYieldSummary {
        CashYieldSummary(
            title: title,
            source: source,
            sourceDetail: sourceDetail,
            startDate: startDate,
            endDate: endDate,
            latestRateDate: latestRateDate,
            latestAnnualRate: latestAnnualRate,
            averageAnnualRate: averageAnnualRate,
            averageCashRatio: averageCashRatio,
            totalCashInterest: totalCashInterest,
            ratePoints: ratePoints.map(\.ratePoint)
        )
    }
}

struct BacktestRecordRiskSignalPointPayload: Codable {
    let date: Date
    let score: Double
    let levelRawValue: String
    let sourceTitle: String
    let shortReturn: Double?
    let monthlyReturn: Double?
    let drawdownFromHigh: Double?
    let annualizedVolatility: Double?

    init(point: MarketRiskSignalPoint) {
        date = point.date
        score = point.score
        levelRawValue = point.level.rawValue
        sourceTitle = point.sourceTitle
        shortReturn = point.shortReturn
        monthlyReturn = point.monthlyReturn
        drawdownFromHigh = point.drawdownFromHigh
        annualizedVolatility = point.annualizedVolatility
    }

    var signalPoint: MarketRiskSignalPoint {
        MarketRiskSignalPoint(
            date: date,
            score: score,
            level: MarketRiskSignalLevel(rawValue: levelRawValue) ?? .calm,
            sourceTitle: sourceTitle,
            shortReturn: shortReturn,
            monthlyReturn: monthlyReturn,
            drawdownFromHigh: drawdownFromHigh,
            annualizedVolatility: annualizedVolatility
        )
    }
}

struct BacktestRecordRiskSignalSummaryPayload: Codable {
    let title: String
    let source: String
    let sourceDetail: String
    let startDate: Date?
    let endDate: Date?
    let latestPoint: BacktestRecordRiskSignalPointPayload?
    let averageScore: Double
    let stressSessionRatio: Double
    let signalPoints: [BacktestRecordRiskSignalPointPayload]

    init(summary: MarketRiskSignalSummary, maxSignalPointCount: Int = 120) {
        title = summary.title
        source = summary.source
        sourceDetail = summary.sourceDetail
        startDate = summary.startDate
        endDate = summary.endDate
        latestPoint = summary.latestPoint.map(BacktestRecordRiskSignalPointPayload.init(point:))
        averageScore = summary.averageScore
        stressSessionRatio = summary.stressSessionRatio
        let sampledPoints = evenlySampledItems(summary.signalPoints, maxCount: maxSignalPointCount)
        signalPoints = sampledPoints.map(BacktestRecordRiskSignalPointPayload.init(point:))
    }

    var riskSignalSummary: MarketRiskSignalSummary {
        let points = signalPoints.map(\.signalPoint)
        return MarketRiskSignalSummary(
            title: title,
            source: source,
            sourceDetail: sourceDetail,
            startDate: startDate,
            endDate: endDate,
            latestPoint: latestPoint?.signalPoint ?? points.last,
            averageScore: averageScore,
            stressSessionRatio: stressSessionRatio,
            signalPoints: points
        )
    }
}

struct BacktestRecordConfigPayload: Codable {
    var kind: BacktestRecordKind
    var cashWeight: Double? = nil
    var goldWeight: Double? = nil
    var indexWeights: [String: Double]? = nil
    var dcaAssetSymbol: String? = nil
    var dcaContributionAmount: Double? = nil
    var dcaIntervalDays: Int? = nil
    var selectedAssetSymbol: String? = nil
    var selectedAssetSymbols: [String]? = nil
    var initialCash: Double? = nil
    var tradeAmount: Double? = nil
    var feeRate: Double? = nil
    var slippageRate: Double? = nil
    var maxPositionRatio: Double? = nil
    var cooldownDays: Int? = nil
    var stopLossRatio: Double? = nil
    var takeProfitRatio: Double? = nil
    var strategyModeRawValue: String? = nil
    var buyDirectionRawValue: String? = nil
    var buyDays: Int? = nil
    var sellDirectionRawValue: String? = nil
    var sellDays: Int? = nil
    var advancedTrades: [BacktestRecordAdvancedTradePayload]? = nil
    var advancedAssetCharts: [BacktestRecordAdvancedAssetChartPayload]? = nil
    var advancedBenchmarkSeries: [BacktestRecordAdvancedBenchmarkSeriesPayload]? = nil
    var finalCash: Double? = nil
    var finalUnits: Double? = nil
    var cashYieldSummary: BacktestRecordCashYieldSummaryPayload? = nil
    var riskSignalSummary: BacktestRecordRiskSignalSummaryPayload? = nil
}

struct AdvancedBacktestRestoreRequest {
    let id: UUID
    let config: BacktestRecordConfigPayload
    let startDate: Date?
    let endDate: Date?
}

enum BacktestRecordCodec {
    static func pointsData(from points: [BacktestSeriesPoint], maxCount: Int = 240) -> Data {
        let sampledPoints = sampled(points, maxCount: maxCount)
        let payload = sampledPoints.enumerated().map { index, point in
            BacktestRecordPointPayload(point: point, sequence: index)
        }
        return (try? JSONEncoder().encode(payload)) ?? Data()
    }

    static func configData(from payload: BacktestRecordConfigPayload) -> Data {
        (try? JSONEncoder().encode(payload)) ?? Data()
    }

    static func cashYieldSummaryPayload(from summary: CashYieldSummary, maxRatePointCount: Int = 60) -> BacktestRecordCashYieldSummaryPayload {
        BacktestRecordCashYieldSummaryPayload(summary: summary, maxRatePointCount: maxRatePointCount)
    }

    static func riskSignalSummaryPayload(from summary: MarketRiskSignalSummary, maxSignalPointCount: Int = 120) -> BacktestRecordRiskSignalSummaryPayload {
        BacktestRecordRiskSignalSummaryPayload(summary: summary, maxSignalPointCount: maxSignalPointCount)
    }

    static func advancedTradePayloads(from trades: [AdvancedBacktestTrade]) -> [BacktestRecordAdvancedTradePayload] {
        trades.enumerated().map { index, trade in
            BacktestRecordAdvancedTradePayload(trade: trade, sequence: index)
        }
    }

    static func advancedBenchmarkSeriesPayloads(
        from series: [AdvancedBacktestBenchmarkSeries],
        maxPointCount: Int = 240
    ) -> [BacktestRecordAdvancedBenchmarkSeriesPayload] {
        series.map { benchmarkSeries in
            let sampledPoints = sampled(benchmarkSeries.points, maxCount: maxPointCount)
                .enumerated()
                .map { index, point in
                    BacktestRecordPointPayload(point: point, sequence: index)
                }
            return BacktestRecordAdvancedBenchmarkSeriesPayload(
                id: benchmarkSeries.id,
                title: benchmarkSeries.title,
                points: sampledPoints
            )
        }
    }

    static func advancedAssetChartPayloads(from assetReports: [AdvancedBacktestAssetReport], maxPricePointCount: Int = 240) -> [BacktestRecordAdvancedAssetChartPayload] {
        assetReports.map { assetReport in
            let sampledPricePoints = sampled(assetReport.pricePoints, maxCount: maxPricePointCount)
                .enumerated()
                .map { index, point in
                    BacktestRecordAdvancedPricePayload(date: point.date, price: point.price, sequence: index)
                }
            let sampledBenchmarkPoints = sampled(assetReport.benchmarkPoints, maxCount: maxPricePointCount)
                .enumerated()
                .map { index, point in
                    BacktestRecordPointPayload(point: point, sequence: index)
                }
            let trades = advancedTradePayloads(from: assetReport.trades)
            return BacktestRecordAdvancedAssetChartPayload(
                symbol: assetReport.symbol,
                title: assetReport.title,
                pricePoints: sampledPricePoints,
                benchmarkPoints: sampledBenchmarkPoints,
                trades: trades,
                finalPortfolioValue: assetReport.finalPortfolioValue,
                finalCash: assetReport.finalCash,
                finalUnits: assetReport.finalUnits,
                exposureRatio: assetReport.exposureRatio
            )
        }
    }

    static func decodePoints(from record: BacktestRecord) -> [BacktestSeriesPoint] {
        guard !record.pointsJSON.isEmpty,
              let payload = try? JSONDecoder().decode([BacktestRecordPointPayload].self, from: record.pointsJSON) else {
            return []
        }
        return payload
            .sorted { $0.sequence < $1.sequence }
            .map(\.seriesPoint)
    }

    static func decodeConfig(from record: BacktestRecord) -> BacktestRecordConfigPayload? {
        guard !record.configJSON.isEmpty else { return nil }
        return try? JSONDecoder().decode(BacktestRecordConfigPayload.self, from: record.configJSON)
    }

    static func kind(for record: BacktestRecord) -> BacktestRecordKind {
        BacktestRecordKind(rawValue: record.kindRawValue) ?? .allocation
    }

    static func advancedReport(from record: BacktestRecord) -> AdvancedBacktestReport? {
        guard kind(for: record) == .advanced,
              let config = decodeConfig(from: record) else { return nil }

        let points = decodePoints(from: record)
        guard !points.isEmpty else { return nil }

        let trades = (config.advancedTrades ?? []).map(\.advancedTrade)
        let benchmarkSeries = (config.advancedBenchmarkSeries ?? []).map {
            AdvancedBacktestBenchmarkSeries(id: $0.id, title: $0.title, points: $0.decodedPoints)
        }
        let benchmarkPoints = benchmarkSeries.first?.points ?? []
        let assetReports = advancedAssetReports(from: config)
        let finalPortfolioValue = record.finalValue ?? points.last?.portfolioValue ?? 0

        return AdvancedBacktestReport(
            points: points,
            benchmarkPoints: benchmarkPoints,
            benchmarkSeries: benchmarkSeries,
            trades: trades,
            assetReports: assetReports,
            finalPortfolioValue: finalPortfolioValue,
            finalCash: config.finalCash ?? 0,
            finalUnits: config.finalUnits ?? 0,
            totalReturn: record.totalReturn,
            annualizedReturn: record.annualizedReturn,
            maxDrawdown: record.maxDrawdown,
            annualizedVolatility: record.annualizedVolatility,
            sharpeRatio: record.sharpeRatio,
            cashYieldSummary: config.cashYieldSummary?.cashYieldSummary ?? defaultCashYieldSummary(for: points),
            riskSignalSummary: config.riskSignalSummary?.riskSignalSummary
        )
    }

    private static func defaultCashYieldSummary(for points: [BacktestSeriesPoint]) -> CashYieldSummary {
        CashYieldSummary(
            title: CashYieldCNY.title,
            source: CashYieldCNY.source,
            sourceDetail: CashYieldCNY.sourceDetail,
            startDate: points.first?.date,
            endDate: points.last?.date,
            latestRateDate: nil,
            latestAnnualRate: 0,
            averageAnnualRate: 0,
            averageCashRatio: 0,
            totalCashInterest: 0,
            ratePoints: []
        )
    }

    static func executionAssumptionText(from record: BacktestRecord) -> String {
        guard let config = decodeConfig(from: record) else { return "" }
        let mode = config.strategyModeRawValue.flatMap(AdvancedBacktestStrategyMode.init(rawValue:)) ?? .ruleBased
        let feeRate = config.feeRate ?? 1.0
        let slippageRate = config.slippageRate ?? 0.05
        let timingText = mode.isRotation
            ? AppLocalization.string("轮动策略使用上一交易日信号、下一调仓日收盘价成交")
            : AppLocalization.string("条件信号使用上一交易日收盘确认、下一交易日收盘价成交")
        return AppLocalization.format(
            "%@；已计入%.2f%%交易费和%.2f%%滑点。",
            timingText,
            feeRate,
            slippageRate
        )
    }

    private static func advancedAssetReports(from config: BacktestRecordConfigPayload) -> [AdvancedBacktestAssetReport] {
        (config.advancedAssetCharts ?? []).map { chart in
            let trades = chart.trades.map(\.advancedTrade)
            let pricePoints = chart.pricePoints
                .sorted { $0.sequence < $1.sequence }
                .map(\.pricePoint)
            let portfolioPoints = chart.decodedBenchmarkPoints
            return AdvancedBacktestAssetReport(
                symbol: chart.symbol,
                title: chart.title,
                points: portfolioPoints,
                benchmarkPoints: chart.decodedBenchmarkPoints,
                pricePoints: pricePoints,
                trades: trades,
                finalPortfolioValue: chart.finalPortfolioValue ?? portfolioPoints.last?.portfolioValue ?? 0,
                finalCash: chart.finalCash ?? 0,
                finalUnits: chart.finalUnits ?? trades.last(where: { $0.action == .buy })?.units ?? 0,
                exposureRatio: chart.exposureRatio ?? 0
            )
        }
    }

    private static func sampled(_ points: [BacktestSeriesPoint], maxCount: Int) -> [BacktestSeriesPoint] {
        guard points.count > maxCount, maxCount > 1 else { return points }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [BacktestSeriesPoint] = []
        sampled.reserveCapacity(maxCount)

        for index in 0 ..< maxCount {
            let rawIndex = Int((Double(index) * step).rounded())
            let safeIndex = min(max(rawIndex, 0), points.count - 1)
            let point = points[safeIndex]
            if sampled.last?.date != point.date {
                sampled.append(point)
            }
        }

        if sampled.last?.date != points.last?.date, let last = points.last {
            sampled.append(last)
        }
        return sampled
    }

    private static func sampled(_ points: [AdvancedBacktestPricePoint], maxCount: Int) -> [AdvancedBacktestPricePoint] {
        guard points.count > maxCount, maxCount > 1 else { return points }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        var sampled: [AdvancedBacktestPricePoint] = []
        sampled.reserveCapacity(maxCount)

        for index in 0 ..< maxCount {
            let rawIndex = Int((Double(index) * step).rounded())
            let safeIndex = min(max(rawIndex, 0), points.count - 1)
            let point = points[safeIndex]
            if sampled.last?.date != point.date {
                sampled.append(point)
            }
        }

        if sampled.last?.date != points.last?.date, let last = points.last {
            sampled.append(last)
        }
        return sampled
    }
}

struct BacktestIndexOption: Identifiable {
    let symbol: String
    let title: String
    let color: Color

    var id: String { symbol }
}

struct BacktestAssetOption: Identifiable {
    let symbol: String
    let title: String
    let color: Color
    let requiresHistoricalFX: Bool
    let historicalFXSymbol: String?

    var id: String { symbol }
}

struct BacktestPerformanceMetrics {
    let totalReturn: Double
    let annualizedReturn: Double?
    let maxDrawdown: Double
    let annualizedVolatility: Double?
    let sharpeRatio: Double?
}

enum BacktestDefaults {
    static let cashWeight: Double = 50
    static let goldWeight: Double = 25
    static let dcaAssetSymbol = "gold_cny"
    static let dcaContributionAmount: Double = 1000
    static let dcaIntervalDays = 30
    static let indexOptions: [BacktestIndexOption] = [
        .init(symbol: "sp500", title: AppLocalization.string("标普500"), color: AssetTheme.goldSoft),
        .init(symbol: "nasdaq", title: AppLocalization.string("纳指"), color: AssetTheme.accentBlue),
        .init(symbol: "dowjones", title: AppLocalization.string("道指"), color: AssetTheme.accentOrange),
        .init(symbol: "hsi", title: AppLocalization.string("恒生"), color: AssetTheme.accentRed),
        .init(symbol: "nikkei", title: AppLocalization.string("日经225"), color: AssetTheme.positive),
        .init(symbol: "csi300", title: AppLocalization.string("沪深300"), color: AssetTheme.textPrimary),
        .init(symbol: "shanghai_composite", title: AppLocalization.string("上证综指"), color: AssetTheme.textSecondary),
        .init(symbol: "shenzhen_component", title: AppLocalization.string("深成指"), color: AssetTheme.accentRed),
        .init(symbol: "chinext", title: AppLocalization.string("创业板"), color: AssetTheme.positive),
    ]
    static let indexWeights: [String: Double] = {
        Dictionary(uniqueKeysWithValues: indexOptions.map { option in
            (option.symbol, option.symbol == "nasdaq" ? 25 : 0)
        })
    }()
    static let dcaAssetOptions: [BacktestAssetOption] = [
        .init(symbol: "gold_cny", title: AppLocalization.string("黄金"), color: AssetTheme.gold, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "sp500", title: AppLocalization.string("标普500"), color: AssetTheme.goldSoft, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "nasdaq", title: AppLocalization.string("纳指"), color: AssetTheme.accentBlue, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "dowjones", title: AppLocalization.string("道指"), color: AssetTheme.accentOrange, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "hsi", title: AppLocalization.string("恒生"), color: AssetTheme.accentRed, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "nikkei", title: AppLocalization.string("日经225"), color: AssetTheme.positive, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "csi300", title: AppLocalization.string("沪深300"), color: AssetTheme.textPrimary, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "shanghai_composite", title: AppLocalization.string("上证综指"), color: AssetTheme.textSecondary, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "shenzhen_component", title: AppLocalization.string("深成指"), color: AssetTheme.accentRed, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "chinext", title: AppLocalization.string("创业板"), color: AssetTheme.positive, requiresHistoricalFX: false, historicalFXSymbol: nil),
        .init(symbol: "usd_cash", title: AppLocalization.string("美元现金"), color: AssetTheme.textSecondary, requiresHistoricalFX: false, historicalFXSymbol: nil),
    ]
    static let strategySleeveAssetOptions: [BacktestAssetOption] = [
        .init(symbol: "qmnrx", title: AppLocalization.string("QMNRX"), color: AssetTheme.accentBlue, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "ostix", title: AppLocalization.string("OSTIX"), color: AssetTheme.textSecondary, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "vmnfx", title: AppLocalization.string("VMNFX"), color: AssetTheme.positive, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
        .init(symbol: "bprrx", title: AppLocalization.string("BPRRX"), color: AssetTheme.accentOrange, requiresHistoricalFX: true, historicalFXSymbol: "usd_per_cny"),
    ]
    static let strategyAssetOptions: [BacktestAssetOption] = dcaAssetOptions + strategySleeveAssetOptions

    static func strategyColor(for symbol: String) -> Color {
        strategyAssetOptions.first(where: { $0.symbol == symbol })?.color ?? AssetTheme.gold
    }
}

enum StrategyNotificationDefaults {
    static let defaultTemplateID = "core-gold-satellite-heat-capped-momentum"
    static let defaultHour = 9

    static var eligibleTemplates: [AdvancedBacktestStrategyTemplate] {
        AdvancedBacktestStrategyTemplate.all.filter { $0.mode.isRotation }
    }

    static func template(for id: String) -> AdvancedBacktestStrategyTemplate? {
        eligibleTemplates.first { $0.id == id } ?? eligibleTemplates.first { $0.id == defaultTemplateID } ?? eligibleTemplates.first
    }

    static func assetOptions(for template: AdvancedBacktestStrategyTemplate) -> [BacktestAssetOption] {
        var selectedSymbols = Set(template.selectedAssetSymbols ?? BacktestDefaults.dcaAssetOptions.map(\.symbol))
        selectedSymbols.formUnion(template.mode.requiredSignalAssetSymbols)
        let options = BacktestDefaults.strategyAssetOptions.filter { selectedSymbols.contains($0.symbol) }
        return options.isEmpty ? BacktestDefaults.dcaAssetOptions : options
    }
}

@MainActor
enum StrategyNotificationContentBuilder {
    static func body(advice: StrategyRebalanceAdvice, actions: [StrategyRebalanceAction]) -> String {
        if advice.isCashDefense || actions.isEmpty {
            return AppLocalization.format(
                "目标现金防守；信号截至 %@，建议下一交易日执行。",
                advice.asOfDate.recordDateString
            )
        }

        let actionable = actions.filter { action in
            switch action.kind {
            case .buy, .sell, .missingRecord:
                return true
            case .hold, .targetOnly:
                return false
            }
        }

        let source = actionable.isEmpty ? Array(actions.prefix(2)) : Array(actionable.prefix(2))
        let summary = source.map(actionSummary).joined(separator: "；")
        let suffix: String
        if actionable.isEmpty {
            suffix = AppLocalization.string("偏离不大，今日可保持。")
        } else if actions.count > source.count {
            suffix = AppLocalization.format("另有%d项。", actions.count - source.count)
        } else {
            suffix = ""
        }

        if suffix.isEmpty {
            return AppLocalization.format("%@。信号截至 %@，建议下一交易日执行。", summary, advice.asOfDate.recordDateString)
        }
        return AppLocalization.format("%@；%@ 信号截至 %@，建议下一交易日执行。", summary, suffix, advice.asOfDate.recordDateString)
    }

    static func preview(template: AdvancedBacktestStrategyTemplate, advice: StrategyRebalanceAdvice?, actions: [StrategyRebalanceAction]) -> String {
        guard let advice else {
            return AppLocalization.format("%@ · 等待历史行情后生成今日调仓", template.title)
        }
        return body(advice: advice, actions: actions)
    }

    private static func actionSummary(_ action: StrategyRebalanceAction) -> String {
        switch action.kind {
        case .buy:
            return AppLocalization.format("%@买入%@", action.title, abs(action.deltaAmount ?? 0).currencyString())
        case .sell:
            return AppLocalization.format("%@卖出%@", action.title, abs(action.deltaAmount ?? 0).currencyString())
        case .missingRecord:
            if let targetAmount = action.targetAmount {
                return AppLocalization.format("%@未记录，目标%@", action.title, targetAmount.currencyString())
            }
            return AppLocalization.format("%@未记录，目标%@", action.title, action.targetWeight.percentString(maxFractionDigits: 1))
        case .hold:
            return AppLocalization.format("%@保持%@", action.title, action.targetWeight.percentString(maxFractionDigits: 1))
        case .targetOnly:
            return AppLocalization.format("%@目标%@", action.title, action.targetWeight.percentString(maxFractionDigits: 1))
        }
    }
}
