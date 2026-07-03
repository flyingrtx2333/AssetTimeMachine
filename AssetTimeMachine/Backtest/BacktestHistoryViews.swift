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
                                .font(AppTypography.blockTitle)
                                .foregroundStyle(AssetTheme.gold)
                                .frame(height: 20)

                            Text(kind.title)
                                .font(AppTypography.captionStrong)
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
                        .font(AppTypography.captionStrong)
                    Text(AppLocalization.string("记录"))
                        .font(AppTypography.rowTitle)
                }
                .foregroundStyle(AssetTheme.gold)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(AssetTheme.gold.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)

            Text(title)
                .font(AppTypography.blockTitle)
                .foregroundStyle(AssetTheme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let trailingTitle, let onTrailingAction {
                Button(action: onTrailingAction) {
                    HStack(spacing: 6) {
                        if let trailingSystemImage {
                            Image(systemName: trailingSystemImage)
                                .font(AppTypography.captionStrong)
                        }
                        Text(trailingTitle)
                            .font(AppTypography.rowTitle)
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
                    .font(AppTypography.blockTitleBold)
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
                            .font(AppTypography.metaStrong)
                        Text(selectedFilter.title)
                            .font(AppTypography.captionStrong)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(AppTypography.chartAxisStrip)
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
                        .font(AppTypography.blockTitleBold)
                        .foregroundStyle(AssetTheme.textPrimary)
                    Text(totalRecordCount > 0 ? AppLocalization.format("共%d条记录", totalRecordCount) : AppLocalization.string("保存后的回测会出现在这里"))
                        .font(AppTypography.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                }

                Spacer(minLength: 12)

                Button(action: onShowAllRecords) {
                    HStack(spacing: 6) {
                        Text(AppLocalization.string("全部回测记录"))
                            .font(AppTypography.captionStrong)
                        Image(systemName: "chevron.right")
                            .font(AppTypography.chartAxisStrip)
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
    let onDeleteMany: ([BacktestRecord]) -> Void

    @State private var selectedFilter: BacktestHistoryFilter = .all
    @State private var isManaging = false
    @State private var selectedRecordIDs: Set<UUID> = []
    @State private var showsFilterDeleteSheet = false
    @State private var showsDeleteSelectedConfirm = false

    private var filteredRecords: [BacktestRecord] {
        records.filter { selectedFilter.includes($0) }
    }

    private var selectedRecords: [BacktestRecord] {
        filteredRecords.filter { selectedRecordIDs.contains($0.id) }
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
                            isSelectionMode: isManaging,
                            selectedRecordIDs: selectedRecordIDs,
                            onSelect: onSelect,
                            onRestore: onRestore,
                            onDelete: onDelete,
                            onToggleSelection: toggleSelection(for:)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, isManaging ? 96 : 32)
            }
        }
        .navigationTitle(AppLocalization.string("全部回测记录"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isManaging {
                    HStack(spacing: 12) {
                        Button(AppLocalization.string("条件删除")) {
                            showsFilterDeleteSheet = true
                        }
                        .font(AppTypography.rowTitle)

                        Button(AppLocalization.string("完成")) {
                            exitManaging()
                        }
                        .font(AppTypography.rowTitle)
                    }
                } else if !records.isEmpty {
                    Button(AppLocalization.string("管理")) {
                        isManaging = true
                    }
                    .font(AppTypography.rowTitle)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isManaging {
                backtestBulkDeleteBar
            }
        }
        .sheet(isPresented: $showsFilterDeleteSheet) {
            BacktestRecordBulkDeleteSheet(
                records: filteredRecords,
                onDelete: { recordsToDelete in
                    onDeleteMany(recordsToDelete)
                    selectedRecordIDs.subtract(recordsToDelete.map(\.id))
                    if selectedRecordIDs.isEmpty && filteredRecords.isEmpty {
                        exitManaging()
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert(AppLocalization.string("删除选中记录？"), isPresented: $showsDeleteSelectedConfirm) {
            Button(AppLocalization.string("删除"), role: .destructive) {
                deleteSelectedRecords()
            }
            Button(AppLocalization.string("取消"), role: .cancel) {}
        } message: {
            Text(AppLocalization.format("将删除 %d 条回测记录，且无法恢复。", selectedRecords.count))
        }
        .onChange(of: selectedFilter) { _, _ in
            selectedRecordIDs = selectedRecordIDs.intersection(Set(filteredRecords.map(\.id)))
        }
    }

    private var backtestBulkDeleteBar: some View {
        HStack(spacing: 12) {
            Button(action: toggleSelectAll) {
                Text(
                    selectedRecordIDs.count == filteredRecords.count && !filteredRecords.isEmpty
                        ? AppLocalization.string("取消全选")
                        : AppLocalization.string("全选")
                )
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.gold)
            }
            .buttonStyle(.plain)
            .disabled(filteredRecords.isEmpty)

            Text(AppLocalization.format("已选 %d 条", selectedRecordIDs.count))
                .font(AppTypography.caption)
                .foregroundStyle(AssetTheme.textSecondary)

            Spacer(minLength: 0)

            Button(AppLocalization.string("删除")) {
                showsDeleteSelectedConfirm = true
            }
            .font(AppTypography.rowTitle)
            .foregroundStyle(selectedRecordIDs.isEmpty ? AssetTheme.textSecondary : AssetTheme.negative)
            .disabled(selectedRecordIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
                .overlay(AssetTheme.border.opacity(0.55))
        }
    }

    private func toggleSelection(for record: BacktestRecord) {
        if selectedRecordIDs.contains(record.id) {
            selectedRecordIDs.remove(record.id)
        } else {
            selectedRecordIDs.insert(record.id)
        }
    }

    private func toggleSelectAll() {
        let visibleIDs = Set(filteredRecords.map(\.id))
        if selectedRecordIDs == visibleIDs {
            selectedRecordIDs.removeAll()
        } else {
            selectedRecordIDs = visibleIDs
        }
    }

    private func deleteSelectedRecords() {
        let targets = selectedRecords
        guard !targets.isEmpty else { return }
        onDeleteMany(targets)
        selectedRecordIDs.removeAll()
        if filteredRecords.isEmpty {
            exitManaging()
        }
    }

    private func exitManaging() {
        isManaging = false
        selectedRecordIDs.removeAll()
    }
}

enum BacktestRecordBulkDeleteMetric: String, CaseIterable, Identifiable {
    case sharpeRatio
    case maxDrawdown
    case annualizedReturn
    case totalReturn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sharpeRatio:
            return AppLocalization.string("夏普")
        case .maxDrawdown:
            return AppLocalization.string("最大回撤")
        case .annualizedReturn:
            return AppLocalization.string("平均年化")
        case .totalReturn:
            return AppLocalization.string("总收益")
        }
    }

    var usesFractionDisplay: Bool {
        switch self {
        case .sharpeRatio:
            return false
        default:
            return true
        }
    }

    var displayRange: ClosedRange<Double> {
        switch self {
        case .sharpeRatio:
            return -2...3
        case .maxDrawdown:
            return 0...80
        case .annualizedReturn:
            return -50...80
        case .totalReturn:
            return -90...500
        }
    }

    var defaultThreshold: Double {
        switch self {
        case .sharpeRatio:
            return 0.5
        case .maxDrawdown:
            return 0.20
        case .annualizedReturn, .totalReturn:
            return 0
        }
    }

    var defaultComparator: BacktestRecordBulkDeleteComparator {
        switch self {
        case .maxDrawdown:
            return .above
        default:
            return .below
        }
    }

    func storedThreshold(fromDisplay display: Double) -> Double {
        usesFractionDisplay ? display / 100 : display
    }

    func displayThreshold(fromStored stored: Double) -> Double {
        usesFractionDisplay ? stored * 100 : stored
    }

    func value(from record: BacktestRecord) -> Double? {
        switch self {
        case .sharpeRatio:
            return record.sharpeRatio
        case .maxDrawdown:
            return record.maxDrawdown
        case .annualizedReturn:
            return record.annualizedReturn
        case .totalReturn:
            return record.totalReturn
        }
    }

    func formattedThreshold(_ stored: Double) -> String {
        if usesFractionDisplay {
            return stored.percentString(maxFractionDigits: 2)
        }
        return String(format: "%.2f", stored)
    }
}

enum BacktestRecordBulkDeleteComparator: String, CaseIterable, Identifiable {
    case below
    case above

    var id: String { rawValue }

    var title: String {
        switch self {
        case .below:
            return AppLocalization.string("低于")
        case .above:
            return AppLocalization.string("高于")
        }
    }

    func matches(value: Double, threshold: Double) -> Bool {
        switch self {
        case .below:
            return value < threshold
        case .above:
            return value > threshold
        }
    }
}

struct BacktestRecordBulkDeleteRule {
    let metric: BacktestRecordBulkDeleteMetric
    let comparator: BacktestRecordBulkDeleteComparator
    let threshold: Double

    func matches(_ record: BacktestRecord) -> Bool {
        guard let value = metric.value(from: record) else { return false }
        return comparator.matches(value: value, threshold: threshold)
    }

    var summaryText: String {
        AppLocalization.format(
            "%@ %@ %@",
            metric.title,
            comparator.title,
            metric.formattedThreshold(threshold)
        )
    }
}

struct BacktestRecordBulkDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss

    let records: [BacktestRecord]
    let onDelete: ([BacktestRecord]) -> Void

    @State private var metric: BacktestRecordBulkDeleteMetric = .sharpeRatio
    @State private var comparator: BacktestRecordBulkDeleteComparator = .below
    @State private var threshold: Double = 0.5
    @State private var thresholdText = "0.50"
    @State private var showsConfirm = false

    private var rule: BacktestRecordBulkDeleteRule {
        BacktestRecordBulkDeleteRule(metric: metric, comparator: comparator, threshold: threshold)
    }

    private var matchingRecords: [BacktestRecord] {
        records.filter { rule.matches($0) }
    }

    private var displayThreshold: Double {
        metric.displayThreshold(fromStored: threshold)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(AppLocalization.string("筛选条件"))
                                .font(AppTypography.blockTitleBold)
                                .foregroundStyle(AssetTheme.textPrimary)

                            Picker(AppLocalization.string("指标"), selection: $metric) {
                                ForEach(BacktestRecordBulkDeleteMetric.allCases) { item in
                                    Text(item.title).tag(item)
                                }
                            }
                            .pickerStyle(.menu)

                            Picker(AppLocalization.string("比较"), selection: $comparator) {
                                ForEach(BacktestRecordBulkDeleteComparator.allCases) { item in
                                    Text(item.title).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(AppLocalization.string("阈值"))
                                        .font(AppTypography.rowTitle)
                                        .foregroundStyle(AssetTheme.textPrimary)
                                    Spacer(minLength: 12)
                                    Text(metric.usesFractionDisplay ? "\(thresholdText)%" : thresholdText)
                                        .font(AppTypography.rowTitle)
                                        .foregroundStyle(AssetTheme.gold)
                                        .monospacedDigit()
                                }

                                Slider(
                                    value: Binding(
                                        get: { displayThreshold },
                                        set: { updateThreshold(display: $0) }
                                    ),
                                    in: metric.displayRange,
                                    step: metric == .sharpeRatio ? 0.05 : 0.5
                                )
                                .tint(AssetTheme.gold)

                                TextField(AppLocalization.string("输入阈值"), text: $thresholdText)
                                    .font(AppTypography.body)
                                    .keyboardType(.decimalPad)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .onSubmit(applyThresholdText)
                            }
                        }
                        .padding(18)
                        .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Text(rule.summaryText)
                                .font(AppTypography.rowTitle)
                                .foregroundStyle(AssetTheme.textPrimary)
                            Text(
                                matchingRecords.isEmpty
                                    ? AppLocalization.string("当前筛选下没有匹配记录")
                                    : AppLocalization.format("将删除 %d 条记录", matchingRecords.count)
                            )
                            .font(AppTypography.caption)
                            .foregroundStyle(AssetTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                        Button {
                            showsConfirm = true
                        } label: {
                            HStack(spacing: 8) {
                                Spacer(minLength: 0)
                                Image(systemName: "trash")
                                Text(AppLocalization.string("删除匹配记录"))
                                Spacer(minLength: 0)
                            }
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(matchingRecords.isEmpty ? AssetTheme.textSecondary : Color.white)
                            .padding(.vertical, 13)
                            .background(
                                matchingRecords.isEmpty ? AssetTheme.overlaySoft : AssetTheme.negative.opacity(0.92),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(matchingRecords.isEmpty)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(AppLocalization.string("条件删除"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                }
            }
            .alert(AppLocalization.string("删除匹配记录？"), isPresented: $showsConfirm) {
                Button(AppLocalization.string("删除"), role: .destructive) {
                    onDelete(matchingRecords)
                    dismiss()
                }
                Button(AppLocalization.string("取消"), role: .cancel) {}
            } message: {
                Text(AppLocalization.format("将删除 %d 条回测记录，且无法恢复。", matchingRecords.count))
            }
            .onAppear {
                resetThresholdDefaults()
            }
            .onChange(of: metric) { _, _ in
                comparator = metric.defaultComparator
                resetThresholdDefaults()
            }
        }
    }

    private func resetThresholdDefaults() {
        threshold = metric.defaultThreshold
        syncThresholdText()
    }

    private func updateThreshold(display: Double) {
        let clamped = min(max(display, metric.displayRange.lowerBound), metric.displayRange.upperBound)
        threshold = metric.storedThreshold(fromDisplay: clamped)
        syncThresholdText()
    }

    private func syncThresholdText() {
        let display = metric.displayThreshold(fromStored: threshold)
        thresholdText = metric.usesFractionDisplay
            ? String(format: "%.2f", display)
            : String(format: "%.2f", threshold)
    }

    private func applyThresholdText() {
        let sanitized = thresholdText
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "％", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(sanitized) else { return }
        updateThreshold(display: value)
    }
}

struct BacktestAllRecordsContainer: View {
    @Query(sort: \BacktestRecord.createdAt, order: .reverse) private var records: [BacktestRecord]
    let onSelect: (BacktestRecord) -> Void
    let onRestore: (BacktestRecord) -> Void
    let onDelete: (BacktestRecord) -> Void
    let onDeleteMany: ([BacktestRecord]) -> Void

    var body: some View {
        BacktestAllRecordsView(
            records: records,
            onSelect: onSelect,
            onRestore: onRestore,
            onDelete: onDelete,
            onDeleteMany: onDeleteMany
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
                .font(AppTypography.blockTitle)
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
    var isSelectionMode: Bool = false
    var selectedRecordIDs: Set<UUID> = []
    let onSelect: (BacktestRecord) -> Void
    let onRestore: (BacktestRecord) -> Void
    let onDelete: (BacktestRecord) -> Void
    var onToggleSelection: ((BacktestRecord) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                BacktestHistoryRow(
                    record: record,
                    showsDetailedContext: showsDetailedContext,
                    isSelectionMode: isSelectionMode,
                    isSelected: selectedRecordIDs.contains(record.id),
                    onSelect: { onSelect(record) },
                    onToggleSelection: { onToggleSelection?(record) },
                    onRestore: { onRestore(record) },
                    onDelete: { onDelete(record) }
                )

                if index < records.count - 1 {
                    Divider()
                        .overlay(AssetTheme.border.opacity(0.55))
                }
            }
        }
        .background(AssetTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct BacktestHistoryRow: View {
    let record: BacktestRecord
    var showsDetailedContext: Bool = false
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    let onSelect: () -> Void
    var onToggleSelection: (() -> Void)? = nil
    let onRestore: () -> Void
    let onDelete: () -> Void

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

    private var displayTitle: String {
        switch kind {
        case .advanced:
            return BacktestRecordCodec.advancedStrategyDisplayTitle(for: record)
        default:
            return record.title
        }
    }

    private var displaySubtitle: String? {
        switch kind {
        case .dca:
            return nil
        case .advanced:
            return backtestRangeSubtitle
        case .allocation:
            if showsDetailedContext {
                return record.configSummary.isEmpty ? nil : record.configSummary
            }
            return record.subtitle.isEmpty ? nil : record.subtitle
        }
    }

    private var backtestRangeSubtitle: String? {
        guard let startDate = record.startDate, let endDate = record.endDate else { return nil }
        return "\(startDate.recordDateString) - \(endDate.recordDateString)"
    }

    var body: some View {
        Group {
            if isSelectionMode {
                rowContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onToggleSelection?()
                    }
            } else {
                rowContent
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSelect)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive, action: onDelete) {
                            Label(AppLocalization.string("删除"), systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button(action: onRestore) {
                            Label(AppLocalization.string("恢复参数"), systemImage: "arrow.uturn.backward")
                        }
                        .tint(AssetTheme.gold)
                    }
                    .contextMenu {
                        Button(AppLocalization.string("恢复参数"), systemImage: "arrow.uturn.backward", action: onRestore)
                        Button(role: .destructive, action: onDelete) {
                            Label(AppLocalization.string("删除记录"), systemImage: "trash")
                        }
                    }
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? AssetTheme.gold : AssetTheme.textSecondary.opacity(0.45))
                    .frame(width: 24, height: 32)
            }

            Image(systemName: iconName)
                .font(AppTypography.blockTitle)
                .foregroundStyle(AssetTheme.gold)
                .frame(width: 32, height: 32)
                .background(AssetTheme.gold.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayTitle)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textPrimary)
                        .lineLimit(1)
                    Text(record.createdAt.recordDateString)
                        .font(AppTypography.caption)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                }

                if let displaySubtitle {
                    Text(displaySubtitle)
                        .font(AppTypography.chartCaption)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
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
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                    .opacity(isSelectionMode ? 0 : 1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyMetricLine(title: String, value: String, valueColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(AppTypography.chartCaption)
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
            Text(value)
                .font(AppTypography.chartAxisStrip)
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
        if kind == .advanced {
            return BacktestRecordCodec.advancedStrategyDisplayTitle(for: record)
        }
        return record.title
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(displayTitle)
                        .font(AppTypography.heroValue)
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
                    .font(AppTypography.body)
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
                .font(AppTypography.captionStrong)
                .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AssetTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
