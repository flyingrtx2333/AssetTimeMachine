import Foundation

nonisolated struct BacktestSplitSchedule {
    let eventsByIndex: [Int: [BacktestShareSplit]]

    init?(frame: MarketDataFrame, events: [BacktestShareSplit]) {
        guard frame.dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
              frame.simulationRange.lowerBound >= 0,
              frame.simulationRange.upperBound < frame.dates.count else { return nil }
        let dates = frame.dates.map(BacktestSeriesAlignment.historicalSeriesDateString)
        guard dates == dates.sorted(), Set(dates).count == dates.count else { return nil }
        let indices = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($1, $0) })
        var ids = Set<String>(), symbolDates = Set<String>()
        var scheduled: [Int: [BacktestShareSplit]] = [:]
        for event in events {
            guard !event.id.isEmpty, ids.insert(event.id).inserted,
                  frame.tradableSymbols.contains(event.symbol),
                  event.effectiveDate.timeIntervalSinceReferenceDate.isFinite,
                  event.newUnitsPerOldUnit.isFinite, event.newUnitsPerOldUnit > 0 else { return nil }
            let day = BacktestSeriesAlignment.historicalSeriesDateString(from: event.effectiveDate)
            guard symbolDates.insert(event.symbol + ":" + day).inserted else { return nil }
            if day < dates[0] || day > dates[dates.count - 1] { continue }
            guard let index = indices[day], frame.observedBySymbol[event.symbol]?[index] == true else { return nil }
            if frame.simulationRange.contains(index) { scheduled[index, default: []].append(event) }
        }
        eventsByIndex = scheduled.mapValues { $0.sorted { $0.id < $1.id } }
    }
}
