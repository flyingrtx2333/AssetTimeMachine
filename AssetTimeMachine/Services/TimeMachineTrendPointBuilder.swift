import Foundation

struct TimeMachineLiveMarketAnchors: Equatable, Sendable {
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
        let projection = TimeMachineSnapshotProjection(
            id: snapshot.id,
            date: snapshot.date,
            updatedAt: snapshot.updatedAt,
            totalAssets: metrics.totalAssets,
            totalLiabilities: metrics.totalLiabilities,
            goldAnchorPriceCNY: snapshot.goldAnchorPriceCNY,
            goldAnchorDate: snapshot.goldAnchorPriceDate,
            btcAnchorPriceUSD: snapshot.btcAnchorPriceUSD,
            btcAnchorPriceCNY: snapshot.btcAnchorPriceCNY,
            btcAnchorDate: snapshot.btcAnchorPriceDate,
            nasdaqAnchorPriceUSD: snapshot.nasdaqAnchorPriceUSD,
            nasdaqAnchorPriceCNY: snapshot.nasdaqAnchorPriceCNY,
            nasdaqAnchorDate: snapshot.nasdaqAnchorPriceDate
        )
        return TimeMachineSnapshotProjectionProcessor.makeTrendPoint(
            from: projection,
            liveAnchors: liveAnchors
        )
    }
}
