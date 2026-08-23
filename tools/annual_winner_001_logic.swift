import Foundation

nonisolated enum AnnualWinner001Logic {
    static func calendarYear(_ dateKey: String) -> Int? {
        guard dateKey.count >= 4 else { return nil }
        return Int(dateKey.prefix(4))
    }

    /// Selects exactly one next-year owner from the prior complete calendar year.
    /// Only observations at or before signalIndex are eligible. Returns nil (cash)
    /// when no asset has a strictly positive prior-year return.
    static func winner(
        executionDateKey: String,
        signalIndex: Int,
        dateKeys: [String],
        pricesBySymbol: [String: [Double]],
        symbols: [String]
    ) -> String? {
        guard let executionYear = calendarYear(executionDateKey), signalIndex >= 0 else { return nil }
        let priorYear = executionYear - 1
        var best: (symbol: String, totalReturn: Double)?

        for symbol in symbols {
            guard let prices = pricesBySymbol[symbol], prices.count == dateKeys.count else { continue }
            var first: Double?
            var last: Double?
            let upper = min(signalIndex, dateKeys.count - 1)
            guard upper >= 0 else { continue }
            for index in 0...upper {
                guard calendarYear(dateKeys[index]) == priorYear else { continue }
                let price = prices[index]
                guard price.isFinite, price > 0 else { continue }
                if first == nil { first = price }
                last = price
            }
            guard let first, let last, first > 0 else { continue }
            let totalReturn = last / first - 1.0
            guard totalReturn.isFinite, totalReturn > 0 else { continue }
            if best == nil || totalReturn > best!.totalReturn {
                best = (symbol, totalReturn)
            }
        }
        return best?.symbol
    }
}
