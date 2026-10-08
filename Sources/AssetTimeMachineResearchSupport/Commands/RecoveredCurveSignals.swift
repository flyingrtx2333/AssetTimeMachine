import AssetTimeMachineBacktestCore
import Foundation

struct CurveRow: Codable, Equatable {
    let date: String
    let vix: Double
    let vix3m: Double
}
struct CurveOrder: Equatable {
    let index: Int
    let signalDate: String
    let weights: [String: Double]
    var json: [String: Any] { ["signal_index": index, "signal_date": signalDate, "weights": weights] }
}
enum CurveSignals {
    enum Invalid: Error { case check(String) }
    static let symbols = ["gold_cny", "nasdaq"]
    static let variants = ["defensive_gold", "panic_premium", "defensive_cash", "reverse_rotation", "nasdaq", "product"]
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Invalid.check(message) } }
    static func date(_ text: String) throws -> Date {
        guard let value = BacktestSeriesAlignment.historicalSeriesDate(from: text) else { throw Invalid.check("Invalid date: " + text) }
        return value
    }
    static func validate(_ rows: [CurveRow]) throws {
        try require(!rows.isEmpty && rows.map(\.date) == rows.map(\.date).sorted(), "Curve dates not sorted")
        try require(Set(rows.map(\.date)).count == rows.count, "Duplicate curve date")
        for r in rows {
            _ = try date(r.date)
            try require(r.vix.isFinite && r.vix3m.isFinite && r.vix > 0 && r.vix3m > 0, "Invalid curve close")
        }
    }
    static func known(_ rows: [CurveRow], before cutoff: String) throws -> CurveRow? {
        var low = 0, high = rows.count
        while low < high { let mid = (low + high) / 2; if rows[mid].date < cutoff { low = mid + 1 } else { high = mid } }
        guard low > 0 else { return nil }
        let row = rows[low-1]
        let age = try date(cutoff).timeIntervalSince(date(row.date)) / 86400
        return age <= 7 ? row : nil
    }
    static func target(_ row: CurveRow?, variant: String) throws -> [String: Double] {
        var w = ["gold_cny": 0.0, "nasdaq": 0.0]
        if variant == "nasdaq" { w["nasdaq"] = 1; return w }
        try require(variants.contains(variant) && variant != "product", "Unknown curve mapping")
        guard let row else { return w }
        let stress = row.vix > row.vix3m
        switch variant {
        case "defensive_gold": w[stress ? "gold_cny" : "nasdaq"] = 1
        case "panic_premium": if stress { w["nasdaq"] = 1 }
        case "defensive_cash": if !stress { w["nasdaq"] = 1 }
        case "reverse_rotation": w[stress ? "nasdaq" : "gold_cny"] = 1
        default: throw Invalid.check("Invalid mapping")
        }
        return w
    }
    static func orders(days: [String], indices: [Int], rows: [CurveRow], variant: String) throws -> ([CurveOrder], [[String: Any]]) {
        var previous: [String: Double]?, result: [CurveOrder] = [], audit: [[String: Any]] = []
        for i in indices {
            try require(i >= 0 && i < days.count, "Invalid signal index")
            let signal = days[i], row = try known(rows, before: signal)
            let weights = try target(row, variant: variant)
            try require(weights.values.allSatisfy { $0 >= 0 } && weights.values.reduce(0,+) <= 1, "Target gross")
            var evidence: [String: Any] = ["signal_date": signal, "source_date": row?.date ?? "", "state": row.map { $0.vix > $0.vix3m ? "stress" : "normal" } ?? "missing_or_stale", "weights": weights]
            if let row { evidence["vix"] = row.vix; evidence["vix3m"] = row.vix3m }
            audit.append(evidence)
            if weights != previous { result.append(.init(index: i, signalDate: signal, weights: weights)); previous = weights }
        }
        return (result, audit)
    }
    static func selfTest() throws -> Int {
        let a = CurveRow(date: "2020-01-02", vix: 12, vix3m: 15)
        let b = CurveRow(date: "2020-01-03", vix: 30, vix3m: 25)
        let tie = CurveRow(date: "2020-01-06", vix: 20, vix3m: 20)
        let rows = [a,b,tie]; try validate(rows)
        try require(try known(rows, before: "2020-01-02") == nil, "Same-day close unavailable")
        try require(try known(rows, before: "2020-01-03") == a, "Strict date exclusion")
        try require(try known(rows, before: "2020-01-06") == b, "Weekend handling")
        try require(try known(rows, before: "2020-01-13") == tie, "Seven-day boundary")
        try require(try known(rows, before: "2020-01-14") == nil, "Stale data rejected")
        try require(try target(a, variant: "defensive_gold")["nasdaq"] == 1, "Calm allocation")
        try require(try target(b, variant: "defensive_gold")["gold_cny"] == 1, "Stress allocation")
        try require(try target(b, variant: "panic_premium")["nasdaq"] == 1, "Contrarian entry")
        try require(try target(a, variant: "panic_premium").values.reduce(0,+) == 0, "Contrarian exit")
        try require(try target(tie, variant: "defensive_gold")["nasdaq"] == 1, "Equality is normal")
        try require(try target(nil, variant: "defensive_gold").values.reduce(0,+) == 0, "Missing input is cash")
        try require(try target(b, variant: "defensive_cash").values.reduce(0,+) == 0, "Cash ablation")
        try require(try target(a, variant: "reverse_rotation")["gold_cny"] == 1, "Reverse direction")
        try require(try target(nil, variant: "nasdaq")["nasdaq"] == 1, "Buy/hold independent of curve")
        let days = ["2020-01-03", "2020-01-06", "2020-01-07", "2020-01-08", "2020-01-14"]
        let (plan, _) = try orders(days: days, indices: Array(days.indices), rows: rows, variant: "defensive_gold")
        try require(plan.map(\.index) == [0,1,2,4], "Unchanged weights not rebalanced")
        let poisoned = [a,b,CurveRow(date: "2020-01-06", vix: 1000, vix3m: 1),CurveRow(date: "2099-01-01", vix: 1, vix3m: 1000)]
        let (newPlan, _) = try orders(days: Array(days.prefix(2)), indices: [0,1], rows: poisoned, variant: "defensive_gold")
        try require(newPlan == plan.filter { $0.signalDate <= "2020-01-06" }, "Future mutation cannot rewrite prior decisions")
        var rejected = false
        do { try validate([a,a]) } catch { rejected = true }
        try require(rejected, "Duplicate input not rejected")
        rejected = false
        do { try validate([CurveRow(date: "2020-01-02", vix: 0, vix3m: 10)]) } catch { rejected = true }
        try require(rejected, "Invalid price not rejected")
        return 18
    }
}
