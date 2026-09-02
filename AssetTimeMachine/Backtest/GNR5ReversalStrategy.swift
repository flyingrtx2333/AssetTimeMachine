import Foundation

/// Frozen GNR-5 signal and event state machine.
///
/// The strategy observes only dates on which both gold_cny and nasdaq have real observations.
/// Forward-filled values may value holdings but never enter the signal window. A signal observed
/// at T-1 schedules its target for T; BacktestDailySimulator remains responsible for waiting until
/// both held and target assets are executable.
nonisolated enum GNR5ReversalStrategy {
    static let goldSymbol = "gold_cny"
    static let nasdaqSymbol = "nasdaq"
    static let lookbackReturns = 60
    static let threshold = 2.0
    static let eventHoldCommonObservations = 5
    static let baselineTarget = [goldSymbol: 0.5, nasdaqSymbol: 0.5]

    enum TargetReason: Equatable {
        case initialBaseline
        case enterGold
        case enterNasdaq
        case exitToBaseline
    }

    struct TargetInstruction: Equatable {
        let weights: [String: Double]
        let reason: TargetReason
    }

    struct SignalAudit: Equatable {
        let currentSpreadReturn: Double
        let priorMean: Double
        let priorSampleStandardDeviation: Double
        let zScore: Double
        let priorReturnCount: Int
    }

    struct Runtime {
        private(set) var initialized = false
        private(set) var eventActive = false
        private(set) var heldCommonObservations = 0
        private(set) var ignoredSignals = 0
        private(set) var enteredEvents = 0
        private(set) var exitedEvents = 0
        private(set) var lastProcessedSignalIndex = -1

        mutating func instruction(
            signalIndex: Int,
            goldPrices: [Double],
            nasdaqPrices: [Double],
            goldObserved: [Bool],
            nasdaqObserved: [Bool]
        ) -> TargetInstruction? {
            guard signalIndex >= 0, signalIndex != lastProcessedSignalIndex else { return nil }
            lastProcessedSignalIndex = signalIndex

            if !initialized {
                initialized = true
                return TargetInstruction(weights: baselineTarget, reason: .initialBaseline)
            }

            let common = isCommonRealObservation(
                index: signalIndex,
                goldPrices: goldPrices,
                nasdaqPrices: nasdaqPrices,
                goldObserved: goldObserved,
                nasdaqObserved: nasdaqObserved
            )

            if eventActive {
                guard common else { return nil }
                heldCommonObservations += 1
                if signalAudit(
                    signalIndex: signalIndex,
                    goldPrices: goldPrices,
                    nasdaqPrices: nasdaqPrices,
                    goldObserved: goldObserved,
                    nasdaqObserved: nasdaqObserved
                ).map({ abs($0.zScore) >= threshold }) == true {
                    ignoredSignals += 1
                }
                guard heldCommonObservations == eventHoldCommonObservations else { return nil }
                eventActive = false
                heldCommonObservations = 0
                exitedEvents += 1
                return TargetInstruction(weights: baselineTarget, reason: .exitToBaseline)
            }

            guard common, let audit = signalAudit(
                signalIndex: signalIndex,
                goldPrices: goldPrices,
                nasdaqPrices: nasdaqPrices,
                goldObserved: goldObserved,
                nasdaqObserved: nasdaqObserved
            ) else { return nil }

            let target: TargetInstruction
            if audit.zScore >= threshold {
                target = TargetInstruction(weights: [nasdaqSymbol: 1], reason: .enterNasdaq)
            } else if audit.zScore <= -threshold {
                target = TargetInstruction(weights: [goldSymbol: 1], reason: .enterGold)
            } else {
                return nil
            }
            eventActive = true
            heldCommonObservations = 0
            enteredEvents += 1
            return target
        }
    }

    static func isCommonRealObservation(
        index: Int,
        goldPrices: [Double],
        nasdaqPrices: [Double],
        goldObserved: [Bool],
        nasdaqObserved: [Bool]
    ) -> Bool {
        guard goldPrices.indices.contains(index), nasdaqPrices.indices.contains(index),
              goldObserved.indices.contains(index), nasdaqObserved.indices.contains(index) else { return false }
        return goldObserved[index] && nasdaqObserved[index]
            && goldPrices[index].isFinite && goldPrices[index] > 0
            && nasdaqPrices[index].isFinite && nasdaqPrices[index] > 0
    }

    static func signalAudit(
        signalIndex: Int,
        goldPrices: [Double],
        nasdaqPrices: [Double],
        goldObserved: [Bool],
        nasdaqObserved: [Bool]
    ) -> SignalAudit? {
        guard isCommonRealObservation(
            index: signalIndex,
            goldPrices: goldPrices,
            nasdaqPrices: nasdaqPrices,
            goldObserved: goldObserved,
            nasdaqObserved: nasdaqObserved
        ) else { return nil }

        let commonIndices = (0...signalIndex).filter {
            isCommonRealObservation(
                index: $0,
                goldPrices: goldPrices,
                nasdaqPrices: nasdaqPrices,
                goldObserved: goldObserved,
                nasdaqObserved: nasdaqObserved
            )
        }
        guard commonIndices.count >= lookbackReturns + 2,
              commonIndices.last == signalIndex else { return nil }

        let needed = Array(commonIndices.suffix(lookbackReturns + 2))
        var spreadReturns: [Double] = []
        spreadReturns.reserveCapacity(lookbackReturns + 1)
        for offset in 1..<needed.count {
            let previous = needed[offset - 1]
            let current = needed[offset]
            let goldReturn = log(goldPrices[current] / goldPrices[previous])
            let nasdaqReturn = log(nasdaqPrices[current] / nasdaqPrices[previous])
            let spread = goldReturn - nasdaqReturn
            guard spread.isFinite else { return nil }
            spreadReturns.append(spread)
        }
        guard spreadReturns.count == lookbackReturns + 1, let current = spreadReturns.last else { return nil }
        let prior = Array(spreadReturns.dropLast())
        let mean = prior.reduce(0, +) / Double(prior.count)
        let squared = prior.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        let sampleStandardDeviation = sqrt(squared / Double(prior.count - 1))
        guard sampleStandardDeviation.isFinite, sampleStandardDeviation > 0 else { return nil }
        let zScore = (current - mean) / sampleStandardDeviation
        guard zScore.isFinite else { return nil }
        return SignalAudit(
            currentSpreadReturn: current,
            priorMean: mean,
            priorSampleStandardDeviation: sampleStandardDeviation,
            zScore: zScore,
            priorReturnCount: prior.count
        )
    }

    static func targetFingerprint(_ states: [BacktestDailyState]) -> String {
        var hash: UInt64 = 1469598103934665603
        for state in states {
            for symbol in [goldSymbol, nasdaqSymbol] {
                var value = UInt64(bitPattern: Int64(((state.targetWeights[symbol] ?? 0) * 1_000_000).rounded()))
                for _ in 0..<8 {
                    hash ^= value & UInt64(0xff)
                    hash &*= UInt64(1099511628211)
                    value >>= 8
                }
            }
        }
        return String(format: "%016llx", hash)
    }
}
