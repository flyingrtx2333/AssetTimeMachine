import Foundation

private struct MarginPointInput: Codable {
    let referenceMonth: String
    let availableDate: String
    let deltaLeverageRatio: Double

    enum CodingKeys: String, CodingKey {
        case referenceMonth = "reference_month"
        case availableDate = "available_date"
        case deltaLeverageRatio = "delta_leverage_ratio"
    }
}

private struct MarginShadowInput: Codable {
    let signalDate: String
    let rebalanceRecommended: Bool
    let priorBaseEventTarget: [String: Double]?
    let currentBaseTarget: [String: Double]
    let priorCandidateShadowTarget: [String: Double]?
    let priorMatchedShadowTarget: [String: Double]?
    let points: [MarginPointInput]

    enum CodingKeys: String, CodingKey {
        case signalDate = "signal_date"
        case rebalanceRecommended = "rebalance_recommended"
        case priorBaseEventTarget = "prior_base_event_target"
        case currentBaseTarget = "current_base_target"
        case priorCandidateShadowTarget = "prior_candidate_shadow_target"
        case priorMatchedShadowTarget = "prior_matched_shadow_target"
        case points
    }
}

private struct FactorStateOutput: Codable {
    let riskOn: Bool
    let referenceMonth: String
    let availableDate: String
    let deltaLeverageRatio: Double

    enum CodingKeys: String, CodingKey {
        case riskOn = "risk_on"
        case referenceMonth = "reference_month"
        case availableDate = "available_date"
        case deltaLeverageRatio = "delta_leverage_ratio"
    }
}

private struct MarginShadowOutput: Codable {
    let factorState: FactorStateOutput?
    let candidateTarget: [String: Double]
    let matchedControlTarget: [String: Double]
    let nextPriorBaseEventTarget: [String: Double]?
    let usDeRiskEvent: Bool
    let factorAvailable: Bool
    let eligibleEvent: Bool
    let intervened: Bool
    let matchedControlIntervened: Bool

    enum CodingKeys: String, CodingKey {
        case factorState = "factor_state"
        case candidateTarget = "candidate_target"
        case matchedControlTarget = "matched_control_target"
        case nextPriorBaseEventTarget = "next_prior_base_event_target"
        case usDeRiskEvent = "us_derisk_event"
        case factorAvailable = "factor_available"
        case eligibleEvent = "eligible_event"
        case intervened
        case matchedControlIntervened = "matched_control_intervened"
    }
}

private func sanitized(_ target: [String: Double]) -> [String: Double] {
    var output = target.reduce(into: [String: Double]()) { result, item in
        let value = max(item.value, 0)
        if value.isFinite, value > 0 { result[item.key] = value }
    }
    let gross = output.values.reduce(0, +)
    if gross > 1.0, gross > 0 { output = output.mapValues { $0 / gross } }
    return output
}

private func latestState(
    inputPoints: [MarginPointInput],
    signalDate: String
) -> FactorStateOutput? {
    let points = inputPoints.map {
        FINRAMarginLeverageV1Logic.Point(
            referenceMonth: $0.referenceMonth,
            availableDate: $0.availableDate,
            deltaLeverageRatio: $0.deltaLeverageRatio
        )
    }
    guard let riskOn = FINRAMarginLeverageV1Logic.latestRiskOn(
        points: points,
        signalDate: signalDate,
        maxStaleDays: 35
    ) else { return nil }

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    guard let signal = formatter.date(from: signalDate) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let latest = inputPoints.last { point in
        guard point.availableDate <= signalDate,
              let available = formatter.date(from: point.availableDate) else { return false }
        let days = calendar.dateComponents([.day], from: available, to: signal).day ?? Int.max
        return days >= 0 && days <= 35
    }
    guard let latest else { return nil }
    return FactorStateOutput(
        riskOn: riskOn,
        referenceMonth: latest.referenceMonth,
        availableDate: latest.availableDate,
        deltaLeverageRatio: latest.deltaLeverageRatio
    )
}

@main
private struct ProspectiveMarginShadowCLI {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: prospective_margin_shadow_cli <input.json>\n".utf8))
            Foundation.exit(64)
        }
        let input = try JSONDecoder().decode(
            MarginShadowInput.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        )
        let current = sanitized(input.currentBaseTarget)
        let state = latestState(inputPoints: input.points, signalDate: input.signalDate)

        let output: MarginShadowOutput
        if !input.rebalanceRecommended {
            output = MarginShadowOutput(
                factorState: state,
                candidateTarget: input.priorCandidateShadowTarget.map(sanitized) ?? current,
                matchedControlTarget: input.priorMatchedShadowTarget.map(sanitized) ?? current,
                nextPriorBaseEventTarget: input.priorBaseEventTarget.map(sanitized),
                usDeRiskEvent: false,
                factorAvailable: state != nil,
                eligibleEvent: false,
                intervened: false,
                matchedControlIntervened: false
            )
        } else if let priorRaw = input.priorBaseEventTarget {
            let prior = sanitized(priorRaw)
            let usDeRisk = FINRAMarginLeverageV1Logic.isUSDeRiskEvent(
                priorBase: prior,
                currentBase: current
            )
            let available = state != nil
            let eligible = usDeRisk && available
            let candidateRetain = eligible && state?.riskOn == true
            let matchedRetain = eligible
            output = MarginShadowOutput(
                factorState: state,
                candidateTarget: FINRAMarginLeverageV1Logic.retainedUSTarget(
                    priorBase: prior,
                    currentBase: current,
                    retain: candidateRetain,
                    retentionFraction: 0.5
                ),
                matchedControlTarget: FINRAMarginLeverageV1Logic.retainedUSTarget(
                    priorBase: prior,
                    currentBase: current,
                    retain: matchedRetain,
                    retentionFraction: 0.5
                ),
                nextPriorBaseEventTarget: current,
                usDeRiskEvent: usDeRisk,
                factorAvailable: available,
                eligibleEvent: eligible,
                intervened: candidateRetain,
                matchedControlIntervened: matchedRetain
            )
        } else {
            output = MarginShadowOutput(
                factorState: state,
                candidateTarget: current,
                matchedControlTarget: current,
                nextPriorBaseEventTarget: current,
                usDeRiskEvent: false,
                factorAvailable: state != nil,
                eligibleEvent: false,
                intervened: false,
                matchedControlIntervened: false
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(output))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
