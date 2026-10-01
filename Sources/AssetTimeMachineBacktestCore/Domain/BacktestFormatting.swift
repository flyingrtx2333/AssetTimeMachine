import Foundation

func evenlySampledItems<T>(_ items: [T], maxCount: Int) -> [T] {
    guard maxCount > 0, items.count > maxCount else { return items }
    guard maxCount > 1 else { return items.last.map { [$0] } ?? [] }
    let step = Double(items.count - 1) / Double(maxCount - 1)
    return (0..<maxCount).map { index in
        let sourceIndex = min(items.count - 1, Int((Double(index) * step).rounded()))
        return items[sourceIndex]
    }
}

extension Double {
    func backtestCurrencyString(code: String = "CNY") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.0f", self)
    }

    func backtestPercentString(maxFractionDigits: Int = 2) -> String {
        String(format: "%.\(maxFractionDigits)f%%", self * 100)
    }

    func backtestCompactNumberString(maxFractionDigits: Int = 1) -> String {
        String(format: "%.\(maxFractionDigits)f", self)
    }
}

extension Date {
    public var backtestDateKey: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
}
