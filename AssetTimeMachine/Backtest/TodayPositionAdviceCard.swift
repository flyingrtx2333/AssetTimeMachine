import Charts
import Combine
import SwiftData
import SwiftUI

private struct StrategyHoldingSlice: Identifiable {
    let id: String
    let title: String
    let weight: Double
    let color: Color
}

private enum StrategyHoldingPalette {
    static let cash = Color(red: 0.39, green: 0.44, blue: 0.53)

    static func color(for symbol: String) -> Color {
        switch symbol {
        case "gold_cny":
            return Color(red: 0.91, green: 0.66, blue: 0.24)
        case "sp500":
            return Color(red: 0.14, green: 0.68, blue: 0.72)
        case "nasdaq":
            return Color(red: 0.29, green: 0.46, blue: 0.91)
        case "dowjones":
            return Color(red: 0.91, green: 0.43, blue: 0.24)
        case "hsi":
            return Color(red: 0.84, green: 0.28, blue: 0.47)
        case "csi300":
            return Color(red: 0.24, green: 0.65, blue: 0.43)
        case "shanghai_composite":
            return Color(red: 0.52, green: 0.38, blue: 0.82)
        case "shenzhen_component":
            return Color(red: 0.76, green: 0.31, blue: 0.67)
        case "chinext":
            return Color(red: 0.25, green: 0.72, blue: 0.62)
        case "nikkei":
            return Color(red: 0.79, green: 0.48, blue: 0.18)
        case "oil_wti_cny":
            return Color(red: 0.65, green: 0.38, blue: 0.18)
        default:
            return Color(red: 0.45, green: 0.58, blue: 0.76)
        }
    }
}

struct TodayPositionAdviceCard: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appLanguageStore: AppLanguageStore
    @AppStorage("app.strategyNotifications.templateID") private var strategyTemplateID = StrategyRebalanceDefaults.defaultTemplateID
    @ObservedObject var marketStore: RemoteMarketStore
    let isActive: Bool

    @StateObject private var adviceStore: StrategyAdviceProjectionStore
    @State private var pendingSnapshotRefreshTask: Task<Void, Never>?
    @State private var showsOperationAmounts = false
    @State private var showsStrategyLibrary = false

    init(
        marketStore: RemoteMarketStore,
        adviceService: StrategyAdviceService,
        isActive: Bool
    ) {
        self.marketStore = marketStore
        self.isActive = isActive
        _adviceStore = StateObject(
            wrappedValue: StrategyAdviceProjectionStore(adviceService: adviceService)
        )
    }

    private var selectedTemplate: AdvancedBacktestStrategyTemplate? {
        StrategyRebalanceDefaults.template(for: strategyTemplateID)
    }

    private var relevantHistorySymbols: Set<String> {
        guard let selectedTemplate else { return [] }
        return StrategyAdviceProjectionStore.historySymbols(
            for: StrategyRebalanceDefaults.assetOptions(for: selectedTemplate)
        )
    }

    private var adviceTaskID: String {
        "\(isActive)|\(strategyTemplateID)"
    }

    private var relevantHistoryToken: String {
        marketStore.historyRelevanceToken(for: relevantHistorySymbols)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if adviceStore.isRefreshing && adviceStore.statusMessage == nil {
                loadingState
            }

            if let statusMessage = adviceStore.statusMessage {
                statusState(statusMessage)
            } else if let advice = adviceStore.advice {
                adviceContent(advice)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .task(id: adviceTaskID) {
            guard isActive else {
                adviceStore.cancel()
                return
            }
            await refreshAdvice(force: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { notification in
            guard isActive, PortfolioSaveNotificationFilter.affectsPortfolio(notification) else { return }
            scheduleSnapshotRefresh()
        }
        .onChange(of: relevantHistoryToken) { _, _ in
            guard isActive, !adviceStore.isRefreshing, adviceStore.advice != nil else { return }
            Task { await refreshAdvice(force: false) }
        }
        .onChange(of: appLanguageStore.language) { _, _ in
            let latestSnapshot = try? SnapshotService.latestSnapshot(in: modelContext)
            adviceStore.refreshLocalization(
                templateID: strategyTemplateID,
                snapshot: latestSnapshot
            )
        }
        .onDisappear {
            pendingSnapshotRefreshTask?.cancel()
            pendingSnapshotRefreshTask = nil
            adviceStore.cancel()
        }
        .sheet(isPresented: $showsStrategyLibrary) {
            AdvancedStrategyLibrarySheet(
                templates: StrategyRebalanceDefaults.eligibleTemplates,
                activeTemplateID: selectedTemplate?.id,
                titleLocalizationKey: "选择调仓策略"
            ) { template in
                strategyTemplateID = template.id
                showsStrategyLibrary = false
            }
            .presentationDetents([.fraction(0.72), .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(AppLocalization.string("今日持仓建议"))
                    .font(AppTypography.eyebrow)
                    .foregroundStyle(AssetTheme.goldSoft)

                Spacer(minLength: 8)

                Button {
                    Task { await refreshAdvice(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(AppTypography.captionStrong)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(adviceStore.isRefreshing || !isActive)
                .accessibilityLabel(AppLocalization.string("刷新今日持仓建议"))
            }

            Button {
                showsStrategyLibrary = true
            } label: {
                HStack(spacing: 8) {
                    Text(AppLocalization.string("调仓策略"))
                        .font(AppTypography.meta)
                        .foregroundStyle(AssetTheme.textSecondary)

                    Spacer(minLength: 8)

                    Text(selectedTemplate?.title ?? AppLocalization.string("未选择策略"))
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(AssetTheme.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)

                    if let selectedTemplate,
                       BacktestProductStrategyCatalog.isCuratedTemplateID(selectedTemplate.id) {
                        CuratedStrategyBadge(compact: true)
                    }

                    Image(systemName: "chevron.right")
                        .font(AppTypography.microLabel)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    Divider().overlay(AssetTheme.border.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("调仓策略"))
            .accessibilityValue(
                selectedTemplate.map(StrategyRebalanceDefaults.pickerTitle)
                    ?? AppLocalization.string("未选择策略")
            )
        }
    }

    private var loadingState: some View {
        StrategyAdviceLoadingProgressView(
            fraction: adviceStore.progressFraction,
            message: adviceStore.progressMessage
        )
        .padding(.vertical, 8)
    }

    private func statusState(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(AssetTheme.accentOrange)

            Text(message)
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adviceContent(_ advice: StrategyRebalanceAdvice) -> some View {
        let currentSlices = currentHoldingSlices
        let targetSlices = targetHoldingSlices(for: advice)

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 30) {
                StrategyHoldingDonut(
                    title: AppLocalization.string("目前持仓"),
                    slices: currentSlices,
                    centerValue: currentInvestedWeight
                )

                StrategyHoldingDonut(
                    title: AppLocalization.string("目标持仓"),
                    slices: targetSlices,
                    centerValue: advice.totalTargetWeight
                )
            }
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(AppLocalization.string("持仓调整"))
                        .font(AppTypography.metaStrong)
                        .foregroundStyle(AssetTheme.textPrimary)

                    Spacer(minLength: 8)

                    Button {
                        showsOperationAmounts.toggle()
                    } label: {
                        Image(systemName: showsOperationAmounts ? "eye" : "eye.slash")
                            .font(AppTypography.captionStrong)
                            .foregroundStyle(AssetTheme.textSecondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        AppLocalization.string(
                            showsOperationAmounts ? "隐藏操作金额" : "显示操作金额"
                        )
                    )
                }
                .padding(.bottom, 6)

                actionTableHeader

                Divider()
                    .overlay(AssetTheme.border.opacity(0.72))

                if adviceStore.actions.isEmpty {
                    cashActionRow(advice: advice)
                } else {
                    ForEach(adviceStore.actions) { action in
                        actionRow(action)
                        if action.id != adviceStore.actions.last?.id || advice.cashWeight > 0.005 {
                            Divider()
                                .overlay(AssetTheme.border.opacity(0.46))
                        }
                    }

                    if advice.cashWeight > 0.005 {
                        cashActionRow(advice: advice)
                    }
                }
            }

            provenanceSection(advice)
        }
    }

    private func provenanceSection(_ advice: StrategyRebalanceAdvice) -> some View {
        Text(
            "\(AppLocalization.format("信号截至 %@", advice.asOfDate.recordDateString)) · "
                + "\(AppLocalization.string("资产记录")) "
                + (adviceStore.snapshotDate?.recordDateString ?? AppLocalization.string("暂无记录"))
        )
        .font(AppTypography.caption)
        .foregroundStyle(AssetTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }

    private var actionTableHeader: some View {
        HStack(spacing: 8) {
            Text(AppLocalization.string("资产"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(AppLocalization.string("当前值"))
                .frame(width: 50, alignment: .trailing)
            Text(AppLocalization.string("目标"))
                .frame(width: 50, alignment: .trailing)
            Text(AppLocalization.string("操作"))
                .frame(width: 76, alignment: .trailing)
        }
        .font(AppTypography.microLabel)
        .foregroundStyle(AssetTheme.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .padding(.bottom, 8)
    }

    private func actionRow(_ action: StrategyRebalanceAction) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(StrategyHoldingPalette.color(for: action.symbol))
                    .frame(width: 6, height: 6)

                Text(action.title)
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AssetTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(action.currentWeight?.percentString(maxFractionDigits: 1) ?? "—")
                .frame(width: 50, alignment: .trailing)

            Text(action.targetWeight.percentString(maxFractionDigits: 1))
                .frame(width: 50, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(action.kind.title)
                    .foregroundStyle(action.kind.accent)

                if showsOperationAmounts {
                    Text(action.amountText)
                        .font(AppTypography.microLabel.monospacedDigit())
                        .foregroundStyle(AssetTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .frame(width: 76, alignment: .trailing)
        }
        .font(AppTypography.caption.monospacedDigit())
        .foregroundStyle(AssetTheme.textSecondary)
        .padding(.vertical, 9)
    }

    private func cashActionRow(advice: StrategyRebalanceAdvice) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(StrategyHoldingPalette.cash)
                    .frame(width: 6, height: 6)

                Text(AppLocalization.string("现金/其他"))
                    .font(AppTypography.captionStrong)
                    .foregroundStyle(AssetTheme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(currentResidualWeight?.percentString(maxFractionDigits: 1) ?? "—")
                .frame(width: 50, alignment: .trailing)

            Text(advice.cashWeight.percentString(maxFractionDigits: 1))
                .frame(width: 50, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(AppLocalization.string("防守仓位"))
                    .font(AppTypography.captionStrong)
            }
            .frame(width: 76, alignment: .trailing)
            .foregroundStyle(AssetTheme.textSecondary)
        }
        .font(AppTypography.caption.monospacedDigit())
        .foregroundStyle(AssetTheme.textSecondary)
        .padding(.vertical, 9)
    }

    private var currentHoldingSlices: [StrategyHoldingSlice] {
        let assetSlices = adviceStore.actions.compactMap { action -> StrategyHoldingSlice? in
            guard let weight = action.currentWeight, weight > 0.0001 else { return nil }
            return StrategyHoldingSlice(
                id: "current-\(action.symbol)",
                title: action.title,
                weight: weight,
                color: StrategyHoldingPalette.color(for: action.symbol)
            )
        }

        guard !assetSlices.isEmpty else { return [] }
        let residual = max(0, 1 - assetSlices.reduce(0) { $0 + $1.weight })
        guard residual > 0.005 else { return assetSlices }
        return assetSlices + [
            StrategyHoldingSlice(
                id: "current-cash-other",
                title: AppLocalization.string("现金/其他"),
                weight: residual,
                color: StrategyHoldingPalette.cash
            )
        ]
    }

    private func targetHoldingSlices(for advice: StrategyRebalanceAdvice) -> [StrategyHoldingSlice] {
        var slices = advice.allocations.compactMap { allocation -> StrategyHoldingSlice? in
            guard allocation.targetWeight > 0.0001 else { return nil }
            return StrategyHoldingSlice(
                id: "target-\(allocation.symbol)",
                title: allocation.title,
                weight: allocation.targetWeight,
                color: StrategyHoldingPalette.color(for: allocation.symbol)
            )
        }

        if advice.cashWeight > 0.005 || slices.isEmpty {
            slices.append(
                StrategyHoldingSlice(
                    id: "target-cash-other",
                    title: AppLocalization.string("现金/其他"),
                    weight: max(advice.cashWeight, slices.isEmpty ? 1 : 0),
                    color: StrategyHoldingPalette.cash
                )
            )
        }
        return slices
    }

    private var currentResidualWeight: Double? {
        let weights = adviceStore.actions.compactMap(\.currentWeight)
        guard !weights.isEmpty else { return nil }
        return max(0, 1 - weights.reduce(0, +))
    }

    private var currentInvestedWeight: Double? {
        let weights = adviceStore.actions.compactMap(\.currentWeight)
        guard !weights.isEmpty else { return nil }
        return weights.reduce(0, +)
    }

    @MainActor
    private func refreshAdvice(force: Bool) async {
        let snapshot = try? SnapshotService.latestSnapshot(in: modelContext)
        await adviceStore.refresh(
            templateID: strategyTemplateID,
            marketStore: marketStore,
            snapshot: snapshot,
            force: force
        )
    }

    @MainActor
    private func scheduleSnapshotRefresh() {
        pendingSnapshotRefreshTask?.cancel()
        pendingSnapshotRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, isActive else { return }
            adviceStore.updateSnapshot(try? SnapshotService.latestSnapshot(in: modelContext))
            pendingSnapshotRefreshTask = nil
        }
    }
}

private struct StrategyHoldingDonut: View {
    let title: String
    let slices: [StrategyHoldingSlice]
    let centerValue: Double?

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(AppTypography.captionStrong)
                .foregroundStyle(AssetTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            ZStack {
                if slices.isEmpty {
                    Circle()
                        .stroke(AssetTheme.border.opacity(0.9), style: StrokeStyle(lineWidth: 13, dash: [3, 4]))
                        .padding(10)

                    Text("--")
                        .font(AppTypography.rowValue.monospacedDigit())
                        .foregroundStyle(AssetTheme.textSecondary)
                } else {
                    Chart(slices) { slice in
                        SectorMark(
                            angle: .value("allocation", slice.weight),
                            innerRadius: .ratio(0.7),
                            angularInset: 1.2
                        )
                        .cornerRadius(1.5)
                        .foregroundStyle(slice.color)
                    }
                    .chartLegend(.hidden)

                    Text(centerValue?.percentString(maxFractionDigits: 1) ?? "—")
                        .font(AppTypography.rowValue.monospacedDigit())
                        .foregroundStyle(AssetTheme.textPrimary)
                }
            }
            .frame(height: 96)
        }
        .frame(maxWidth: .infinity)
    }
}
