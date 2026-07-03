import Foundation
import SwiftUI

enum ChartLayoutSupport {
    static func paddedValueDomain(values: [Double]) -> ClosedRange<Double> {
        let filtered = values.filter(\.isFinite)
        guard let minValue = filtered.min(), let maxValue = filtered.max() else {
            return 0...1
        }
        if abs(maxValue - minValue) < .ulpOfOne {
            let padding = max(abs(maxValue) * 0.08, 1)
            return (minValue - padding)...(maxValue + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02)
        return (minValue - padding)...(maxValue + padding)
    }

    static func threeTickValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 2
        guard step.isFinite, step > 0 else { return [domain.lowerBound] }
        return [domain.lowerBound, domain.lowerBound + step, domain.upperBound]
    }

    static func axisLabelPosition(for date: Date, in axisDates: [Date]) -> TimeMachineAxisDateLabel.Position {
        guard let first = axisDates.first, let last = axisDates.last else { return .middle }
        if Calendar.current.isDate(date, inSameDayAs: first) {
            return .leading
        }
        if Calendar.current.isDate(date, inSameDayAs: last) {
            return .trailing
        }
        return .middle
    }

    static func axisLabelAnchor(for date: Date?, in axisDates: [Date]) -> UnitPoint {
        guard let date else { return .top }
        switch axisLabelPosition(for: date, in: axisDates) {
        case .leading:
            return .topLeading
        case .middle:
            return .top
        case .trailing:
            return .topTrailing
        }
    }
}

enum TabScrollLayout {
    static let bottomPadding: CGFloat = 20
    static let sheetBottomPadding: CGFloat = 24
    static let keyboardDismissSpacer: CGFloat = 48
    static let formKeyboardDismissSpacer: CGFloat = 64
}
