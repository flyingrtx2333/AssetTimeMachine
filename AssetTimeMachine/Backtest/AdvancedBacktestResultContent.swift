import SwiftUI
import SwiftData
import Charts
import UIKit

enum AdvancedBacktestPresentation {
    nonisolated static func comparisonSeries(from report: AdvancedBacktestReport) -> [BacktestChartComparisonSeries] {
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
                BacktestChartData.sampledPoints(from: series.points),
                targetStartValue: report.points.first?.portfolioValue
            )
            guard !points.isEmpty else { return nil }
            return BacktestChartComparisonSeries(
                id: BacktestChartSeriesKey.assetBenchmark(series.id),
                title: series.title,
                points: points,
                color: BacktestChartPalette.comparisonLine(at: index)
            )
        }
    }
}

private struct AdvancedBacktestTradeEvent: Identifiable {
    let id: String
    let date: Date
    var trades: [AdvancedBacktestTrade]
}

struct AdvancedBacktestResultPresentation: Identifiable {
    let id = UUID()
    let title: String
    let report: AdvancedBacktestReport
    let comparisonSeries: [BacktestChartComparisonSeries]
    let strategyMode: AdvancedBacktestStrategyMode
    var rebalanceAdvice: StrategyRebalanceAdvice? = nil
    var latestSnapshot: AssetSnapshot? = nil
    var selectedAssetOptions: [BacktestAssetOption]? = nil
    var showsRebalanceAdvice = true
    var record: BacktestRecord? = nil
}

struct AdvancedBacktestResultPage: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: AdvancedBacktestResultPresentation
    var onRestore: ((BacktestRecord) -> Void)? = nil
    var onDelete: ((BacktestRecord) -> Void)? = nil

    @State private var showsCashYieldSheet = false
    @State private var showsRiskSignalSheet = false
    @State private var showsSharePoster = false

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    pageHeader

                    AdvancedBacktestResultContent(
                        report: presentation.report,
                        comparisonSeries: presentation.comparisonSeries,
                        strategyMode: presentation.strategyMode,
                        rebalanceAdvice: presentation.rebalanceAdvice,
                        latestSnapshot: presentation.latestSnapshot,
                        selectedAssetOptions: presentation.selectedAssetOptions,
                        showsRebalanceAdvice: presentation.showsRebalanceAdvice,
                        showsSupplementalRows: true,
                        onShowCashYield: { showsCashYieldSheet = true },
                        onShowRiskSignal: { showsRiskSignalSheet = true }
                    )

                    if let record = presentation.record {
                        recordActions(record)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, TabScrollLayout.sheetBottomPadding)
            }
        }
        .sheet(isPresented: $showsCashYieldSheet) {
            CashYieldDetailSheet(summary: presentation.report.cashYieldSummary)
                .presentationDetents([.fraction(0.58), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsRiskSignalSheet) {
            if let summary = presentation.report.riskSignalSummary {
                MarketRiskSignalDetailSheet(summary: summary)
                    .presentationDetents([.fraction(0.62), .large])
                    .presentationDragIndicator(.visible)
                }
        }
        .sheet(isPresented: $showsSharePoster) {
            BacktestPosterPreviewSheet(
                title: presentation.title,
                report: presentation.report,
                comparisonSeries: presentation.comparisonSeries
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var pageHeader: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.gold)
                    .frame(width: 36, height: 36)
                    .background(AssetTheme.gold.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("返回"))

            Text(presentation.title)
                .font(AppTypography.blockTitle)
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 0)

            Button {
                showsSharePoster = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.gold)
                    .frame(width: 36, height: 36)
                    .background(AssetTheme.gold.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("分享"))
        }
    }

    private func recordActions(_ record: BacktestRecord) -> some View {
        HStack(spacing: 12) {
            if let onRestore {
                Button {
                    onRestore(record)
                    dismiss()
                } label: {
                    Label(AppLocalization.string("恢复参数"), systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AssetTheme.gold)
                .disabled(BacktestRecordCodec.decodeConfig(from: record) == nil)
            }

            if let onDelete {
                Button(role: .destructive) {
                    onDelete(record)
                    dismiss()
                } label: {
                    Label(AppLocalization.string("删除"), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct AdvancedBacktestResultContent: View {
    let report: AdvancedBacktestReport
    let comparisonSeries: [BacktestChartComparisonSeries]
    var strategyMode: AdvancedBacktestStrategyMode = .ruleBased
    var rebalanceAdvice: StrategyRebalanceAdvice? = nil
    var latestSnapshot: AssetSnapshot? = nil
    var selectedAssetOptions: [BacktestAssetOption]? = nil
    var showsRebalanceAdvice: Bool = true
    var showsSupplementalRows: Bool = true
    var onShowCashYield: (() -> Void)? = nil
    var onShowRiskSignal: (() -> Void)? = nil

    @State private var showsAllRecentTrades = false

    private var assetOptions: [BacktestAssetOption] {
        BacktestDefaults.dcaAssetOptions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            resultSection
            tradeSection
        }
    }

    private var resultSection: some View {
        let benchmarkMetricTitle = report.benchmarkSeries.count == 1
            ? (report.benchmarkSeries.first?.title ?? AppLocalization.string("资产基准"))
            : AppLocalization.string("资产基准")

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 16) {
                if !report.exposurePoints.isEmpty {
                    AdvancedBacktestCombinedChartSection(
                        points: report.points,
                        comparisonSeries: comparisonSeries,
                        exposurePoints: report.exposurePoints,
                        assetExposureSeries: report.assetExposureSeries,
                        averageExposureRatio: report.averageExposureRatio
                    )
                } else {
                    BacktestValueChartSection(
                        points: report.points,
                        comparisonSeries: comparisonSeries,
                        valueStyle: .currency(code: "CNY")
                    )
                }

                Divider()
                    .overlay(AssetTheme.border.opacity(0.6))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    compactMetric(title: AppLocalization.string("期末资产"), value: report.finalPortfolioValue.currencyString())
                    compactMetric(title: AppLocalization.string("盈亏"), value: report.profitLoss.currencyString(), accent: report.profitLoss >= 0 ? AssetTheme.positive : AssetTheme.negative)
                    compactMetric(title: AppLocalization.string("策略收益"), value: report.totalReturn.percentString(), accent: report.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
                    compactMetric(title: benchmarkMetricTitle, value: report.benchmarkTotalReturn?.percentString() ?? "--")
                    compactMetric(title: AppLocalization.string("超额收益"), value: report.excessReturn?.percentString() ?? "--", accent: (report.excessReturn ?? 0) >= 0 ? AssetTheme.positive : AssetTheme.negative)
                    compactMetric(title: AppLocalization.string("年化收益"), value: report.annualizedReturn?.percentString() ?? "--")
                    compactMetric(title: AppLocalization.string("最大回撤"), value: report.maxDrawdown.percentString(), accent: AssetTheme.negative)
                    compactMetric(title: AppLocalization.string("年化波动"), value: report.annualizedVolatility?.percentString() ?? "--")
                    compactMetric(title: AppLocalization.string("夏普比率"), value: report.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                    compactMetric(title: AppLocalization.string("回撤收益比"), subtitle: AppLocalization.string("Calmar"), value: report.calmarRatio.map { String(format: "%.2f", $0) } ?? "--")
                    compactMetric(title: AppLocalization.string("平均仓位"), value: report.averageExposureRatio.percentString())
                    compactMetric(title: AppLocalization.string("交易次数"), value: AppLocalization.format("买%d · 卖%d", report.buyCount, report.sellCount))
                    compactMetric(
                        title: AppLocalization.string("胜率"),
                        subtitle: report.completedTradeCount > 0 ? AppLocalization.format("赢%d / 平仓%d", report.winningTradeCount, report.completedTradeCount) : nil,
                        value: report.winRate?.percentString(maxFractionDigits: 0) ?? "--",
                        accent: (report.winRate ?? 0) >= 0.5 ? AssetTheme.positive : AssetTheme.textPrimary
                    )
                    compactMetric(title: AppLocalization.string("剩余现金"), value: report.finalCash.currencyString())
                }

                if showsRebalanceAdvice {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.6))

                    rebalanceAdviceSection(rebalanceAdvice)
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
        }
    }

    private func compactMetric(
        title: String,
        subtitle: String? = nil,
        value: String,
        accent: Color = AssetTheme.gold
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(AppTypography.chartCaptionStrong)
                    .foregroundStyle(AssetTheme.textSecondary)
                if let subtitle {
                    Text(subtitle)
                        .font(AppTypography.chartCaption)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.68))
                }
            }
            .lineLimit(1)

            Text(value)
                .font(AppTypography.metaStrong.monospacedDigit())
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
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
                    Text(AppLocalization.string("当前行情或策略计算尚未完成，暂时无法生成目标仓位。"))
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

        if advice.lookbackSessions <= 0 {
            return basePrefix + AppLocalization.string("按最新策略状态生成目标仓位。")
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

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(assetReport.title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)
                Text(AppLocalization.format("买%d · 卖%d", assetReport.buyCount, assetReport.sellCount))
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
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(AppLocalization.string("最近交易"))

            advancedPanel {
                if report.trades.isEmpty {
                    Text(AppLocalization.string("暂无成交"))
                        .font(AppTypography.body)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if strategyMode.isRotation {
                        rotationTradeList
                    } else {
                        ruleBasedTradeList
                    }

                    if hasMoreRecentTrades {
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

    private var rotationTradeEvents: [AdvancedBacktestTradeEvent] {
        var events: [AdvancedBacktestTradeEvent] = []
        for trade in report.trades {
            let eventID = trade.date.recordDateString
            if events.last?.id == eventID {
                events[events.count - 1].trades.append(trade)
            } else {
                events.append(
                    AdvancedBacktestTradeEvent(
                        id: eventID,
                        date: trade.date,
                        trades: [trade]
                    )
                )
            }
        }
        return Array(events.reversed())
    }

    private var displayedRotationTradeEvents: [AdvancedBacktestTradeEvent] {
        showsAllRecentTrades ? rotationTradeEvents : Array(rotationTradeEvents.prefix(3))
    }

    private var displayedRuleBasedTrades: [AdvancedBacktestTrade] {
        showsAllRecentTrades
            ? Array(report.trades.reversed())
            : Array(report.trades.suffix(6).reversed())
    }

    private var hasMoreRecentTrades: Bool {
        strategyMode.isRotation
            ? rotationTradeEvents.count > 3
            : report.trades.count > 6
    }

    private var rotationTradeList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displayedRotationTradeEvents.enumerated()), id: \.element.id) { eventIndex, event in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(AppLocalization.format("%@调仓", strategyMode.title))
                            .font(AppTypography.metaStrong)
                            .foregroundStyle(AssetTheme.textPrimary)

                        Spacer(minLength: 8)

                        Text(event.date.shortDateString)
                            .font(AppTypography.chartCaption)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                    .padding(.bottom, 5)

                    ForEach(Array(event.trades.enumerated()), id: \.element.id) { tradeIndex, trade in
                        tradeRow(
                            trade,
                            actionTitle: rotationActionTitle(for: trade),
                            detailText: "\(trade.assetTitle) · \(trade.price.currencyString())",
                            noteText: nil
                        )

                        if tradeIndex < event.trades.count - 1 {
                            Divider()
                                .overlay(AssetTheme.border.opacity(0.42))
                        }
                    }
                }

                if eventIndex < displayedRotationTradeEvents.count - 1 {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.72))
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private var ruleBasedTradeList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(displayedRuleBasedTrades.enumerated()), id: \.element.id) { index, trade in
                tradeRow(
                    trade,
                    actionTitle: trade.action.title,
                    detailText: "\(trade.assetTitle) · \(trade.date.shortDateString) · \(trade.price.currencyString())",
                    noteText: trade.reason.isEmpty ? nil : AppLocalization.format("触发：%@", trade.reason)
                )

                if index < displayedRuleBasedTrades.count - 1 {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.6))
                }
            }
        }
    }

    private func tradeRow(
        _ trade: AdvancedBacktestTrade,
        actionTitle: String,
        detailText: String,
        noteText: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(actionTitle)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(trade.action.accent)
                Text(detailText)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
                if let noteText {
                    Text(noteText)
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
    }

    private func rotationActionTitle(for trade: AdvancedBacktestTrade) -> String {
        guard trade.action == .sell else {
            return AppLocalization.string("买入")
        }
        return isRotationExit(trade)
            ? AppLocalization.string("退出持仓")
            : AppLocalization.string("减仓")
    }

    private func isRotationExit(_ trade: AdvancedBacktestTrade) -> Bool {
        let normalizedReason = trade.reason.lowercased()
        return trade.reason.contains("空仓")
            || trade.reason.contains("退出")
            || normalizedReason.contains("exit")
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
