import Foundation

nonisolated enum ShortMomentum001Logic {
    static func monthKey(_ dateKey: String) -> String? {
        guard dateKey.count >= 7 else { return nil }
        return String(dateKey.prefix(7))
    }

    /// Select the single positive-return leader from the immediately preceding
    /// complete calendar month. The return is measured from the last aligned close
    /// before that month to the final aligned close inside that month. Nothing after
    /// signalIndex is read.
    static func owner(
        signalIndex: Int,
        dateKeys: [String],
        pricesBySymbol: [String: [Double]],
        symbols: [String]
    ) -> String? {
        guard dateKeys.indices.contains(signalIndex), signalIndex > 0,
              let priorMonth = monthKey(dateKeys[signalIndex]) else { return nil }

        var firstIndex: Int?
        var lastIndex: Int?
        for index in 0...signalIndex where monthKey(dateKeys[index]) == priorMonth {
            firstIndex = firstIndex ?? index
            lastIndex = index
        }
        guard let firstIndex, let lastIndex, firstIndex > 0 else { return nil }
        let baseIndex = firstIndex - 1

        var best: (symbol: String, totalReturn: Double)?
        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol],
                  prices.indices.contains(baseIndex),
                  prices.indices.contains(lastIndex) else { continue }
            let start = prices[baseIndex]
            let end = prices[lastIndex]
            guard start.isFinite, end.isFinite, start > 0, end > 0 else { continue }
            let totalReturn = end / start - 1.0
            guard totalReturn.isFinite, totalReturn > 0 else { continue }
            if best == nil || totalReturn > best!.totalReturn {
                best = (symbol, totalReturn)
            }
        }
        return best?.symbol
    }
}
