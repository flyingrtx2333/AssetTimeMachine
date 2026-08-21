import Foundation

@main
struct ProspectiveFactorShadowLogicTest {
    static func main() {
        let current = ["gold_cny": 0.20, "nasdaq": 0.20, "sp500": 0.10]
        let prior = ["gold_cny": 0.30, "nasdaq": 0.30, "sp500": 0.10]
        let priorShadow = ["gold_cny": 0.25, "nasdaq": 0.25, "sp500": 0.10]
        let priorMatched = ["gold_cny": 0.27, "nasdaq": 0.27, "sp500": 0.10]

        let nonEvent = ProspectiveFactorShadowLogic.evaluateRetention(
            rebalanceRecommended: false,
            priorBaseEventTarget: prior,
            currentBaseTarget: current,
            priorCandidateShadowTarget: priorShadow,
            priorMatchedShadowTarget: priorMatched,
            factorState: true
        )
        precondition(nonEvent.candidateTarget == priorShadow)
        precondition(nonEvent.matchedControlTarget == priorMatched)
        precondition(nonEvent.nextPriorBaseEventTarget == prior)
        precondition(!nonEvent.eligibleEvent)
        precondition(!nonEvent.intervened)

        let retained = ProspectiveFactorShadowLogic.evaluateRetention(
            rebalanceRecommended: true,
            priorBaseEventTarget: prior,
            currentBaseTarget: current,
            priorCandidateShadowTarget: priorShadow,
            priorMatchedShadowTarget: priorMatched,
            factorState: true
        )
        precondition(retained.deRiskEvent)
        precondition(retained.eligibleEvent)
        precondition(retained.intervened)
        precondition(abs((retained.candidateTarget["gold_cny"] ?? 0) - 0.25) < 1e-12)
        precondition(abs((retained.candidateTarget["nasdaq"] ?? 0) - 0.25) < 1e-12)
        precondition(retained.candidateTarget == retained.matchedControlTarget)
        precondition(retained.nextPriorBaseEventTarget == current)

        let riskOff = ProspectiveFactorShadowLogic.evaluateRetention(
            rebalanceRecommended: true,
            priorBaseEventTarget: prior,
            currentBaseTarget: current,
            priorCandidateShadowTarget: priorShadow,
            priorMatchedShadowTarget: priorMatched,
            factorState: false
        )
        precondition(riskOff.eligibleEvent)
        precondition(!riskOff.intervened)
        precondition(riskOff.candidateTarget == current)
        precondition(riskOff.matchedControlTarget != current)

        let unavailable = ProspectiveFactorShadowLogic.evaluateRetention(
            rebalanceRecommended: true,
            priorBaseEventTarget: prior,
            currentBaseTarget: current,
            priorCandidateShadowTarget: priorShadow,
            priorMatchedShadowTarget: priorMatched,
            factorState: nil
        )
        precondition(!unavailable.eligibleEvent)
        precondition(unavailable.candidateTarget == current)
        precondition(unavailable.matchedControlTarget == current)

        let firstEvent = ProspectiveFactorShadowLogic.evaluateRetention(
            rebalanceRecommended: true,
            priorBaseEventTarget: nil,
            currentBaseTarget: current,
            priorCandidateShadowTarget: nil,
            priorMatchedShadowTarget: nil,
            factorState: true
        )
        precondition(firstEvent.candidateTarget == current)
        precondition(firstEvent.matchedControlTarget == current)
        precondition(firstEvent.nextPriorBaseEventTarget == current)
        precondition(!firstEvent.deRiskEvent)

        let completion = ProspectiveFactorShadowLogic.evaluateCompletion(
            rebalanceRecommended: true,
            currentBaseTarget: current,
            priorCandidateShadowTarget: priorShadow,
            priorMatchedShadowTarget: priorMatched,
            factorState: true
        )
        precondition(completion.eligibleEvent)
        precondition(completion.intervened)
        precondition(abs(completion.candidateTarget.values.reduce(0, +) - 1.0) < 1e-12)
        precondition(completion.candidateTarget == completion.matchedControlTarget)

        let completionRiskOff = ProspectiveFactorShadowLogic.evaluateCompletion(
            rebalanceRecommended: true,
            currentBaseTarget: current,
            priorCandidateShadowTarget: priorShadow,
            priorMatchedShadowTarget: priorMatched,
            factorState: false
        )
        precondition(completionRiskOff.eligibleEvent)
        precondition(!completionRiskOff.intervened)
        precondition(completionRiskOff.candidateTarget == current)
        precondition(abs(completionRiskOff.matchedControlTarget.values.reduce(0, +) - 1.0) < 1e-12)

        let completionNonEvent = ProspectiveFactorShadowLogic.evaluateCompletion(
            rebalanceRecommended: false,
            currentBaseTarget: current,
            priorCandidateShadowTarget: priorShadow,
            priorMatchedShadowTarget: priorMatched,
            factorState: true
        )
        precondition(completionNonEvent.candidateTarget == priorShadow)
        precondition(completionNonEvent.matchedControlTarget == priorMatched)

        let pointsA = (0...24).map {
            OrthogonalEventFactorV3Logic.Point(date: String(format: "2026-07-%02d", $0 + 1), value: 100 + Double($0))
        }
        let pointsB = (0...24).map {
            OrthogonalEventFactorV3Logic.Point(date: String(format: "2026-07-%02d", $0 + 1), value: 100)
        }
        let state = ProspectiveFactorShadowLogic.ratioState(
            numerator: pointsA,
            denominator: pointsB,
            signalDate: "2026-07-25"
        )
        precondition(state?.riskOn == true)
        precondition(state?.latestDate == "2026-07-25")
        precondition(state?.priorDate == "2026-07-05")

        print("PROSPECTIVE_FACTOR_SHADOW_LOGIC_TEST_OK")
    }
}
