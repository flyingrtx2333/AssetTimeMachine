import SwiftUI
import SwiftData
import Charts
import UIKit

enum BacktestRunStage: Equatable {
    case loadingHistory
    case preparing
    case calculating
    case finalizing
    case saving

    var progress: Double {
        switch self {
        case .loadingHistory: return 0.14
        case .preparing: return 0.28
        case .calculating: return 0.62
        case .finalizing: return 0.86
        case .saving: return 0.96
        }
    }

    var message: String {
        switch self {
        case .loadingHistory:
            return AppLocalization.string("正在加载历史数据…")
        case .preparing:
            return AppLocalization.string("正在准备回测数据…")
        case .calculating:
            return AppLocalization.string("正在计算回测…")
        case .finalizing:
            return AppLocalization.string("正在生成图表与指标…")
        case .saving:
            return AppLocalization.string("正在保存回测记录…")
        }
    }
}

struct BacktestRunProgressView: View {
    let stage: BacktestRunStage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(AssetTheme.gold)

                Text(stage.message)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text("\(Int((stage.progress * 100).rounded()))%")
                    .font(AppTypography.chartAxisStrip)
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.goldSoft)
            }

            ProgressView(value: stage.progress)
                .tint(AssetTheme.gold)
                .animation(.easeOut(duration: 0.28), value: stage.progress)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppLocalization.string("回测进度"))
        .accessibilityValue("\(Int((stage.progress * 100).rounded()))% · \(stage.message)")
    }
}

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
    let runStage: BacktestRunStage?
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

            if runStage != nil || onTapPrimaryAction != nil {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(AssetTheme.border.opacity(0.34))
                        .frame(height: 1)
                        .padding(.horizontal, 18)

                    if let runStage {
                        BacktestRunProgressView(stage: runStage)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                    } else if let onTapPrimaryAction {
                        HStack {
                            BacktestPrimaryActionButton(title: AppLocalization.string("开始回测"), systemImage: "play.fill", action: onTapPrimaryAction)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }
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

private enum BacktestDateEndpoint {
    case start
    case end
}

struct BacktestDateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var activeEndpoint: BacktestDateEndpoint = .start
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

    private var activeDateBinding: Binding<Date> {
        switch activeEndpoint {
        case .start:
            return startDateBinding
        case .end:
            return endDateBinding
        }
    }

    private var activeDateBounds: ClosedRange<Date> {
        switch activeEndpoint {
        case .start:
            return availableBounds.lowerBound...endDate
        case .end:
            return startDate...availableBounds.upperBound
        }
    }

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                sheetHeader

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(AppLocalization.string("快速选择"))
                                    .font(AppTypography.captionStrong)
                                    .foregroundStyle(AssetTheme.textSecondary)

                                Spacer(minLength: 12)

                                Text(AppLocalization.format("%d天", selectedSpanDays))
                                    .font(AppTypography.microLabel.monospacedDigit())
                                    .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                            }

                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                                spacing: 8
                            ) {
                                BacktestRangePresetButton(
                                    title: AppLocalization.string("3年"),
                                    isSelected: matchesPreset(yearsBack: 3)
                                ) {
                                    applyRelativePreset(yearsBack: 3)
                                }

                                BacktestRangePresetButton(
                                    title: AppLocalization.string("5年"),
                                    isSelected: matchesPreset(yearsBack: 5)
                                ) {
                                    applyRelativePreset(yearsBack: 5)
                                }

                                BacktestRangePresetButton(
                                    title: AppLocalization.string("10年"),
                                    isSelected: matchesPreset(yearsBack: 10)
                                ) {
                                    applyRelativePreset(yearsBack: 10)
                                }
                            }
                        }

                        HStack(spacing: 18) {
                            BacktestDateEndpointButton(
                                title: AppLocalization.string("开始日期"),
                                value: startDate.recordDateString,
                                isSelected: activeEndpoint == .start
                            ) {
                                activeEndpoint = .start
                            }

                            BacktestDateEndpointButton(
                                title: AppLocalization.string("结束日期"),
                                value: endDate.recordDateString,
                                isSelected: activeEndpoint == .end
                            ) {
                                activeEndpoint = .end
                            }
                        }

                        DatePicker("", selection: activeDateBinding, in: activeDateBounds, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.graphical)
                            .tint(AssetTheme.gold)
                            .environment(\.locale, AppLocalization.currentLocale)
                            .id(activeEndpoint)

                        Text(AppLocalization.format(
                            "可选范围：%@ - %@",
                            availableBounds.lowerBound.recordDateString,
                            availableBounds.upperBound.recordDateString
                        ))
                        .font(AppTypography.microLabel)
                        .foregroundStyle(AssetTheme.textSecondary.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var sheetHeader: some View {
        ZStack {
            Text(AppLocalization.string("调整时间"))
                .font(AppTypography.blockTitleBold)
                .foregroundStyle(AssetTheme.textPrimary)

            HStack {
                Button(AppLocalization.string("取消")) {
                    dismiss()
                }
                .foregroundStyle(AssetTheme.textSecondary)

                Spacer()

                Button(AppLocalization.string("完成")) {
                    onApply(startDate, endDate)
                    dismiss()
                }
                .fontWeight(.semibold)
                .foregroundStyle(AssetTheme.gold)
            }
        }
        .font(AppTypography.meta)
        .frame(height: 48)
        .padding(.horizontal, 18)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AssetTheme.border.opacity(0.32))
                .frame(height: 1)
        }
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
        activeEndpoint = .start
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
                .foregroundStyle(isSelected ? AssetTheme.goldSoft : AssetTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    isSelected ? AssetTheme.gold.opacity(0.16) : AssetTheme.overlaySubtle,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

private struct BacktestDateEndpointButton: View {
    let title: String
    let value: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(AppTypography.microLabel)
                    .foregroundStyle(AssetTheme.textSecondary)

                Text(value)
                    .font(AppTypography.rowTitle)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AssetTheme.goldSoft : AssetTheme.textPrimary)
                    .lineLimit(1)

                Rectangle()
                    .fill(isSelected ? AssetTheme.gold : AssetTheme.border.opacity(0.46))
                    .frame(height: isSelected ? 2 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct AdvancedStrategyLibrarySheet: View {
    private enum LibraryGroup: String, CaseIterable, Identifiable {
        case selected
        case basic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .selected: return AppLocalization.string("精选")
            case .basic: return AppLocalization.string("基础")
            }
        }

        var icon: String {
            switch self {
            case .selected: return "sparkles"
            case .basic: return "function"
            }
        }

        var accent: Color {
            switch self {
            case .selected: return AssetTheme.gold
            case .basic: return AssetTheme.accentBlue
            }
        }
    }

    private enum StrategyTier: String, CaseIterable, Identifiable {
        case steady
        case balanced
        case growth

        var id: String { rawValue }

        var title: String {
            switch self {
            case .steady: return AppLocalization.string("稳健")
            case .balanced: return AppLocalization.string("均衡")
            case .growth: return AppLocalization.string("进取")
            }
        }

        var icon: String {
            switch self {
            case .steady: return "shield.fill"
            case .balanced: return "scale.3d"
            case .growth: return "bolt.fill"
            }
        }

        var accent: Color {
            switch self {
            case .steady: return AssetTheme.accentBlue
            case .balanced: return AssetTheme.gold
            case .growth: return AssetTheme.accentOrange
            }
        }
    }

    private enum BasicStrategyFamily: String, CaseIterable, Identifiable {
        case trend
        case reversal

        var id: String { rawValue }

        var title: String {
            switch self {
            case .trend: return AppLocalization.string("趋势")
            case .reversal: return AppLocalization.string("反转")
            }
        }

        var icon: String {
            switch self {
            case .trend: return "chart.line.uptrend.xyaxis"
            case .reversal: return "arrow.uturn.down.circle.fill"
            }
        }

        var accent: Color {
            switch self {
            case .trend: return AssetTheme.accentBlue
            case .reversal: return AssetTheme.positive
            }
        }
    }

    private struct StrategySection: Identifiable {
        let id: String
        let title: String
        let icon: String
        let accent: Color
        let templates: [AdvancedBacktestStrategyTemplate]
    }

    private struct ValidationSheetSelection: Identifiable {
        let template: AdvancedBacktestStrategyTemplate
        var id: String { template.id }
    }

    @Environment(\.dismiss) private var dismiss
    let templates: [AdvancedBacktestStrategyTemplate]
    let activeTemplateID: String?
    let onSelect: (AdvancedBacktestStrategyTemplate) -> Void
    @State private var searchText = ""
    @State private var selectedGroup: LibraryGroup
    @State private var validationSelection: ValidationSheetSelection?

    init(
        templates: [AdvancedBacktestStrategyTemplate],
        activeTemplateID: String?,
        onSelect: @escaping (AdvancedBacktestStrategyTemplate) -> Void
    ) {
        self.templates = templates
        self.activeTemplateID = activeTemplateID
        self.onSelect = onSelect
        let initialGroup: LibraryGroup
        if activeTemplateID?.hasPrefix("basic-") == true {
            initialGroup = .basic
        } else {
            initialGroup = .selected
        }
        _selectedGroup = State(initialValue: initialGroup)
    }

    private var matchingTemplates: [AdvancedBacktestStrategyTemplate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return templates.filter { template in
            let matchesGroup = group(for: template) == selectedGroup
            guard matchesGroup else { return false }
            guard !query.isEmpty else { return true }
            return template.title.localizedCaseInsensitiveContains(query)
                || template.subtitle.localizedCaseInsensitiveContains(query)
                || template.category.localizedCaseInsensitiveContains(query)
                || template.mode.title.localizedCaseInsensitiveContains(query)
                || template.mode.detail.localizedCaseInsensitiveContains(query)
        }
    }

    private var availableGroups: [LibraryGroup] {
        LibraryGroup.allCases.filter { group in
            templates.contains { template in
                self.group(for: template) == group
            }
        }
    }

    private var visibleSections: [StrategySection] {
        switch selectedGroup {
        case .selected:
            return StrategyTier.allCases.compactMap { tier in
                let sectionTemplates = matchingTemplates.filter {
                    self.tier(for: $0) == tier
                }
                guard !sectionTemplates.isEmpty else { return nil }
                return StrategySection(
                    id: "selected-\(tier.id)",
                    title: tier.title,
                    icon: tier.icon,
                    accent: tier.accent,
                    templates: sectionTemplates
                )
            }
        case .basic:
            return BasicStrategyFamily.allCases.compactMap { family in
                let sectionTemplates = matchingTemplates.filter {
                    self.basicFamily(for: $0) == family
                }
                guard !sectionTemplates.isEmpty else { return nil }
                return StrategySection(
                    id: "basic-\(family.id)",
                    title: family.title,
                    icon: family.icon,
                    accent: family.accent,
                    templates: sectionTemplates
                )
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        strategyLibraryHeader
                        strategySearchArea
                        if availableGroups.count > 1 {
                            strategyGroupPicker
                        }

                        if matchingTemplates.isEmpty {
                            strategyEmptyState
                        } else {
                            ForEach(visibleSections) { section in
                                strategySection(section)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
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
            .sheet(item: $validationSelection) { selection in
                ForwardStrategyValidationSheet(template: selection.template)
            }
        }
    }

    private var strategyLibraryHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AssetTheme.gold)
                .frame(width: 38, height: 38)
                .background(AssetTheme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AssetTheme.gold.opacity(0.2), lineWidth: 1)
                )

            Text(AppLocalization.string("策略大全"))
                .font(.title2.weight(.bold))
                .foregroundStyle(AssetTheme.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private var strategySearchArea: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(AppTypography.metaStrong)
                .foregroundStyle(AssetTheme.textSecondary)
            TextField(AppLocalization.string("搜索策略、机制或资产"), text: $searchText)
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
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(AssetTheme.overlaySoft, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
        )
    }

    private var strategyGroupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableGroups) { group in
                    let isSelected = selectedGroup == group
                    let accent = group.accent
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedGroup = group
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: group.icon)
                                .font(.caption2.weight(.bold))
                            Text(group.title)
                                .font(AppTypography.captionStrong)
                            Text(String(templates.filter { self.group(for: $0) == group }.count))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(isSelected ? Color.black.opacity(0.64) : AssetTheme.textSecondary)
                        }
                        .foregroundStyle(isSelected ? Color.black.opacity(0.86) : AssetTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            isSelected
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [accent, accent.opacity(0.72)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                : AnyShapeStyle(AssetTheme.overlaySoft.opacity(0.86)),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.white.opacity(0.18) : accent.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: isSelected ? accent.opacity(0.18) : .clear, radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func strategySection(_ section: StrategySection) -> some View {
        return VStack(alignment: .leading, spacing: 9) {
            strategySectionLabel(
                icon: section.icon,
                title: section.title,
                accent: section.accent,
                count: section.templates.count
            )

            LazyVStack(spacing: 0) {
                ForEach(Array(section.templates.enumerated()), id: \.element.id) { index, template in
                    AdvancedStrategyTemplateRow(
                        template: template,
                        isActive: template.id == activeTemplateID,
                        isFeatured: template.id == activeTemplateID,
                        onInfo: template.id == "nfci-dual-core-v11" ? {
                            validationSelection = ValidationSheetSelection(template: template)
                        } : nil
                    ) {
                        onSelect(template)
                        dismiss()
                    }

                    if index < section.templates.count - 1 {
                        Divider()
                            .overlay(AssetTheme.border.opacity(0.5))
                            .padding(.leading, 46)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func strategySectionLabel(
        icon: String,
        title: String,
        accent: Color = AssetTheme.gold,
        count: Int? = nil
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(title)
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.textPrimary)

            if let count {
                Text(String(count))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.09), in: Capsule())
            }

            Spacer()
        }
    }

    private func group(for template: AdvancedBacktestStrategyTemplate) -> LibraryGroup {
        BacktestProductStrategyCatalog.isBasicTemplateID(template.id) ? .basic : .selected
    }

    private func tier(for template: AdvancedBacktestStrategyTemplate) -> StrategyTier {
        switch template.id {
        case "risk-contribution-cash-confidence-low-noise",
             "core-gold-satellite-profit-lock-momentum":
            return .steady
        case "core-gold-satellite-risk-budget-state-gate-momentum",
             "gold-nasdaq-dual-trend-barbell":
            return .growth
        default:
            return .balanced
        }
    }

    private func basicFamily(for template: AdvancedBacktestStrategyTemplate) -> BasicStrategyFamily {
        template.id == "basic-boll-mean-reversion" ? .reversal : .trend
    }

    private var strategyEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string("没有匹配策略"))
                .font(AppTypography.rowTitle)
                .foregroundStyle(AssetTheme.textPrimary)
            Text(AppLocalization.string("换个关键词，或切换策略分类。"))
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

struct CuratedStrategyBadge: View {
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
            Text(AppLocalization.string("精选"))
        }
        .font(compact ? .caption2.weight(.semibold) : AppTypography.chartAxisStrip)
        .foregroundStyle(AssetTheme.goldSoft)
        .lineLimit(1)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 3 : 4)
        .background(AssetTheme.gold.opacity(0.11), in: Capsule())
        .overlay(
            Capsule()
                .stroke(AssetTheme.gold.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

struct AdvancedStrategyTemplateRow: View {
    let template: AdvancedBacktestStrategyTemplate
    let isActive: Bool
    var isFeatured = false
    var onInfo: (() -> Void)? = nil
    let onTap: () -> Void

    private var strategyIcon: String {
        switch template.id {
        case "risk-contribution-cash-confidence-low-noise":
            return "waveform.path.ecg"
        case "nfci-dual-core-v1":
            return "point.3.connected.trianglepath.dotted"
        case "nfci-dual-core-v11":
            return "slider.horizontal.3"
        case "core-gold-satellite-equity-curve-state-gate-momentum":
            return "scale.3d"
        case "core-gold-satellite-risk-budget-state-gate-momentum":
            return "bolt.fill"
        case "core-gold-satellite-profit-lock-momentum":
            return "shield.fill"
        case "gold-nasdaq-dual-trend-barbell":
            return "arrow.triangle.swap"
        case "basic-ma60-trend":
            return "chart.line.uptrend.xyaxis"
        case "basic-ma-golden-cross":
            return "arrow.triangle.branch"
        case "basic-ma20-trend":
            return "clock.arrow.circlepath"
        case "basic-boll-mean-reversion":
            return "arrow.uturn.down.circle.fill"
        default:
            return "sparkles"
        }
    }

    private var strategyAccent: Color {
        switch template.id {
        case "risk-contribution-cash-confidence-low-noise",
             "basic-ma-golden-cross":
            return AssetTheme.positive
        case "nfci-dual-core-v1",
             "nfci-dual-core-v11":
            return AssetTheme.accentOrange
        case "core-gold-satellite-risk-budget-state-gate-momentum",
             "basic-boll-mean-reversion":
            return AssetTheme.accentOrange
        case "core-gold-satellite-profit-lock-momentum",
             "basic-ma60-trend":
            return AssetTheme.accentBlue
        case "gold-nasdaq-dual-trend-barbell":
            return AssetTheme.accentRed
        default:
            return AssetTheme.gold
        }
    }

    private var isDefaultStrategy: Bool {
        template.id == StrategyNotificationDefaults.defaultTemplateID
    }

    private var isRecommendedStrategy: Bool {
        template.id == StrategyNotificationDefaults.recommendedTemplateID
    }

    private var isCuratedStrategy: Bool {
        BacktestProductStrategyCatalog.isCuratedTemplateID(template.id)
    }

    private var isExperimentalStrategy: Bool {
        BacktestProductStrategyCatalog.isExperimentalTemplateID(template.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: strategyIcon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(strategyAccent)
                        .frame(width: 36, height: 36)
                        .background(strategyAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(template.title)
                            .font(isFeatured ? .headline.weight(.bold) : AppTypography.rowTitle)
                            .foregroundStyle(AssetTheme.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if isCuratedStrategy || isExperimentalStrategy || isRecommendedStrategy || isDefaultStrategy || isActive {
                            HStack(spacing: 5) {
                                if isCuratedStrategy {
                                    CuratedStrategyBadge(compact: true)
                                }
                                if isExperimentalStrategy {
                                    strategyBadge(AppLocalization.string("前瞻观察"), accent: AssetTheme.accentOrange)
                                }
                                if isRecommendedStrategy {
                                    strategyBadge(AppLocalization.string("推荐"), accent: AssetTheme.positive)
                                } else if isDefaultStrategy {
                                    strategyBadge(AppLocalization.string("默认"), accent: AssetTheme.gold)
                                }
                                if isActive {
                                    strategyBadge(AppLocalization.string("使用中"), accent: AssetTheme.positive)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 6)

                    Image(systemName: isActive ? "checkmark.circle.fill" : "chevron.right")
                        .font(isActive ? .headline.weight(.semibold) : .caption.weight(.bold))
                        .foregroundStyle(isActive ? AssetTheme.positive : AssetTheme.textSecondary.opacity(0.62))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 13)
                .padding(.trailing, onInfo == nil ? 13 : 7)
                .padding(.vertical, isFeatured ? 13 : 11)
            }
            .buttonStyle(.plain)

            if let onInfo {
                Button(action: onInfo) {
                    Image(systemName: "checkmark.seal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AssetTheme.accentOrange)
                        .frame(width: 34, height: 34)
                        .background(AssetTheme.accentOrange.opacity(0.1), in: Circle())
                        .accessibilityLabel(AppLocalization.string("查看验证档案"))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }
        }
        .background(
            isFeatured || isActive ? strategyAccent.opacity(0.075) : Color.clear,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(strategyAccent.opacity(0.78))
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 1)
            }
        }
    }

    private func strategyBadge(_ title: String, accent: Color) -> some View {
        Text(title)
            .font(AppTypography.chartAxisStrip)
            .foregroundStyle(accent)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(accent.opacity(0.11), in: Capsule())
    }
}

struct ForwardStrategyValidationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let template: AdvancedBacktestStrategyTemplate

    @State private var validation: PublicForwardValidationResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var liveStrategy: PublicForwardValidationStrategy? {
        validation?.strategies.first { $0.strategyID == template.id }
    }

    private var isSimplifiedV11: Bool {
        template.id == "nfci-dual-core-v11"
    }

    private var prospectiveSessions: Int {
        liveStrategy?.newSessions ?? validation?.newSessions ?? 0
    }

    private var nextMilestone: Int {
        [63, 126, 252, 504].first(where: { prospectiveSessions < $0 }) ?? 504
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        validationHeader
                        evidenceBoundaryCard
                        prospectiveOOSCard
                        retrospectiveRobustnessCard
                        factorExplanationCard
                        crossAssetCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                }
                .refreshable {
                    await loadValidation()
                }
            }
            .navigationTitle(AppLocalization.string("验证档案"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) { dismiss() }
                        .foregroundStyle(AssetTheme.gold)
                }
            }
            .task {
                await loadValidation()
            }
        }
    }

    private var validationHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSimplifiedV11 ? "slider.horizontal.3" : "point.3.connected.trianglepath.dotted")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AssetTheme.accentOrange)
                .frame(width: 44, height: 44)
                .background(AssetTheme.accentOrange.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(template.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AssetTheme.textPrimary)
                Text(AppLocalization.string("冻结策略 · 参数不得因后续表现回写修改"))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var evidenceBoundaryCard: some View {
        validationCard(title: AppLocalization.string("证据边界"), icon: "checkmark.seal.fill") {
            VStack(spacing: 9) {
                statusRow(
                    title: AppLocalization.string("回顾性稳健性"),
                    status: AppLocalization.string("通过"),
                    accent: AssetTheme.positive
                )
                statusRow(
                    title: AppLocalization.string("跨资产泛化"),
                    status: AppLocalization.string("未通过门槛"),
                    accent: AssetTheme.accentOrange
                )
                statusRow(
                    title: AppLocalization.string("真实未来 OOS"),
                    status: AppLocalization.string("进行中"),
                    accent: AssetTheme.accentBlue
                )
            }
        }
    }

    private var prospectiveOOSCard: some View {
        validationCard(title: AppLocalization.string("真实前瞻 OOS"), icon: "clock.badge.checkmark") {
            if isLoading && validation == nil {
                HStack(spacing: 9) {
                    ProgressView()
                    Text(AppLocalization.string("正在读取服务器不可变账本…"))
                        .font(AppTypography.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
            } else if let errorMessage, validation == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.string("暂时无法读取前瞻账本"))
                        .font(AppTypography.metaStrong)
                        .foregroundStyle(AssetTheme.accentRed)
                    Text(errorMessage)
                        .font(AppTypography.caption)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let validation {
                let sessions = prospectiveSessions
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(AppLocalization.string("冻结后新增交易日"))
                            .font(AppTypography.metaStrong)
                            .foregroundStyle(AssetTheme.textPrimary)
                        Spacer()
                        Text("\(sessions) / \(nextMilestone)")
                            .font(.headline.monospacedDigit().weight(.bold))
                            .foregroundStyle(AssetTheme.accentOrange)
                    }

                    ProgressView(
                        value: Double(min(sessions, nextMilestone)),
                        total: Double(max(nextMilestone, 1))
                    )
                    .tint(AssetTheme.accentOrange)

                    HStack(spacing: 7) {
                        ForEach(validation.milestones) { milestone in
                            milestoneChip(milestone)
                        }
                    }

                    Divider().overlay(AssetTheme.border.opacity(0.55))

                    if let liveStrategy {
                        validationValueRow(
                            AppLocalization.string("冻结日期"),
                            liveStrategy.frozenAt
                        )
                        validationValueRow(
                            AppLocalization.string("账本首条 Signal"),
                            liveStrategy.firstSignalDate
                        )
                        validationValueRow(
                            AppLocalization.string("最新 Signal"),
                            liveStrategy.latestSignalDate
                        )
                        validationValueRow(
                            AppLocalization.string("不可变记录"),
                            "\(liveStrategy.signalCount)"
                        )
                        validationValueRow(
                            AppLocalization.string("目标指纹"),
                            liveStrategy.latestTargetFingerprint
                        )
                        validationValueRow(
                            AppLocalization.string("最新目标现金"),
                            String(format: "%.1f%%", liveStrategy.latestDesiredCashWeight * 100)
                        )
                    }

                    Text(
                        sessions == 0
                            ? AppLocalization.string("当前尚无冻结后的新增交易日，因此不应计算或宣传前瞻收益、Sharpe 或回撤。")
                            : AppLocalization.string("前瞻样本正在累积；252 个新交易日才进行第一次主要判定，期间不得因短期表现修改冻结策略。")
                    )
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var retrospectiveRobustnessCard: some View {
        validationCard(title: AppLocalization.string("回顾性稳健性"), icon: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: 11) {
                if isSimplifiedV11 {
                    metricGrid([
                        (AppLocalization.string("历史 CAGR"), "14.35%"),
                        (AppLocalization.string("最大回撤"), "7.69%"),
                        (AppLocalization.string("Sharpe"), "1.522"),
                        (AppLocalization.string("交易数"), "451"),
                    ])
                    validationBullet(AppLocalization.string("5/7 时间折 Sharpe > 1；6/7 时间折最大回撤不高于前一简化版本。"))
                    validationBullet(AppLocalization.string("Block63 Bootstrap：Sharpe P2.5 = 1.221，MDD P97.5 = 13.93%。"))
                    validationBullet(AppLocalization.string("删除 1.24、1.30、A股 5% 哨兵与 24.4% 交易带，保留统一 1.22 与自然 25% 交易带。"))
                } else {
                    metricGrid([
                        (AppLocalization.string("历史 CAGR"), "14.58%"),
                        (AppLocalization.string("最大回撤"), "7.69%"),
                        (AppLocalization.string("Sharpe"), "1.534"),
                        (AppLocalization.string("交易数"), "460"),
                    ])
                    validationBullet(AppLocalization.string("5/7 时间折 Sharpe > 1；相对高收益核心，7/7 时间折最大回撤更低。"))
                    validationBullet(AppLocalization.string("Block63 Bootstrap：Sharpe P2.5 = 1.231，MDD P97.5 = 14.09%。"))
                    validationBullet(AppLocalization.string("50/50 双核心权重与 25% 最终交易带在验证前固定，不做事后权重搜索。"))
                }
            }
        }
    }

    private var factorExplanationCard: some View {
        validationCard(title: AppLocalization.string("因子解释与增量证据"), icon: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 10) {
                metricGrid([
                    (AppLocalization.string("NFCI主动增量"), "+1.15%/年"),
                    (AppLocalization.string("Active Sharpe"), "0.785"),
                    (AppLocalization.string("HAC t值"), "3.16–3.53"),
                    (AppLocalization.string("底座扰动"), "6/6 正增量"),
                ])
                Text(AppLocalization.string("NFCI 并不直接预测上涨。它只在基础趋势模型准备明显减仓、但信用或杠杆金融条件正在改善时，缓冲过快的风险退出。它不会凭 NFCI 新开仓，也不允许总仓超过 100%。"))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var crossAssetCard: some View {
        validationCard(title: AppLocalization.string("方法级换资产泛化"), icon: "globe.asia.australia.fill") {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text(AppLocalization.string("预注册结论"))
                        .font(AppTypography.metaStrong)
                        .foregroundStyle(AssetTheme.textPrimary)
                    Spacer()
                    Text(AppLocalization.string("未通过"))
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AssetTheme.accentOrange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AssetTheme.accentOrange.opacity(0.11), in: Capsule())
                }

                metricGrid([
                    (AppLocalization.string("独立国家市场"), "8"),
                    (AppLocalization.string("正 Sharpe"), "8 / 8"),
                    (AppLocalization.string("组合 Sharpe"), "0.417"),
                    (AppLocalization.string("组合 MDD"), "26.70%"),
                ])

                validationValueRow(AppLocalization.string("Sharpe 门槛"), "≥ 0.45  →  FAIL")
                validationValueRow(AppLocalization.string("MDD 门槛"), "≤ 25%  →  FAIL")
                validationValueRow(AppLocalization.string("买入持有 MDD"), "69.03%")

                Text(AppLocalization.string("这项测试是对相关底层资产配置方法进行换国家、换市场验证，不是把 DualCore 原样搬到 8 个国家。结果说明存在一定迁移性，但没有达到预注册门槛，所以不能标记为“跨资产泛化通过”。"))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loadValidation() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        do {
            let response = try await RemoteMarketClient.fetchForwardValidation()
            await MainActor.run {
                validation = response
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func milestoneChip(_ milestone: PublicForwardValidationMilestone) -> some View {
        let reached = prospectiveSessions >= milestone.sessions
        let accent = reached ? AssetTheme.positive : AssetTheme.textSecondary
        return HStack(spacing: 3) {
            Image(systemName: reached ? "checkmark.circle.fill" : "circle")
                .font(.caption2.weight(.bold))
            Text("\(milestone.sessions)")
                .font(.caption2.monospacedDigit().weight(.bold))
        }
        .foregroundStyle(accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func statusRow(title: String, status: String, accent: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
            Text(title)
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.textPrimary)
            Spacer()
            Text(status)
                .font(AppTypography.captionStrong)
                .foregroundStyle(accent)
        }
    }

    private func validationValueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(AppTypography.caption)
                .foregroundStyle(AssetTheme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(AppTypography.captionStrong.monospacedDigit())
                .foregroundStyle(AssetTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func validationBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(AssetTheme.accentOrange.opacity(0.72))
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            Text(text)
                .font(AppTypography.caption)
                .foregroundStyle(AssetTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func metricGrid(_ metrics: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.0)
                        .font(.caption2)
                        .foregroundStyle(AssetTheme.textSecondary)
                    Text(metric.1)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AssetTheme.overlaySoft.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func validationCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AssetTheme.accentOrange)
                    .frame(width: 28, height: 28)
                    .background(AssetTheme.accentOrange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)
                Spacer()
            }
            content()
        }
        .padding(14)
        .background(AssetTheme.overlaySoft.opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.55), lineWidth: 1)
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
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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
        case .goldNasdaqDualTrendBarbell:
            growth = 0.88; stability = 0.78; defense = 0.80; flexibility = 0.82
        case .convexCrashHedgeComposite:
            growth = 0.98; stability = 0.74; defense = 0.78; flexibility = 0.96
        case .onlineStrategyAllocator:
            growth = 0.76; stability = 0.94; defense = 0.94; flexibility = 0.98
        case .riskContributionReallocation:
            growth = 0.92; stability = 0.98; defense = 0.98; flexibility = 1.00
        case .riskContributionRegimeRouter:
            growth = 0.98; stability = 0.96; defense = 0.96; flexibility = 1.00
        case .riskContributionRecoveryRouter:
            growth = 0.99; stability = 0.97; defense = 0.96; flexibility = 1.00
        case .riskContributionCashConfidenceRouter,
             .riskContributionCashConfidenceLowNoise:
            growth = 1.00; stability = 1.00; defense = 1.00; flexibility = 1.00
        case .nfciDualCoreV1,
             .nfciDualCoreSimplifiedV11:
            growth = 0.96; stability = 1.00; defense = 1.00; flexibility = 0.98
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
    @State private var selectedSectionID: String
    let assetOptions: [BacktestAssetOption]
    let onApply: (Set<String>) -> Void

    init(selectedSymbols: Set<String>, assetOptions: [BacktestAssetOption], onApply: @escaping (Set<String>) -> Void) {
        let initialSelection = selectedSymbols.isEmpty ? [BacktestDefaults.dcaAssetSymbol] : selectedSymbols
        _selectedSymbols = State(initialValue: initialSelection)
        let selectedSection = assetOptions.first { initialSelection.contains($0.symbol) }?.category
            ?? assetOptions.first?.category
            ?? "index"
        _selectedSectionID = State(initialValue: selectedSection)
        self.assetOptions = assetOptions
        self.onApply = onApply
    }

    private var catalogAssets: [MarketAssetDescriptor] {
        assetOptions.map(\.marketDescriptor)
    }

    private var visibleOptions: [BacktestAssetOption] {
        assetOptions.filter { $0.category == selectedSectionID }
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

                        MarketAssetCategoryStrip(
                            assets: catalogAssets,
                            selectedSectionID: $selectedSectionID
                        )

                        VStack(spacing: 0) {
                            ForEach(Array(visibleOptions.enumerated()), id: \.element.id) { index, option in
                                MarketAssetOptionTile(
                                    asset: option.marketDescriptor,
                                    isSelected: selectedSymbols.contains(option.symbol),
                                    showsCheckbox: true
                                ) {
                                    toggle(option.symbol)
                                }

                                if index < visibleOptions.count - 1 {
                                    Divider()
                                        .overlay(AssetTheme.border.opacity(0.28))
                                        .padding(.leading, 51)
                                }
                            }
                        }
                        .background(AssetTheme.overlaySubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    @State private var selectedSectionID: String
    let assetOptions: [BacktestAssetOption]
    let onApply: (String) -> Void

    init(selectedSymbol: String, assetOptions: [BacktestAssetOption], onApply: @escaping (String) -> Void) {
        _selectedSymbol = State(initialValue: selectedSymbol)
        _selectedSectionID = State(initialValue: assetOptions.first(where: { $0.symbol == selectedSymbol })?.category ?? assetOptions.first?.category ?? "index")
        self.assetOptions = assetOptions
        self.onApply = onApply
    }

    private var catalogAssets: [MarketAssetDescriptor] {
        assetOptions.map(\.marketDescriptor)
    }

    private var visibleOptions: [BacktestAssetOption] {
        assetOptions.filter { $0.category == selectedSectionID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        MarketAssetCategoryStrip(
                            assets: catalogAssets,
                            selectedSectionID: $selectedSectionID
                        )

                        VStack(spacing: 0) {
                            ForEach(Array(visibleOptions.enumerated()), id: \.element.id) { index, option in
                                MarketAssetOptionTile(
                                    asset: option.marketDescriptor,
                                    isSelected: selectedSymbol == option.symbol
                                ) {
                                    selectedSymbol = option.symbol
                                    onApply(option.symbol)
                                    dismiss()
                                }

                                if index < visibleOptions.count - 1 {
                                    Divider()
                                        .overlay(AssetTheme.border.opacity(0.28))
                                        .padding(.leading, 51)
                                }
                            }
                        }
                        .background(AssetTheme.overlaySubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
