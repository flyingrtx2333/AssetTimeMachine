import Foundation

nonisolated enum ProspectiveFactorShadowLogic {
    struct RatioState: Equatable {
        let riskOn: Bool
        let latestDate: String
        let priorDate: String
        let latestRatio: Double
        let priorRatio: Double
    }

    struct Evaluation: Equatable {
        let candidateTarget: [String: Double]
        let matchedControlTarget: [String: Double]
        let nextPriorBaseEventTarget: [String: Double]?
        let deRiskEvent: Bool
        let factorAvailable: Bool
        let eligibleEvent: Bool
        let intervened: Bool
        let matchedControlIntervened: Bool
    }

    static func ratioState(
        numerator: [OrthogonalEventFactorV3Logic.Point],
        denominator: [OrthogonalEventFactorV3Logic.Point],
        signalDate: String,
        lookbackObservations: Int = 20,
        maxStaleDays: Int = 7
    ) -> RatioState? {
        guard lookbackObservations > 0 else { return nil }
        let ratio = OrthogonalEventFactorV3Logic.commonRatio(
            numerator: numerator,
            denominator: denominator
        )
        guard let latestIndex = OrthogonalEventFactorV3Logic.latestUsableIndex(
            points: ratio,
            signalDate: signalDate,
            maxStaleDays: maxStaleDays
        ), latestIndex >= lookbackObservations else { return nil }
        let latest = ratio[latestIndex]
        let prior = ratio[latestIndex - lookbackObservations]
        guard latest.value.isFinite,
              prior.value.isFinite,
              latest.value > 0,
              prior.value > 0 else { return nil }
        return RatioState(
            riskOn: latest.value >= prior.value,
            latestDate: latest.date,
            priorDate: prior.date,
            latestRatio: latest.value,
            priorRatio: prior.value
        )
    }

    static func evaluateRetention(
        rebalanceRecommended: Bool,
        priorBaseEventTarget: [String: Double]?,
        currentBaseTarget: [String: Double],
        priorCandidateShadowTarget: [String: Double]?,
        priorMatchedShadowTarget: [String: Double]?,
        factorState: Bool?
    ) -> Evaluation {
        let sanitizedCurrent = sanitized(currentBaseTarget)
        if !rebalanceRecommended {
            return Evaluation(
                candidateTarget: priorCandidateShadowTarget.map(sanitized) ?? sanitizedCurrent,
                matchedControlTarget: priorMatchedShadowTarget.map(sanitized) ?? sanitizedCurrent,
                nextPriorBaseEventTarget: priorBaseEventTarget.map(sanitized),
                deRiskEvent: false,
                factorAvailable: factorState != nil,
                eligibleEvent: false,
                intervened: false,
                matchedControlIntervened: false
            )
        }

        guard let prior = priorBaseEventTarget.map(sanitized) else {
            return Evaluation(
                candidateTarget: sanitizedCurrent,
                matchedControlTarget: sanitizedCurrent,
                nextPriorBaseEventTarget: sanitizedCurrent,
                deRiskEvent: false,
                factorAvailable: factorState != nil,
                eligibleEvent: false,
                intervened: false,
                matchedControlIntervened: false
            )
        }

        let deRisk = OrthogonalEventFactorV3Logic.isDeRiskEvent(
            priorBase: prior,
            currentBase: sanitizedCurrent
        )
        let available = factorState != nil
        let eligible = deRisk && available
        let candidateRetain = eligible && factorState == true
        let matchedRetain = eligible
        return Evaluation(
            candidateTarget: OrthogonalEventFactorV3Logic.retainedTarget(
                priorBase: prior,
                currentBase: sanitizedCurrent,
                retain: candidateRetain,
                retentionFraction: 0.5
            ),
            matchedControlTarget: OrthogonalEventFactorV3Logic.retainedTarget(
                priorBase: prior,
                currentBase: sanitizedCurrent,
                retain: matchedRetain,
                retentionFraction: 0.5
            ),
            nextPriorBaseEventTarget: sanitizedCurrent,
            deRiskEvent: deRisk,
            factorAvailable: available,
            eligibleEvent: eligible,
            intervened: candidateRetain,
            matchedControlIntervened: matchedRetain
        )
    }

    static func evaluateCompletion(
        rebalanceRecommended: Bool,
        currentBaseTarget: [String: Double],
        priorCandidateShadowTarget: [String: Double]?,
        priorMatchedShadowTarget: [String: Double]?,
        factorState: Bool?
    ) -> Evaluation {
        let sanitizedCurrent = sanitized(currentBaseTarget)
        if !rebalanceRecommended {
            return Evaluation(
                candidateTarget: priorCandidateShadowTarget.map(sanitized) ?? sanitizedCurrent,
                matchedControlTarget: priorMatchedShadowTarget.map(sanitized) ?? sanitizedCurrent,
                nextPriorBaseEventTarget: nil,
                deRiskEvent: false,
                factorAvailable: factorState != nil,
                eligibleEvent: false,
                intervened: false,
                matchedControlIntervened: false
            )
        }

        let gross = sanitizedCurrent.values.reduce(0, +)
        let available = factorState != nil
        let grossEligible = gross > 1e-12 && gross < 1.0 - 1e-12
        let eligible = grossEligible && available
        let candidateComplete = eligible && factorState == true
        let matchedComplete = eligible
        return Evaluation(
            candidateTarget: OrthogonalFactorFamilyV1Logic.completedRiskBudget(
                baseTarget: sanitizedCurrent,
                riskOn: candidateComplete
            ),
            matchedControlTarget: OrthogonalFactorFamilyV1Logic.completedRiskBudget(
                baseTarget: sanitizedCurrent,
                riskOn: matchedComplete
            ),
            nextPriorBaseEventTarget: nil,
            deRiskEvent: false,
            factorAvailable: available,
            eligibleEvent: eligible,
            intervened: candidateComplete,
            matchedControlIntervened: matchedComplete
        )
    }

    private static func sanitized(_ target: [String: Double]) -> [String: Double] {
        var output = target.reduce(into: [String: Double]()) { result, item in
            let value = max(item.value, 0)
            if value > 0, value.isFinite {
                result[item.key] = value
            }
        }
        let gross = output.values.reduce(0, +)
        if gross > 1.0, gross > 0 {
            output = output.mapValues { $0 / gross }
        }
        return output
    }
}
