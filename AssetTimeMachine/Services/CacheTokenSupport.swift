import Foundation
import SwiftData

enum SnapshotRevisionToken {
    static func revision(
        for snapshots: [AssetSnapshot],
        includeOldest: Bool = false,
        includeMarketAnchorsUpdatedAt: Bool = false
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshots.count)
        for snapshot in snapshots {
            hasher.combine(contentRevision(
                for: snapshot,
                includeMarketAnchorsUpdatedAt: includeMarketAnchorsUpdatedAt
            ))
        }
        if includeOldest {
            hasher.combine(snapshots.last?.id)
        }
        return hasher.finalize()
    }

    static func contentRevision(
        for snapshot: AssetSnapshot,
        includeMarketAnchorsUpdatedAt: Bool = true
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.id)
        hasher.combine(snapshot.date.timeIntervalSinceReferenceDate)
        hasher.combine(snapshot.updatedAt.timeIntervalSinceReferenceDate)
        if includeMarketAnchorsUpdatedAt {
            hasher.combine(snapshot.marketAnchorsUpdatedAt?.timeIntervalSinceReferenceDate)
            hasher.combine(snapshot.goldAnchorPriceCNY)
            hasher.combine(snapshot.btcAnchorPriceUSD)
            hasher.combine(snapshot.nasdaqAnchorPriceUSD)
            hasher.combine(snapshot.usdPerCNY)
        }

        let entries = snapshot.entries.sorted { $0.id.uuidString < $1.id.uuidString }
        hasher.combine(entries.count)
        for entry in entries {
            hasher.combine(entry.id)
            hasher.combine(entry.updatedAt.timeIntervalSinceReferenceDate)
            hasher.combine(entry.amount)
            hasher.combine(entry.quantity)
            hasher.combine(entry.unitPrice)
            hasher.combine(entry.item?.id)
            hasher.combine(entry.item?.category?.group.rawValue)
        }
        return hasher.finalize()
    }
}

extension RemoteMarketStore {
    func exchangeRateCacheToken() -> Int {
        var hasher = Hasher()
        let rates = exchangeRates.sorted { $0.key < $1.key }
        hasher.combine(rates.count)
        for (currency, rate) in rates {
            hasher.combine(currency)
            hasher.combine(rate)
        }
        return hasher.finalize()
    }

    func overviewCacheToken() -> Int {
        var hasher = Hasher()
        let markets = (overview?.markets ?? []).sorted { $0.symbol < $1.symbol }
        hasher.combine(markets.count)
        for market in markets {
            hasher.combine(market.symbol)
            hasher.combine(market.price)
            hasher.combine(market.currency)
            hasher.combine(market.fetchedAt.timeIntervalSinceReferenceDate)
        }
        return hasher.finalize()
    }

    func liveMarketCacheToken() -> Int {
        var hasher = Hasher()
        hasher.combine(exchangeRateCacheToken())
        hasher.combine(overviewCacheToken())
        return hasher.finalize()
    }
}
