import SwiftUI
import SwiftData
import Charts
import UIKit

enum AdvancedBacktestPresentation {
    static func comparisonSeries(from report: AdvancedBacktestReport) -> [BacktestChartComparisonSeries] {
        let sourceSeries: [AdvancedBacktestBenchmarkSeries]
        if !report.benchmarkSeries.isEmpty {
            sourceSeries = report.benchmarkSeries
        } else {
            sourceSeries = report.assetReports.map {
                AdvancedBacktestBenchmarkSeries(id: $0.symbol, title: $0.title, points: $0.benchmarkPoints)
            }
        }

        return sourceSeries.enumerated().compactMap { index, series in
            let points = BacktestChartData.normalizedComparisonPoints(
                series.points,
                targetStartValue: report.points.first?.portfolioValue
            )
            guard !points.isEmpty else { return nil }
            return BacktestChartComparisonSeries(
                id: "asset-benchmark-\(series.id)",
                title: series.title,
                points: points,
                color: BacktestChartPalette.comparisonLine(at: index)
            )
        }
    }
}

struct AdvancedBacktestResultContent<MiddleContent: View>: View {
    let report: AdvancedBacktestReport
    let comparisonSeries: [BacktestChartComparisonSeries]
    let executionAssumptionText: String
    var strategyMode: AdvancedBacktestStrategyMode = .ruleBased
    var rebalanceAdvice: StrategyRebalanceAdvice? = nil
    var latestSnapshot: AssetSnapshot? = nil
    var selectedAssetOptions: [BacktestAssetOption]? = nil
    var showsRebalanceAdvice: Bool = true
    var showsSupplementalRows: Bool = true
    var onShowCashYield: (() -> Void)? = nil
    var onShowRiskSignal: (() -> Void)? = nil
    @ViewBuilder var middleContent: () -> MiddleContent

    @State private var showsAllRecentTrades = false

    private var assetOptions: [BacktestAssetOption] {
        BacktestDefaults.dcaAssetOptions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            resultSection
            middleContent()
            tradeSection
        }
    }

    private var resultSection: some View {
        let benchmarkMetricTitle = report.benchmarkSeries.count == 1
            ? (report.benchmarkSeries.first?.title ?? AppLocalization.string("资产基准"))
            : AppLocalization.string("资产基准")

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 16) {
                BacktestValueChartSection(
                    points: report.points,
                    comparisonSeries: comparisonSeries,
                    valueStyle: .currency(code: "CNY"),
                    footnote: executionAssumptionText
                )

                if showsRebalanceAdvice {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.6))

                    rebalanceAdviceSection(rebalanceAdvice)

                    Divider()
                        .overlay(AssetTheme.border.opacity(0.6))
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    BacktestMetricCard(title: AppLocalization.string("期末资产"), value: report.finalPortfolioValue.currencyString())
                    BacktestMetricCard(title: AppLocalization.string("盈亏"), value: report.profitLoss.currencyString(), accent: report.profitLoss >= 0 ? AssetTheme.positive : AssetTheme.negative)
                    BacktestMetricCard(title: AppLocalization.string("策略收益"), value: report.totalReturn.percentString(), accent: report.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
                    BacktestMetricCard(title: benchmarkMetricTitle, value: report.benchmarkTotalReturn?.percentString() ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("超额收益"), value: report.excessReturn?.percentString() ?? "--", accent: (report.excessReturn ?? 0) >= 0 ? AssetTheme.positive : AssetTheme.negative)
                    BacktestMetricCard(title: AppLocalization.string("年化收益"), value: report.annualizedReturn?.percentString() ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("最大回撤"), value: report.maxDrawdown.percentString(), accent: AssetTheme.negative)
                    BacktestMetricCard(title: AppLocalization.string("年化波动"), value: report.annualizedVolatility?.percentString() ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("夏普比率"), value: report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("回撤收益比"), subtitle: AppLocalization.string("Calmar"), value: report.calmarRatio.map { String(format: "%.2f", $0) } ?? "--")
                    BacktestMetricCard(title: AppLocalization.string("平均仓位"), value: report.averageExposureRatio.percentString())
                    BacktestMetricCard(title: AppLocalization.string("交易次数"), value: AppLocalization.format("买%d · 卖%d", report.buyCount, report.sellCount))
                    BacktestMetricCard(
                        title: AppLocalization.string("胜率"),
                        subtitle: report.completedTradeCount > 0 ? AppLocalization.format("赢%d / 平仓%d", report.winningTradeCount, report.completedTradeCount) : nil,
                        value: report.winRate?.percentString(maxFractionDigits: 0) ?? "--",
                        accent: (report.winRate ?? 0) >= 0.5 ? AssetTheme.positive : AssetTheme.textPrimary
                    )
                    BacktestMetricCard(title: AppLocalization.string("剩余现金"), value: report.finalCash.currencyString())
                }

                if showsSupplementalRows {
                    if report.cashYieldSummary.totalCashInterest > 0 || report.cashYieldSummary.averageCashRatio > 0 {
                        cashYieldInfoRow(report.cashYieldSummary)
                    }
                    if let riskSignalSummary = report.riskSignalSummary {
                        riskSignalInfoRow(riskSignalSummary)
                    }
                }

                if report.assetReports.count > 1 {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.6))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(AppLocalization.string("分资产结果"))
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(AssetTheme.textPrimary)

                        ForEach(report.assetReports) { assetReport in
                            assetReportRow(assetReport)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, -8)
        }
    }

    private func cashYieldInfoRow(_ summary: CashYieldSummary) -> some View {
        Button {
            onShowCashYield?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "banknote")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.gold)
                    .frame(width: 28, height: 28)
                    .background(AssetTheme.gold.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.string("现金收益按活期计息"))
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textPrimary)
                    Text(AppLocalization.format(
                        "现金利息%@ · 平均现金仓%@ · 最新年利率%@",
                        summary.totalCashInterest.currencyString(),
                        summary.averageCashRatio.percentString(maxFractionDigits: 1),
                        summary.latestAnnualRate.percentString(maxFractionDigits: 2)
                    ))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 10)

                Text(AppLocalization.string("明细"))
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AssetTheme.gold)

                Image(systemName: "chevron.right")
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.65))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func riskSignalInfoRow(_ summary: MarketRiskSignalSummary) -> some View {
        Button {
            onShowRiskSignal?()
        } label: {
            HStack(spacing: 10) {
                let latestLevel = summary.latestPoint?.level ?? .calm
                Image(systemName: "waveform.path.ecg")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(latestLevel.accent)
                    .frame(width: 28, height: 28)
                    .background(latestLevel.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.string("外部风险信号"))
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textPrimary)
                    Text(AppLocalization.format(
                        "当前%@ · 压力日%@ · 平均分%.0f",
                        latestLevel.title,
                        summary.stressSessionRatio.percentString(maxFractionDigits: 1),
                        summary.averageScore
                    ))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 10)

                Text(AppLocalization.string("明细"))
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(latestLevel.accent)

                Image(systemName: "chevron.right")
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.65))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func rebalanceAdviceSection(_ advice: StrategyRebalanceAdvice?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(AppLocalization.string("今日调仓建议"))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 12)

                Text(rebalanceAdviceTrailingText(advice))
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(strategyMode.isRotation ? AssetTheme.textSecondary : AssetTheme.accentOrange)
                    .lineLimit(1)
            }

            if strategyMode.isRotation {
                if let advice {
                    let actions = rebalanceActions(for: advice)

                    Text(rebalanceAdviceSummary(advice, actions: actions))
                        .font(AppTypography.meta)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        if actions.isEmpty {
                            rebalanceCashRow(
                                weight: 1,
                                title: AppLocalization.string("现金防守"),
                                detail: AppLocalization.string("当前没有资产满足策略条件")
                            )
                        } else {
                            ForEach(actions) { action in
                                rebalanceActionRow(action, lookbackSessions: advice.lookbackSessions)
                            }

                            if advice.cashWeight > 0.005 {
                                rebalanceCashRow(
                                    weight: advice.cashWeight,
                                    title: AppLocalization.string("现金/其他"),
                                    detail: AppLocalization.string("未投入部分保留为防守仓位")
                                )
                            }
                        }
                    }

                } else {
                    Text(AppLocalization.string("当前资产数据不足，暂时无法计算今日目标仓位。"))
                        .font(AppTypography.meta)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            } else {
                Text(AppLocalization.string("自定义策略暂不支持即时调仓建议；建议先使用策略大全里的轮动/长期策略。"))
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
            }
        }
    }

    private func rebalanceAdviceTrailingText(_ advice: StrategyRebalanceAdvice?) -> String {
        if let advice {
            return AppLocalization.format("信号截至 %@", advice.asOfDate.recordDateString)
        }
        return strategyMode.isRotation ? AppLocalization.string("等待数据") : AppLocalization.string("暂不支持")
    }

    private func rebalanceAdviceSummary(_ advice: StrategyRebalanceAdvice, actions: [StrategyRebalanceAction]) -> String {
        let basePrefix: String
        if let investmentBase = actions.compactMap(\.investmentBase).first, investmentBase > 0 {
            basePrefix = AppLocalization.format("按最新记录%@估算；", investmentBase.currencyString())
        } else if latestSnapshot == nil {
            basePrefix = AppLocalization.string("暂无资产记录；")
        } else {
            basePrefix = AppLocalization.string("当前记录缺少可投资资产；")
        }

        if advice.isCashDefense && actions.isEmpty {
            return basePrefix + AppLocalization.format(
                "%d日信号未通过，策略建议暂不投入。",
                advice.lookbackSessions
            )
        }

        if let targetAnnualVolatility = advice.targetAnnualVolatility {
            return basePrefix + AppLocalization.format(
                "目标投入 %@，现金 %@；按%d日信号、目标波动%@评估。",
                advice.totalTargetWeight.percentString(maxFractionDigits: 1),
                advice.cashWeight.percentString(maxFractionDigits: 1),
                advice.lookbackSessions,
                targetAnnualVolatility.percentString(maxFractionDigits: 1)
            )
        }

        return basePrefix + AppLocalization.format(
            "目标投入 %@，现金 %@；按%d日信号评估。",
            advice.totalTargetWeight.percentString(maxFractionDigits: 1),
            advice.cashWeight.percentString(maxFractionDigits: 1),
            advice.lookbackSessions
        )
    }

    private func rebalanceActionRow(_ action: StrategyRebalanceAction, lookbackSessions: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(BacktestDefaults.strategyColor(for: action.symbol))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(action.detailText(lookbackSessions: lookbackSessions))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(action.kind.title)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(action.kind.accent)

                Text(action.amountText)
                    .font(AppTypography.rowTitle.monospacedDigit())
                    .foregroundStyle(action.kind.accent)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func rebalanceCashRow(weight: Double, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .stroke(AssetTheme.textSecondary.opacity(0.55), lineWidth: 1.5)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(detail)
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(weight.percentString(maxFractionDigits: 1))
                .font(AppTypography.rowTitle.monospacedDigit())
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func rebalanceActions(for advice: StrategyRebalanceAdvice) -> [StrategyRebalanceAction] {
        StrategyRebalanceActionBuilder.actions(
            for: advice,
            snapshot: latestSnapshot,
            selectedAssetOptions: selectedAssetOptions ?? assetOptions,
            allAssetOptions: assetOptions
        )
    }

    private func assetReportRow(_ assetReport: AdvancedBacktestAssetReport) -> some View {
        let initialValue = assetReport.points.first?.portfolioValue ?? 0
        let assetReturn = initialValue > 0 ? (assetReport.finalPortfolioValue - initialValue) / initialValue : 0
        let tradeCounts = assetReport.trades.reduce(into: (buy: 0, sell: 0)) { counts, trade in
            switch trade.action {
            case .buy:
                counts.buy += 1
            case .sell:
                counts.sell += 1
            }
        }

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(assetReport.title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)
                Text(AppLocalization.format("买%d · 卖%d", tradeCounts.buy, tradeCounts.sell))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(assetReport.finalPortfolioValue.currencyString())
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)
                Text(assetReturn.percentString())
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(assetReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
            }
        }
        .padding(12)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var tradeSection: some View {
        let displayLimit = 6
        let displayedTrades = showsAllRecentTrades
            ? Array(report.trades.reversed())
            : Array(report.trades.suffix(displayLimit).reversed())
        let hasMoreTrades = report.trades.count > displayLimit

        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(AppLocalization.string("最近交易"))

            advancedPanel {
                if report.trades.isEmpty {
                    Text(AppLocalization.string("暂无成交"))
                        .font(AppTypography.body)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(displayedTrades.enumerated()), id: \.element.id) { index, trade in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trade.action.title)
                                    .font(AppTypography.rowTitle)
                                    .foregroundStyle(trade.action.accent)
                                Text("\(trade.assetTitle) · \(trade.date.shortDateString) · \(trade.price.currencyString())")
                                    .font(AppTypography.meta)
                                    .foregroundStyle(AssetTheme.textSecondary)
                                if !trade.reason.isEmpty {
                                    Text(AppLocalization.format("触发：%@", trade.reason))
                                        .font(AppTypography.chartCaption)
                                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.78))
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text((trade.action == .buy ? "-" : "+") + trade.cashAmount.currencyString())
                                    .font(AppTypography.rowTitle)
                                    .foregroundStyle(AssetTheme.textPrimary)
                                Text(AppLocalization.format("%@份", trade.units.plainNumberString()))
                                    .font(AppTypography.meta)
                                    .foregroundStyle(AssetTheme.textSecondary)
                                if let realizedProfit = trade.realizedProfit {
                                    Text("\(realizedProfit >= 0 ? "+" : "")\(realizedProfit.currencyString())")
                                        .font(AppTypography.chartAxisStrip)
                                        .foregroundStyle(realizedProfit >= 0 ? AssetTheme.positive : AssetTheme.negative)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if index < displayedTrades.count - 1 {
                            Divider()
                                .overlay(AssetTheme.border.opacity(0.6))
                        }
                    }

                    if hasMoreTrades {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showsAllRecentTrades.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(showsAllRecentTrades ? AppLocalization.string("收起") : AppLocalization.format("查看更多（共%d笔）", report.trades.count))
                                    .font(AppTypography.metaStrong)
                                Image(systemName: showsAllRecentTrades ? "chevron.up" : "chevron.down")
                                    .font(AppTypography.chartAxisStrip)
                            }
                            .foregroundStyle(AssetTheme.gold)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, trailing: String? = nil, trailingColor: Color = AssetTheme.textSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(AppTypography.blockTitleBold)
                .foregroundStyle(AssetTheme.textPrimary)
            Spacer()
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(trailingColor)
                    .lineLimit(1)
            }
        }
    }

    private func advancedPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AssetTheme.surface.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
        )
    }

}
