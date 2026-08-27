import Foundation

nonisolated struct AssetWidgetTrendPoint: Codable, Hashable, Sendable {
    let date: Date
    let value: Double
}

nonisolated enum AssetWidgetFreedomStatus: String, Codable, Sendable {
    case alreadyFree
    case projected
    case unreachable
    case unavailable
}

nonisolated enum AssetWidgetTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case darkGold
    case daylightGold

    var id: String { rawValue }
}

nonisolated struct AssetWidgetSnapshot: Codable, Sendable {
    static let currentVersion = 2

    let version: Int
    let updatedAt: Date
    let totalAssets: Double?
    let thirtyDayChange: Double?
    let trendPoints: [AssetWidgetTrendPoint]
    let surplusActual: Double?
    let surplusTarget: Double?
    let surplusProgress: Double
    let freedomProgress: Double
    let freedomStatus: AssetWidgetFreedomStatus
    let freedomMonths: Int?
    let amountsVisible: Bool
    let languageIdentifier: String
    let theme: AssetWidgetTheme

    var hasPortfolioData: Bool {
        totalAssets != nil || !trendPoints.isEmpty
    }

    static var empty: AssetWidgetSnapshot {
        AssetWidgetSnapshot(
            version: currentVersion,
            updatedAt: .now,
            totalAssets: nil,
            thirtyDayChange: nil,
            trendPoints: [],
            surplusActual: nil,
            surplusTarget: nil,
            surplusProgress: 0,
            freedomProgress: 0,
            freedomStatus: .unavailable,
            freedomMonths: nil,
            amountsVisible: true,
            languageIdentifier: "system",
            theme: .system
        )
    }

    static var preview: AssetWidgetSnapshot {
        preview(theme: .darkGold)
    }

    static func preview(theme: AssetWidgetTheme) -> AssetWidgetSnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let values = [
            4_384_000.0, 4_401_000, 4_428_000, 4_451_000, 4_487_000,
            4_515_000, 4_552_000, 4_589_000, 4_474_000, 4_506_000,
            4_527_000, 4_568_000, 4_615_732
        ]
        let points = values.enumerated().map { index, value in
            AssetWidgetTrendPoint(
                date: calendar.date(byAdding: .day, value: index - values.count + 1, to: .now) ?? .now,
                value: value
            )
        }

        return AssetWidgetSnapshot(
            version: currentVersion,
            updatedAt: .now,
            totalAssets: 4_615_731.70,
            thirtyDayChange: 0.0068,
            trendPoints: points,
            surplusActual: 783_259.15,
            surplusTarget: 960_000,
            surplusProgress: 0.816,
            freedomProgress: 0.80,
            freedomStatus: .projected,
            freedomMonths: 53,
            amountsVisible: true,
            languageIdentifier: "zh-Hans",
            theme: theme
        )
    }
}

nonisolated enum AssetWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.flyingrtx.AssetTimeMachine"
    static let snapshotKey = "asset-widget.snapshot.v2"

    static func load() -> AssetWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? PropertyListDecoder().decode(AssetWidgetSnapshot.self, from: data),
              snapshot.version == AssetWidgetSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    @discardableResult
    static func save(_ snapshot: AssetWidgetSnapshot) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = try? PropertyListEncoder().encode(snapshot) else {
            return false
        }
        defaults.set(data, forKey: snapshotKey)
        return true
    }
}
