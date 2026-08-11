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
            return
        }

        if lastSuccessfulCalculationToken?.hasPrefix("\(template.id)|") != true {
            advice = nil
            actions = []
        }

        isRefreshing = true
        statusMessage = nil
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
        await marketStore.refreshHistoryIfNeeded(force: shouldForceHistoryRefresh)
        guard !Task.isCancelled, calculationGeneration == generation else { return }

        if isMissingRequiredHistory(for: assetOptions, marketStore: marketStore) {
            await waitForRequiredHistory(assetOptions, marketStore: marketStore)
        }
        guard !Task.isCancelled, calculationGeneration == generation else { return }

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
            updateSnapshot(snapshot)
            return
        }

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
            return
        }

        advice = nextAdvice
        lastSuccessfulCalculationToken = calculationToken
        updateSnapshot(snapshot)
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

    func cancel() {
        calculationGeneration &+= 1
        activeCalculationToken = nil
        isRefreshing = false
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
        marketStore: RemoteMarketStore
    ) async {
        for _ in 0 ..< 6 {
            guard !Task.isCancelled else { return }
            guard isMissingRequiredHistory(for: assetOptions, marketStore: marketStore) else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard isMissingRequiredHistory(for: assetOptions, marketStore: marketStore) else { return }
            await marketStore.refreshHistoryIfNeeded(force: true)
        }
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
}
