import AppKit
import Foundation
import SwiftUI

enum MacMemoryRelief {
    static func scheduleAfterHeavyOperation() {}
}

// Presentation adapters for shared backtest models; native charts live in NativeQuantView.
enum BacktestChartValueStyle: Equatable {
    case multiple
    case currency(code: String)
}

struct BacktestChartComparisonSeries: Identifiable {
    let id: String
    let title: String
    let points: [BacktestSeriesPoint]
    let color: Color
}

enum AdvancedBacktestPresentation {
    nonisolated static func comparisonSeries(from report: AdvancedBacktestReport) -> [BacktestChartComparisonSeries] {
        report.benchmarkSeries.enumerated().compactMap { index, series in
            guard let first = series.points.first?.portfolioValue, first > 0,
                  let start = report.points.first?.portfolioValue else { return nil }
            return BacktestChartComparisonSeries(id: series.id, title: series.title,
                points: series.points.map { .init(date: $0.date, portfolioValue: $0.portfolioValue / first * start, sequence: $0.id) },
                color: [AssetTheme.accentBlue, AssetTheme.gold, AssetTheme.positive][index % 3])
        }
    }
}

enum AppTypography {
    static let meta = Font.system(size: 11)
    static let chartAxisStrip = Font.system(size: 11).monospacedDigit()
}
