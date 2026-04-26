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
}
