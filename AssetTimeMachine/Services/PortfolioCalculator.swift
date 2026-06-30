import Foundation

enum PortfolioCalculator {
    static func metrics(for snapshot: AssetSnapshot) -> SnapshotMetrics {
        var totalAssets: Double = 0
        var totalLiabilities: Double = 0

        for entry in snapshot.entries {
            if (entry.item?.category?.group ?? .financial) == .liability {
                totalLiabilities += entry.resolvedAmount
            } else {
                totalAssets += entry.resolvedAmount
            }
        }

        return SnapshotMetrics(
            date: snapshot.date,
            totalAssets: totalAssets,
            totalLiabilities: totalLiabilities,
            netAssets: totalAssets - totalLiabilities
        )
    }

    static func totalAssets(for snapshot: AssetSnapshot) -> Double {
        metrics(for: snapshot).totalAssets
    }

    static func totalLiabilities(for snapshot: AssetSnapshot) -> Double {
        metrics(for: snapshot).totalLiabilities
    }

    static func netAssets(for snapshot: AssetSnapshot) -> Double {
        metrics(for: snapshot).netAssets
    }

    static func breakdown(for snapshot: AssetSnapshot) -> [AssetGroup: Double] {
        Dictionary(grouping: snapshot.entries) { entry in
            entry.item?.category?.group ?? .financial
        }
        .mapValues { entries in
            entries.reduce(0) { $0 + $1.resolvedAmount }
        }
    }

    static func historyMetrics(for snapshots: [AssetSnapshot]) -> [SnapshotMetrics] {
        snapshots
            .sorted { $0.date < $1.date }
            .map(metrics(for:))
    }

    static func change(from previous: SnapshotMetrics?, to current: SnapshotMetrics) -> ChangeMetrics? {
        guard let previous else { return nil }
        let absoluteChange = current.netAssets - previous.netAssets
        let percentageChange: Double?
        if previous.netAssets == 0 {
            percentageChange = nil
        } else {
            percentageChange = absoluteChange / previous.netAssets
        }
        return ChangeMetrics(absoluteChange: absoluteChange, percentageChange: percentageChange)
    }

    static func maxDrawdown(in metrics: [SnapshotMetrics]) -> DrawdownMetrics? {
        guard let first = metrics.first else { return nil }

        var peak = first
        var worst: DrawdownMetrics?

        for point in metrics {
            if point.netAssets > peak.netAssets {
                peak = point
            }

            guard peak.netAssets > 0 else { continue }
            let drawdownRatio = (peak.netAssets - point.netAssets) / peak.netAssets

            if let existingWorst = worst {
                if drawdownRatio > existingWorst.drawdownRatio {
                    worst = DrawdownMetrics(
                        peakValue: peak.netAssets,
                        troughValue: point.netAssets,
                        drawdownRatio: drawdownRatio,
                        peakDate: peak.date,
                        troughDate: point.date
                    )
                }
            } else {
                worst = DrawdownMetrics(
                    peakValue: peak.netAssets,
                    troughValue: point.netAssets,
                    drawdownRatio: drawdownRatio,
                    peakDate: peak.date,
                    troughDate: point.date
                )
            }
        }

        return worst
    }

    static func highestNetWorth(in metrics: [SnapshotMetrics]) -> SnapshotMetrics? {
        metrics.max { $0.netAssets < $1.netAssets }
    }

    static func lowestNetWorth(in metrics: [SnapshotMetrics]) -> SnapshotMetrics? {
        metrics.min { $0.netAssets < $1.netAssets }
    }
}
