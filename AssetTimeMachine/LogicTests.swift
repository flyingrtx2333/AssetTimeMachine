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
}
