import SwiftUI
import SwiftData
import Charts
import UIKit

struct BacktestDCACard: View {
    let assetTitle: String
    let amount: Double
    let intervalDays: Int
    let selectedDateRangeLabel: String
    let accent: Color
    let onTapRange: () -> Void
    let onTapAsset: () -> Void
    let onTapAmount: () -> Void
    let onTapInterval: () -> Void
    let onTapPrimaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onTapRange) {
                    HStack(spacing: 8) {
                        Text(selectedDateRangeLabel)
                            .font(AppTypography.blockTitleBold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Image(systemName: "chevron.down")
                            .font(AppTypography.captionStrong)
                    }
                    .foregroundStyle(AssetTheme.textPrimary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onTapAsset) {
                    BacktestInfoRow(title: AppLocalization.string("回测资产"), value: assetTitle, valueColor: accent, showsDivider: true, showsChevron: true)
                }
                .buttonStyle(.plain)

                Button(action: onTapAmount) {
                    BacktestInfoRow(title: AppLocalization.string("每次投入"), value: amount.currencyString(), valueColor: AssetTheme.textPrimary, showsDivider: true, showsChevron: true)
                }
                .buttonStyle(.plain)

                Button(action: onTapInterval) {
                    BacktestInfoRow(title: AppLocalization.string("定投频率"), value: AppLocalization.format("每%d天", intervalDays), valueColor: AssetTheme.textPrimary, showsDivider: false, showsChevron: true)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 18)

            if let onTapPrimaryAction {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.34))
                        .frame(height: 1)
                        .padding(.horizontal, 18)

                    HStack {
                        BacktestPrimaryActionButton(title: AppLocalization.string("开始回测"), systemImage: "play.fill", action: onTapPrimaryAction)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .onboardingAnchor(.backtestStart)
            }
        }
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.04), AssetTheme.overlaySoft.opacity(0.3), Color.black.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.1), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.1), radius: 16, y: 8)
        .frame(maxWidth: .infinity)
    }
}

struct BacktestInfoRow: View {
    let title: String
    let value: String
    var valueColor: Color = AssetTheme.textPrimary
    let showsDivider: Bool
    var showsChevron = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(AppLocalization.string(title))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AssetTheme.textSecondary)

                Spacer()

                Text(value)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            if showsDivider {
                Rectangle()
                    .fill(AssetTheme.border.opacity(0.45))
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }
}

struct BacktestPrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Image(systemName: systemImage)
                    .font(AppTypography.metaStrong)

                Text(AppLocalization.string(title))
                    .font(AppTypography.rowTitle)

                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.black.opacity(0.88))
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [AssetTheme.gold.opacity(0.98), AssetTheme.goldSoft.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: AssetTheme.gold.opacity(0.12), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}

struct BacktestActionChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(AppTypography.metaStrong)
                    .foregroundStyle(AssetTheme.textSecondary)
                Text(AppLocalization.string(title))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(AssetTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AssetTheme.border.opacity(0.68), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct BacktestDateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var endDate: Date
    let availableBounds: ClosedRange<Date>
    let onApply: (Date, Date) -> Void

    init(
        availableBounds: ClosedRange<Date>,
        selectedBounds: ClosedRange<Date>,
        onApply: @escaping (Date, Date) -> Void
    ) {
        _startDate = State(initialValue: selectedBounds.lowerBound)
        _endDate = State(initialValue: selectedBounds.upperBound)
        self.availableBounds = availableBounds
        self.onApply = onApply
    }

    private var calendar: Calendar {
        Calendar(identifier: .gregorian)
    }

    private var selectedSpanDays: Int {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { startDate },
            set: { startDate = min($0, endDate) }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { endDate },
            set: { endDate = max($0, startDate) }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        summaryCard

                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppLocalization.string("快速选择"))
                                .font(AppTypography.captionStrong)
                                .foregroundStyle(AssetTheme.textSecondary)

                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                                spacing: 10
                            ) {
                                BacktestRangePresetButton(
                                    title: AppLocalization.string("全部历史"),
                                    isSelected: matchesRange(start: availableBounds.lowerBound, end: availableBounds.upperBound)
                                ) {
                                    startDate = availableBounds.lowerBound
                                    endDate = availableBounds.upperBound
                                }

                                BacktestRangePresetButton(
                                    title: AppLocalization.string("近1年"),
                                    isSelected: matchesPreset(yearsBack: 1)
                                ) {
                                    applyRelativePreset(yearsBack: 1)
                                }

                                BacktestRangePresetButton(
                                    title: AppLocalization.string("近6个月"),
                                    isSelected: matchesPreset(monthsBack: 6)
                                ) {
                                    applyRelativePreset(monthsBack: 6)
                                }
                            }
                        }

                        BacktestCalendarCard(
                            title: AppLocalization.string("开始日期"),
                            value: startDate.longDateString,
                            accent: AssetTheme.gold,
                            selection: startDateBinding,
                            bounds: availableBounds.lowerBound...endDate
                        )

                        BacktestCalendarCard(
                            title: AppLocalization.string("结束日期"),
                            value: endDate.longDateString,
                            accent: AssetTheme.goldSoft,
                            selection: endDateBinding,
                            bounds: startDate...availableBounds.upperBound
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 36)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.textSecondary)
                }

                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("调整时间"))
                        .font(AppTypography.blockTitleBold)
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(startDate, endDate)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(AssetTheme.gold)
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLocalization.string("已选区间"))
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AssetTheme.textSecondary)

                    Text("\(startDate.recordDateString) - \(endDate.recordDateString)")
                        .font(AppTypography.sheetTitle)
                        .foregroundStyle(AssetTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(AppLocalization.string("天数"))
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AssetTheme.textSecondary)
                    Text(AppLocalization.format("%d天", selectedSpanDays))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AssetTheme.gold)
                }
            }

            Rectangle()
                .fill(AssetTheme.border.opacity(0.4))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalization.string("可选范围"))
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AssetTheme.textSecondary)

                Text("\(availableBounds.lowerBound.longDateString) - \(availableBounds.upperBound.longDateString)")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.05), AssetTheme.overlaySoft.opacity(0.35), Color.black.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 8)
    }

    private func applyRelativePreset(monthsBack: Int? = nil, yearsBack: Int? = nil) {
        let targetStart: Date
        if let monthsBack {
            targetStart = calendar.date(byAdding: .month, value: -monthsBack, to: availableBounds.upperBound) ?? availableBounds.lowerBound
        } else if let yearsBack {
            targetStart = calendar.date(byAdding: .year, value: -yearsBack, to: availableBounds.upperBound) ?? availableBounds.lowerBound
        } else {
            targetStart = availableBounds.lowerBound
        }

        startDate = max(targetStart, availableBounds.lowerBound)
        endDate = availableBounds.upperBound
    }

    private func matchesPreset(monthsBack: Int? = nil, yearsBack: Int? = nil) -> Bool {
        let presetStart: Date
        if let monthsBack {
            presetStart = calendar.date(byAdding: .month, value: -monthsBack, to: availableBounds.upperBound) ?? availableBounds.lowerBound
        } else if let yearsBack {
            presetStart = calendar.date(byAdding: .year, value: -yearsBack, to: availableBounds.upperBound) ?? availableBounds.lowerBound
        } else {
            presetStart = availableBounds.lowerBound
        }

        return matchesRange(start: max(presetStart, availableBounds.lowerBound), end: availableBounds.upperBound)
    }

    private func matchesRange(start: Date, end: Date) -> Bool {
        calendar.isDate(startDate, inSameDayAs: start) && calendar.isDate(endDate, inSameDayAs: end)
    }
}

struct BacktestRangePresetButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(AppLocalization.string(title))
                .font(AppTypography.captionStrong)
                .foregroundStyle(isSelected ? Color.black.opacity(0.88) : AssetTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [AssetTheme.gold.opacity(0.98), AssetTheme.goldSoft.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        : AnyShapeStyle(AssetTheme.overlaySoft),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isSelected ? Color.white.opacity(0.12) : AssetTheme.border.opacity(0.7),
                            lineWidth: 1
                        )
                )
                .shadow(color: isSelected ? AssetTheme.gold.opacity(0.14) : .clear, radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }
}

struct BacktestCalendarCard: View {
    let title: String
    let value: String
    let accent: Color
    let selection: Binding<Date>
    let bounds: ClosedRange<Date>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLocalization.string(title))
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AssetTheme.textSecondary)
                    Text(value)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(accent)
                }

                Spacer(minLength: 8)

                Image(systemName: "calendar")
                    .font(AppTypography.metaStrong)
                    .foregroundStyle(accent)
                    .padding(10)
                    .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AssetTheme.border.opacity(0.65), lineWidth: 1)
                    )
            }

            DatePicker(title, selection: selection, in: bounds, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
                .tint(AssetTheme.gold)
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.04), AssetTheme.overlaySoft.opacity(0.32), Color.black.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.1), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.1), radius: 16, y: 8)
    }
}

struct BacktestLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(AssetTheme.gold)
                .scaleEffect(1.15)
            Text(AppLocalization.string("正在重新回测..."))
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

struct AdvancedStrategyLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let templates: [AdvancedBacktestStrategyTemplate]
    let activeTemplateID: String?
    let onSelect: (AdvancedBacktestStrategyTemplate) -> Void
    @State private var searchText = ""

    private var visibleTemplates: [AdvancedBacktestStrategyTemplate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return templates.filter { template in
            guard !query.isEmpty else { return true }
            return template.title.localizedCaseInsensitiveContains(query)
                || template.subtitle.localizedCaseInsensitiveContains(query)
                || template.category.localizedCaseInsensitiveContains(query)
                || template.mode.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleTemplateColumns: [[AdvancedBacktestStrategyTemplate]] {
        var columns = Array(repeating: [AdvancedBacktestStrategyTemplate](), count: 2)
        var estimatedHeights = Array(repeating: CGFloat.zero, count: 2)

        for template in visibleTemplates {
            let columnIndex = estimatedHeights[0] <= estimatedHeights[1] ? 0 : 1
            columns[columnIndex].append(template)
            estimatedHeights[columnIndex] += estimatedCardHeight(for: template)
        }

        return columns
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(AppLocalization.string("策略大全"))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(AssetTheme.textPrimary)
                            .padding(.bottom, 2)

                        strategySearchAndFilterArea

                        if visibleTemplates.isEmpty {
                            strategyEmptyState
                        } else {
                            strategyMasonryGrid
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.gold)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var strategyMasonryGrid: some View {
        let columns = visibleTemplateColumns

        return HStack(alignment: .top, spacing: 12) {
            ForEach(columns.indices, id: \.self) { columnIndex in
                LazyVStack(spacing: 12) {
                    ForEach(columns[columnIndex]) { template in
                        AdvancedStrategyTemplateRow(
                            template: template,
                            isActive: template.id == activeTemplateID
                        ) {
                            onSelect(template)
                            dismiss()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func estimatedCardHeight(for template: AdvancedBacktestStrategyTemplate) -> CGFloat {
        let textLength = template.title.count + template.subtitle.count + template.category.count
        let linePenalty = CGFloat(min(max(textLength - 36, 0), 72)) * 0.45
        let rotationPenalty: CGFloat = template.mode.isRotation ? 18 : 0
        return 190 + linePenalty + rotationPenalty
    }

    private var strategySearchAndFilterArea: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(AppTypography.metaStrong)
                .foregroundStyle(AssetTheme.textSecondary)
            TextField(AppLocalization.string("搜索策略、指标或资产"), text: $searchText)
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppTypography.metaStrong)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.76))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
        )
        .padding(.bottom, 2)
    }

    private var strategyEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string("没有匹配策略"))
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.textPrimary)
            Text(AppLocalization.string("换个关键词，或切回全部分类。"))
                .font(AppTypography.caption)
                .foregroundStyle(AssetTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
        )
    }
}

struct AdvancedStrategyTemplateRow: View {
    let template: AdvancedBacktestStrategyTemplate
    let isActive: Bool
    let onTap: () -> Void

    private var strategyHighlights: [String] {
        let rotationTitles = rotationChipTitles(for: template.mode)
        if !rotationTitles.isEmpty {
            return Array(rotationTitles.prefix(4))
        }

        return [
            template.category,
            ruleLabel(template.buyRule),
            ruleLabel(template.sellRule)
        ]
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Text(template.category)
                        .font(AppTypography.chartAxisStrip)
                        .foregroundStyle(isActive ? AssetTheme.gold : AssetTheme.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background((isActive ? AssetTheme.gold.opacity(0.14) : AssetTheme.overlayFaint), in: Capsule())

                    Spacer(minLength: 4)

                    Image(systemName: isActive ? "checkmark.circle.fill" : "chevron.right")
                        .font(isActive ? .title3.weight(.semibold) : .caption.weight(.bold))
                        .foregroundStyle(isActive ? AssetTheme.gold : AssetTheme.textSecondary.opacity(0.72))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(template.title)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if !template.subtitle.isEmpty {
                        Text(template.subtitle)
                            .font(AppTypography.captionStrong)
                            .foregroundStyle(AssetTheme.gold)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ATMFlowLayout(horizontalSpacing: 6, verticalSpacing: 6, rowAlignment: .leading) {
                    ForEach(Array(strategyHighlights.enumerated()), id: \.offset) { _, title in
                        strategyChip(title)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                StrategyCapabilityRadarChart(profile: template.capabilityProfile)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(isActive ? AssetTheme.gold.opacity(0.13) : AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isActive ? AssetTheme.gold.opacity(0.72) : AssetTheme.border.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func ruleLabel(_ rule: AdvancedBacktestRule) -> String {
        if rule.direction.usesDayThreshold {
            return AppLocalization.format("%@%d天", rule.direction.shortTitle, rule.days)
        }
        return rule.direction.shortTitle
    }

    private func rotationChipTitles(for mode: AdvancedBacktestStrategyMode) -> [String] {
        switch mode {
        case .ultraDefensiveRotation:
            return [
                AppLocalization.string("40日强弱"),
                AppLocalization.string("目标波动6%"),
                AppLocalization.string("最高仓位35%"),
                AppLocalization.string("现金防守")
            ]
        case .defensiveRotation:
            return [
                AppLocalization.string("40日强弱"),
                AppLocalization.string("目标波动8%"),
                AppLocalization.string("最高仓位55%"),
                AppLocalization.string("现金防守")
            ]
        case .lowDrawdownRotation:
            return [
                AppLocalization.string("40日强弱"),
                AppLocalization.string("分散持有"),
                AppLocalization.string("目标波动10%"),
                AppLocalization.string("最高仓位65%")
            ]
        case .balancedRotation:
            return [
                AppLocalization.string("40日强弱"),
                AppLocalization.string("分散持有"),
                AppLocalization.string("目标波动12%"),
                AppLocalization.string("最高仓位75%")
            ]
        case .enhancedRotation:
            return [
                AppLocalization.string("40日强弱"),
                AppLocalization.string("分散持有"),
                AppLocalization.string("目标波动12%"),
                AppLocalization.string("最高仓位90%")
            ]
        case .longTermDefensiveTrend:
            return [
                AppLocalization.string("黄金65%"),
                AppLocalization.string("MA200过滤"),
                AppLocalization.string("目标波动8.5%"),
                AppLocalization.string("现金防守")
            ]
        case .longTermEnhancedLowDrawdownTrend:
            return [
                AppLocalization.string("黄金73%"),
                AppLocalization.string("MA220过滤"),
                AppLocalization.string("目标波动9.5%"),
                AppLocalization.string("波动刹车")
            ]
        case .steadyDrawdownLadderTrend:
            return [
                AppLocalization.string("黄金73%"),
                AppLocalization.string("MA220过滤"),
                AppLocalization.string("目标波动8.5%"),
                AppLocalization.string("回撤阶梯")
            ]
        case .septemberGuardLadderTrend:
            return [
                AppLocalization.string("回撤阶梯"),
                AppLocalization.string("9月权益25%"),
                AppLocalization.string("黄金承接"),
                AppLocalization.string("目标波动8.5%")
            ]
        case .longTermGrowthTrend:
            return [
                AppLocalization.string("黄金50%"),
                AppLocalization.string("MA220过滤"),
                AppLocalization.string("目标波动11%"),
                AppLocalization.string("进取")
            ]
        case .longTermLowVolMomentum:
            return [
                AppLocalization.string("非均线"),
                AppLocalization.string("240日动量"),
                AppLocalization.string("波动<18%"),
                AppLocalization.string("最多3项")
            ]
        case .robustLowVolMomentum:
            return [
                AppLocalization.string("180日动量"),
                AppLocalization.string("波动<18%"),
                AppLocalization.string("最高仓位55%"),
                AppLocalization.string("目标波动7.5%")
            ]
        case .overheatGuardMomentum:
            return [
                AppLocalization.string("Top1动量"),
                AppLocalization.string("A股过热降仓"),
                AppLocalization.string("最高仓位75%"),
                AppLocalization.string("目标波动11%")
            ]
        case .highZoneDecelerationMomentum:
            return [
                AppLocalization.string("Top1动量"),
                AppLocalization.string("高位锁盈"),
                AppLocalization.string("短弱接管"),
                AppLocalization.string("目标波动11%")
            ]
        case .pairConfirmDoubleGuardMomentum:
            return [
                AppLocalization.string("Top1动量"),
                AppLocalization.string("同组确认"),
                AppLocalization.string("双守门"),
                AppLocalization.string("目标波动11%")
            ]
        case .tailBreakdownLockMomentum:
            return [
                AppLocalization.string("Top1动量"),
                AppLocalization.string("持有破位"),
                AppLocalization.string("锁盈降仓"),
                AppLocalization.string("防守发动机")
            ]
        case .recentLossVolatilityMetaMomentum:
            return [
                AppLocalization.string("亏损监控"),
                AppLocalization.string("波动监控"),
                AppLocalization.string("短期防守"),
                AppLocalization.string("恢复进攻")
            ]
        case .coreGoldSatelliteConservativeMomentum:
            return [
                AppLocalization.string("核心95%"),
                AppLocalization.string("黄金卫星10%"),
                AppLocalization.string("2月弱势刹车"),
                AppLocalization.string("回撤优先")
            ]
        case .coreGoldSatelliteBalancedMomentum:
            return [
                AppLocalization.string("核心97.5%"),
                AppLocalization.string("黄金卫星10%"),
                AppLocalization.string("2月弱势刹车"),
                AppLocalization.string("平衡推荐")
            ]
        case .coreGoldSatelliteFullMomentum:
            return [
                AppLocalization.string("核心100%"),
                AppLocalization.string("黄金卫星10%"),
                AppLocalization.string("总仓85%"),
                AppLocalization.string("净值轻刹车")
            ]
        case .coreGoldSatelliteHeatCappedMomentum:
            return [
                AppLocalization.string("单权益64%"),
                AppLocalization.string("黄金卫星10%"),
                AppLocalization.string("总仓85%"),
                AppLocalization.string("回撤优先")
            ]
        case .coreGoldSatelliteGoldHandoffMomentum:
            return [
                AppLocalization.string("黄金45%保护"),
                AppLocalization.string("美股确认交接"),
                AppLocalization.string("总仓85%"),
                AppLocalization.string("回撤<10%")
            ]
        case .coreGoldSatelliteEquityBreadthMomentum:
            return [
                AppLocalization.string("黄金交接"),
                AppLocalization.string("权益宽度"),
                AppLocalization.string("趋势确认"),
                AppLocalization.string("进攻引擎")
            ]
        case .coreGoldSatelliteOneWayVolManagedMomentum:
            return [
                AppLocalization.string("双引擎路由"),
                AppLocalization.string("只降不升"),
                AppLocalization.string("现金缓冲"),
                AppLocalization.string("高夏普")
            ]
        case .coreGoldSatelliteEquityCurveStateGateMomentum:
            return [
                AppLocalization.string("双引擎路由"),
                AppLocalization.string("90日状态"),
                AppLocalization.string("70%低风险"),
                AppLocalization.string("现金缓冲")
            ]
        case .coreGoldSatelliteSharpeStateGateMomentum:
            return [
                AppLocalization.string("双引擎路由"),
                AppLocalization.string("75日状态"),
                AppLocalization.string("35%低风险"),
                AppLocalization.string("夏普优先")
            ]
        case .coreGoldSatelliteAssetRiskGateMomentum:
            return [
                AppLocalization.string("权益曲线底座"),
                AppLocalization.string("A股破位保护"),
                AppLocalization.string("73%低风险"),
                AppLocalization.string("回撤<10%")
            ]
        case .coreGoldSatelliteRiskBudgetStateGateMomentum:
            return [
                AppLocalization.string("风险预算"),
                AppLocalization.string("无融资"),
                AppLocalization.string("全周期"),
                AppLocalization.string("状态门")
            ]
        case .coreGoldSatelliteConfirmedAccelerationMomentum:
            return [
                AppLocalization.string("确认加速"),
                AppLocalization.string("额外权益"),
                AppLocalization.string("波动收缩"),
                AppLocalization.string("进攻袖套")
            ]
        case .coreGoldSatelliteProfitLockMomentum:
            return [
                AppLocalization.string("回撤预算"),
                AppLocalization.string("快涨锁盈"),
                AppLocalization.string("现金缓冲"),
                AppLocalization.string("防守袖套")
            ]
        case .coreGoldSatelliteDynamicSleeveMomentum:
            return [
                AppLocalization.string("315日选择"),
                AppLocalization.string("95/25袖套"),
                AppLocalization.string("无融资"),
                AppLocalization.string("实时回测")
            ]
        case .coreGoldSatelliteContagionRepairMomentum:
            return [
                AppLocalization.string("全球修复"),
                AppLocalization.string("传染控制"),
                AppLocalization.string("恒生/日经"),
                AppLocalization.string("无融资")
            ]
        case .coreGoldSatelliteCurrencyCashMomentum:
            return [
                AppLocalization.string("美元现金"),
                AppLocalization.string("闲置承接"),
                AppLocalization.string("全球修复"),
                AppLocalization.string("实时回测")
            ]
        case .coreGoldSatelliteGoldPanicLockMomentum:
            return [
                AppLocalization.string("黄金锁盈"),
                AppLocalization.string("美元现金"),
                AppLocalization.string("释放现金"),
                AppLocalization.string("实时回测")
            ]
        case .coreGoldSatelliteRiskEfficiencyMomentum:
            return [
                AppLocalization.string("风险效率"),
                AppLocalization.string("黄金锁盈"),
                AppLocalization.string("美元现金"),
                AppLocalization.string("当前候选")
            ]
        case .coreGoldSatelliteMonthlyHeatCappedMomentum:
            return [
                AppLocalization.string("30日调仓"),
                AppLocalization.string("单权益72%"),
                AppLocalization.string("黄金卫星10%"),
                AppLocalization.string("总仓85%")
            ]
        case .coreGoldSatelliteConfirmedExcessMomentum:
            return [
                AppLocalization.string("单权益64%"),
                AppLocalization.string("超额确认轮动"),
                AppLocalization.string("黄金优先"),
                AppLocalization.string("总仓85%")
            ]
        case .coreGoldSatelliteAggressiveMomentum:
            return [
                AppLocalization.string("核心97.5%"),
                AppLocalization.string("黄金卫星15%"),
                AppLocalization.string("2月弱势刹车"),
                AppLocalization.string("收益进取")
            ]
        case .canaryMomentumDefense:
            return [
                AppLocalization.string("双金丝雀"),
                AppLocalization.string("前2强势"),
                AppLocalization.string("黄金底仓"),
                AppLocalization.string("现金防守")
            ]
        case .drawdownReentryMomentum:
            return [
                AppLocalization.string("90日回撤<8%"),
                AppLocalization.string("动量/RSI再入场"),
                AppLocalization.string("最高仓位65%"),
                AppLocalization.string("目标波动7.5%")
            ]
        case .goldCoreTrendSatellite:
            return [
                AppLocalization.string("黄金核心"),
                AppLocalization.string("趋势卫星"),
                AppLocalization.string("分线过滤"),
                AppLocalization.string("现金防守")
            ]
        case .goldNasdaqSteadyRotation:
            return [
                AppLocalization.string("黄金/纳指"),
                AppLocalization.string("20日强弱>2%"),
                AppLocalization.string("MA250过滤"),
                AppLocalization.string("目标波动8%")
            ]
        case .goldNasdaqPortfolioScheduler:
            return [
                AppLocalization.string("纳指/黄金"),
                AppLocalization.string("现金防守"),
                AppLocalization.string("压力信号"),
                AppLocalization.string("目标波动9.5%")
            ]
        case .strongVolControlledRotation:
            return [
                AppLocalization.string("20日强弱"),
                AppLocalization.string("单一强势"),
                AppLocalization.string("目标波动12%"),
                AppLocalization.string("最高仓位90%")
            ]
        case .momentumRotation:
            return [
                AppLocalization.string("20日强弱"),
                AppLocalization.string("每20交易日"),
                AppLocalization.string("MA60过滤"),
                AppLocalization.string("空仓防守")
            ]
        case .ruleBased:
            return []
        }
    }

    private func strategyChip(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.chartCaptionStrong)
            .foregroundStyle(AssetTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AssetTheme.overlayFaint, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(AssetTheme.border.opacity(0.45), lineWidth: 1)
            )
    }
}

struct StrategyCapabilityProfile {
    struct Metric: Identifiable {
        let label: String
        let value: Double
        var id: String { label }
    }

    let metrics: [Metric]
    let summary: String

    init(summary: String, metrics: [(String, Double)]) {
        self.summary = summary
        self.metrics = metrics.map { Metric(label: $0.0, value: min(max($0.1, 0), 1)) }
    }
}

struct StrategyCapabilityRadarChart: View {
    let profile: StrategyCapabilityProfile

    var body: some View {
        VStack(spacing: 3) {
            Canvas { context, size in
                let metrics = profile.metrics
                guard metrics.count >= 3 else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.34
                let labelRadius = min(size.width, size.height) * 0.47

                func point(index: Int, radius: CGFloat, valueScale: Double = 1) -> CGPoint {
                    let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(metrics.count)
                    let scaledRadius = radius * CGFloat(valueScale)
                    return CGPoint(
                        x: center.x + CGFloat(cos(angle)) * scaledRadius,
                        y: center.y + CGFloat(sin(angle)) * scaledRadius
                    )
                }

                for step in 1...3 {
                    var gridPath = Path()
                    for index in metrics.indices {
                        let item = point(index: index, radius: radius, valueScale: Double(step) / 3)
                        if index == metrics.startIndex {
                            gridPath.move(to: item)
                        } else {
                            gridPath.addLine(to: item)
                        }
                    }
                    gridPath.closeSubpath()
                    context.stroke(gridPath, with: .color(AssetTheme.border.opacity(step == 3 ? 0.48 : 0.24)), lineWidth: step == 3 ? 0.8 : 0.55)
                }

                for index in metrics.indices {
                    var axisPath = Path()
                    axisPath.move(to: center)
                    axisPath.addLine(to: point(index: index, radius: radius))
                    context.stroke(axisPath, with: .color(AssetTheme.border.opacity(0.28)), lineWidth: 0.55)

                    let labelPoint = point(index: index, radius: labelRadius)
                    context.draw(
                        Text(metrics[index].label)
                            .font(AppTypography.chartAxisMini)
                            .foregroundStyle(AssetTheme.textSecondary.opacity(0.92)),
                        at: labelPoint,
                        anchor: .center
                    )
                }

                var valuePath = Path()
                for index in metrics.indices {
                    let item = point(index: index, radius: radius, valueScale: metrics[index].value)
                    if index == metrics.startIndex {
                        valuePath.move(to: item)
                    } else {
                        valuePath.addLine(to: item)
                    }
                }
                valuePath.closeSubpath()
                context.fill(valuePath, with: .color(AssetTheme.gold.opacity(0.22)))
                context.stroke(valuePath, with: .color(AssetTheme.gold.opacity(0.92)), lineWidth: 1.2)
            }
            .frame(width: 82, height: 82)
            .accessibilityHidden(true)

            Text(profile.summary)
                .font(AppTypography.chartAxisStrip)
                .foregroundStyle(AssetTheme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityLabel(AppLocalization.format("策略能力：%@", profile.summary))
    }
}

extension AdvancedBacktestStrategyTemplate {
    var capabilityProfile: StrategyCapabilityProfile {
        var growth = 0.35 + min(maxPositionRatio / 100, 1) * 0.45
        var stability = 0.88 - min(maxPositionRatio / 100, 1) * 0.36
        var defense = 0.34 + (1 - min(maxPositionRatio / 100, 1)) * 0.36
        var flexibility = mode.isRotation ? 0.72 : 0.42

        if (selectedAssetSymbols?.count ?? 1) >= 3 {
            flexibility += 0.10
            stability += 0.06
        }
        if stopLossRatio > 0 {
            defense += 0.18
            stability += 0.08
        }
        if takeProfitRatio > 0 {
            growth += 0.08
            defense += 0.06
        }

        switch mode {
        case .ultraDefensiveRotation:
            growth = 0.36; stability = 0.93; defense = 0.94; flexibility = 0.74
        case .defensiveRotation:
            growth = 0.48; stability = 0.86; defense = 0.88; flexibility = 0.78
        case .lowDrawdownRotation:
            growth = 0.60; stability = 0.80; defense = 0.78; flexibility = 0.82
        case .balancedRotation:
            growth = 0.70; stability = 0.70; defense = 0.68; flexibility = 0.84
        case .enhancedRotation:
            growth = 0.82; stability = 0.58; defense = 0.58; flexibility = 0.86
        case .longTermDefensiveTrend:
            growth = 0.64; stability = 0.86; defense = 0.90; flexibility = 0.66
        case .longTermEnhancedLowDrawdownTrend:
            growth = 0.82; stability = 0.78; defense = 0.76; flexibility = 0.68
        case .steadyDrawdownLadderTrend:
            growth = 0.68; stability = 0.88; defense = 0.88; flexibility = 0.68
        case .septemberGuardLadderTrend:
            growth = 0.72; stability = 0.90; defense = 0.91; flexibility = 0.72
        case .longTermGrowthTrend:
            growth = 0.86; stability = 0.62; defense = 0.60; flexibility = 0.66
        case .longTermLowVolMomentum:
            growth = 0.78; stability = 0.82; defense = 0.78; flexibility = 0.88
        case .robustLowVolMomentum:
            growth = 0.66; stability = 0.90; defense = 0.92; flexibility = 0.86
        case .overheatGuardMomentum:
            growth = 0.90; stability = 0.84; defense = 0.86; flexibility = 0.88
        case .highZoneDecelerationMomentum:
            growth = 0.92; stability = 0.86; defense = 0.88; flexibility = 0.90
        case .pairConfirmDoubleGuardMomentum:
            growth = 0.90; stability = 0.88; defense = 0.90; flexibility = 0.90
        case .tailBreakdownLockMomentum:
            growth = 0.76; stability = 0.90; defense = 0.92; flexibility = 0.88
        case .recentLossVolatilityMetaMomentum:
            growth = 0.94; stability = 0.90; defense = 0.92; flexibility = 0.94
        case .coreGoldSatelliteConservativeMomentum:
            growth = 0.92; stability = 0.93; defense = 0.94; flexibility = 0.94
        case .coreGoldSatelliteBalancedMomentum:
            growth = 0.96; stability = 0.91; defense = 0.92; flexibility = 0.95
        case .coreGoldSatelliteFullMomentum:
            growth = 0.99; stability = 0.90; defense = 0.91; flexibility = 0.96
        case .coreGoldSatelliteHeatCappedMomentum:
            growth = 0.97; stability = 0.94; defense = 0.94; flexibility = 0.96
        case .coreGoldSatelliteGoldHandoffMomentum:
            growth = 0.99; stability = 0.95; defense = 0.96; flexibility = 0.97
        case .coreGoldSatelliteEquityBreadthMomentum:
            growth = 1.00; stability = 0.76; defense = 0.72; flexibility = 0.98
        case .coreGoldSatelliteOneWayVolManagedMomentum:
            growth = 0.93; stability = 0.96; defense = 0.96; flexibility = 0.99
        case .coreGoldSatelliteEquityCurveStateGateMomentum:
            growth = 0.94; stability = 0.98; defense = 0.98; flexibility = 0.99
        case .coreGoldSatelliteSharpeStateGateMomentum:
            growth = 0.78; stability = 1.00; defense = 1.00; flexibility = 0.99
        case .coreGoldSatelliteAssetRiskGateMomentum:
            growth = 0.90; stability = 0.98; defense = 0.98; flexibility = 1.00
        case .coreGoldSatelliteRiskBudgetStateGateMomentum:
            growth = 1.00; stability = 0.72; defense = 0.70; flexibility = 0.96
        case .coreGoldSatelliteConfirmedAccelerationMomentum:
            growth = 1.00; stability = 0.82; defense = 0.78; flexibility = 0.99
        case .coreGoldSatelliteProfitLockMomentum:
            growth = 0.88; stability = 0.96; defense = 0.97; flexibility = 0.98
        case .coreGoldSatelliteDynamicSleeveMomentum:
            growth = 0.96; stability = 0.97; defense = 0.96; flexibility = 1.00
        case .coreGoldSatelliteContagionRepairMomentum:
            growth = 0.98; stability = 0.96; defense = 0.95; flexibility = 1.00
        case .coreGoldSatelliteCurrencyCashMomentum:
            growth = 0.99; stability = 0.96; defense = 0.95; flexibility = 1.00
        case .coreGoldSatelliteGoldPanicLockMomentum:
            growth = 0.98; stability = 0.98; defense = 0.98; flexibility = 1.00
        case .coreGoldSatelliteRiskEfficiencyMomentum:
            growth = 0.98; stability = 0.98; defense = 0.98; flexibility = 1.00
        case .coreGoldSatelliteMonthlyHeatCappedMomentum:
            growth = 0.98; stability = 0.93; defense = 0.95; flexibility = 0.97
        case .coreGoldSatelliteConfirmedExcessMomentum:
            growth = 0.99; stability = 0.94; defense = 0.94; flexibility = 0.98
        case .coreGoldSatelliteAggressiveMomentum:
            growth = 0.98; stability = 0.86; defense = 0.88; flexibility = 0.95
        case .canaryMomentumDefense:
            growth = 0.82; stability = 0.92; defense = 0.94; flexibility = 0.94
        case .drawdownReentryMomentum:
            growth = 0.82; stability = 0.84; defense = 0.88; flexibility = 0.86
        case .goldCoreTrendSatellite:
            growth = 0.62; stability = 0.88; defense = 0.92; flexibility = 0.74
        case .goldNasdaqSteadyRotation:
            growth = 0.58; stability = 0.82; defense = 0.82; flexibility = 0.76
        case .goldNasdaqPortfolioScheduler:
            growth = 0.74; stability = 0.86; defense = 0.90; flexibility = 0.88
        case .strongVolControlledRotation:
            growth = 0.78; stability = 0.66; defense = 0.66; flexibility = 0.78
        case .momentumRotation:
            growth = 0.86; stability = 0.50; defense = 0.48; flexibility = 0.72
        case .ruleBased:
            switch id {
            case "gold-dip-take-profit":
                growth = 0.78; stability = 0.56; defense = 0.60; flexibility = 0.45
            case "index-compound-take-profit":
                growth = 0.84; stability = 0.52; defense = 0.54; flexibility = 0.45
            case "ma60-strength":
                growth = 0.72; stability = 0.70; defense = 0.74; flexibility = 0.48
            case "ma20-index-follow":
                growth = 0.78; stability = 0.58; defense = 0.58; flexibility = 0.48
            case "rebound":
                growth = 0.48; stability = 0.62; defense = 0.56; flexibility = 0.50
            case "trend":
                growth = 0.64; stability = 0.56; defense = 0.52; flexibility = 0.54
            case "golden-cross":
                growth = 0.58; stability = 0.70; defense = 0.62; flexibility = 0.50
            case "bollinger":
                growth = 0.45; stability = 0.68; defense = 0.62; flexibility = 0.50
            default:
                break
            }
        }

        let summary: String
        if defense >= 0.86 && stability >= 0.82 {
            summary = AppLocalization.string("防守型")
        } else if growth >= 0.82 {
            summary = AppLocalization.string("进取型")
        } else if flexibility >= 0.82 {
            summary = AppLocalization.string("轮动型")
        } else {
            summary = AppLocalization.string("均衡型")
        }

        return StrategyCapabilityProfile(
            summary: summary,
            metrics: [
                (AppLocalization.string("收益"), growth),
                (AppLocalization.string("防守"), defense),
                (AppLocalization.string("弹性"), flexibility)
            ]
        )
    }
}

struct BacktestDCASettingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var assetSymbol: String
    @State private var contributionAmount: Double
    @State private var intervalDays: Int
    let assetOptions: [BacktestAssetOption]
    let onApply: (String, Double, Int) -> Void

    init(
        assetSymbol: String,
        contributionAmount: Double,
        intervalDays: Int,
        assetOptions: [BacktestAssetOption],
        onApply: @escaping (String, Double, Int) -> Void
    ) {
        _assetSymbol = State(initialValue: assetSymbol)
        _contributionAmount = State(initialValue: contributionAmount)
        _intervalDays = State(initialValue: intervalDays)
        self.assetOptions = assetOptions
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppLocalization.string("回测资产"))
                                .font(AppTypography.rowTitle)
                                .foregroundStyle(AssetTheme.textPrimary)

                            Picker(AppLocalization.string("回测资产"), selection: $assetSymbol) {
                                ForEach(assetOptions) { option in
                                    Text(AppLocalization.string(option.title)).tag(option.symbol)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(AssetTheme.textPrimary)

                            Text(AppLocalization.string("每次投入固定为人民币。美元资产会按历史 USD/CNY 折算，人民币资产保持原口径。"))
                                .font(AppTypography.caption)
                                .foregroundStyle(AssetTheme.textSecondary)
                        }
                        .padding(16)
                        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
                        )

                        BacktestStepperCard(
                            title: AppLocalization.string("每次投入"),
                            valueText: contributionAmount.currencyString(),
                            caption: AppLocalization.string("按人民币计价，支持按固定金额持续定投。"),
                            decrementTitle: AppLocalization.string("减少"),
                            incrementTitle: AppLocalization.string("增加")
                        ) {
                            contributionAmount = max(100, contributionAmount - 100)
                        } onIncrement: {
                            contributionAmount = min(1_000_000, contributionAmount + 100)
                        }

                        BacktestStepperCard(
                            title: AppLocalization.string("定投间隔"),
                            valueText: AppLocalization.format("每%d天", intervalDays),
                            caption: AppLocalization.string("若计划日无行情，则顺延到下一可用历史点执行。"),
                            decrementTitle: AppLocalization.string("缩短"),
                            incrementTitle: AppLocalization.string("拉长")
                        ) {
                            intervalDays = max(1, intervalDays - 1)
                        } onIncrement: {
                            intervalDays = min(365, intervalDays + 1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("重置")) {
                        assetSymbol = BacktestDefaults.dcaAssetSymbol
                        contributionAmount = BacktestDefaults.dcaContributionAmount
                        intervalDays = BacktestDefaults.dcaIntervalDays
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("定投参数"))
                        .font(AppTypography.blockTitleBold)
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(assetSymbol, contributionAmount, intervalDays)
                        dismiss()
                    }
                    .tint(AssetTheme.gold)
                }
            }
        }
    }
}

struct AdvancedBacktestAssetPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSymbols: Set<String>
    let assetOptions: [BacktestAssetOption]
    let onApply: (Set<String>) -> Void

    init(selectedSymbols: Set<String>, assetOptions: [BacktestAssetOption], onApply: @escaping (Set<String>) -> Void) {
        _selectedSymbols = State(initialValue: selectedSymbols.isEmpty ? [BacktestDefaults.dcaAssetSymbol] : selectedSymbols)
        self.assetOptions = assetOptions
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(AppLocalization.string("可同时勾选多种资产；初始资金会按资产数量平均分配，每种资产独立执行同一套买卖规则。"))
                            .font(AppTypography.meta)
                            .foregroundStyle(AssetTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)

                        ForEach(assetOptions) { option in
                            Button {
                                toggle(option.symbol)
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 10, height: 10)

                                    Text(AppLocalization.string(option.title))
                                        .font(AppTypography.rowTitle)
                                        .foregroundStyle(AssetTheme.textPrimary)

                                    Spacer(minLength: 12)

                                    Image(systemName: selectedSymbols.contains(option.symbol) ? "checkmark.circle.fill" : "circle")
                                        .font(AppTypography.blockTitle)
                                        .foregroundStyle(selectedSymbols.contains(option.symbol) ? option.color : AssetTheme.textSecondary.opacity(0.7))
                                }
                                .padding(16)
                                .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(selectedSymbols.contains(option.symbol) ? option.color.opacity(0.45) : AssetTheme.border.opacity(0.68), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("取消")) {
                        dismiss()
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("回测资产"))
                        .font(AppTypography.blockTitleBold)
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(selectedSymbols.isEmpty ? [BacktestDefaults.dcaAssetSymbol] : selectedSymbols)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .tint(AssetTheme.gold)
                }
            }
        }
    }

    private func toggle(_ symbol: String) {
        if selectedSymbols.contains(symbol) {
            guard selectedSymbols.count > 1 else { return }
            selectedSymbols.remove(symbol)
        } else {
            selectedSymbols.insert(symbol)
        }
    }
}

struct BacktestDCAAssetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSymbol: String
    let assetOptions: [BacktestAssetOption]
    let onApply: (String) -> Void

    init(selectedSymbol: String, assetOptions: [BacktestAssetOption], onApply: @escaping (String) -> Void) {
        _selectedSymbol = State(initialValue: selectedSymbol)
        self.assetOptions = assetOptions
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(assetOptions) { option in
                            Button {
                                selectedSymbol = option.symbol
                                onApply(option.symbol)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 10, height: 10)

                                    Text(AppLocalization.string(option.title))
                                        .font(AppTypography.rowTitle)
                                        .foregroundStyle(AssetTheme.textPrimary)

                                    Spacer(minLength: 12)

                                    Image(systemName: selectedSymbol == option.symbol ? "checkmark.circle.fill" : "circle")
                                        .font(AppTypography.blockTitle)
                                        .foregroundStyle(selectedSymbol == option.symbol ? option.color : AssetTheme.textSecondary.opacity(0.7))
                                }
                                .padding(16)
                                .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(AssetTheme.border.opacity(0.68), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("关闭")) {
                        dismiss()
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("回测资产"))
                        .font(AppTypography.blockTitleBold)
                        .foregroundStyle(AssetTheme.textPrimary)
                }
            }
        }
    }
}

struct BacktestDCAAmountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Double
    let onApply: (Double) -> Void

    private let presetAmounts: [Double] = [500, 1000, 2000, 3000, 5000, 10000, 20000, 50000]

    init(amount: Double, onApply: @escaping (Double) -> Void) {
        _amount = State(initialValue: amount)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(presetAmounts, id: \.self) { preset in
                                BacktestSelectionChip(
                                    title: preset.currencyString(),
                                    isSelected: amount == preset,
                                    accent: AssetTheme.gold
                                ) {
                                    amount = preset
                                }
                            }
                        }

                        BacktestStepperCard(
                            title: AppLocalization.string("每次投入"),
                            valueText: amount.currencyString(),
                            caption: AppLocalization.string("按人民币计价，支持按固定金额持续定投。"),
                            decrementTitle: AppLocalization.string("减少"),
                            incrementTitle: AppLocalization.string("增加")
                        ) {
                            amount = max(100, amount - 100)
                        } onIncrement: {
                            amount = min(1_000_000, amount + 100)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("重置")) {
                        amount = BacktestDefaults.dcaContributionAmount
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("每次投入"))
                        .font(AppTypography.blockTitleBold)
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(amount)
                        dismiss()
                    }
                    .tint(AssetTheme.gold)
                }
            }
        }
    }
}

struct BacktestDCAIntervalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var intervalDays: Int
    let onApply: (Int) -> Void

    private let presetIntervals: [Int] = [1, 7, 14, 30, 60, 90, 180, 365]

    init(intervalDays: Int, onApply: @escaping (Int) -> Void) {
        _intervalDays = State(initialValue: intervalDays)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(presetIntervals, id: \.self) { preset in
                                BacktestSelectionChip(
                                    title: AppLocalization.format("每%d天", preset),
                                    isSelected: intervalDays == preset,
                                    accent: AssetTheme.gold
                                ) {
                                    intervalDays = preset
                                }
                            }
                        }

                        BacktestStepperCard(
                            title: AppLocalization.string("定投间隔"),
                            valueText: AppLocalization.format("每%d天", intervalDays),
                            caption: AppLocalization.string("若计划日无行情，则顺延到下一可用历史点执行。"),
                            decrementTitle: AppLocalization.string("缩短"),
                            incrementTitle: AppLocalization.string("拉长")
                        ) {
                            intervalDays = max(1, intervalDays - 1)
                        } onIncrement: {
                            intervalDays = min(365, intervalDays + 1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("重置")) {
                        intervalDays = BacktestDefaults.dcaIntervalDays
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.string("定投频率"))
                        .font(AppTypography.blockTitleBold)
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(intervalDays)
                        dismiss()
                    }
                    .tint(AssetTheme.gold)
                }
            }
        }
    }
}

struct BacktestSelectionChip: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.rowTitle)
                .foregroundStyle(isSelected ? Color.black.opacity(0.86) : AssetTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [accent.opacity(0.96), AssetTheme.goldSoft.opacity(0.88)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        : AnyShapeStyle(AssetTheme.overlaySoft),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isSelected ? Color.white.opacity(0.08) : AssetTheme.border.opacity(0.68), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct BacktestAllocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cashWeight: Double
    @State private var goldWeight: Double
    @State private var indexWeights: [String: Double]
    let indexOptions: [BacktestIndexOption]
    let onApply: (Double, Double, [String: Double]) -> Void

    private enum AllocationSlot: Hashable {
        case cash
        case gold
        case index(String)
    }

    init(
        cashWeight: Double,
        goldWeight: Double,
        indexWeights: [String: Double],
        indexOptions: [BacktestIndexOption],
        onApply: @escaping (Double, Double, [String: Double]) -> Void
    ) {
        _cashWeight = State(initialValue: cashWeight)
        _goldWeight = State(initialValue: goldWeight)
        _indexWeights = State(initialValue: indexWeights)
        self.indexOptions = indexOptions
        self.onApply = onApply
    }

    private var totalWeight: Double {
        cashWeight + goldWeight + indexOptions.reduce(0) { partial, option in
            partial + indexWeights[option.symbol, default: 0]
        }
    }

    private var remainingWeight: Int {
        Int((100 - totalWeight).rounded())
    }

    private var isAllocationComplete: Bool {
        remainingWeight == 0
    }

    private var quotaText: String {
        if remainingWeight > 0 {
            return AppLocalization.format("剩余配额 %d%%", remainingWeight)
        }
        if remainingWeight < 0 {
            return AppLocalization.format("超出 %d%%", -remainingWeight)
        }
        return AppLocalization.string("剩余配额 0%")
    }

    private var quotaColor: Color {
        if remainingWeight > 0 {
            return AssetTheme.textSecondary
        }
        if remainingWeight < 0 {
            return AssetTheme.negative
        }
        return AssetTheme.gold
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        BacktestWeightRow(title: AppLocalization.string("现金"), value: binding(for: .cash), tint: AssetTheme.textSecondary)
                        BacktestWeightRow(title: AppLocalization.string("黄金"), value: binding(for: .gold), tint: AssetTheme.gold)

                        ForEach(indexOptions) { option in
                            BacktestWeightRow(
                                title: option.title,
                                value: binding(for: .index(option.symbol)),
                                tint: option.color
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.string("重置")) {
                        resetDraft()
                    }
                    .tint(AssetTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(AppLocalization.string("调整配置"))
                            .font(AppTypography.blockTitleBold)
                            .foregroundStyle(AssetTheme.textPrimary)
                        Text(quotaText)
                            .font(AppTypography.chartCaptionStrong)
                            .foregroundStyle(quotaColor)
                    }
                    .multilineTextAlignment(.center)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        onApply(cashWeight, goldWeight, indexWeights)
                        dismiss()
                    }
                    .tint(isAllocationComplete ? AssetTheme.gold : AssetTheme.textSecondary)
                    .disabled(!isAllocationComplete)
                }
            }
        }
    }

    private func binding(for slot: AllocationSlot) -> Binding<Double> {
        Binding(
            get: { currentWeight(for: slot) },
            set: { updateWeight(for: slot, to: $0) }
        )
    }

    private func currentWeight(for slot: AllocationSlot) -> Double {
        switch slot {
        case .cash:
            return cashWeight
        case .gold:
            return goldWeight
        case let .index(symbol):
            return indexWeights[symbol, default: 0]
        }
    }

    private func otherWeightTotal(excluding slot: AllocationSlot) -> Double {
        switch slot {
        case .cash:
            return goldWeight + indexOptions.reduce(0) { $0 + indexWeights[$1.symbol, default: 0] }
        case .gold:
            return cashWeight + indexOptions.reduce(0) { $0 + indexWeights[$1.symbol, default: 0] }
        case let .index(symbol):
            return cashWeight + goldWeight + indexOptions.reduce(0) { partial, option in
                guard option.symbol != symbol else { return partial }
                return partial + indexWeights[option.symbol, default: 0]
            }
        }
    }

    private func updateWeight(for slot: AllocationSlot, to newValue: Double) {
        let clampedValue = min(max(0, newValue.rounded()), max(0, 100 - otherWeightTotal(excluding: slot)))

        switch slot {
        case .cash:
            cashWeight = clampedValue
        case .gold:
            goldWeight = clampedValue
        case let .index(symbol):
            indexWeights[symbol] = clampedValue
        }
    }

    private func resetDraft() {
        cashWeight = BacktestDefaults.cashWeight
        goldWeight = BacktestDefaults.goldWeight
        indexWeights = BacktestDefaults.indexWeights
    }
}

struct BacktestStepperCard: View {
    let title: String
    let valueText: String
    let caption: String
    let decrementTitle: String
    let incrementTitle: String
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLocalization.string(title))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
                Text(valueText)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AssetTheme.goldSoft)
            }

            Text(AppLocalization.string(caption))
                .font(AppTypography.caption)
                .foregroundStyle(AssetTheme.textSecondary)

            HStack(spacing: 10) {
                Button(AppLocalization.string(decrementTitle), action: onDecrement)
                    .buttonStyle(BacktestMiniControlButtonStyle())
                Button(AppLocalization.string(incrementTitle), action: onIncrement)
                    .buttonStyle(BacktestMiniControlButtonStyle(filled: true))
            }
        }
        .padding(16)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
        )
    }
}

struct BacktestMiniControlButtonStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.captionStrong)
            .foregroundStyle(filled ? Color.black.opacity(configuration.isPressed ? 0.7 : 0.88) : AssetTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                filled
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [AssetTheme.goldSoft, AssetTheme.gold],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    : AnyShapeStyle(AssetTheme.overlaySoft),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        filled ? AssetTheme.gold.opacity(0.32) : AssetTheme.border.opacity(0.7),
                        lineWidth: 1
                    )
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct BacktestWeightRow: View {
    let title: String
    @Binding var value: Double
    var tint: Color = AssetTheme.gold

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppLocalization.string(title))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(tint)
            }

            Slider(value: $value, in: 0...100, step: 1)
                .tint(tint)
        }
        .padding(14)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.7), lineWidth: 1)
        )
    }
}

struct BacktestMetricCard: View {
    let title: String
    var subtitle: String? = nil
    let value: String
    var accent: Color = AssetTheme.gold

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.string(title))
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AssetTheme.textSecondary)
                if let subtitle {
                    Text(AppLocalization.string(subtitle))
                        .font(AppTypography.chartCaption)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                }
            }
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(accent)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
