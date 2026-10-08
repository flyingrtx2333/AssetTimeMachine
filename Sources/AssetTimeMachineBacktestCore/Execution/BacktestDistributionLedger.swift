import Foundation

/// Optional settlement-v4 cash-distribution extension. It never forecasts a
/// distribution or reinvests one automatically. Quotes must be unadjusted.
nonisolated struct BacktestDistributionLedger {
    static let version = "dividend-cash-v1"

    private let fxBySymbol: [String: [Double]]
    private let eventsByExIndex: [Int: [BacktestCashDistribution]]
    private let paymentIndexByID: [String: Int]
    private var paymentsByIndex: [Int: [Int]] = [:]
    private var outstanding = Set<Int>()
    private(set) var entitlements: [BacktestDistributionEntitlement] = []

    init?(frame: MarketDataFrame, events: [BacktestCashDistribution],
          fxToBaseBySymbol: [String: [Double]]) {
        guard frame.dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
              frame.simulationRange.lowerBound >= 0,
              frame.simulationRange.upperBound < frame.dates.count else { return nil }
        let dates = frame.dates.map(BacktestSeriesAlignment.historicalSeriesDateString)
        guard dates.count == Set(dates).count, dates == dates.sorted() else { return nil }
        let indexByDate = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($1, $0) })
        var eventsByIndex: [Int: [BacktestCashDistribution]] = [:]
        var paymentIndices: [String: Int] = [:]
        var ids = Set<String>()
        var symbolExDates = Set<String>()
        var currencies: [String: String] = [:]
        for event in events {
            guard event.exDate.timeIntervalSinceReferenceDate.isFinite,
                  event.paymentDate.timeIntervalSinceReferenceDate.isFinite else { return nil }
            let exDate = BacktestSeriesAlignment.historicalSeriesDateString(from: event.exDate)
            let payDate = BacktestSeriesAlignment.historicalSeriesDateString(from: event.paymentDate)
            guard !event.id.isEmpty, ids.insert(event.id).inserted,
                  frame.tradableSymbols.contains(event.symbol),
                  payDate >= exDate,
                  event.amountPerUnit.isFinite, event.amountPerUnit > 0,
                  event.withholdingRate.isFinite, (0...1).contains(event.withholdingRate),
                  event.currencyCode.count == 3,
                  event.currencyCode.utf8.allSatisfy({ (65...90).contains($0) }),
                  symbolExDates.insert(event.symbol + ":" + exDate).inserted,
                  currencies[event.symbol] == nil || currencies[event.symbol] == event.currencyCode,
                  let fx = fxToBaseBySymbol[event.symbol], fx.count == dates.count,
                  fx.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
            currencies[event.symbol] = event.currencyCode
            guard let first = dates.first, let last = dates.last else { return nil }
            // There are no initial holdings. Pre-frame events cannot earn a claim.
            if exDate < first || exDate > last { continue }
            guard let exIndex = indexByDate[exDate],
                  frame.observedBySymbol[event.symbol]?[exIndex] == true else { return nil }
            guard frame.simulationRange.contains(exIndex) else { continue }
            eventsByIndex[exIndex, default: []].append(event)
            var low = exIndex, high = dates.count
            while low < high {
                let mid = (low + high) / 2
                if dates[mid] < payDate { low = mid + 1 } else { high = mid }
            }
            if frame.simulationRange.contains(low) { paymentIndices[event.id] = low }
        }
        self.fxBySymbol = fxToBaseBySymbol
        self.eventsByExIndex = eventsByIndex.mapValues { $0.sorted { $0.id < $1.id } }
        self.paymentIndexByID = paymentIndices
    }

    mutating func recognize(at index: Int, previousCloseUnits: [String: Double]) {
        for event in eventsByExIndex[index] ?? [] {
            let units = previousCloseUnits[event.symbol] ?? 0
            guard units > 0 else { continue }
            let entitlementIndex = entitlements.count
            entitlements.append(.init(distribution: event, eligibleUnits: units,
                netAmountInDistributionCurrency: units * event.amountPerUnit * (1 - event.withholdingRate),
                paidOn: nil, paidAmountInBaseCurrency: nil))
            outstanding.insert(entitlementIndex)
            if let paymentIndex = paymentIndexByID[event.id] {
                paymentsByIndex[paymentIndex, default: []].append(entitlementIndex)
            }
        }
    }

    func receivableValue(at index: Int) -> Double {
        outstanding.sorted().reduce(0) { value, i in
            let claim = entitlements[i]
            return value + claim.netAmountInDistributionCurrency * fxBySymbol[claim.distribution.symbol]![index]
        }
    }

    /// Payment is credited after the session's trades, using the supplied
    /// closing FX. It first funds trades on a later observed session.
    mutating func payAfterTrading(at index: Int, date: Date) -> Double {
        var paid = 0.0
        for i in paymentsByIndex.removeValue(forKey: index) ?? [] {
            let claim = entitlements[i]
            let amount = claim.netAmountInDistributionCurrency * fxBySymbol[claim.distribution.symbol]![index]
            entitlements[i].paidOn = date
            entitlements[i].paidAmountInBaseCurrency = amount
            outstanding.remove(i)
            paid += amount
        }
        return paid
    }
}
