import Foundation
import AssetTimeMachineBacktestCore

@MainActor
enum BacktestRecordCodec {
    static func recordSignature(
        kindRawValue: String,
        subtitle: String,
        configSummary: String,
        startDate: Date?,
        endDate: Date?,
        totalReturn: Double,
        maxDrawdown: Double,
        finalValue: Double?,
        tradeCount: Int
    ) -> String {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.recordSignature(kindRawValue: kindRawValue, subtitle: subtitle, configSummary: configSummary, startDate: startDate, endDate: endDate, totalReturn: totalReturn, maxDrawdown: maxDrawdown, finalValue: finalValue, tradeCount: tradeCount)
    }

    static func pointsData(from points: [BacktestSeriesPoint], maxCount: Int = 240) -> Data {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.pointsData(from: points, maxCount: maxCount)
    }

    static func pointPayloads(
        from points: [BacktestSeriesPoint],
        maxCount: Int = 240
    ) -> [BacktestRecordPointPayload] {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.pointPayloads(from: points, maxCount: maxCount)
    }

    static func configData(from payload: BacktestRecordConfigPayload) -> Data {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.configData(from: payload)
    }

    static func cashYieldSummaryPayload(from summary: CashYieldSummary, maxRatePointCount: Int = 60) -> BacktestRecordCashYieldSummaryPayload {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.cashYieldSummaryPayload(from: summary, maxRatePointCount: maxRatePointCount)
    }

    static func riskSignalSummaryPayload(from summary: MarketRiskSignalSummary, maxSignalPointCount: Int = 120) -> BacktestRecordRiskSignalSummaryPayload {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.riskSignalSummaryPayload(from: summary, maxSignalPointCount: maxSignalPointCount)
    }

    static func advancedTradePayloads(from trades: [AdvancedBacktestTrade]) -> [BacktestRecordAdvancedTradePayload] {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.advancedTradePayloads(from: trades)
    }

    static func advancedBenchmarkSeriesPayloads(
        from series: [AdvancedBacktestBenchmarkSeries],
        maxPointCount: Int = 240
    ) -> [BacktestRecordAdvancedBenchmarkSeriesPayload] {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.advancedBenchmarkSeriesPayloads(from: series, maxPointCount: maxPointCount)
    }

    static func exposurePointPayloads(
        from points: [BacktestExposurePoint],
        maxCount: Int = 360
    ) -> [BacktestRecordExposurePointPayload] {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.exposurePointPayloads(from: points, maxCount: maxCount)
    }

    static func assetExposureSeriesPayloads(
        from series: [BacktestAssetExposureSeries],
        maxPointCount: Int = BacktestExposureSampling.assetSeriesMaxCount
    ) -> [BacktestRecordAssetExposureSeriesPayload] {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.assetExposureSeriesPayloads(from: series, maxPointCount: maxPointCount)
    }

    static func advancedAssetChartPayloads(from assetReports: [AdvancedBacktestAssetReport], maxPricePointCount: Int = 240) -> [BacktestRecordAdvancedAssetChartPayload] {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.advancedAssetChartPayloads(from: assetReports, maxPricePointCount: maxPricePointCount)
    }

    static func decodePoints(from record: BacktestRecord) -> [BacktestSeriesPoint] {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.decodePoints(from: record.storedBacktestValue)
    }

    static func decodeConfig(from record: BacktestRecord) -> BacktestRecordConfigPayload? {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.decodeConfig(from: record.storedBacktestValue)
    }

    static func kind(for record: BacktestRecord) -> BacktestRecordKind {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.kind(for: record.storedBacktestValue)
    }

    static func advancedStrategyDisplayTitle(for record: BacktestRecord) -> String {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.advancedStrategyDisplayTitle(for: record.storedBacktestValue)
    }

    static func advancedReport(from record: BacktestRecord) -> AdvancedBacktestReport? {
        return AssetTimeMachineBacktestCore.BacktestRecordCodec.advancedReport(from: record.storedBacktestValue)
    }
}
