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
            // This token is evaluated by SwiftUI while resolving `body` and
            // `onChange`. Keep it relationship-free: walking every entry here
            // can synchronously fault thousands of SwiftData objects on the
            // main actor during a tab switch. Entry writes update the parent
            // snapshot's `updatedAt`; views also observe ModelContext saves for
            // item/category-only changes.
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

        // Relationship-only edits are invalidated through ModelContext.didSave
        // by the consumer. Keeping this per-snapshot token scalar avoids doing
        // the same entry walk once for validation and again for metric building.
        return hasher.finalize()
    }
}

enum PortfolioSaveNotificationFilter {
    private static let portfolioEntityNames: Set<String> = [
        Schema.entityName(for: AssetCategory.self),
        Schema.entityName(for: AssetItem.self),
        Schema.entityName(for: AssetSnapshot.self),
        Schema.entityName(for: AssetEntry.self)
    ]

    static func affectsPortfolio(_ notification: Notification) -> Bool {
        guard let userInfo = notification.userInfo else { return true }
        let identifierKeys: [ModelContext.NotificationKey] = [
            .invalidatedAllIdentifiers,
            .insertedIdentifiers,
            .updatedIdentifiers,
            .deletedIdentifiers
        ]
        var foundIdentifiers = false
        for key in identifierKeys {
            let rawValue = userInfo[key.rawValue] ?? userInfo[key]
            let identifiers: [PersistentIdentifier]
            if let values = rawValue as? [PersistentIdentifier] {
                identifiers = values
            } else if let values = rawValue as? Set<PersistentIdentifier> {
                identifiers = Array(values)
            } else {
                continue
            }

            foundIdentifiers = true
            if identifiers.contains(where: { Self.portfolioEntityNames.contains($0.entityName) }) {
                return true
            }
        }

        // Unknown notification payloads stay conservative; known non-portfolio saves
        // (for example BacktestRecord inserts) no longer invalidate every chart cache.
        return !foundIdentifiers
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
