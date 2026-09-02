import Foundation

/// Immutable, precomputed target instruction. `signalIndex`/`signalDate` identify the
/// information cut; execution is always delegated to `BacktestDailySimulator` at T or later.
nonisolated struct FrozenTargetEvent: Equatable {
    let signalIndex: Int
    let signalDate: Date
    let targetWeights: [String: Double]
    let reason: String
}

/// An immutable schedule built before simulation. Querying it cannot advance strategy state.
nonisolated struct FrozenTargetSchedule: Equatable {
    let events: [FrozenTargetEvent]

    init?(events: [FrozenTargetEvent]) {
        var previousIndex = -1
        for event in events {
            guard event.signalIndex > previousIndex,
                  !event.reason.isEmpty,
                  !event.targetWeights.isEmpty,
                  event.targetWeights.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  event.targetWeights.values.reduce(0, +) <= 1.0 + 1e-12 else { return nil }
            previousIndex = event.signalIndex
        }
        self.events = events
    }

    func event(signalIndex: Int) -> FrozenTargetEvent? {
        events.first { $0.signalIndex == signalIndex }
    }

    /// FNV-1a over the complete frozen instruction identity, including audit reason.
    var fingerprint: String {
        var hash: UInt64 = 1469598103934665603
        for event in events {
            let weights = event.targetWeights.keys.sorted().map { symbol in
                let scaled = Int64(((event.targetWeights[symbol] ?? 0) * 1_000_000_000).rounded())
                return "\(symbol)=\(scaled)"
            }.joined(separator: ",")
            let row = "\(event.signalIndex)|\(event.signalDate.recordDateString)|\(weights)|\(event.reason)\n"
            for byte in row.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
        }
        return String(format: "%016llx", hash)
    }
}

/// Frozen GOR-QREG-252-63 candidate and controls.
///
/// The schedule is a pure function of one immutable `MarketDataFrame`: no portfolio state,
/// cost, callback frequency, or execution outcome can change the target path.
nonisolated enum GORQREG25263Strategy {
    static let candidateID = "GOR-QREG-252-63"
    static let goldSymbol = "gold_cny"
    static let oilSymbol = "oil_wti_cny"
    static let nasdaqSymbol = "nasdaq"
    static let fxSymbol = "usd_per_cny"
    static let lookbackCommonObservations = 252
    static let reviewIntervalCommonObservations = 63
    static let tradableSymbols: Set<String> = [goldSymbol, nasdaqSymbol]
    static let signalOnlySymbols: Set<String> = [oilSymbol, fxSymbol]

    enum Variant: String {
        case candidate
        case stateIndependentEqualWeightControl
        case signReversalFalsificationControl
    }

    static func makeSchedule(frame: MarketDataFrame, variant: Variant = .candidate) -> FrozenTargetSchedule? {
        let requiredSymbols = [goldSymbol, oilSymbol, nasdaqSymbol, fxSymbol]
        guard Set(frame.tradableSymbols) == tradableSymbols,
              frame.dates.count > lookbackCommonObservations,
              requiredSymbols.allSatisfy({ symbol in
                  frame.pricesBySymbol[symbol]?.count == frame.dates.count
                      && frame.observedBySymbol[symbol]?.count == frame.dates.count
              }) else { return nil }

        let commonIndices = frame.dates.indices.filter { index in
            requiredSymbols.allSatisfy { symbol in
                frame.observedBySymbol[symbol]?[index] == true
                    && (frame.pricesBySymbol[symbol]?[index] ?? 0).isFinite
                    && (frame.pricesBySymbol[symbol]?[index] ?? 0) > 0
            }
        }
        guard commonIndices.count > lookbackCommonObservations else {
            return FrozenTargetSchedule(events: [])
        }

        var events: [FrozenTargetEvent] = []
        var priorTarget: [String: Double]?
        for commonOrdinal in stride(
            from: lookbackCommonObservations,
            to: commonIndices.count,
            by: reviewIntervalCommonObservations
        ) {
            let signalIndex = commonIndices[commonOrdinal]
            let target: [String: Double]
            let reason: String

            switch variant {
            case .stateIndependentEqualWeightControl:
                target = [goldSymbol: 0.5, nasdaqSymbol: 0.5]
                reason = "state_independent_50_50_control"
            case .candidate, .signReversalFalsificationControl:
                let priorCommonIndices = commonIndices[(commonOrdinal - lookbackCommonObservations)..<commonOrdinal]
                var priorRatios: [Double] = []
                priorRatios.reserveCapacity(lookbackCommonObservations)
                for index in priorCommonIndices {
                    guard let gold = frame.pricesBySymbol[goldSymbol]?[index],
                          let oil = frame.pricesBySymbol[oilSymbol]?[index] else { continue }
                    let ratio = gold / oil
                    guard ratio.isFinite, ratio > 0 else { continue }
                    priorRatios.append(ratio)
                }
                guard priorRatios.count == lookbackCommonObservations,
                      let gold = frame.pricesBySymbol[goldSymbol]?[signalIndex],
                      let oil = frame.pricesBySymbol[oilSymbol]?[signalIndex] else {
                    continue // Fixed anchor is consumed; the next review is not shifted.
                }
                let currentRatio = gold / oil
                let sum = priorRatios.reduce(0, +)
                let priorMean = sum / Double(lookbackCommonObservations)
                guard currentRatio.isFinite, currentRatio > 0,
                      sum.isFinite, priorMean.isFinite, priorMean > 0 else {
                    continue // Keep the old target and preserve the 63-observation anchor grid.
                }
                let ordinaryTargetIsGold = currentRatio > priorMean
                let targetIsGold = variant == .candidate
                    ? ordinaryTargetIsGold
                    : !ordinaryTargetIsGold
                target = targetIsGold ? [goldSymbol: 1] : [nasdaqSymbol: 1]
                let relation = currentRatio > priorMean ? "ratio_gt_prior_252_mean" : "ratio_le_prior_252_mean"
                reason = variant == .candidate ? relation : "sign_reversal_\(relation)"
            }

            guard target != priorTarget else { continue }
            events.append(FrozenTargetEvent(
                signalIndex: signalIndex,
                signalDate: frame.dates[signalIndex],
                targetWeights: target,
                reason: reason
            ))
            priorTarget = target
        }
        return FrozenTargetSchedule(events: events)
    }
}
