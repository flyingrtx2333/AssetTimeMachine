import AssetTimeMachineBacktestCore
import Combine
import Foundation
import SwiftData

struct NativeQuantConfiguration: Sendable {
    var kind: BacktestRecordKind = .allocation
    var cashWeight = BacktestDefaults.cashWeight
    var goldWeight = BacktestDefaults.goldWeight
    var indexWeights = BacktestDefaults.indexWeights
    var dcaSymbol = BacktestDefaults.dcaAssetSymbol
    var contribution = BacktestDefaults.dcaContributionAmount
    var intervalDays = BacktestDefaults.dcaIntervalDays
    var templateID = StrategyRebalanceDefaults.defaultTemplateID
    var selectedSymbols: Set<String> = []
    var initialCash = 100_000.0
    var tradeAmount = 10_000.0
    var fee = BacktestDefaults.advancedFeeRatePercent
    var slippage = BacktestDefaults.advancedSlippageRatePercent
    var maxPosition = 100.0
    var cooldown = 0
    var stopLoss = 0.0
    var takeProfit = 0.0
    var mode: AdvancedBacktestStrategyMode = .ruleBased
    var buyDirection: AdvancedBacktestSignalDirection = .consecutiveDown
    var buyDays = 3
    var sellDirection: AdvancedBacktestSignalDirection = .consecutiveUp
    var sellDays = 3
    var startDate: Date?
    var endDate: Date?

    init() { applyTemplate(templateID) }

    mutating func applyTemplate(_ id: String) {
        templateID = id
        guard let template = AdvancedBacktestStrategyTemplate.all.first(where: { $0.id == id }) else { return }
        mode = template.mode
        selectedSymbols = Set(StrategyRebalanceDefaults.assetOptions(for: template).map(\.symbol))
        tradeAmount = initialCash * template.tradeAmountRatio
        maxPosition = template.maxPositionRatio
        cooldown = template.cooldownDays
        stopLoss = template.stopLossRatio
        takeProfit = template.takeProfitRatio
        buyDirection = template.buyRule.direction; buyDays = template.buyRule.days
        sellDirection = template.sellRule.direction; sellDays = template.sellRule.days
    }

    var settings: AdvancedBacktestRiskSettings {
        .init(feeRate: fee, slippageRate: slippage, maxPositionRatio: maxPosition,
              cooldownDays: cooldown, stopLossRatio: stopLoss, takeProfitRatio: takeProfit)
    }

    func assetOptions(catalog: [BacktestAssetOption]) -> [BacktestAssetOption] {
        let all = catalog + BacktestDefaults.strategyAssetOptions.filter { option in !catalog.contains(where: { $0.symbol == option.symbol }) }
        let symbols = selectedSymbols.union(mode.requiredSignalAssetSymbols)
        return all.filter { symbols.contains($0.symbol) }
    }

    func validate() throws {
        if let startDate, let endDate, startDate >= endDate { throw NativeQuantError.invalid("结束日期须晚于开始日期") }
        switch kind {
        case .allocation:
            let weights = [cashWeight, goldWeight] + Array(indexWeights.values)
            guard weights.allSatisfy({ $0.isFinite && $0 >= 0 }), abs(weights.reduce(0, +) - 100) < 0.01 else {
                throw NativeQuantError.invalid("配置比例合计须为 100%")
            }
        case .dca:
            guard contribution.isFinite, contribution > 0, intervalDays > 0 else { throw NativeQuantError.invalid("请填写有效的定投金额和间隔") }
        case .advanced:
            guard initialCash.isFinite, initialCash > 0, tradeAmount.isFinite, tradeAmount > 0,
                  [fee, slippage, stopLoss, takeProfit].allSatisfy({ $0.isFinite && (0...100).contains($0) }),
                  maxPosition.isFinite, (0...100).contains(maxPosition), cooldown >= 0, buyDays > 0, sellDays > 0,
                  !selectedSymbols.isEmpty else { throw NativeQuantError.invalid("请检查策略参数与资产选择") }
        }
    }

    @MainActor
    mutating func restore(_ record: BacktestRecord) throws {
        guard let config = BacktestRecordCodec.decodeConfig(from: record) else { throw NativeQuantError.invalid("此记录缺少可恢复的参数") }
        kind = config.kind
        startDate = record.startDate; endDate = record.endDate
        cashWeight = config.cashWeight ?? BacktestDefaults.cashWeight
        goldWeight = config.goldWeight ?? BacktestDefaults.goldWeight
        indexWeights = config.indexWeights ?? BacktestDefaults.indexWeights
        dcaSymbol = config.dcaAssetSymbol ?? BacktestDefaults.dcaAssetSymbol
        contribution = config.dcaContributionAmount ?? BacktestDefaults.dcaContributionAmount
        intervalDays = config.dcaIntervalDays ?? BacktestDefaults.dcaIntervalDays
        selectedSymbols = Set(config.selectedAssetSymbols ?? config.selectedAssetSymbol.map { [$0] } ?? [])
        initialCash = config.initialCash ?? 100_000; tradeAmount = config.tradeAmount ?? 10_000
        fee = config.feeRate ?? BacktestDefaults.advancedFeeRatePercent
        slippage = config.slippageRate ?? BacktestDefaults.advancedSlippageRatePercent
        maxPosition = config.maxPositionRatio ?? 70; cooldown = config.cooldownDays ?? 3
        stopLoss = config.stopLossRatio ?? 0; takeProfit = config.takeProfitRatio ?? 0
        mode = config.strategyModeRawValue.flatMap(AdvancedBacktestStrategyMode.init(rawValue:)) ?? .ruleBased
        buyDirection = config.buyDirectionRawValue.flatMap(AdvancedBacktestSignalDirection.init(rawValue:)) ?? .consecutiveDown
        sellDirection = config.sellDirectionRawValue.flatMap(AdvancedBacktestSignalDirection.init(rawValue:)) ?? .consecutiveUp
        buyDays = config.buyDays ?? 3; sellDays = config.sellDays ?? 3
        templateID = config.runtimeProvenance?.strategy?.id
            ?? (mode.isRotation ? AdvancedBacktestStrategyTemplate.all.first(where: { $0.mode == mode })?.id ?? "custom" : "custom")
    }
}

enum NativeQuantError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// The native UI uses the same preparation, engines and record codec as the iPhone app.
enum NativeQuantCalculation {
    case allocation(BacktestReport)
    case dca(DCABacktestReport)
    case advanced(AdvancedBacktestReport)

    static func run(_ config: NativeQuantConfiguration, catalog: [BacktestAssetOption],
                    history: [String: PublicHistorySeries], nfci: BacktestNFCIAsOfData?) throws -> Self {
        try config.validate()
        switch config.kind {
        case .allocation, .dca:
            let option = catalog.first { $0.symbol == config.dcaSymbol }
            let prepared = StandardBacktestDataSupport.prepare(.init(
                mode: config.kind == .allocation ? .allocation : .dca, goldWeight: config.goldWeight,
                indexWeights: config.indexWeights, indexSymbols: BacktestDefaults.indexOptions.map(\.symbol),
                dcaAssetSymbol: config.dcaSymbol, dcaAssetOption: option,
                selectedStartDate: config.startDate, selectedEndDate: config.endDate, historySnapshots: history))
            try validateRange(config, available: prepared.availableDateBounds)
            if config.kind == .allocation, let report = BacktestEngine.run(cashWeight: config.cashWeight,
                goldWeight: config.goldWeight, goldSeries: prepared.filteredGoldSeries,
                indexWeights: config.indexWeights, indexSeriesBySymbol: prepared.filteredIndexSeriesBySymbol) {
                return .allocation(report)
            }
            if config.kind == .dca, let option,
               let report = BacktestEngine.runDCA(assetSeries: prepared.filteredDCASeries, assetOption: option,
                    fxSeries: prepared.filteredDCAFXSeries, contributionAmount: config.contribution, intervalDays: config.intervalDays) {
                return .dca(report)
            }
        case .advanced:
            let options = config.assetOptions(catalog: catalog)
            guard AdvancedBacktestDataSupport.hasRequiredHistoryData(for: options, in: history) else {
                throw NativeQuantError.invalid("所选资产或汇率行情不完整，请刷新后重试")
            }
            let prepared = AdvancedBacktestDataSupport.buildDataCache(calculationAssetOptions: options,
                strategyMode: config.mode, historySnapshots: history, selectedStartDate: config.startDate, selectedEndDate: config.endDate)
            try validateRange(config, available: prepared.availableDateBounds)
            let bounds = AdvancedBacktestDataSupport.effectiveDateBounds(availableBounds: prepared.availableDateBounds,
                selectedStartDate: config.startDate, selectedEndDate: config.endDate)
            if config.mode.isRotation {
                let statefulBounds = prepared.availableDateBounds.flatMap { available in bounds.map { available.lowerBound...$0.upperBound } }
                // Preserve pre-range state and T-1 warmup before rebasing the selected window.
                if let run = BacktestEngine.runAdvancedRotationStrategyWithTrace(assetInputs: prepared.selectedAssetInputs,
                    initialCash: config.initialCash, settings: config.settings, mode: config.mode, nfciAsOf: nfci, dateBounds: statefulBounds) {
                    if let bounds, let report = BacktestEngine.statefulAdvancedReport(from: run.report,
                        dailyStates: run.dailyStates, within: bounds, rebasedTo: config.initialCash) { return .advanced(report) }
                    if bounds == nil { return .advanced(run.report) }
                }
            } else if let report = BacktestEngine.runAdvancedStrategies(assetInputs: prepared.filteredAssetInputs,
                initialCash: config.initialCash, tradeAmount: config.tradeAmount,
                buyRule: .init(direction: config.buyDirection, days: config.buyDays),
                sellRule: .init(direction: config.sellDirection, days: config.sellDays), settings: config.settings) {
                return .advanced(report)
            }
        }
        throw NativeQuantError.invalid("该区间行情不足，无法完成回测")
    }

    fileprivate static func validateRange(_ config: NativeQuantConfiguration, available: ClosedRange<Date>?) throws {
        guard let available,
              max(config.startDate ?? available.lowerBound, available.lowerBound) < min(config.endDate ?? available.upperBound, available.upperBound) else {
            throw NativeQuantError.invalid("所选日期与可用行情没有重叠")
        }
    }

    @MainActor func makeRecord(config: NativeQuantConfiguration, catalog: [BacktestAssetOption]) -> BacktestRecord {
        switch self {
        case .allocation(let report):
            let configData = BacktestRecordConfigPayload(kind: .allocation, cashWeight: config.cashWeight,
                goldWeight: config.goldWeight, indexWeights: config.indexWeights)
            return record(kind: .allocation, title: "配置回测", points: report.points, totalReturn: report.totalReturn,
                annualized: report.annualizedReturn, drawdown: report.maxDrawdown, volatility: report.annualizedVolatility,
                sharpe: report.sharpeRatio, config: configData, summary: "现金 \(config.cashWeight)% · 黄金 \(config.goldWeight)%")
        case .dca(let report):
            let payload = BacktestRecordConfigPayload(kind: .dca, dcaAssetSymbol: config.dcaSymbol,
                dcaContributionAmount: config.contribution, dcaIntervalDays: config.intervalDays)
            let record = record(kind: .dca, title: "定投回测", points: report.points, totalReturn: report.totalReturn,
                annualized: report.annualizedReturn, drawdown: report.maxDrawdown, volatility: report.annualizedVolatility,
                sharpe: report.sharpeRatio, config: payload, summary: "\(config.dcaSymbol) · 每 \(config.intervalDays) 天 · \(config.contribution)")
            record.finalValue = report.finalPortfolioValue; record.totalInvested = report.totalInvested
            record.profitLoss = report.profitLoss; record.tradeCount = report.contributionCount
            return record
        case .advanced(let report):
            let reference = try? StrategyRegistry.definition(id: config.templateID).reference
            return AdvancedBacktestDataSupport.buildRecordDraft(report: report, selectedAssetOptions: config.assetOptions(catalog: catalog),
                initialCash: config.initialCash, tradeAmount: config.tradeAmount, feeRate: config.fee, slippageRate: config.slippage,
                maxPositionRatio: config.maxPosition, cooldownDays: config.cooldown, stopLossRatio: config.stopLoss, takeProfitRatio: config.takeProfit,
                strategyMode: config.mode, buyDirection: config.buyDirection, buyDays: config.buyDays,
                sellDirection: config.sellDirection, sellDays: config.sellDays,
                configSummary: "\(config.mode.localizedTitle) · 费率 \(config.fee)% · 滑点 \(config.slippage)%", strategyReference: reference).record
        }
    }

    @MainActor private func record(kind: BacktestRecordKind, title: String, points: [BacktestSeriesPoint], totalReturn: Double,
        annualized: Double?, drawdown: Double, volatility: Double?, sharpe: Double?, config: BacktestRecordConfigPayload, summary: String) -> BacktestRecord {
        BacktestRecord(kindRawValue: kind.rawValue, title: title, subtitle: title, configSummary: summary,
            startDate: points.first?.date, endDate: points.last?.date, totalReturn: totalReturn,
            annualizedReturn: annualized, maxDrawdown: drawdown, annualizedVolatility: volatility, sharpeRatio: sharpe,
            finalValue: points.last?.portfolioValue, pointsJSON: BacktestRecordCodec.pointsData(from: points), configJSON: BacktestRecordCodec.configData(from: config))
    }
}

@MainActor
final class NativeQuantStore: ObservableObject {
    let market = RemoteMarketStore()
    let advice = StrategyAdviceProjectionStore(adviceService: StrategyAdviceService())
    @Published var config = NativeQuantConfiguration() { didSet { candidates = [] } }
    @Published var route = "overview"
    @Published private(set) var isWorking = false
    @Published private(set) var progress = ""
    @Published var error: String?
    @Published var result: BacktestRecord?
    @Published private(set) var candidates: [AdvancedBacktestCandidate] = []
    @Published private(set) var records: [BacktestRecord] = []
    private var runTask: Task<Void, Never>?
    private var calculation: Task<NativeQuantCalculation, Error>?
    private var optimization: Task<[AdvancedBacktestCandidate], Error>?
    private var generation = 0

    func loadRecords(_ context: ModelContext) {
        do { records = try context.fetch(FetchDescriptor<BacktestRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])) }
        catch { self.error = "无法读取回测记录：\(error.localizedDescription)" }
    }

    func show(_ kind: BacktestRecordKind) { config.kind = kind; route = "configure"; error = nil }

    func run(in context: ModelContext) {
        cancel()
        let request = config
        do { try request.validate() } catch { self.error = error.localizedDescription; return }
        error = nil; isWorking = true; progress = "更新行情"
        let token = generation
        runTask = Task {
            defer { if token == generation { isWorking = false; progress = "" } }
            if !AppPreviewSession.isActive {
                let options = request.assetOptions(catalog: market.backtestAssetOptions)
                let symbols: Set<String>
                switch request.kind {
                case .allocation: symbols = Set(["gold_cny"] + request.indexWeights.filter { $0.value > 0 }.map(\.key))
                case .dca:
                    let option = market.backtestAssetOptions.first { $0.symbol == request.dcaSymbol }
                    symbols = Set([request.dcaSymbol] + (option?.historicalFXSymbol.map { [$0] } ?? []))
                case .advanced: symbols = StrategyRebalanceDefaults.historySymbols(for: options)
                }
                _ = await market.refreshHistory(for: symbols, force: false)
                if request.kind == .advanced && request.mode.requiresNFCIAsOf { _ = await market.refreshLiveData(forceRemote: false) }
            }
            guard !Task.isCancelled, token == generation else { return }
            progress = "计算回测"
            let catalog = market.backtestAssetOptions
            let history = market.historySeries
            let nfci = market.nfciAsOf?.backtestNFCIAsOfData
            let task = Task.detached(priority: .userInitiated) {
                try await BackgroundTaskWork.runSynchronousOnLargeStack {
                    try NativeQuantCalculation.run(request, catalog: catalog, history: history, nfci: nfci)
                }
            }
            calculation = task
            do {
                let output = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled, token == generation else { return }
                let record = output.makeRecord(config: request, catalog: catalog)
                context.insert(record)
                do { try context.save() }
                catch { context.delete(record); throw error }
                result = record; loadRecords(context); route = "result"
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                self.error = error.localizedDescription
            }
            if token == generation { calculation = nil }
        }
    }

    func optimize() {
        cancel()
        let request = config
        do { try request.validate() } catch { self.error = error.localizedDescription; return }
        error = nil; isWorking = true; progress = "扫描候选"
        let token = generation
        runTask = Task {
            defer { if token == generation { isWorking = false; progress = ""; optimization = nil } }
            let catalog = market.backtestAssetOptions
            let options = request.assetOptions(catalog: catalog)
            if !AppPreviewSession.isActive { _ = await market.refreshHistory(for: StrategyRebalanceDefaults.historySymbols(for: options)) }
            guard !Task.isCancelled, token == generation else { return }
            let history = market.historySeries
            let task = Task.detached(priority: .userInitiated) {
                try await BackgroundTaskWork.runSynchronousOnLargeStack {
                    let prepared = AdvancedBacktestDataSupport.buildDataCache(calculationAssetOptions: options,
                        strategyMode: .ruleBased, historySnapshots: history, selectedStartDate: request.startDate, selectedEndDate: request.endDate)
                    try NativeQuantCalculation.validateRange(request, available: prepared.availableDateBounds)
                    return BacktestEngine.optimizeAdvancedStrategies(assetInputs: prepared.filteredAssetInputs,
                        initialCash: request.initialCash, baseSettings: request.settings, limit: 3)
                }
            }
            optimization = task
            do {
                let values = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled, token == generation else { return }
                candidates = values
                if values.isEmpty { error = "暂无可用候选，请调整资产或区间" }
            } catch {
                if !Task.isCancelled, token == generation { self.error = error.localizedDescription }
            }
        }
    }

    func apply(_ candidate: AdvancedBacktestCandidate) {
        var next = config
        next.templateID = "custom"; next.mode = .ruleBased
        next.buyDirection = candidate.buyRule.direction; next.buyDays = candidate.buyRule.days
        next.sellDirection = candidate.sellRule.direction; next.sellDays = candidate.sellRule.days
        next.tradeAmount = candidate.tradeAmount
        next.fee = candidate.settings.feeRate; next.slippage = candidate.settings.slippageRate
        next.maxPosition = candidate.settings.maxPositionRatio; next.cooldown = candidate.settings.cooldownDays
        next.stopLoss = candidate.settings.stopLossRatio; next.takeProfit = candidate.settings.takeProfitRatio
        config = next
    }

    func cancel() {
        generation &+= 1; runTask?.cancel(); calculation?.cancel(); optimization?.cancel()
        runTask = nil; calculation = nil; optimization = nil; isWorking = false; progress = ""
    }

    func restore(_ record: BacktestRecord) {
        do { try config.restore(record); route = "configure"; error = nil }
        catch { self.error = error.localizedDescription }
    }

    func delete(_ record: BacktestRecord, context: ModelContext) {
        context.delete(record)
        do { try context.save(); if result?.id == record.id { result = nil }; loadRecords(context) }
        catch { context.rollback(); self.error = "删除失败：\(error.localizedDescription)" }
    }
}
