import Foundation

nonisolated enum FactorDuration001Logic {
    static let targetWeights: [String: Double] = [
        "vbr_tr": 0.25, "mtum_tr": 0.25, "qual_tr": 0.25, "tlt_tr": 0.25
    ]
    static func year(_ key:String)->Int? { key.count >= 4 ? Int(key.prefix(4)) : nil }
    static func shouldRebalance(current:String, previous:String?)->Bool {
        guard let cy=year(current) else{return false}; guard let previous,let py=year(previous) else{return true}; return cy != py
    }
}
