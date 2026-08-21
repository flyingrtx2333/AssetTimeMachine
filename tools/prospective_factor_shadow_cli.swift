import Foundation

private struct JSONPoint: Codable {
    let date: String
    let value: Double
}

private struct ShadowKernelInput: Codable {
    let mode: String
    let signalDate: String
    let rebalanceRecommended: Bool
    let priorBaseEventTarget: [String: Double]?
    let currentBaseTarget: [String: Double]
    let priorCandidateShadowTarget: [String: Double]?
    let priorMatchedShadowTarget: [String: Double]?
    let numerator: [JSONPoint]
    let denominator: [JSONPoint]

    enum CodingKeys: String, CodingKey {
        case mode
        case signalDate = "signal_date"
        case rebalanceRecommended = "rebalance_recommended"
        case priorBaseEventTarget = "prior_base_event_target"
        case currentBaseTarget = "current_base_target"
        case priorCandidateShadowTarget = "prior_candidate_shadow_target"
        case priorMatchedShadowTarget = "prior_matched_shadow_target"
        case numerator
        case denominator
    }
}

private struct RatioStateOutput: Codable {
    let riskOn: Bool
    let latestDate: String
    let priorDate: String
    let latestRatio: Double
    let priorRatio: Double

    enum CodingKeys: String, CodingKey {
        case riskOn = "risk_on"
        case latestDate = "latest_date"
        case priorDate = "prior_date"
        case latestRatio = "latest_ratio"
        case priorRatio = "prior_ratio"
    }
}

private struct ShadowKernelOutput: Codable {
    let factorState: RatioStateOutput?
    let candidateTarget: [String: Double]
    let matchedControlTarget: [String: Double]
    let nextPriorBaseEventTarget: [String: Double]?
    let deRiskEvent: Bool
    let factorAvailable: Bool
    let eligibleEvent: Bool
    let intervened: Bool
    let matchedControlIntervened: Bool

    enum CodingKeys: String, CodingKey {
        case factorState = "factor_state"
        case candidateTarget = "candidate_target"
        case matchedControlTarget = "matched_control_target"
        case nextPriorBaseEventTarget = "next_prior_base_event_target"
        case deRiskEvent = "de_risk_event"
        case factorAvailable = "factor_available"
        case eligibleEvent = "eligible_event"
        case intervened
        case matchedControlIntervened = "matched_control_intervened"
    }
}

@main
private struct ProspectiveFactorShadowCLI {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: prospective_factor_shadow_cli <input.json>\n".utf8))
            Foundation.exit(64)
        }
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let input = try JSONDecoder().decode(ShadowKernelInput.self, from: Data(contentsOf: inputURL))
        guard input.mode == "retention" || input.mode == "completion" else {
            throw NSError(domain: "ProspectiveFactorShadowCLI", code: 65, userInfo: [NSLocalizedDescriptionKey: "unknown mode"])
        }
        let numerator = input.numerator.map {
            OrthogonalEventFactorV3Logic.Point(date: $0.date, value: $0.value)
        }
        let denominator = input.denominator.map {
            OrthogonalEventFactorV3Logic.Point(date: $0.date, value: $0.value)
        }
        let state = ProspectiveFactorShadowLogic.ratioState(
            numerator: numerator,
            denominator: denominator,
            signalDate: input.signalDate,
            lookbackObservations: 20,
            maxStaleDays: 7
        )
        let evaluation: ProspectiveFactorShadowLogic.Evaluation
        if input.mode == "retention" {
            evaluation = ProspectiveFactorShadowLogic.evaluateRetention(
                rebalanceRecommended: input.rebalanceRecommended,
                priorBaseEventTarget: input.priorBaseEventTarget,
                currentBaseTarget: input.currentBaseTarget,
                priorCandidateShadowTarget: input.priorCandidateShadowTarget,
                priorMatchedShadowTarget: input.priorMatchedShadowTarget,
                factorState: state?.riskOn
            )
        } else {
            evaluation = ProspectiveFactorShadowLogic.evaluateCompletion(
                rebalanceRecommended: input.rebalanceRecommended,
                currentBaseTarget: input.currentBaseTarget,
                priorCandidateShadowTarget: input.priorCandidateShadowTarget,
                priorMatchedShadowTarget: input.priorMatchedShadowTarget,
                factorState: state?.riskOn
            )
        }
        let stateOutput = state.map {
            RatioStateOutput(
                riskOn: $0.riskOn,
                latestDate: $0.latestDate,
                priorDate: $0.priorDate,
                latestRatio: $0.latestRatio,
                priorRatio: $0.priorRatio
            )
        }
        let output = ShadowKernelOutput(
            factorState: stateOutput,
            candidateTarget: evaluation.candidateTarget,
            matchedControlTarget: evaluation.matchedControlTarget,
            nextPriorBaseEventTarget: evaluation.nextPriorBaseEventTarget,
            deRiskEvent: evaluation.deRiskEvent,
            factorAvailable: evaluation.factorAvailable,
            eligibleEvent: evaluation.eligibleEvent,
            intervened: evaluation.intervened,
            matchedControlIntervened: evaluation.matchedControlIntervened
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
