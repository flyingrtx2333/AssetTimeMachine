import Foundation

struct AdvancedBacktestPreparedDataCache: Sendable {
    let selectedAssetInputs: [(
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

    static func buildDataCache(
        calculationAssetOptions: [BacktestAssetOption],
        strategyMode: AdvancedBacktestStrategyMode,
        historySnapshots: [String: PublicHistorySeries]
    ) -> AdvancedBacktestPreparedDataCache {
        let historyProvider: (String) -> PublicHistorySeries? = { historySnapshots[$0] }

        let selectedAssetInputs = calculationAssetOptions.map { option in
            BacktestEngine.advancedAssetInput(for: option, historyProvider: historyProvider)
        }

        let boundarySymbols = strategyMode.dateBoundaryAssetSymbols
        let boundaryOptions = calculationAssetOptions.filter { option in
            boundarySymbols?.contains(option.symbol) ?? true
        }
        let sourceSeries = boundaryOptions.flatMap { option -> [PublicHistorySeries] in
            var series: [PublicHistorySeries] = []
            let input = BacktestEngine.advancedAssetInput(for: option, historyProvider: historyProvider)
            if let assetSeries = input.assetSeries {
                series.append(assetSeries)
            }
            if let fxSeries = input.fxSeries {
                series.append(fxSeries)
            }
            return series
        }

        return AdvancedBacktestPreparedDataCache(
            selectedAssetInputs: selectedAssetInputs,
            availableDateBounds: BacktestEngine.availableDateBounds(for: sourceSeries)
        )
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

        let signature = [
            record.kindRawValue,
            record.subtitle,
            record.configSummary,
            record.startDate?.recordDateString ?? "nil",
            record.endDate?.recordDateString ?? "nil",
            String(format: "%.8f", record.totalReturn),
            String(format: "%.8f", record.maxDrawdown),
            String(format: "%.4f", record.finalValue ?? 0),
            String(record.tradeCount)
        ].joined(separator: "|")

        return AdvancedBacktestRecordDraft(record: record, signature: signature)
    }
}
