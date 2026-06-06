import Foundation

struct LogicTests {
    static func snapshotInheritancePreview() -> String {
        let financial = AssetCategory(name: "金融资产", group: .financial)
        let cash = AssetItem(name: "现金", category: financial)
        let liabilityCategory = AssetCategory(name: "负债", group: .liability)
        let mortgage = AssetItem(name: "房贷", category: liabilityCategory)

        let snapshot = AssetSnapshot(date: .now)
        let cashEntry = AssetEntry(amount: 120_000, snapshot: snapshot, item: cash)
        let mortgageEntry = AssetEntry(amount: 40_000, snapshot: snapshot, item: mortgage)
        snapshot.entries = [cashEntry, mortgageEntry]

        let totalAssets = PortfolioCalculator.totalAssets(for: snapshot)
        let totalLiabilities = PortfolioCalculator.totalLiabilities(for: snapshot)
        let netAssets = PortfolioCalculator.netAssets(for: snapshot)

        return "assets=\(Int(totalAssets)), liabilities=\(Int(totalLiabilities)), net=\(Int(netAssets))"
    }

    static func trendPreview() -> String {
        let category = AssetCategory(name: "金融资产", group: .financial)
        let cash = AssetItem(name: "现金", category: category)

        let s1 = AssetSnapshot(date: Date(timeIntervalSince1970: 0))
        s1.entries = [AssetEntry(amount: 100, snapshot: s1, item: cash)]

        let s2 = AssetSnapshot(date: Date(timeIntervalSince1970: 86_400))
        s2.entries = [AssetEntry(amount: 150, snapshot: s2, item: cash)]

        let s3 = AssetSnapshot(date: Date(timeIntervalSince1970: 172_800))
        s3.entries = [AssetEntry(amount: 120, snapshot: s3, item: cash)]

        let history = PortfolioCalculator.historyMetrics(for: [s1, s2, s3])
        let change = PortfolioCalculator.change(from: history[1], to: history[2])
        let drawdown = PortfolioCalculator.maxDrawdown(in: history)
        let drawdownText = String(format: "%.2f", drawdown?.drawdownRatio ?? 0)
        let weekly = TrendAnalysisService.comparisonMetrics(for: s3, period: .week, in: [s1, s2, s3])

        return "change=\(Int(change?.absoluteChange ?? 0)), drawdown=\(drawdownText), weekly=\(Int(weekly?.absoluteChange ?? 0))"
    }

    static func exportPreview() -> String {
        let payload = ExportPayload(
            exportedAt: Date(timeIntervalSince1970: 0),
            categories: [.init(id: UUID(), name: "金融资产", group: "financial", createdAt: .now)],
            items: [],
            snapshots: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try? encoder.encode(payload)
        return "bytes=\(data?.count ?? 0)"
    }

    static func syncMergePreview() -> String {
        let categoryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let itemID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let snapshotID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let entryID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)

        let remote = ExportPayload(
            exportedAt: oldDate,
            categories: [.init(id: categoryID, name: "金融资产", group: "financial", createdAt: oldDate)],
            items: [.init(id: itemID, name: "现金", note: "remote-old", iconName: nil, valuationMethod: "directAmount", autoPricedAssetKind: nil, sortOrder: 0, isActive: true, createdAt: oldDate, updatedAt: oldDate, categoryID: categoryID)],
            snapshots: [.init(id: snapshotID, date: oldDate, note: "remote", createdAt: oldDate, updatedAt: oldDate, goldAnchorPriceCNY: nil, goldAnchorPriceDate: nil, btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil, nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceDate: nil, usdPerCNY: nil, usdPerCNYDate: nil, marketAnchorsUpdatedAt: nil, entries: [.init(id: entryID, amount: 100, quantity: nil, unitPrice: nil, note: "old", createdAt: oldDate, updatedAt: oldDate, itemID: itemID)])]
        )

        let local = ExportPayload(
            exportedAt: newDate,
            categories: [.init(id: categoryID, name: "金融资产", group: "financial", createdAt: oldDate)],
            items: [.init(id: itemID, name: "现金", note: "local-new", iconName: nil, valuationMethod: "directAmount", autoPricedAssetKind: nil, sortOrder: 0, isActive: true, createdAt: oldDate, updatedAt: newDate, categoryID: categoryID)],
            snapshots: [.init(id: snapshotID, date: oldDate, note: "local", createdAt: oldDate, updatedAt: newDate, goldAnchorPriceCNY: nil, goldAnchorPriceDate: nil, btcAnchorPriceUSD: nil, btcAnchorPriceDate: nil, nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceDate: nil, usdPerCNY: nil, usdPerCNYDate: nil, marketAnchorsUpdatedAt: nil, entries: [.init(id: entryID, amount: 200, quantity: nil, unitPrice: nil, note: "new", createdAt: oldDate, updatedAt: newDate, itemID: itemID)])]
        )

        let merged = SyncMergeService.mergedPayload(local: local, remote: remote)
        let amount = merged.snapshots.first?.entries.first?.amount ?? 0
        let note = merged.items.first?.note ?? ""
        return "amount=\(Int(amount)), itemNote=\(note)"
    }
}
