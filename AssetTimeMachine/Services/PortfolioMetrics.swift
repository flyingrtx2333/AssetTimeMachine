import Foundation

struct SnapshotMetrics {
    let date: Date
    let totalAssets: Double
    let totalLiabilities: Double
    let netAssets: Double
}

struct ChangeMetrics {
    let absoluteChange: Double
    let percentageChange: Double?
}

struct DrawdownMetrics {
    let peakValue: Double
    let troughValue: Double
    let drawdownRatio: Double
    let peakDate: Date
    let troughDate: Date
}

enum ComparisonPeriod: CaseIterable {
    case day
    case week
    case month
    case year

    var calendarComponent: Calendar.Component {
        switch self {
        case .day:
            return .day
        case .week:
            return .day
        case .month:
            return .month
        case .year:
            return .year
        }
    }

    var offsetValue: Int {
        switch self {
        case .day:
            return -1
        case .week:
            return -7
        case .month:
            return -1
        case .year:
            return -1
        }
    }
}
