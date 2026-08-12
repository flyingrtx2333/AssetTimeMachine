import Combine
import SwiftUI

@MainActor
final class StrategyAdviceProjectionStore: ObservableObject {
    @Published private(set) var advice: StrategyRebalanceAdvice?
    @Published private(set) var actions: [StrategyRebalanceAction] = []
    @Published private(set) var historySourceNames: [String] = []
    @Published private(set) var snapshotDate: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var progressFraction = 0.0
    @Published private(set) var progressMessage = AppLocalization.string("正在准备今日策略")

    private var calculationGeneration = 0
    private var activeCalculationToken: String?
    private var lastSuccessfulCalculationToken: String?
    private var selectedAssetOptions: [BacktestAssetOption] = []
    private let adviceService: StrategyAdviceService

    init(adviceService: StrategyAdviceService) {
        self.adviceService = adviceService
    }

    func refresh(
        templateID: String,
        marketStore: RemoteMarketStore,
        snapshot: AssetSnapshot?,
        force: Bool
    ) async {
        calculationGeneration &+= 1
        let generation = calculationGeneration
        activeCalculationToken = nil

        guard let template = StrategyNotificationDefaults.template(for: templateID) else {
            advice = nil
            actions = []
            historySourceNames = []
            snapshotDate = snapshot?.date
            statusMessage = AppLocalization.string("设置里还没有可用的提醒策略。")
            isRefreshing = false
            resetProgress()
            return
        }

        if lastSuccessfulCalculationToken?.hasPrefix("\(template.id)|") != true {
            advice = nil
            actions = []
        }

        isRefreshing = true
        statusMessage = nil
        resetProgress()
        updateProgress(
            fraction: 0.08,
            message: AppLocalization.format("正在准备%@", template.title)
        )
        defer {
            if calculationGeneration == generation {
                isRefreshing = false
            }
        }

        let assetOptions = StrategyNotificationDefaults.assetOptions(for: template)
        let shouldForceHistoryRefresh = force || isMissingRequiredHistory(
            for: assetOptions,
            marketStore: marketStore
        )
        updateProgress(
            fraction: 0.20,
            message: AppLocalization.format(
                shouldForceHistoryRefresh ? "正在更新%@所需行情" : "正在读取%@所需行情",
                template.title
            )
        )
        await marketStore.refreshHistoryIfNeeded(force: shouldForceHistoryRefresh)
        guard !Task.isCancelled, calculationGeneration == generation else { return }

        if isMissingRequiredHistory(for: assetOptions, marketStore: marketStore) {
            await waitForRequiredHistory(
                assetOptions,
                templateTitle: template.title,
                generation: generation,
                marketStore: marketStore
            )
        }
        guard !Task.isCancelled, calculationGeneration == generation else { return }

        updateProgress(
            fraction: 0.54,
            message: AppLocalization.format("正在整理%@行情", template.title)
        )
        let historySymbols = Self.historySymbols(for: assetOptions)
        let historyBySymbol = Dictionary(uniqueKeysWithValues: historySymbols.compactMap { symbol in
            marketStore.history(for: symbol).map { (symbol, $0) }
        })
        let historyToken = marketStore.historyRelevanceToken(for: historySymbols)
        let calculationToken = "\(template.id)|\(historyToken)"
        activeCalculationToken = calculationToken
        selectedAssetOptions = assetOptions
        historySourceNames = Self.sourceNames(from: historyBySymbol.values)

        if !force,
           lastSuccessfulCalculationToken == calculationToken,
           advice != nil {
            updateProgress(
                fraction: 0.90,
                message: AppLocalization.string("正在匹配当前持仓")
            )
            updateSnapshot(snapshot)
            updateProgress(fraction: 1, message: AppLocalization.string("今日策略已生成"))
            return
        }

        updateProgress(
            fraction: 0.66,
            message: AppLocalization.format("正在计算%@目标仓位", template.title)
        )
        let nextAdvice = await adviceService.advice(
            calculationToken: calculationToken,
            mode: template.mode,
            assetOptions: assetOptions,
            historyBySymbol: historyBySymbol,
            force: force
        )

        guard !Task.isCancelled,
              calculationGeneration == generation,
              activeCalculationToken == calculationToken,
              StrategyNotificationDefaults.template(for: templateID)?.id == template.id,
              marketStore.historyRelevanceToken(for: historySymbols) == historyToken else { return }

        guard let nextAdvice else {
            advice = nil
            actions = []
            snapshotDate = snapshot?.date
            statusMessage = AppLocalization.string("历史行情暂时不足，今日调仓将在数据补齐后更新。")
            resetProgress()
            return
        }

        advice = Self.localizedAdvice(
            nextAdvice,
            template: template,
            assetOptions: assetOptions
        )
        lastSuccessfulCalculationToken = calculationToken
        updateProgress(
            fraction: 0.90,
            message: AppLocalization.string("正在匹配当前持仓")
        )
        updateSnapshot(snapshot)
        updateProgress(fraction: 1, message: AppLocalization.string("今日策略已生成"))
    }

    func updateSnapshot(_ snapshot: AssetSnapshot?) {
        snapshotDate = snapshot?.date
        guard let advice else {
            actions = []
            return
        }

        actions = StrategyRebalanceActionBuilder.actions(
            for: advice,
            snapshot: snapshot,
            selectedAssetOptions: selectedAssetOptions,
            allAssetOptions: BacktestDefaults.dcaAssetOptions
        )
    }

    func refreshLocalization(templateID: String, snapshot: AssetSnapshot?) {
        guard let template = StrategyNotificationDefaults.template(for: templateID) else { return }
        let assetOptions = StrategyNotificationDefaults.assetOptions(for: template)
        selectedAssetOptions = assetOptions

        if let currentAdvice = advice {
            advice = Self.localizedAdvice(
                currentAdvice,
                template: template,
                assetOptions: assetOptions
            )
        }
        updateSnapshot(snapshot)

        if !isRefreshing {
            progressMessage = AppLocalization.string("今日策略已生成")
        }
    }

    func cancel() {
        calculationGeneration &+= 1
        activeCalculationToken = nil
        isRefreshing = false
        resetProgress()
    }

    static func historySymbols(for assetOptions: [BacktestAssetOption]) -> Set<String> {
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

    private func waitForRequiredHistory(
        _ assetOptions: [BacktestAssetOption],
        templateTitle: String,
        generation: Int,
        marketStore: RemoteMarketStore
    ) async {
        let maximumAttempts = 6
        for attempt in 0 ..< maximumAttempts {
            guard !Task.isCancelled else { return }
            guard isMissingRequiredHistory(for: assetOptions, marketStore: marketStore) else { return }
            guard calculationGeneration == generation else { return }
            updateProgress(
                fraction: 0.30 + (Double(attempt) / Double(maximumAttempts)) * 0.20,
                message: AppLocalization.format(
                    "正在补齐%@行情（%d/%d）",
                    templateTitle,
                    attempt + 1,
                    maximumAttempts
                )
            )
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard isMissingRequiredHistory(for: assetOptions, marketStore: marketStore) else { return }
            await marketStore.refreshHistoryIfNeeded(force: true)
        }
    }

    private func updateProgress(fraction: Double, message: String) {
        progressFraction = min(max(fraction, progressFraction), 1)
        progressMessage = message
    }

    private func resetProgress() {
        progressFraction = 0
        progressMessage = AppLocalization.string("正在准备今日策略")
    }

    private func isMissingRequiredHistory(
        for assetOptions: [BacktestAssetOption],
        marketStore: RemoteMarketStore
    ) -> Bool {
        assetOptions.contains { option in
            guard hasUsableHistory(for: option.symbol, marketStore: marketStore) else { return true }
            if let fxSymbol = option.historicalFXSymbol {
                return !hasUsableHistory(for: fxSymbol, marketStore: marketStore)
            }
            return false
        }
    }

    private func hasUsableHistory(for symbol: String, marketStore: RemoteMarketStore) -> Bool {
        let lookupSymbol = symbol == "usd_cash" ? "usd_per_cny" : symbol
        guard let series = marketStore.history(for: lookupSymbol) else { return false }
        return series.dates.count >= 2 && series.prices.count >= 2
    }

    private static func sourceNames(
        from series: Dictionary<String, PublicHistorySeries>.Values
    ) -> [String] {
        Array(Set(series.compactMap { value in
            let source = value.source.trimmingCharacters(in: .whitespacesAndNewlines)
            return source.isEmpty ? nil : source
        })).sorted()
    }

    private static func localizedAdvice(
        _ advice: StrategyRebalanceAdvice,
        template: AdvancedBacktestStrategyTemplate,
        assetOptions: [BacktestAssetOption]
    ) -> StrategyRebalanceAdvice {
        let titlesBySymbol = Dictionary(
            uniqueKeysWithValues: assetOptions.map { ($0.symbol, $0.title) }
        )
        return StrategyRebalanceAdvice(
            strategyTitle: template.title,
            asOfDate: advice.asOfDate,
            lookbackSessions: advice.lookbackSessions,
            rebalanceSessions: advice.rebalanceSessions,
            targetAnnualVolatility: advice.targetAnnualVolatility,
            allocations: advice.allocations.map { allocation in
                StrategyRebalanceAllocation(
                    symbol: allocation.symbol,
                    title: titlesBySymbol[allocation.symbol] ?? AppLocalization.string(allocation.title),
                    targetWeight: allocation.targetWeight,
                    momentum: allocation.momentum,
                    annualizedVolatility: allocation.annualizedVolatility
                )
            }
        )
    }
}

struct StrategyAdviceLoadingProgressView: View {
    let fraction: Double
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(message)
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                    .font(AppTypography.chartAxisStrip)
                    .monospacedDigit()
                    .foregroundStyle(AssetTheme.goldSoft)
            }

            ProgressView(value: min(max(fraction, 0), 1))
                .tint(AssetTheme.gold)
                .accessibilityLabel(AppLocalization.string("今日策略生成进度"))
                .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
