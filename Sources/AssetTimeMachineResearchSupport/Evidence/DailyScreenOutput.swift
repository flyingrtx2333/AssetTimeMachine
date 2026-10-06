import Foundation
import AssetTimeMachineBacktestCore

/// Common evidence shape and accounting checks for fixed daily research screens.
enum DailyScreenOutput {
    struct Metric: Encodable {
        let annualizedReturn: Double?
        let maxDrawdown: Double
        let sharpeRF0: Double?
        let excessSharpeCNYCash: Double?
        let start: Date
        let end: Date
        let pointCount: Int
    }
    struct Trade: Encodable {
        let date: Date
        let symbol: String
        let action: String
        let price: Double
        let cashAmount: Double
        let units: Double
    }
    struct Row: Encodable {
        let id: String
        let dailyStates: [BacktestDailyState]
        let trades: [Trade]
        let slices: [String: Metric]
        let meanExposure: Double
    }
    static func row(_ id: String, states: [BacktestDailyState], trades: [AdvancedBacktestTrade],
                    windows: [(String, String, String)]) throws -> Row {
        guard !states.isEmpty else { throw BacktestConfigurationError.missingData(id) }
        for s in states {
            let held = s.holdingsBySymbol.values.reduce(0, +)
            guard s.portfolioValue > 0, s.portfolioValue.isFinite, s.cash >= -1e-8,
                  abs(held + s.cash - s.portfolioValue) <= max(1e-8, abs(s.portfolioValue) * 1e-12),
                  held / s.portfolioValue <= 1 + 1e-12,
                  s.targetWeights.values.allSatisfy({ $0 >= 0 && $0.isFinite }),
                  s.targetWeights.values.reduce(0, +) <= 1 + 1e-12 else {
                throw BacktestConfigurationError.invalidParameter("accounting or leverage \(id)")
            }
        }
        var slices: [String: Metric] = [:]
        for (name, a, b) in windows {
            let lower = BacktestSeriesAlignment.historicalSeriesDate(from: a)!
            let upper = BacktestSeriesAlignment.historicalSeriesDate(from: b)!
            let slice = states.filter { $0.date >= lower && $0.date <= upper }
            let points = slice.enumerated().map { BacktestSeriesPoint(date: $0.element.date,
                portfolioValue: $0.element.portfolioValue, sequence: $0.offset) }
            guard let m = BacktestMetricsCalculator.performanceMetrics(from: points), slice.count > 2 else { continue }
            let excess = zip(slice, slice.dropFirst()).map { previous, current in
                current.portfolioValue / previous.portfolioValue - 1
                    - CashYieldCNY.periodReturn(from: previous.date, to: current.date)
            }
            let mean = excess.reduce(0, +) / Double(excess.count)
            let variance = excess.reduce(0) { $0 + pow($1 - mean, 2) } / Double(excess.count - 1)
            let days = BacktestSeriesAlignment.historicalSeriesCalendar.dateComponents([.day], from: slice.first!.date, to: slice.last!.date).day!
            let excessSharpe = variance > 0 ? mean / sqrt(variance) * sqrt(Double(excess.count) / (Double(days) / 365.25)) : nil
            slices[name] = .init(annualizedReturn: m.annualizedReturn, maxDrawdown: m.maxDrawdown,
                sharpeRF0: m.sharpeRatio, excessSharpeCNYCash: excessSharpe,
                start: slice.first!.date, end: slice.last!.date, pointCount: slice.count)
        }
        return .init(id: id, dailyStates: states,
            trades: trades.map { .init(date: $0.date, symbol: $0.assetSymbol, action: $0.action.rawValue,
                price: $0.price, cashAmount: $0.cashAmount, units: $0.units) }, slices: slices,
            meanExposure: states.reduce(0) { $0 + $1.holdingsBySymbol.values.reduce(0, +) / $1.portfolioValue } / Double(states.count))
    }
}
