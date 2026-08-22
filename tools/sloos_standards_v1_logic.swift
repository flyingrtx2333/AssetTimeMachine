import Foundation

nonisolated enum SLOOSStandardsV1Logic {
    struct Point: Equatable {
        let availableDate: String
        let observationDate: String
        let value: Double
    }

    static func latestValue(points: [Point], signalDate: String) -> Double? {
        var latest: Point?
        for point in points {
            guard point.value.isFinite else { continue }
            if point.availableDate <= signalDate {
                latest = point
            } else {
                break
            }
        }
        return latest?.value
    }

    static func riskOn(points: [Point], signalDate: String) -> Bool? {
        guard let value = latestValue(points: points, signalDate: signalDate) else { return nil }
        // DRTSCILM is the net percentage of banks tightening C&I lending standards.
        // Zero has a direct economic interpretation: no net tightening.
        return value <= 0
    }
}
