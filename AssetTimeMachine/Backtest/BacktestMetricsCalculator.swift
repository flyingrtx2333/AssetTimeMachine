import Foundation

nonisolated enum BacktestCashFlowTiming {
    case periodStart
    case periodEnd
}

nonisolated enum BacktestMetricsCalculator {
    static func performanceMetrics(
        from points: [BacktestSeriesPoint],
        cashFlowsByDate: [Date: Double] = [:],
        cashFlowTiming: BacktestCashFlowTiming = .periodEnd
    ) -> BacktestPerformanceMetrics? {
        guard let first = points.first, let last = points.last, first.portfolioValue > 0 else { return nil }

        var normalizedValue = 1.0
        var previousValue = first.portfolioValue
        var peakNormalizedValue = normalizedValue
        var returns: [Double] = []
        var maxDrawdown = 0.0

        for point in points.dropFirst() {
            let cashFlow = cashFlowsByDate[point.date, default: 0]
            let denominator: Double
            let numerator: Double
            switch cashFlowTiming {
            case .periodStart:
                denominator = previousValue + cashFlow
                numerator = point.portfolioValue
            case .periodEnd:
                denominator = previousValue
                numerator = point.portfolioValue - cashFlow
            }
            guard denominator > 0, numerator > 0 else {
                previousValue = point.portfolioValue
                continue
            }

            let periodReturn = (numerator / denominator) - 1
            returns.append(periodReturn)
            normalizedValue *= (1 + periodReturn)
            peakNormalizedValue = max(peakNormalizedValue, normalizedValue)

            if peakNormalizedValue > 0 {
                maxDrawdown = max(maxDrawdown, (peakNormalizedValue - normalizedValue) / peakNormalizedValue)
            }

            previousValue = point.portfolioValue
        }

        let totalReturn = normalizedValue - 1
        let daySpan = max(Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0, 1)
        let years = Double(daySpan) / 365.25
        let annualizedReturn = years > 0 ? pow(normalizedValue, 1 / years) - 1 : nil

        let mean = returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count)
        let variance = returns.count > 1 && mean != nil
            ? returns.reduce(0) { $0 + pow($1 - mean!, 2) } / Double(returns.count - 1)
            : nil
        let dailyVolatility = variance.map { sqrt($0) }
        let annualizedVolatility = dailyVolatility.map { $0 * sqrt(252) }
        let sharpeRatio: Double?
        if let mean, let dailyVolatility, dailyVolatility > 0 {
            sharpeRatio = (mean * 252) / (dailyVolatility * sqrt(252))
        } else {
            sharpeRatio = nil
        }

        return BacktestPerformanceMetrics(
            totalReturn: totalReturn,
            annualizedReturn: annualizedReturn,
            maxDrawdown: maxDrawdown,
            annualizedVolatility: annualizedVolatility,
            sharpeRatio: sharpeRatio
        )
    }
}
