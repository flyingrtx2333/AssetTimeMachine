import SwiftUI
import SwiftData
import Charts
import UIKit

struct BacktestModeEntryPanel: View {
    let onStart: (BacktestRecordKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(BacktestRecordKind.allCases.enumerated()), id: \.element.rawValue) { index, kind in
                    Button {
                        onStart(kind)
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: kind.entryIconName)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AssetTheme.gold)
                                .frame(height: 20)

                            Text(kind.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AssetTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < BacktestRecordKind.allCases.count - 1 {
                        Divider()
                            .overlay(AssetTheme.border.opacity(0.55))
                            .frame(height: 54)
                    }
                }
            }
            .background(AssetTheme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.62), lineWidth: 1)
            )
        }
    }
}

struct BacktestReturnHeader: View {
    let title: String
    var trailingTitle: String? = nil
    var trailingSystemImage: String? = nil
    var onTrailingAction: (() -> Void)? = nil
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                    Text(AppLocalization.string("记录"))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(AssetTheme.gold)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(AssetTheme.gold.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let trailingTitle, let onTrailingAction {
                Button(action: onTrailingAction) {
                    HStack(spacing: 6) {
                        if let trailingSystemImage {
                            Image(systemName: trailingSystemImage)
                                .font(.caption.weight(.bold))
                        }
                        Text(trailingTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(AssetTheme.textPrimary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 11)
                    .background(AssetTheme.overlaySubtle, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }
}

enum BacktestHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case allocation
    case dca
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return AppLocalization.string("全部")
        case .allocation:
            return BacktestRecordKind.allocation.title
        case .dca:
            return BacktestRecordKind.dca.title
        case .advanced:
            return BacktestRecordKind.advanced.title
        }
    }

    var iconName: String {
        switch self {
        case .all:
            return "tray.full"
        case .allocation:
            return BacktestRecordKind.allocation.entryIconName
        case .dca:
            return BacktestRecordKind.dca.entryIconName
        case .advanced:
            return BacktestRecordKind.advanced.entryIconName
        }
    }

    private var kind: BacktestRecordKind? {
        switch self {
        case .all:
            return nil
        case .allocation:
            return .allocation
        case .dca:
            return .dca
        case .advanced:
            return .advanced
        }
    }

    func includes(_ record: BacktestRecord) -> Bool {
        guard let kind else { return true }
        return BacktestRecordCodec.kind(for: record) == kind
    }
}

struct BacktestHistorySectionHeader: View {
    @Binding var selectedFilter: BacktestHistoryFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(AssetTheme.border.opacity(0.48))
                .frame(height: 1)

            HStack(alignment: .center, spacing: 12) {
                Text(AppLocalization.string("记录"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 12)

                Menu {
                    ForEach(BacktestHistoryFilter.allCases) { filter in
                        Button {
                            selectedFilter = filter
                        } label: {
                            Label(filter.title, systemImage: selectedFilter == filter ? "checkmark" : filter.iconName)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.footnote.weight(.semibold))
                        Text(selectedFilter.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(AssetTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AssetTheme.overlaySoft, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}

struct BacktestEntryLoadingView: View {
    var body: some View {
        LoadingStateCard(title: AppLocalization.string("正在准备量化回测"))
    }
}

struct BacktestHomeView: View {
    let records: [BacktestRecord]
    let totalRecordCount: Int
    let onStart: (BacktestRecordKind) -> Void
    let onShowAllRecords: () -> Void
    let onSelect: (BacktestRecord) -> Void
    let onRestore: (BacktestRecord) -> Void
    let onDelete: (BacktestRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BacktestModeEntryPanel(onStart: onStart)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalization.string("最近回测"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                    Text(totalRecordCount > 0 ? AppLocalization.format("共%d条记录", totalRecordCount) : AppLocalization.string("保存后的回测会出现在这里"))
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                }

                Spacer(minLength: 12)

                Button(action: onShowAllRecords) {
                    HStack(spacing: 6) {
                        Text(AppLocalization.string("全部回测记录"))
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(AssetTheme.gold)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(AssetTheme.gold.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)

            if records.isEmpty {
                BacktestHistoryEmptyCard(title: AppLocalization.string("还没有回测记录"), iconName: "tray")
            } else {
                BacktestRecordListCard(
                    records: records,
                    onSelect: onSelect,
                    onRestore: onRestore,
                    onDelete: onDelete
                )
            }
        }
    }
}

struct BacktestAllRecordsView: View {
    let records: [BacktestRecord]
    let onSelect: (BacktestRecord) -> Void
    let onRestore: (BacktestRecord) -> Void
    let onDelete: (BacktestRecord) -> Void

    @State private var selectedFilter: BacktestHistoryFilter = .all

    private var filteredRecords: [BacktestRecord] {
        records.filter { selectedFilter.includes($0) }
    }

    private var emptyTitle: String {
        guard !records.isEmpty else { return AppLocalization.string("还没有回测记录") }
        return AppLocalization.format("暂无%@记录", selectedFilter.title)
    }

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    BacktestHistorySectionHeader(selectedFilter: $selectedFilter)

                    if filteredRecords.isEmpty {
                        BacktestHistoryEmptyCard(
                            title: emptyTitle,
                            iconName: records.isEmpty ? "tray" : "line.3.horizontal.decrease.circle"
                        )
                    } else {
                        BacktestRecordListCard(
                            records: filteredRecords,
                            showsDetailedContext: true,
                            onSelect: onSelect,
                            onRestore: onRestore,
                            onDelete: onDelete
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(AppLocalization.string("全部回测记录"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }
}

struct BacktestAllRecordsContainer: View {
    @Query(sort: \BacktestRecord.createdAt, order: .reverse) private var records: [BacktestRecord]
    let onSelect: (BacktestRecord) -> Void
    let onRestore: (BacktestRecord) -> Void
    let onDelete: (BacktestRecord) -> Void

    var body: some View {
        BacktestAllRecordsView(
            records: records,
            onSelect: onSelect,
            onRestore: onRestore,
            onDelete: onDelete
        )
    }
}

struct BacktestHistoryEmptyCard: View {
    let title: String
    let iconName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: iconName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(AssetTheme.gold)
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(AssetTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
        )
    }
}

struct BacktestRecordListCard: View {
    let records: [BacktestRecord]
    var showsDetailedContext: Bool = false
    let onSelect: (BacktestRecord) -> Void
    let onRestore: (BacktestRecord) -> Void
    let onDelete: (BacktestRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                BacktestHistoryRow(
                    record: record,
                    showsDetailedContext: showsDetailedContext,
                    onSelect: { onSelect(record) },
                    onRestore: { onRestore(record) },
                    onDelete: { onDelete(record) }
                )

                if index < records.count - 1 {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.55))
                        .padding(.leading, 18)
                }
            }
        }
        .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
        )
    }
}

struct BacktestHistoryRow: View {
    let record: BacktestRecord
    var showsDetailedContext: Bool = false
    let onSelect: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDeleteRevealed = false

    private let deleteActionWidth: CGFloat = 86

    private var kind: BacktestRecordKind {
        BacktestRecordCodec.kind(for: record)
    }

    private var iconName: String {
        switch kind {
        case .allocation:
            return "chart.pie.fill"
        case .dca:
            return "calendar.badge.plus"
        case .advanced:
            return "slider.horizontal.3"
        }
    }

    private var annualizedReturnText: String {
        record.annualizedReturn?.percentString() ?? "--"
    }

    private var annualizedReturnColor: Color {
        guard let annualizedReturn = record.annualizedReturn else { return AssetTheme.textPrimary }
        return annualizedReturn >= 0 ? AssetTheme.positive : AssetTheme.negative
    }

    private var sharpeRatioText: String {
        record.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--"
    }

    private var displaySubtitle: String {
        if showsDetailedContext {
            switch kind {
            case .allocation, .dca:
                return record.configSummary.isEmpty ? record.title : record.configSummary
            case .advanced:
                return advancedStrategyDisplayName()
            }
        }

        switch kind {
        case .advanced:
            return advancedStrategyDisplayName()
        case .allocation, .dca:
            return record.title
        }
    }

    private var extraSubtitleLine: String? {
        guard showsDetailedContext, kind == .advanced else { return nil }
        guard let startDate = record.startDate, let endDate = record.endDate else { return nil }
        return AppLocalization.format("回测区间 %@", "\(startDate.recordDateString) - \(endDate.recordDateString)")
    }

    private func advancedStrategyDisplayName() -> String {
        let summaryLead = record.configSummary
            .split(separator: "·", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        if let summaryLead, !summaryLead.isEmpty {
            return summaryLead
        }

        if !record.subtitle.isEmpty,
           !record.subtitle.contains("·") {
            return record.subtitle
        }

        return AdvancedBacktestStrategyMode.ruleBased.title
    }

    private var currentHorizontalOffset: CGFloat {
        let baseOffset = isDeleteRevealed ? -deleteActionWidth : 0
        return min(0, max(-deleteActionWidth, baseOffset + dragOffset))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                withAnimation(.snappy(duration: 0.22)) {
                    isDeleteRevealed = false
                    dragOffset = 0
                }
                onDelete()
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "trash.fill")
                        .font(.subheadline.weight(.bold))
                    Text(AppLocalization.string("删除"))
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(width: deleteActionWidth)
                .frame(maxHeight: .infinity)
                .background(AssetTheme.negative)
            }
            .buttonStyle(.plain)
            .opacity(currentHorizontalOffset < -8 ? 1 : 0)

            rowButton
                .offset(x: currentHorizontalOffset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 14, coordinateSpace: .local)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            dragOffset = value.translation.width
                        }
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else {
                                dragOffset = 0
                                return
                            }
                            let predictedOffset = (isDeleteRevealed ? -deleteActionWidth : 0) + value.predictedEndTranslation.width
                            withAnimation(.snappy(duration: 0.22)) {
                                isDeleteRevealed = predictedOffset < -deleteActionWidth * 0.42
                                dragOffset = 0
                            }
                        }
                )
        }
        .contentShape(Rectangle())
        .clipped()
        .animation(.snappy(duration: 0.22), value: isDeleteRevealed)
        .contextMenu {
            Button(AppLocalization.string("恢复参数"), systemImage: "arrow.uturn.backward") {
                onRestore()
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(AppLocalization.string("删除记录"), systemImage: "trash")
            }
        }
    }

    private var rowButton: some View {
        Button {
            if isDeleteRevealed {
                withAnimation(.snappy(duration: 0.22)) {
                    isDeleteRevealed = false
                    dragOffset = 0
                }
            } else {
                onSelect()
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AssetTheme.gold)
                    .frame(width: 32, height: 32)
                    .background(AssetTheme.gold.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(record.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AssetTheme.textPrimary)
                            .lineLimit(1)
                        Text(record.createdAt.recordDateString)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                    }

                    Text(displaySubtitle)
                        .font(.caption2)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                        .lineLimit(1)

                    if let extraSubtitleLine {
                        Text(extraSubtitleLine)
                            .font(.caption2)
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.62))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 10)

                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 4) {
                        historyMetricLine(
                            title: AppLocalization.string("平均年化"),
                            value: annualizedReturnText,
                            valueColor: annualizedReturnColor
                        )
                        historyMetricLine(
                            title: AppLocalization.string("最大回撤"),
                            value: record.maxDrawdown.percentString(),
                            valueColor: AssetTheme.negative
                        )
                        historyMetricLine(
                            title: AppLocalization.string("夏普"),
                            value: sharpeRatioText,
                            valueColor: AssetTheme.textPrimary
                        )
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func historyMetricLine(title: String, value: String, valueColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
            Text(value)
                .font(.caption2.weight(.bold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
        .lineLimit(1)
    }
}

private struct BacktestRecordDetailCache {
    var advancedReport: AdvancedBacktestReport?
    var comparisonSeries: [BacktestChartComparisonSeries] = []
    var executionAssumptionText: String = ""
    var strategyMode: AdvancedBacktestStrategyMode = .ruleBased
    var standardPoints: [BacktestSeriesPoint] = []
}

struct BacktestRecordDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let record: BacktestRecord
    let onRestore: (BacktestRecord) -> Void
    let onDelete: (BacktestRecord) -> Void

    @State private var detailCache = BacktestRecordDetailCache()

    private var kind: BacktestRecordKind {
        BacktestRecordCodec.kind(for: record)
    }

    private var canRestore: Bool {
        BacktestRecordCodec.decodeConfig(from: record) != nil
    }

    private var displayTitle: String {
        if kind == .advanced, !record.subtitle.isEmpty {
            return AppLocalization.format("%@-%@", record.title, record.subtitle)
        }
        return record.title
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(displayTitle)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(AssetTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if kind == .advanced, let report = detailCache.advancedReport {
                        AdvancedBacktestResultContent(
                            report: report,
                            comparisonSeries: detailCache.comparisonSeries,
                            executionAssumptionText: detailCache.executionAssumptionText,
                            strategyMode: detailCache.strategyMode,
                            showsRebalanceAdvice: false,
                            showsSupplementalRows: true
                        ) {
                            EmptyView()
                        }
                    } else if kind != .advanced {
                        standardRecordContent
                    }

                    recordActions
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
            .background(AssetTheme.background.ignoresSafeArea())
            .navigationTitle(AppLocalization.string("记录详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                }
            }
        }
        .task(id: record.id) {
            loadDetailCache()
        }
    }

    @MainActor
    private func loadDetailCache() {
        var cache = BacktestRecordDetailCache()
        if kind == .advanced, let report = BacktestRecordCodec.advancedReport(from: record) {
            cache.advancedReport = report
            cache.comparisonSeries = AdvancedBacktestPresentation.comparisonSeries(from: report)
            cache.executionAssumptionText = BacktestRecordCodec.executionAssumptionText(from: record)
            if let config = BacktestRecordCodec.decodeConfig(from: record) {
                cache.strategyMode = config.strategyModeRawValue
                    .flatMap(AdvancedBacktestStrategyMode.init(rawValue:)) ?? .ruleBased
            }
        } else {
            cache.standardPoints = BacktestRecordCodec.decodePoints(from: record)
        }
        detailCache = cache
    }

    @ViewBuilder
    private var standardRecordContent: some View {
        let points = detailCache.standardPoints

        detailPanel {
            if points.isEmpty {
                Text(AppLocalization.string("这条记录没有可展示的曲线快照。"))
                    .font(.subheadline)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                BacktestValueChartSection(
                    points: points,
                    valueStyle: kind.chartValueStyle
                )
            }
        }

        detailPanel {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                BacktestMetricCard(title: AppLocalization.string("总收益"), value: record.totalReturn.percentString(), accent: record.totalReturn >= 0 ? AssetTheme.positive : AssetTheme.negative)
                BacktestMetricCard(title: AppLocalization.string("年化收益"), value: record.annualizedReturn?.percentString() ?? "--")
                BacktestMetricCard(title: AppLocalization.string("最大回撤"), value: record.maxDrawdown.percentString(), accent: AssetTheme.negative)
                BacktestMetricCard(title: AppLocalization.string("夏普比率"), value: record.sharpeRatio.map { String(format: "%.2f", $0) } ?? "--")
                BacktestMetricCard(title: AppLocalization.string("期末资产"), value: record.finalValue?.currencyString() ?? "--")
                BacktestMetricCard(title: AppLocalization.string("交易次数"), value: record.tradeCount > 0 ? AppLocalization.format("%d次", record.tradeCount) : "--")
            }
        }

        detailPanel {
            VStack(alignment: .leading, spacing: 12) {
                detailLine(title: AppLocalization.string("保存时间"), value: record.createdAt.longDateString)
                detailLine(title: AppLocalization.string("回测区间"), value: rangeText)
                detailLine(title: AppLocalization.string("策略参数"), value: record.configSummary)
                if let totalInvested = record.totalInvested {
                    detailLine(title: AppLocalization.string("投入/本金"), value: totalInvested.currencyString())
                }
                if let profitLoss = record.profitLoss {
                    detailLine(title: AppLocalization.string("盈亏"), value: profitLoss.currencyString())
                }
            }
        }
    }

    private var recordActions: some View {
        HStack(spacing: 12) {
            Button {
                onRestore(record)
            } label: {
                Label(AppLocalization.string("恢复参数"), systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AssetTheme.gold)
            .disabled(!canRestore)

            Button(role: .destructive) {
                onDelete(record)
            } label: {
                Label(AppLocalization.string("删除"), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var rangeText: String {
        guard let startDate = record.startDate, let endDate = record.endDate else { return "--" }
        return "\(startDate.recordDateString) - \(endDate.recordDateString)"
    }

    private func detailPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(16)
        .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
        )
    }

    private func detailLine(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AssetTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
