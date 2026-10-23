import Foundation

// Research-only port of the fixed-warmup diagnostic for MarketMind 0.1.0.
// Derived from Layan Oraidi's BSD-3-Clause software, source ad1b13da2f7ea02ee24ae6097d8451a634e4ee97.
// See marketmind_source_LICENSE.txt for the retained copyright and license terms.
// Daily keys here are synthetic observation order, not certified market availability.
struct MIICausalPoint: Codable {
    let day: String
    let value: Double?
}

struct MIICausalState: Codable {
    let day: String
    let value: Double?
    let lower: Double?
    let upper: Double?
    let regime: String?
}

enum MIICausalClassifierError: Error {
    case invalidDay(String)
    case nonIncreasingDay(String)
    case invalidMII(String)
}

enum MIICausalClassifier {
    // Original paper/software constants. The sole diagnostic correction is to use
    // 252 prior observations regardless of the eventually supplied series length.
    static let lookback = 756
    static let minimumHistory = 252

    static func classify(_ points: [MIICausalPoint]) throws -> [MIICausalState] {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = false
        var previousDay: String?
        var previousMonth: String?
        var lower: Double?
        var upper: Double?
        var states: [MIICausalState] = []

        for (position, point) in points.enumerated() {
            guard point.day.count == 10, let date = parser.date(from: point.day),
                  parser.string(from: date) == point.day else {
                throw MIICausalClassifierError.invalidDay(point.day)
            }
            if let previousDay, point.day <= previousDay {
                throw MIICausalClassifierError.nonIncreasingDay(point.day)
            }
            if let value = point.value, !value.isFinite || !(0...1).contains(value) {
                throw MIICausalClassifierError.invalidMII(point.day)
            }
            let month = String(point.day.prefix(7))
            if month != previousMonth {
                // Position limits are applied before missing values are removed,
                // matching the author's trailing-observation history semantics.
                let first = max(0, position - lookback)
                let history = points[first..<position].compactMap(\.value).sorted()
                if history.count >= minimumHistory {
                    lower = quantile(history, probability: 1.0 / 3.0)
                    upper = quantile(history, probability: 2.0 / 3.0)
                }
                previousMonth = month
            }
            let regime: String?
            if let value = point.value, let lower, let upper {
                regime = value < lower ? "low" : value > upper ? "high" : "medium"
            } else {
                regime = nil
            }
            states.append(MIICausalState(day: point.day, value: point.value,
                                        lower: lower, upper: upper, regime: regime))
            previousDay = point.day
        }
        return states
    }

    private static func quantile(_ values: [Double], probability: Double) -> Double {
        let position = Double(values.count - 1) * probability
        let low = Int(floor(position)), high = Int(ceil(position))
        let fraction = position - Double(low)
        // Match the linear interpolation branch used by NumPy/Pandas, including
        // subtraction from the upper neighbor for fractions at least one half.
        if fraction >= 0.5 {
            return values[high] - (values[high] - values[low]) * (1 - fraction)
        }
        return values[low] + (values[high] - values[low]) * fraction
    }
}
