import Foundation

nonisolated enum StandardBacktestPreparationMode: Sendable {
    case allocation
    case dca
}

nonisolated struct StandardBacktestPreparationRequest: Sendable {
    let mode: StandardBacktestPreparationMode
    let goldWeight: Double
    let indexWeights: [String: Double]
    let indexSymbols: [String]
    let dcaAssetSymbol: String
    let dcaAssetOption: BacktestAssetOption?
    let selectedStartDate: Date?
    let selectedEndDate: Date?
    let historySnapshots: [String: PublicHistorySeries]
}

nonisolated struct StandardBacktestPreparedDataCache: Sendable {
    let selectedDCAAssetOption: BacktestAssetOption?
    let filteredGoldSeries: PublicHistorySeries?
    let filteredIndexSeriesBySymbol: [String: PublicHistorySeries]
    let filteredDCASeries: PublicHistorySeries?
    let filteredDCAFXSeries: PublicHistorySeries?
    let availableDateBounds: ClosedRange<Date>?
    let effectiveDateBounds: ClosedRange<Date>?
}

/// Builds the immutable data slice used by a standard backtest. All date
/// parsing, sorting, and OHLC slicing happens after the UI has captured a
/// value-only history snapshot, so none of this work needs the main actor.
nonisolated enum StandardBacktestDataSupport {
    static func prepare(_ request: StandardBacktestPreparationRequest) -> StandardBacktestPreparedDataCache {
        let sourceSeries = activeSourceSeries(for: request)
        let availableBounds = BacktestEngine.availableDateBounds(for: sourceSeries)
        let effectiveBounds = effectiveBounds(
            availableBounds: availableBounds,
            selectedStartDate: request.selectedStartDate,
            selectedEndDate: request.selectedEndDate
        )

        switch request.mode {
        case .allocation:
            let activeIndexSymbols = request.indexSymbols.filter {
                request.indexWeights[$0, default: 0] > 0
            }
            let preparedIndexSymbols = activeIndexSymbols.isEmpty && request.goldWeight <= 0
                ? request.indexSymbols
                : activeIndexSymbols
            let filteredIndexPairs: [(String, PublicHistorySeries)] = preparedIndexSymbols.compactMap { symbol -> (String, PublicHistorySeries)? in
                guard let series = BacktestEngine.filteredHistorySeries(
                    request.historySnapshots[symbol],
                    within: effectiveBounds
                ) else { return nil }
                return (symbol, series)
            }
            let filteredIndices = Dictionary(uniqueKeysWithValues: filteredIndexPairs)

            return StandardBacktestPreparedDataCache(
                selectedDCAAssetOption: request.dcaAssetOption,
                filteredGoldSeries: BacktestEngine.filteredHistorySeries(
                    request.historySnapshots["gold_cny"],
                    within: effectiveBounds
                ),
                filteredIndexSeriesBySymbol: filteredIndices,
                filteredDCASeries: nil,
                filteredDCAFXSeries: nil,
                availableDateBounds: availableBounds,
                effectiveDateBounds: effectiveBounds
            )

        case .dca:
            let fxSeries = request.dcaAssetOption?.historicalFXSymbol.flatMap {
                request.historySnapshots[$0]
            }
            return StandardBacktestPreparedDataCache(
                selectedDCAAssetOption: request.dcaAssetOption,
                filteredGoldSeries: nil,
                filteredIndexSeriesBySymbol: [:],
                filteredDCASeries: BacktestEngine.filteredHistorySeries(
                    request.historySnapshots[request.dcaAssetSymbol],
                    within: effectiveBounds
                ),
                filteredDCAFXSeries: BacktestEngine.filteredHistorySeries(
                    fxSeries,
                    within: effectiveBounds
                ),
                availableDateBounds: availableBounds,
                effectiveDateBounds: effectiveBounds
            )
        }
    }

    private static func activeSourceSeries(
        for request: StandardBacktestPreparationRequest
    ) -> [PublicHistorySeries] {
        switch request.mode {
        case .dca:
            guard let assetSeries = request.historySnapshots[request.dcaAssetSymbol] else { return [] }
            guard let fxSymbol = request.dcaAssetOption?.historicalFXSymbol else { return [assetSeries] }
            guard let fxSeries = request.historySnapshots[fxSymbol] else { return [] }
            return [assetSeries, fxSeries]

        case .allocation:
            var series: [PublicHistorySeries] = []
            if request.goldWeight > 0,
               let goldSeries = request.historySnapshots["gold_cny"] {
                series.append(goldSeries)
            }
            for symbol in request.indexSymbols where request.indexWeights[symbol, default: 0] > 0 {
                if let indexSeries = request.historySnapshots[symbol] {
                    series.append(indexSeries)
                }
            }

            if !series.isEmpty { return series }
            if let goldSeries = request.historySnapshots["gold_cny"] {
                series.append(goldSeries)
            }
            for symbol in request.indexSymbols {
                if let indexSeries = request.historySnapshots[symbol] {
                    series.append(indexSeries)
                }
            }
            return series
        }
    }

    private static func effectiveBounds(
        availableBounds: ClosedRange<Date>?,
        selectedStartDate: Date?,
        selectedEndDate: Date?
    ) -> ClosedRange<Date>? {
        guard let availableBounds else { return nil }
        let start = max(selectedStartDate ?? availableBounds.lowerBound, availableBounds.lowerBound)
        let end = min(selectedEndDate ?? availableBounds.upperBound, availableBounds.upperBound)
        return start <= end ? (start...end) : availableBounds
    }
}

nonisolated struct AdvancedBacktestPreparedDataCache: Sendable {
    let selectedAssetInputs: [(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?
    )]
    let filteredAssetInputs: [(
        assetSeries: PublicHistorySeries?,
        assetOption: BacktestAssetOption,
        fxSeries: PublicHistorySeries?
    )]
    let availableDateBounds: ClosedRange<Date>?
}

struct AdvancedBacktestRecordDraft: Sendable {
    let record: BacktestRecord
    let signature: String
}

enum AdvancedBacktestDataSupport {
    static func historySnapshots(
        symbols: some Sequence<String>,
        historyProvider: (String) -> PublicHistorySeries?
    ) -> [String: PublicHistorySeries] {
        var snapshots: [String: PublicHistorySeries] = [:]
        for symbol in symbols {
            if let series = historyProvider(symbol) {
                snapshots[symbol] = series
            }
        }
        return snapshots
    }

    static func hasRequiredHistoryData(
        for options: [BacktestAssetOption],
        in snapshots: [String: PublicHistorySeries]
    ) -> Bool {
        guard !options.isEmpty else { return false }
        return options.allSatisfy { option in
            if option.symbol == "usd_cash" {
                return snapshots["usd_per_cny"] != nil
            }
            guard snapshots[option.symbol] != nil else { return false }
            if let fxSymbol = option.historicalFXSymbol {
                return snapshots[fxSymbol] != nil
            }
            return true
        }
    }

    nonisolated static func buildDataCache(
        calculationAssetOptions: [BacktestAssetOption],
        strategyMode: AdvancedBacktestStrategyMode,
        historySnapshots: [String: PublicHistorySeries],
        selectedStartDate: Date? = nil,
        selectedEndDate: Date? = nil
    ) -> AdvancedBacktestPreparedDataCache {
        let historyProvider: (String) -> PublicHistorySeries? = { historySnapshots[$0] }

        let selectedAssetInputs = calculationAssetOptions.map { option in
            BacktestEngine.advancedAssetInput(for: option, historyProvider: historyProvider)
        }

        let boundarySymbols = strategyMode.dateBoundaryAssetSymbols
        let sourceSeries = zip(calculationAssetOptions, selectedAssetInputs).flatMap { option, input -> [PublicHistorySeries] in
            guard boundarySymbols?.contains(option.symbol) ?? true else { return [] }
            var series: [PublicHistorySeries] = []
            if let assetSeries = input.assetSeries {
                series.append(assetSeries)
            }
            if let fxSeries = input.fxSeries {
                series.append(fxSeries)
            }
            return series
        }

        let availableDateBounds = BacktestEngine.availableDateBounds(for: sourceSeries)
        let effectiveDateBounds = effectiveDateBounds(
            availableBounds: availableDateBounds,
            selectedStartDate: selectedStartDate,
            selectedEndDate: selectedEndDate
        )

        return AdvancedBacktestPreparedDataCache(
            selectedAssetInputs: selectedAssetInputs,
            filteredAssetInputs: BacktestEngine.filteredAdvancedAssetInputs(
                selectedAssetInputs,
                within: effectiveDateBounds
            ),
            availableDateBounds: availableDateBounds
        )
    }

    nonisolated static func effectiveDateBounds(
        availableBounds: ClosedRange<Date>?,
        selectedStartDate: Date?,
        selectedEndDate: Date?
    ) -> ClosedRange<Date>? {
        guard let availableBounds else { return nil }
        let start = max(selectedStartDate ?? availableBounds.lowerBound, availableBounds.lowerBound)
        let end = min(selectedEndDate ?? availableBounds.upperBound, availableBounds.upperBound)
        return start <= end ? (start...end) : availableBounds
    }

    static func buildRecordDraft(
        report: AdvancedBacktestReport,
        selectedAssetOptions: [BacktestAssetOption],
        initialCash: Double,
        tradeAmount: Double,
        feeRate: Double,
        slippageRate: Double,
        maxPositionRatio: Double,
        cooldownDays: Int,
        stopLossRatio: Double,
        takeProfitRatio: Double,
        strategyMode: AdvancedBacktestStrategyMode,
        buyDirection: AdvancedBacktestSignalDirection,
        buyDays: Int,
        sellDirection: AdvancedBacktestSignalDirection,
        sellDays: Int,
        configSummary: String
    ) -> AdvancedBacktestRecordDraft {
        let config = BacktestRecordConfigPayload(
            kind: .advanced,
            selectedAssetSymbol: selectedAssetOptions.first?.symbol,
            selectedAssetSymbols: selectedAssetOptions.map(\.symbol),
            initialCash: initialCash,
            tradeAmount: tradeAmount,
            feeRate: feeRate,
            slippageRate: slippageRate,
            maxPositionRatio: maxPositionRatio,
            cooldownDays: cooldownDays,
            stopLossRatio: stopLossRatio,
            takeProfitRatio: takeProfitRatio,
            strategyModeRawValue: strategyMode.rawValue,
            buyDirectionRawValue: buyDirection.rawValue,
            buyDays: buyDays,
            sellDirectionRawValue: sellDirection.rawValue,
            sellDays: sellDays,
            advancedTrades: BacktestRecordCodec.advancedTradePayloads(from: report.trades),
            advancedAssetCharts: BacktestRecordCodec.advancedAssetChartPayloads(from: report.assetReports),
            advancedBenchmarkSeries: BacktestRecordCodec.advancedBenchmarkSeriesPayloads(from: report.benchmarkSeries),
            advancedCombinedBenchmarkPoints: BacktestRecordCodec.pointPayloads(from: report.benchmarkPoints),
            advancedExposurePoints: BacktestRecordCodec.exposurePointPayloads(from: report.exposurePoints),
            advancedAssetExposureSeries: BacktestRecordCodec.assetExposureSeriesPayloads(from: report.assetExposureSeries),
            advancedAverageExposureRatio: report.averageExposureRatio,
            finalCash: report.finalCash,
            finalUnits: report.finalUnits,
            cashYieldSummary: BacktestRecordCodec.cashYieldSummaryPayload(from: report.cashYieldSummary),
            riskSignalSummary: report.riskSignalSummary.map { BacktestRecordCodec.riskSignalSummaryPayload(from: $0) }
        )

        let record = BacktestRecord(
            kindRawValue: BacktestRecordKind.advanced.rawValue,
            title: BacktestRecordKind.advanced.title,
            subtitle: strategyMode.title,
            configSummary: configSummary,
            startDate: report.points.first?.date,
            endDate: report.points.last?.date,
            totalReturn: report.totalReturn,
            annualizedReturn: report.annualizedReturn,
            maxDrawdown: report.maxDrawdown,
            annualizedVolatility: report.annualizedVolatility,
            sharpeRatio: report.sharpeRatio,
            finalValue: report.finalPortfolioValue,
            totalInvested: initialCash,
            profitLoss: report.finalPortfolioValue - initialCash,
            tradeCount: report.buyCount + report.sellCount,
            pointsJSON: BacktestRecordCodec.pointsData(from: report.points),
            configJSON: BacktestRecordCodec.configData(from: config)
        )

        let signature = recordSignature(
            report: report,
            strategyMode: strategyMode,
            configSummary: configSummary
        )

        return AdvancedBacktestRecordDraft(record: record, signature: signature)
    }

    static func recordSignature(
        report: AdvancedBacktestReport,
        strategyMode: AdvancedBacktestStrategyMode,
        configSummary: String
    ) -> String {
        BacktestRecordCodec.recordSignature(
            kindRawValue: BacktestRecordKind.advanced.rawValue,
            subtitle: strategyMode.title,
            configSummary: configSummary,
            startDate: report.points.first?.date,
            endDate: report.points.last?.date,
            totalReturn: report.totalReturn,
            maxDrawdown: report.maxDrawdown,
            finalValue: report.finalPortfolioValue,
            tradeCount: report.buyCount + report.sellCount
        )
    }
}
