import Foundation

struct TimeMachineLiveMarketAnchors: Equatable {
    let goldPriceCNY: Double?
    let btcPriceUSD: Double?
    let btcPriceCNY: Double?
    let nasdaqPriceUSD: Double?
    let nasdaqPriceCNY: Double?

    static func from(marketStore: RemoteMarketStore) -> TimeMachineLiveMarketAnchors {
        let usdPerCNY = marketStore.exchangeRate(for: "USD")
        let btcUSD = marketStore.market(for: "btc")?.price
        let nasdaqUSD = marketStore.market(for: "nasdaq")?.price

        let btcCNY: Double?
        if let btcUSD, let usdPerCNY, usdPerCNY > 0 {
            btcCNY = btcUSD / usdPerCNY
        } else {
            btcCNY = nil
        }

        let nasdaqCNY: Double?
        if let nasdaqUSD, let usdPerCNY, usdPerCNY > 0 {
            nasdaqCNY = nasdaqUSD / usdPerCNY
        } else {
            nasdaqCNY = nil
        }

        return TimeMachineLiveMarketAnchors(
            goldPriceCNY: marketStore.market(for: "gold")?.price,
            btcPriceUSD: btcUSD,
            btcPriceCNY: btcCNY,
            nasdaqPriceUSD: nasdaqUSD,
            nasdaqPriceCNY: nasdaqCNY
        )
    }
}

enum TimeMachineTrendPointBuilder {
    static func make(
        from snapshot: AssetSnapshot,
        liveAnchors: TimeMachineLiveMarketAnchors? = nil
    ) -> TimeMachineTrendPoint {
        let metrics = PortfolioCalculator.metrics(for: snapshot)
        let mainAssets = metrics.totalAssets
        let isToday = Calendar.current.isDateInToday(snapshot.date)

        let goldAnchorPriceCNY = snapshot.goldAnchorPriceCNY ?? (isToday ? liveAnchors?.goldPriceCNY : nil)
        let btcAnchorPriceCNY = snapshot.btcAnchorPriceCNY ?? (isToday ? liveAnchors?.btcPriceCNY : nil)
        let nasdaqAnchorPriceCNY = snapshot.nasdaqAnchorPriceCNY ?? (isToday ? liveAnchors?.nasdaqPriceCNY : nil)
        let btcAnchorPriceUSD = snapshot.btcAnchorPriceUSD ?? (isToday ? liveAnchors?.btcPriceUSD : nil)
        let nasdaqAnchorPriceUSD = snapshot.nasdaqAnchorPriceUSD ?? (isToday ? liveAnchors?.nasdaqPriceUSD : nil)

        return TimeMachineTrendPoint(
            date: snapshot.date,
            mainAssets: mainAssets,
            netAssets: metrics.netAssets,
            liabilities: metrics.totalLiabilities,
            goldEquivalent: goldAnchorPriceCNY.map { $0 > 0 ? mainAssets / $0 : nil } ?? nil,
            btcEquivalent: btcAnchorPriceCNY.map { $0 > 0 ? mainAssets / $0 : nil } ?? nil,
            nasdaqEquivalent: nasdaqAnchorPriceCNY.map { $0 > 0 ? mainAssets / $0 : nil } ?? nil,
            goldAnchorPriceCNY: goldAnchorPriceCNY,
            goldAnchorDate: snapshot.goldAnchorPriceDate ?? anchorDateIfToday(isToday, hasValue: goldAnchorPriceCNY != nil, snapshotDate: snapshot.date),
            btcAnchorPriceUSD: btcAnchorPriceUSD,
            btcAnchorPriceCNY: btcAnchorPriceCNY,
            btcAnchorDate: snapshot.btcAnchorPriceDate ?? anchorDateIfToday(isToday, hasValue: btcAnchorPriceUSD != nil, snapshotDate: snapshot.date),
            nasdaqAnchorPriceUSD: nasdaqAnchorPriceUSD,
            nasdaqAnchorPriceCNY: nasdaqAnchorPriceCNY,
            nasdaqAnchorDate: snapshot.nasdaqAnchorPriceDate ?? anchorDateIfToday(isToday, hasValue: nasdaqAnchorPriceUSD != nil, snapshotDate: snapshot.date)
        )
    }

    static func cacheToken(
        for snapshot: AssetSnapshot,
        liveAnchors: TimeMachineLiveMarketAnchors? = nil
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.id)
        hasher.combine(snapshot.date.timeIntervalSinceReferenceDate)
        hasher.combine(snapshot.updatedAt.timeIntervalSinceReferenceDate)
        hasher.combine(snapshot.marketAnchorsUpdatedAt?.timeIntervalSinceReferenceDate)
        hasher.combine(snapshot.entries.count)

        if Calendar.current.isDateInToday(snapshot.date), let liveAnchors {
            hasher.combine(liveAnchors.goldPriceCNY)
            hasher.combine(liveAnchors.btcPriceUSD)
            hasher.combine(liveAnchors.btcPriceCNY)
            hasher.combine(liveAnchors.nasdaqPriceUSD)
            hasher.combine(liveAnchors.nasdaqPriceCNY)
        }
        return hasher.finalize()
    }

    private static func anchorDateIfToday(_ isToday: Bool, hasValue: Bool, snapshotDate: Date) -> Date? {
        hasValue && isToday ? snapshotDate : nil
    }
}
