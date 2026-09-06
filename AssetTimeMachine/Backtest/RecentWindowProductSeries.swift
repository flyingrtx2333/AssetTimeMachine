import Foundation

nonisolated enum RecentWindowProductSeries {
    private struct Spec {
        let symbol: String
        let file: String
        let valueColumn: Int
        let proxySymbol: String
        let label: String
        let currency: String
        let extendFlat: Bool
    }

    private static let specs = [
        Spec(symbol: RecentWindowOverlayStrategy.spySymbol, file: "SPY", valueColumn: 1, proxySymbol: "sp500", label: "SPY标普500ETF", currency: "USD", extendFlat: false),
        Spec(symbol: RecentWindowOverlayStrategy.oneqSymbol, file: "ONEQ", valueColumn: 1, proxySymbol: "nasdaq", label: "ONEQ纳斯达克ETF", currency: "USD", extendFlat: false),
        Spec(symbol: RecentWindowOverlayStrategy.sseETFSymbol, file: "510210", valueColumn: 1, proxySymbol: "shanghai_composite", label: "510210上证综指ETF", currency: "CNY", extendFlat: false),
        Spec(symbol: RecentWindowOverlayStrategy.csiETFSymbol, file: "510300", valueColumn: 1, proxySymbol: "csi300", label: "510300沪深300ETF", currency: "CNY", extendFlat: false),
        Spec(symbol: RecentWindowOverlayStrategy.moneySymbol, file: "511990", valueColumn: 2, proxySymbol: "shanghai_composite", label: "511990货币基金", currency: "CNY", extendFlat: true),
    ]

    static func appendingProductInputs(
        to inputs: [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)]
    ) -> [(assetSeries: PublicHistorySeries?, assetOption: BacktestAssetOption, fxSeries: PublicHistorySeries?)]? {
        let inputBySymbol = Dictionary(uniqueKeysWithValues: inputs.map { ($0.assetOption.symbol, $0) })
        let calendarDates = Array(Set(inputs.flatMap { $0.assetSeries?.dates ?? [] })).sorted()
        guard !calendarDates.isEmpty else { return nil }
        var output = inputs.filter { input in !specs.contains(where: { $0.symbol == input.assetOption.symbol }) }
        for spec in specs {
            guard let proxyInput = inputBySymbol[spec.proxySymbol],
                  let proxy = proxyInput.assetSeries,
                  let frozen = loadFrozen(spec),
                  let extended = extend(frozen, with: proxy, flat: spec.extendFlat),
                  let series = align(extended, to: calendarDates),
                  let option = BacktestDefaults.strategyAssetOptions.first(where: { $0.symbol == spec.symbol }) else {
                return nil
            }
            output.append((series, option, spec.currency == "USD" ? proxyInput.fxSeries : nil))
        }
        return output
    }

    private static func loadFrozen(_ spec: Spec) -> PublicHistorySeries? {
        guard let url = resourceURL(named: spec.file),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var dates: [String] = []
        var prices: [Double] = []
        for rawLine in text.split(whereSeparator: \.isNewline).dropFirst() {
            let columns = rawLine.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.indices.contains(spec.valueColumn),
                  let value = Double(columns[spec.valueColumn]),
                  value.isFinite, value > 0 else { return nil }
            let date = String(columns[0])
            guard date.count == 10, date > (dates.last ?? "") else { return nil }
            dates.append(date)
            prices.append(value)
        }
        guard !dates.isEmpty, dates.count == prices.count else { return nil }
        return PublicHistorySeries(
            symbol: spec.symbol,
            category: "etf",
            label: spec.label,
            currency: spec.currency,
            unit: "share",
            source: "frozen-product-total-return+index-extension",
            dates: dates,
            prices: prices,
            hasOHLC: false,
            ohlcSource: nil,
            ohlcCoverageRatio: nil,
            openPrices: nil,
            highPrices: nil,
            lowPrices: nil,
            closePrices: nil,
            volumes: nil
        )
    }

    private static func extend(_ frozen: PublicHistorySeries, with proxy: PublicHistorySeries, flat: Bool) -> PublicHistorySeries? {
        guard let cutoff = frozen.dates.last,
              var current = frozen.prices.last,
              proxy.dates.count == proxy.prices.count else { return nil }
        var dates = frozen.dates
        var prices = frozen.prices
        for index in proxy.dates.indices where proxy.dates[index] > cutoff {
            guard index > 0,
                  proxy.prices[index].isFinite, proxy.prices[index] > 0,
                  proxy.prices[index - 1].isFinite, proxy.prices[index - 1] > 0 else { continue }
            if !flat { current *= proxy.prices[index] / proxy.prices[index - 1] }
            dates.append(proxy.dates[index])
            prices.append(current)
        }
        return PublicHistorySeries(
            symbol: frozen.symbol,
            category: frozen.category,
            label: frozen.label,
            currency: frozen.currency,
            unit: frozen.unit,
            source: frozen.source,
            dates: dates,
            prices: prices,
            hasOHLC: false,
            ohlcSource: nil,
            ohlcCoverageRatio: nil,
            openPrices: nil,
            highPrices: nil,
            lowPrices: nil,
            closePrices: nil,
            volumes: nil
        )
    }

    private static func align(_ series: PublicHistorySeries, to calendarDates: [String]) -> PublicHistorySeries? {
        guard series.dates.count == series.prices.count else { return nil }
        var cursor = -1
        var prices: [Double] = []
        prices.reserveCapacity(calendarDates.count)
        for date in calendarDates {
            while cursor + 1 < series.dates.count && series.dates[cursor + 1] <= date { cursor += 1 }
            prices.append(cursor >= 0 ? series.prices[cursor] : 100)
        }
        return PublicHistorySeries(
            symbol: series.symbol,
            category: series.category,
            label: series.label,
            currency: series.currency,
            unit: series.unit,
            source: series.source,
            dates: calendarDates,
            prices: prices,
            hasOHLC: false,
            ohlcSource: nil,
            ohlcCoverageRatio: nil,
            openPrices: nil,
            highPrices: nil,
            lowPrices: nil,
            closePrices: nil,
            volumes: nil
        )
    }

    private static func resourceURL(named name: String) -> URL? {
#if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "BacktestData/RecentWindow") {
            return url
        }
#endif
        if let url = Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: "BacktestData/RecentWindow") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "csv") { return url }
        let repoRelative = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("AssetTimeMachine/Backtest/BacktestData/RecentWindow/\(name).csv")
        return FileManager.default.fileExists(atPath: repoRelative.path) ? repoRelative : nil
    }
}
