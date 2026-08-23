import Foundation

nonisolated enum FaberGTAA001Logic {
    static func monthKey(_ dateKey: String) -> String? {
        guard dateKey.count >= 7 else { return nil }
        return String(dateKey.prefix(7))
    }

    static func monthEndIndices(
        signalIndex: Int,
        dateKeys: [String],
        count: Int
    ) -> [Int]? {
        guard signalIndex >= 0, dateKeys.indices.contains(signalIndex), count > 0 else { return nil }
        var indices: [Int] = []
        var seen: Set<String> = []
        var index = signalIndex
        while index >= 0 && indices.count < count {
            if let month = monthKey(dateKeys[index]), !seen.contains(month) {
                seen.insert(month)
                indices.append(index)
            }
            index -= 1
        }
        return indices.count == count ? indices : nil
    }

    /// Faber-style monthly absolute trend test using only completed month-end closes.
    /// An asset is active when the latest completed month-end close is strictly above
    /// the simple average of the latest ten completed month-end closes.
    static func activeSymbols(
        signalIndex: Int,
        dateKeys: [String],
        pricesBySymbol: [String: [Double]],
        symbols: [String],
        monthCount: Int = 10
    ) -> Set<String>? {
        guard let indices = monthEndIndices(signalIndex: signalIndex, dateKeys: dateKeys, count: monthCount),
              let latestIndex = indices.first else { return nil }
        var active: Set<String> = []
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol], prices.indices.contains(latestIndex) else { continue }
            var values: [Double] = []
            values.reserveCapacity(monthCount)
            for index in indices {
                guard prices.indices.contains(index) else { values.removeAll(); break }
                let price = prices[index]
                guard price.isFinite, price > 0 else { values.removeAll(); break }
                values.append(price)
            }
            guard values.count == monthCount else { continue }
            let latest = prices[latestIndex]
            let sma = values.reduce(0, +) / Double(values.count)
            if latest > sma { active.insert(symbol) }
        }
        return active
    }
}
