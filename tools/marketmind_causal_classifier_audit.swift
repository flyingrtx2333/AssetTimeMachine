import Foundation

private struct Case: Decodable {
    let id: String
    let points: [MIICausalPoint]
    let expected: [MIICausalState]
}

private struct Fixture: Decodable {
    let kind: String
    let synthetic: Bool
    let cases: [Case]
}

private struct CaseResult: Encodable {
    let id: String
    let states: [MIICausalState]
}

@main
enum MIICausalClassifierAudit {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "MIIAudit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected synthetic fixture and output paths"])
        }
        let decoder = JSONDecoder()
        let fixture = try decoder.decode(Fixture.self, from: Data(contentsOf:
            URL(fileURLWithPath: CommandLine.arguments[1])))
        guard fixture.synthetic, fixture.kind == "synthetic-mii-classification-reference-v1",
              fixture.cases.count == 11 else {
            throw NSError(domain: "MIIAudit", code: 2)
        }
        var outputs: [CaseResult] = []
        var verified = 0
        for item in fixture.cases {
            let result = try MIICausalClassifier.classify(item.points)
            guard result.count == item.expected.count else {
                throw NSError(domain: "MIIAudit", code: 3)
            }
            for (actual, expected) in zip(result, item.expected) {
                guard actual.day == expected.day, actual.value == expected.value,
                      actual.regime == expected.regime,
                      equivalent(actual.lower, expected.lower), equivalent(actual.upper, expected.upper) else {
                    throw NSError(domain: "MIIAudit", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Reference mismatch: \(item.id) \(actual.day)"])
                }
                verified += 1
            }
            outputs.append(CaseResult(id: item.id, states: result))
        }

        // Input rejection and current-value isolation exercise admission behavior;
        // they do not certify availability of any real cross-market observation.
        let valid = fixture.cases[0].points
        var rejections = 0
        for points in [[MIICausalPoint(day: "2001-02-29", value: 0.5)],
                       [valid[0], valid[0]], [valid[1], valid[0]],
                       [MIICausalPoint(day: "2001-01-01", value: 1.1)],
                       [MIICausalPoint(day: "2001-01-01", value: .infinity)]] {
            do {
                _ = try MIICausalClassifier.classify(points)
                throw NSError(domain: "MIIAudit", code: 5)
            } catch is MIICausalClassifierError {
                rejections += 1
            }
        }
        guard rejections == 5 else { throw NSError(domain: "MIIAudit", code: 6) }

        let original = try MIICausalClassifier.classify(valid)
        var changed = valid
        guard let pivot = valid.indices.first(where: { index in
            index >= 252 && valid[index].day.prefix(7) != valid[index - 1].day.prefix(7)
        }) else { throw NSError(domain: "MIIAudit", code: 8) }
        changed[pivot] = MIICausalPoint(day: valid[pivot].day, value: 1)
        let withCurrentChange = try MIICausalClassifier.classify(changed)
        guard original[pivot].lower == withCurrentChange[pivot].lower,
              original[pivot].upper == withCurrentChange[pivot].upper else {
            throw NSError(domain: "MIIAudit", code: 7)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        try encoder.encode(outputs).write(to: destination)
        print("PASS fixed252 causal classifier: \(verified) states, 11 reference cases, 5 rejections; zero accounts")
    }

    private static func equivalent(_ left: Double?, _ right: Double?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a - b) <= 1e-12
        default: return false
        }
    }
}
