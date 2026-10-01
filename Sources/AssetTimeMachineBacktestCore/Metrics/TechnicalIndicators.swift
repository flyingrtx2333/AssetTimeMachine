import Foundation

nonisolated enum TechnicalIndicators {
    static func rollingAnnualizedVolatility(values: [Double], period: Int) -> [Double?] {
        guard period > 1, values.count > 1 else { return Array(repeating: nil, count: values.count) }

        var logReturns = Array<Double>(repeating: 0, count: values.count)
        for index in values.indices.dropFirst() {
            let previous = values[index - 1]
            let current = values[index]
            logReturns[index] = previous > 0 && current > 0 ? log(current / previous) : 0
        }

        var result = Array<Double?>(repeating: nil, count: values.count)
        var rollingSum = 0.0
        var rollingSquaredSum = 0.0

        for index in logReturns.indices {
            let value = logReturns[index]
            rollingSum += value
            rollingSquaredSum += value * value

            if index >= period {
                let removed = logReturns[index - period]
                rollingSum -= removed
                rollingSquaredSum -= removed * removed
            }

            if index >= period {
                let mean = rollingSum / Double(period)
                let variance = max((rollingSquaredSum / Double(period)) - (mean * mean), 0)
                result[index] = sqrt(variance) * sqrt(252)
            }
        }

        return result
    }

    static func movingAverage(values: [Double], period: Int) -> [Double?] {
        guard period > 0, !values.isEmpty else { return Array(repeating: nil, count: values.count) }

        var result = Array<Double?>(repeating: nil, count: values.count)
        var rollingSum = 0.0

        for index in values.indices {
            rollingSum += values[index]
            if index >= period {
                rollingSum -= values[index - period]
            }
            if index >= period - 1 {
                result[index] = rollingSum / Double(period)
            }
        }

        return result
    }

    static func priceMomentum(values: [Double], at index: Int, lookback: Int) -> Double? {
        guard lookback > 0,
              values.indices.contains(index),
              values.indices.contains(index - lookback) else { return nil }
        let previous = values[index - lookback]
        guard previous > 0 else { return nil }
        return values[index] / previous - 1
    }

    static func rollingDrawdownFromHigh(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index - period + 1 >= 0 else { return nil }
        let startIndex = index - period + 1
        guard let peak = values[startIndex...index].max(), peak > 0 else { return nil }
        return values[index] / peak - 1
    }

    static func relativeStrengthIndex(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index >= period,
              values.count > period else { return nil }

        var averageGain = 0.0
        var averageLoss = 0.0
        for cursor in 1...period {
            let previous = values[cursor - 1]
            let change = previous > 0 ? values[cursor] / previous - 1 : 0
            averageGain += max(change, 0)
            averageLoss += max(-change, 0)
        }
        averageGain /= Double(period)
        averageLoss /= Double(period)

        if index > period {
            for cursor in (period + 1)...index {
                let previous = values[cursor - 1]
                let change = previous > 0 ? values[cursor] / previous - 1 : 0
                let gain = max(change, 0)
                let loss = max(-change, 0)
                averageGain = (averageGain * Double(period - 1) + gain) / Double(period)
                averageLoss = (averageLoss * Double(period - 1) + loss) / Double(period)
            }
        }

        if averageLoss == 0 { return 100 }
        let relativeStrength = averageGain / averageLoss
        return 100 - 100 / (1 + relativeStrength)
    }

    static func donchianRangePosition(values: [Double], at index: Int, period: Int) -> Double? {
        guard period > 0,
              values.indices.contains(index),
              index - period + 1 >= 0 else { return nil }
        let startIndex = index - period + 1
        guard let high = values[startIndex...index].max(),
              let low = values[startIndex...index].min() else { return nil }
        return (values[index] - low) / max(high - low, 1e-12)
    }

    static func bollingerBands(values: [Double], period: Int, multiplier: Double) -> [(middle: Double, lower: Double, upper: Double)?] {
        guard period > 0, !values.isEmpty else { return Array(repeating: nil, count: values.count) }

        var result = Array<(middle: Double, lower: Double, upper: Double)?>(repeating: nil, count: values.count)
        var rollingSum = 0.0
        var rollingSquaredSum = 0.0

        for index in values.indices {
            let value = values[index]
            rollingSum += value
            rollingSquaredSum += value * value

            if index >= period {
                let removed = values[index - period]
                rollingSum -= removed
                rollingSquaredSum -= removed * removed
            }

            if index >= period - 1 {
                let mean = rollingSum / Double(period)
                let variance = max((rollingSquaredSum / Double(period)) - (mean * mean), 0)
                let deviation = sqrt(variance)
                result[index] = (
                    middle: mean,
                    lower: mean - multiplier * deviation,
                    upper: mean + multiplier * deviation
                )
            }
        }

        return result
    }
}
