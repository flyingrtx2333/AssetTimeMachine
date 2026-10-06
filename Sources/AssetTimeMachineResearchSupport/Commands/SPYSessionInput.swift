import Foundation
import AssetTimeMachineBacktestCore

/// Real SPY session quotes and strictly prior FX, shared only by fixed research screens.
public struct SPYSessionInput {
    public struct Bar {
        public let date: Date
        public let open: Double
        public let high: Double
        public let low: Double
        public let close: Double
        public init(date: Date, open: Double, high: Double, low: Double, close: Double) {
            self.date = date; self.open = open; self.high = high; self.low = low; self.close = close
        }
    }

    let bars: [Bar]
    let opens: [Double]
    let frame: MarketDataFrame
    let first: Int
    let dataset: PublicBacktestDataset

    init(raw: Data, history: Data, start: Date, end: Date) throws {
        let dataset = try PublicBacktestCore.loadDataset(from: history,
            datasetHash: ResearchRunEvidence.sha256(history), dataStale: false)
        let document = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        guard let chart = document?["chart"] as? [String: Any],
              let root = (chart["result"] as? [[String: Any]])?.first,
              let meta = root["meta"] as? [String: Any], meta["symbol"] as? String == "SPY",
              meta["currency"] as? String == "USD",
              let times = root["timestamp"] as? [Double],
              let indicators = root["indicators"] as? [String: Any],
              let quote = (indicators["quote"] as? [[String: Any]])?.first,
              let open = quote["open"] as? [Double], let high = quote["high"] as? [Double],
              let low = quote["low"] as? [Double], let close = quote["close"] as? [Double],
              [open.count, high.count, low.count, close.count].allSatisfy({ $0 == times.count }),
              let fx = dataset.seriesBySymbol["usd_per_cny"] else {
            throw BacktestConfigurationError.missingData("SPY real OHLC and historical FX")
        }
        let ny = DateFormatter()
        ny.locale = Locale(identifier: "en_US_POSIX")
        ny.timeZone = TimeZone(identifier: "America/New_York")
        ny.dateFormat = "yyyy-MM-dd"
        let bars = try times.indices.map { i -> Bar in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: ny.string(from: Date(timeIntervalSince1970: times[i]))) else {
                throw BacktestConfigurationError.invalidParameter("SPY trade date")
            }
            return .init(date: date, open: open[i], high: high[i], low: low[i], close: close[i])
        }
        let dates = bars.map(\.date)
        guard let first = dates.firstIndex(where: { $0 >= start }),
              let last = dates.lastIndex(where: { $0 <= end }), first > 0, last > first,
              dates[first] == start, dates[last] == end,
              fx.dates.count == fx.prices.count,
              zip(fx.dates, fx.dates.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw BacktestConfigurationError.missingData("frozen coverage")
        }
        let fxDates = try fx.dates.map { day -> Date in
            guard let date = BacktestSeriesAlignment.historicalSeriesDate(from: day) else {
                throw BacktestConfigurationError.invalidParameter("FX trade date")
            }
            return date
        }
        // Strictly prior calendar-date FX for both open sizing and close marks.
        // No execution-day final FX quote can enter an opening-auction fill.
        let knownFX = try dates.map { date -> Double in
            var lo = 0, hi = fxDates.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if fxDates[mid] < date { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0, date.timeIntervalSince(fxDates[lo - 1]) <= 14 * 86400,
                  fx.prices[lo - 1].isFinite, fx.prices[lo - 1] > 0 else {
                throw BacktestConfigurationError.missingData("prior FX within 14 days")
            }
            return fx.prices[lo - 1]
        }
        let closes = bars.indices.map { bars[$0].close / knownFX[$0] }
        let opens = bars.indices.map { bars[$0].open / knownFX[$0] }
        let option = BacktestInstrument(symbol: "SPY", title: "SPY", requiresHistoricalFX: true,
            historicalFXSymbol: "usd_per_cny", currency: "USD")
        let frame = MarketDataFrame(dates: dates, pricesBySymbol: ["SPY": closes],
            observedBySymbol: ["SPY": Array(repeating: true, count: dates.count)], ohlcBySymbol: [:],
            tradableSymbols: ["SPY"], optionBySymbol: ["SPY": option], simulationRange: first...last)
        self.bars = bars; self.opens = opens; self.frame = frame
        self.first = first; self.dataset = dataset
    }
}
