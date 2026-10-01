import Foundation
import AssetTimeMachineBacktestCore

public struct ResearchConfiguration: Codable, Sendable {
    public let schemaVersion: Int
    public let run: BacktestRunConfiguration

    public init(run: BacktestRunConfiguration) {
        self.schemaVersion = 1
        self.run = run
    }

    /// Codable normally ignores misspelled keys. Research rejects them before execution.
    public static func decode(_ data: Data) throws -> ResearchConfiguration {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let run = root["run"] as? [String: Any],
              let parameters = run["parameters"] as? [String: Any],
              let strategy = run["strategy"] as? [String: Any],
              let settings = run["settings"] as? [String: Any] else {
            throw BacktestConfigurationError.invalidParameter("required configuration objects")
        }
        try rejectUnknown(root, allowed: ["schemaVersion", "run"])
        try rejectUnknown(run, allowed: ["strategy", "purpose", "initialCash", "settings", "evaluationRange", "parameters"])
        try rejectUnknown(strategy, allowed: ["id", "version"])
        try rejectUnknown(settings, allowed: ["feeRate", "slippageRate", "maxPositionRatio", "cooldownDays", "stopLossRatio", "takeProfitRatio"])
        try rejectUnknown(parameters, allowed: Set(Mirror(reflecting: BacktestResearchParameters.frozen).children.compactMap(\.label)))
        if let range = run["evaluationRange"] as? [String: Any] {
            try rejectUnknown(range, allowed: ["startDate", "endDate"])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(Self.self, from: data)
        guard result.schemaVersion == 1 else { throw BacktestConfigurationError.unknownVersion("research configuration schema") }
        _ = try StrategyRegistry.definition(reference: result.run.strategy)
        try result.run.parameters.validate()
        if result.run.purpose == .product && result.run.parameters.hasOverrides {
            throw BacktestConfigurationError.researchOverrideOnProduct
        }
        return result
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static func rejectUnknown(_ object: [String: Any], allowed: Set<String>) throws {
        if let key = Set(object.keys).subtracting(allowed).sorted().first {
            throw BacktestConfigurationError.invalidParameter("unknown key: \(key)")
        }
    }
}
