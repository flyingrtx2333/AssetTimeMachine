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
        if let latest = snapshots.first {
            hasher.combine(latest.id)
            hasher.combine(latest.updatedAt.timeIntervalSinceReferenceDate)
            if includeMarketAnchorsUpdatedAt {
                hasher.combine(latest.marketAnchorsUpdatedAt?.timeIntervalSinceReferenceDate)
            }
            hasher.combine(latest.entries.count)
        }
        if includeOldest,
           let oldest = snapshots.last,
           oldest.id != snapshots.first?.id {
            hasher.combine(oldest.id)
            hasher.combine(oldest.updatedAt.timeIntervalSinceReferenceDate)
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
