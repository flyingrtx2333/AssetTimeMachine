import Foundation

// MARK: - IDB-63-21 frozen return-blind protocol

/// Intraday downside breadth. Fingerprints use explicit, domain-separated byte grammars.
/// Strings and arrays are U64 big-endian length-prefixed; integers are U64 big-endian;
/// doubles are IEEE-754 binary64 bits in U64 big-endian order; booleans/enums are one byte.
/// Asset, signal-asset, review, and bar ordering is fixed by the artifact header.
nonisolated enum IntradayDownsideBreadthStrategy {
    static let trialID = "ATM-SVP2-IDB-63-21-001"
    static let strategyID = "IDB-63-21"
    static let strategyVersion = "1"
    static let lineage = "intraday-downside-breadth-63-21-v1"
    static let assetOrder = ["gold_cny", "nasdaq", "sp500"]
    static let signalAssetOrder = ["nasdaq", "sp500"]
    static let lookback = 63
    static let reviewStep = 21
    static let headerDomain = "ATM_IDB_63_21_HEADER_V1\0"
    static let inputDomain = "ATM_IDB_63_21_INPUT_V1\0"
    static let variantDomain = "ATM_IDB_63_21_VARIANT_V1\0"
    static let fullDomain = "ATM_IDB_63_21_FULL_V1\0"

    enum Variant: UInt8, Codable, CaseIterable {
        case candidate = 0
        case natural = 1
        case placebo = 2
    }
}

nonisolated enum IntradayDownsideBreadthError: Error, Equatable, CustomStringConvertible {
    case invalidInput(String)
    case fingerprintMismatch(String)
    case runtimeMismatch(String)
    case queueIncomplete(String)

    var description: String {
        switch self {
        case .invalidInput(let value): return "invalid input: \(value)"
        case .fingerprintMismatch(let value): return "fingerprint mismatch: \(value)"
        case .runtimeMismatch(let value): return "runtime mismatch: \(value)"
        case .queueIncomplete(let value): return "queue incomplete: \(value)"
        }
    }
}

nonisolated struct IntradayDownsideBreadthRuntime: Codable, Equatable {
    let swiftVersion: String
    let target: String
    let osProduct: String
    let osVersion: String
    let osBuild: String

    static let formal = IntradayDownsideBreadthRuntime(
        swiftVersion: "swift-driver version: 1.127.15 Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2)",
        target: "arm64-apple-macosx26.0",
        osProduct: "macOS",
        osVersion: "26.5.2",
        osBuild: "25F84"
    )
}

nonisolated struct IntradayDownsideBreadthWindow: Codable, Equatable {
    let id: String
    let requestedStart: String?
    let actualStart: String
    let actualEnd: String
}

nonisolated struct IntradayDownsideBreadthProvenance: Codable, Equatable {
    let symbol: String
    let sourceID: String
    let claim: String
    let rowLevelSourceProof: Bool
    let provenanceSHA256: String?
}

nonisolated struct IntradayDownsideBreadthFreezeConfig: Codable, Equatable {
    let gitCommit: String
    let fixturePath: String
    let fixtureSHA256: String
    let provenancePath: String
    let provenanceSHA256: String
    let runtime: IntradayDownsideBreadthRuntime
    let actualWindows: [IntradayDownsideBreadthWindow]
    let executableDates: [String]
    let provenance: [IntradayDownsideBreadthProvenance]
}

nonisolated struct IntradayDownsideBreadthSignalBar: Equatable {
    let date: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let sourceID: String
}

nonisolated struct IntradayDownsideBreadthAssetInput {
    let symbol: String
    let sourceID: String
    let currency: String
    let bars: [IntradayDownsideBreadthSignalBar]
}

nonisolated enum IntradayDownsideBreadthFactor {
    /// Production-prepared CNY OHLC only. Swift division occurs before Foundation.log.
    static func intradayLogReturn(open: Double, high: Double, low: Double, close: Double) -> Double? {
        guard open.isFinite, high.isFinite, low.isFinite, close.isFinite,
              min(open, high, low, close) > 0,
              high >= max(open, close, low),
              low <= min(open, close, high) else { return nil }
        let value = Foundation.log(close / open)
        return value.isFinite ? value : nil
    }

    /// Exact oldest-to-newest summation; no rounding, epsilon, or compensated summation.
    static func mean(_ values: [Double]) -> Double? {
        guard values.count == IntradayDownsideBreadthStrategy.lookback,
              values.allSatisfy(\.isFinite) else { return nil }
        var sum = 0.0
        for value in values { sum += value }
        let result = sum / Double(IntradayDownsideBreadthStrategy.lookback)
        return result.isFinite ? result : nil
    }
}

nonisolated struct IDBBitExactDouble: Codable, Equatable {
    let bits: String
    init(_ value: Double) { bits = String(format: "%016llx", value.bitPattern) }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value.count == 16, let raw = UInt64(value, radix: 16), Double(bitPattern: raw).isFinite else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid finite binary64 bits"))
        }
        bits = value.lowercased()
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(bits)
    }
    var value: Double { Double(bitPattern: UInt64(bits, radix: 16) ?? 0) }
}

nonisolated struct IDBFrozenBar: Codable, Equatable {
    let date: String
    let open: IDBBitExactDouble
    let high: IDBBitExactDouble
    let low: IDBBitExactDouble
    let close: IDBBitExactDouble
    let sourceID: String
    let x: IDBBitExactDouble
}

nonisolated struct IDBAssetReviewAudit: Codable, Equatable {
    let symbol: String
    let sourceID: String
    let currency: String
    let bars: [IDBFrozenBar]
    let mean: IDBBitExactDouble
}

nonisolated struct IDBWeight: Codable, Equatable {
    let symbol: String
    let bits: IDBBitExactDouble
    var value: Double { bits.value }
}

nonisolated struct IDBTargetAudit: Codable, Equatable {
    let weights: [IDBWeight]
    let event: Bool
    let suppressed: Bool
    var valuesBySymbol: [String: Double] { Dictionary(uniqueKeysWithValues: weights.map { ($0.symbol, $0.value) }) }
}

nonisolated struct IDBReviewAudit: Codable, Equatable {
    let date: String
    let assets: [IDBAssetReviewAudit]
    let candidate: IDBTargetAudit
    let natural: IDBTargetAudit
    let placebo: IDBTargetAudit

    func target(_ variant: IntradayDownsideBreadthStrategy.Variant) -> IDBTargetAudit {
        switch variant {
        case .candidate: return candidate
        case .natural: return natural
        case .placebo: return placebo
        }
    }
}

nonisolated struct IDBFingerprints: Codable, Equatable {
    let header: String
    let input: String
    let candidate: String
    let natural: String
    let placebo: String
    let full: String

    func variant(_ value: IntradayDownsideBreadthStrategy.Variant) -> String {
        switch value {
        case .candidate: return candidate
        case .natural: return natural
        case .placebo: return placebo
        }
    }
}

nonisolated struct IntradayDownsideBreadthFrozenArtifact: Codable, Equatable {
    let schemaVersion: Int
    let trialID: String
    let strategyID: String
    let strategyVersion: String
    let lineage: String
    let gitCommit: String
    let fixturePath: String
    let fixtureSHA256: String
    let provenancePath: String
    let provenanceSHA256: String
    let assetOrder: [String]
    let signalAssetOrder: [String]
    let lookback: Int
    let reviewStep: Int
    let anchorDate: String
    let runtime: IntradayDownsideBreadthRuntime
    let actualWindows: [IntradayDownsideBreadthWindow]
    let signalCommonDates: [String]
    let executableDates: [String]
    let provenance: [IntradayDownsideBreadthProvenance]
    let reviews: [IDBReviewAudit]
    let fingerprints: IDBFingerprints
}

nonisolated enum IntradayDownsideBreadthScheduleBuilder {
    static func build(
        assets: [IntradayDownsideBreadthAssetInput],
        config: IntradayDownsideBreadthFreezeConfig
    ) throws -> IntradayDownsideBreadthFrozenArtifact {
        guard assets.map(\.symbol) == IntradayDownsideBreadthStrategy.signalAssetOrder else {
            throw IntradayDownsideBreadthError.invalidInput("signal asset order")
        }
        guard config.fixtureSHA256.isSHA256, config.provenanceSHA256.isSHA256,
              config.gitCommit.count == 40, config.gitCommit.allSatisfy(\.isHexDigit),
              config.provenance.map(\.symbol) == IntradayDownsideBreadthStrategy.assetOrder else {
            throw IntradayDownsideBreadthError.invalidInput("freeze identity")
        }
        for row in config.provenance {
            guard !row.sourceID.isEmpty, !row.claim.isEmpty,
                  row.provenanceSHA256.map(\.isSHA256) ?? true else {
                throw IntradayDownsideBreadthError.invalidInput("provenance \(row.symbol)")
            }
            if row.symbol != "gold_cny" && row.rowLevelSourceProof {
                throw IntradayDownsideBreadthError.invalidInput("equity provenance overclaim")
            }
        }

        var barsBySymbol: [String: [IntradayDownsideBreadthSignalBar]] = [:]
        for asset in assets {
            guard asset.currency == "CNY", !asset.sourceID.isEmpty else {
                throw IntradayDownsideBreadthError.invalidInput("metadata \(asset.symbol)")
            }
            let dates = asset.bars.map(\.date)
            guard dates == dates.sorted(), Set(dates).count == dates.count else {
                throw IntradayDownsideBreadthError.invalidInput("bar order/duplicates \(asset.symbol)")
            }
            for bar in asset.bars {
                guard bar.sourceID == asset.sourceID,
                      BacktestSeriesAlignment.historicalSeriesDate(from: bar.date) != nil,
                      IntradayDownsideBreadthFactor.intradayLogReturn(
                        open: bar.open, high: bar.high, low: bar.low, close: bar.close
                      ) != nil else {
                    throw IntradayDownsideBreadthError.invalidInput("bar \(asset.symbol) \(bar.date)")
                }
            }
            barsBySymbol[asset.symbol] = asset.bars
        }

        let signalCommonDates = assets.dropFirst().reduce(Set(assets[0].bars.map(\.date))) {
            $0.intersection(Set($1.bars.map(\.date)))
        }.sorted()
        let executableDates = Array(Set(config.executableDates)).sorted()
        guard executableDates == config.executableDates.sorted().reduce(into: [String](), { if $0.last != $1 { $0.append($1) } }),
              !executableDates.isEmpty,
              executableDates.allSatisfy({ BacktestSeriesAlignment.historicalSeriesDate(from: $0) != nil }),
              signalCommonDates.count >= IntradayDownsideBreadthStrategy.lookback + IntradayDownsideBreadthStrategy.reviewStep else {
            throw IntradayDownsideBreadthError.invalidInput("date coverage")
        }

        let firstExecutable = executableDates[0]
        guard let anchorOrdinal = signalCommonDates.indices.first(where: { ordinal in
            guard ordinal >= IntradayDownsideBreadthStrategy.lookback - 1,
                  signalCommonDates[ordinal] >= firstExecutable else { return false }
            let nextOrdinal = ordinal + IntradayDownsideBreadthStrategy.reviewStep
            guard signalCommonDates.indices.contains(nextOrdinal) else { return false }
            return hasExecution(after: signalCommonDates[ordinal], before: signalCommonDates[nextOrdinal], in: executableDates)
        }) else { throw IntradayDownsideBreadthError.invalidInput("no executable anchor") }

        let barsLookup = Dictionary(uniqueKeysWithValues: assets.map { asset in
            (asset.symbol, Dictionary(uniqueKeysWithValues: asset.bars.map { ($0.date, $0) }))
        })
        let reviewOrdinals = stride(from: anchorOrdinal, to: signalCommonDates.count, by: IntradayDownsideBreadthStrategy.reviewStep).map { $0 }
        var previous = Dictionary(uniqueKeysWithValues: IntradayDownsideBreadthStrategy.Variant.allCases.map {
            ($0, Array(repeating: 0.0, count: IntradayDownsideBreadthStrategy.assetOrder.count))
        })
        var reviews: [IDBReviewAudit] = []

        for (reviewPosition, ordinal) in reviewOrdinals.enumerated() {
            let reviewDate = signalCommonDates[ordinal]
            let windowDates = Array(signalCommonDates[(ordinal - IntradayDownsideBreadthStrategy.lookback + 1)...ordinal])
            var audits: [IDBAssetReviewAudit] = []
            for asset in assets {
                let frozenBars: [IDBFrozenBar] = try windowDates.map { date in
                    guard let bar = barsLookup[asset.symbol]?[date],
                          let x = IntradayDownsideBreadthFactor.intradayLogReturn(
                            open: bar.open, high: bar.high, low: bar.low, close: bar.close
                          ) else { throw IntradayDownsideBreadthError.invalidInput("signal-common lookup") }
                    return .init(date: date, open: .init(bar.open), high: .init(bar.high), low: .init(bar.low),
                                 close: .init(bar.close), sourceID: bar.sourceID, x: .init(x))
                }
                guard let mean = IntradayDownsideBreadthFactor.mean(frozenBars.map { $0.x.value }) else {
                    throw IntradayDownsideBreadthError.invalidInput("mean")
                }
                audits.append(.init(symbol: asset.symbol, sourceID: asset.sourceID, currency: asset.currency,
                                    bars: frozenBars, mean: .init(mean)))
            }

            func breadthTarget(count: Int) -> [Double] {
                let equityCount = Double(count) / 2.0
                let equity = (1.0 - equityCount) / 2.0
                return [equityCount, equity, equity]
            }
            let negativeCount = audits.reduce(0) { $0 + ($1.mean.value < 0 ? 1 : 0) }
            let positiveCount = audits.reduce(0) { $0 + ($1.mean.value > 0 ? 1 : 0) }
            let targets: [IntradayDownsideBreadthStrategy.Variant: [Double]] = [
                .candidate: breadthTarget(count: negativeCount),
                .natural: Array(repeating: 1.0 / 3.0, count: 3),
                .placebo: breadthTarget(count: positiveCount)
            ]
            var requiredExecutionDays = 0
            func makeAudit(_ variant: IntradayDownsideBreadthStrategy.Variant) -> IDBTargetAudit {
                let values = targets[variant]!
                let prior = previous[variant]!
                let event = zip(prior, values).contains { $0.bitPattern != $1.bitPattern }
                if event {
                    let hasSell = zip(prior, values).contains { $0 > $1 }
                    let hasBuy = zip(prior, values).contains { $0 < $1 }
                    requiredExecutionDays = max(requiredExecutionDays, hasSell && hasBuy ? 2 : 1)
                }
                previous[variant] = values
                return .init(weights: zip(IntradayDownsideBreadthStrategy.assetOrder, values).map {
                    .init(symbol: $0.0, bits: .init($0.1))
                }, event: event, suppressed: !event)
            }
            let review = IDBReviewAudit(date: reviewDate, assets: audits,
                                        candidate: makeAudit(.candidate), natural: makeAudit(.natural), placebo: makeAudit(.placebo))
            let nextDate = reviewOrdinals.indices.contains(reviewPosition + 1)
                ? signalCommonDates[reviewOrdinals[reviewPosition + 1]] : nil
            let capacity = executionCapacity(after: reviewDate, before: nextDate, in: executableDates)
            if capacity < requiredExecutionDays {
                throw IntradayDownsideBreadthError.queueIncomplete(
                    "joint execution capacity \(capacity) < required \(requiredExecutionDays) after \(reviewDate)"
                )
            }
            reviews.append(review)
        }
        guard !reviews.isEmpty else { throw IntradayDownsideBreadthError.invalidInput("no reviews") }

        let blank = IDBFingerprints(header: "", input: "", candidate: "", natural: "", placebo: "", full: "")
        var artifact = IntradayDownsideBreadthFrozenArtifact(
            schemaVersion: 1, trialID: IntradayDownsideBreadthStrategy.trialID,
            strategyID: IntradayDownsideBreadthStrategy.strategyID, strategyVersion: IntradayDownsideBreadthStrategy.strategyVersion,
            lineage: IntradayDownsideBreadthStrategy.lineage, gitCommit: config.gitCommit,
            fixturePath: config.fixturePath, fixtureSHA256: config.fixtureSHA256,
            provenancePath: config.provenancePath, provenanceSHA256: config.provenanceSHA256,
            assetOrder: IntradayDownsideBreadthStrategy.assetOrder, signalAssetOrder: IntradayDownsideBreadthStrategy.signalAssetOrder,
            lookback: IntradayDownsideBreadthStrategy.lookback, reviewStep: IntradayDownsideBreadthStrategy.reviewStep,
            anchorDate: reviews[0].date, runtime: config.runtime, actualWindows: config.actualWindows,
            signalCommonDates: signalCommonDates, executableDates: executableDates,
            provenance: config.provenance, reviews: reviews, fingerprints: blank
        )
        artifact = artifact.replacing(fingerprints: IDBFingerprints(
            header: IDBFingerprint.header(artifact), input: IDBFingerprint.input(artifact),
            candidate: IDBFingerprint.variant(artifact, .candidate), natural: IDBFingerprint.variant(artifact, .natural),
            placebo: IDBFingerprint.variant(artifact, .placebo), full: IDBFingerprint.full(artifact)
        ))
        return artifact
    }

    private static func hasExecution(after review: String, before next: String?, in dates: [String]) -> Bool {
        executionCapacity(after: review, before: next, in: dates) > 0
    }

    private static func executionCapacity(after review: String, before next: String?, in dates: [String]) -> Int {
        dates.reduce(into: 0) { count, date in
            guard date > review && (next.map { date < $0 } ?? true) else { return }
            count += 1
        }
    }
}

private extension String {
    var isSHA256: Bool { count == 64 && allSatisfy(\.isHexDigit) && self == lowercased() }
}

private extension IntradayDownsideBreadthFrozenArtifact {
    func replacing(fingerprints: IDBFingerprints) -> Self {
        .init(schemaVersion: schemaVersion, trialID: trialID, strategyID: strategyID, strategyVersion: strategyVersion,
              lineage: lineage, gitCommit: gitCommit, fixturePath: fixturePath, fixtureSHA256: fixtureSHA256,
              provenancePath: provenancePath, provenanceSHA256: provenanceSHA256, assetOrder: assetOrder,
              signalAssetOrder: signalAssetOrder, lookback: lookback, reviewStep: reviewStep, anchorDate: anchorDate,
              runtime: runtime, actualWindows: actualWindows, signalCommonDates: signalCommonDates,
              executableDates: executableDates, provenance: provenance, reviews: reviews, fingerprints: fingerprints)
    }
}

nonisolated private struct IDBByteWriter {
    var bytes: [UInt8] = []
    mutating func u64(_ value: UInt64) { bytes.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init)) }
    mutating func integer(_ value: Int) { u64(UInt64(value)) }
    mutating func double(_ value: IDBBitExactDouble) { u64(UInt64(value.bits, radix: 16)!) }
    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }
    mutating func enumeration(_ value: UInt8) { bytes.append(value) }
    mutating func string(_ value: String) { let value = Array(value.utf8); u64(UInt64(value.count)); bytes.append(contentsOf: value) }
    mutating func optionalString(_ value: String?) { bool(value != nil); if let value { string(value) } }
    mutating func count(_ value: Int) { u64(UInt64(value)) }
}

nonisolated enum IDBFingerprint {
    private static func identity(_ artifact: IntradayDownsideBreadthFrozenArtifact, into w: inout IDBByteWriter) {
        w.integer(artifact.schemaVersion); w.string(artifact.trialID); w.string(artifact.strategyID)
        w.string(artifact.strategyVersion); w.string(artifact.lineage); w.string(artifact.gitCommit)
        w.string(artifact.fixturePath); w.string(artifact.fixtureSHA256)
        w.string(artifact.provenancePath); w.string(artifact.provenanceSHA256)
        w.count(artifact.assetOrder.count); artifact.assetOrder.forEach { w.string($0) }
        w.count(artifact.signalAssetOrder.count); artifact.signalAssetOrder.forEach { w.string($0) }
        w.integer(artifact.lookback); w.integer(artifact.reviewStep); w.string(artifact.anchorDate)
        w.string(artifact.runtime.swiftVersion); w.string(artifact.runtime.target); w.string(artifact.runtime.osProduct)
        w.string(artifact.runtime.osVersion); w.string(artifact.runtime.osBuild)
        w.count(artifact.actualWindows.count)
        for item in artifact.actualWindows {
            w.string(item.id); w.optionalString(item.requestedStart); w.string(item.actualStart); w.string(item.actualEnd)
        }
        w.count(artifact.provenance.count)
        for item in artifact.provenance {
            w.string(item.symbol); w.string(item.sourceID); w.string(item.claim); w.bool(item.rowLevelSourceProof); w.optionalString(item.provenanceSHA256)
        }
    }

    private static func inputs(_ artifact: IntradayDownsideBreadthFrozenArtifact, into w: inout IDBByteWriter) {
        w.count(artifact.signalCommonDates.count); artifact.signalCommonDates.forEach { w.string($0) }
        w.count(artifact.executableDates.count); artifact.executableDates.forEach { w.string($0) }
        w.count(artifact.reviews.count)
        for review in artifact.reviews {
            w.string(review.date); w.count(review.assets.count)
            for asset in review.assets {
                w.string(asset.symbol); w.string(asset.sourceID); w.string(asset.currency); w.count(asset.bars.count)
                for bar in asset.bars {
                    w.string(bar.date); w.double(bar.open); w.double(bar.high); w.double(bar.low); w.double(bar.close)
                    w.string(bar.sourceID); w.double(bar.x)
                }
                w.double(asset.mean)
            }
        }
    }

    private static func targets(_ artifact: IntradayDownsideBreadthFrozenArtifact, variants: [IntradayDownsideBreadthStrategy.Variant], into w: inout IDBByteWriter) {
        w.count(artifact.reviews.count)
        for review in artifact.reviews {
            w.string(review.date); w.count(variants.count)
            for variant in variants {
                w.enumeration(variant.rawValue)
                let target = review.target(variant); w.count(target.weights.count)
                for weight in target.weights { w.string(weight.symbol); w.double(weight.bits) }
                w.bool(target.event); w.bool(target.suppressed)
            }
        }
    }

    static func header(_ artifact: IntradayDownsideBreadthFrozenArtifact) -> String {
        var w = IDBByteWriter(); w.bytes.append(contentsOf: IntradayDownsideBreadthStrategy.headerDomain.utf8)
        identity(artifact, into: &w); return IDBSHA256.hex(w.bytes)
    }
    static func input(_ artifact: IntradayDownsideBreadthFrozenArtifact) -> String {
        var w = IDBByteWriter(); w.bytes.append(contentsOf: IntradayDownsideBreadthStrategy.inputDomain.utf8)
        identity(artifact, into: &w); inputs(artifact, into: &w); return IDBSHA256.hex(w.bytes)
    }
    static func variant(_ artifact: IntradayDownsideBreadthFrozenArtifact, _ variant: IntradayDownsideBreadthStrategy.Variant) -> String {
        var w = IDBByteWriter(); w.bytes.append(contentsOf: IntradayDownsideBreadthStrategy.variantDomain.utf8)
        identity(artifact, into: &w); inputs(artifact, into: &w); targets(artifact, variants: [variant], into: &w)
        return IDBSHA256.hex(w.bytes)
    }
    static func full(_ artifact: IntradayDownsideBreadthFrozenArtifact) -> String {
        var w = IDBByteWriter(); w.bytes.append(contentsOf: IntradayDownsideBreadthStrategy.fullDomain.utf8)
        identity(artifact, into: &w); inputs(artifact, into: &w)
        targets(artifact, variants: [.candidate, .natural, .placebo], into: &w); return IDBSHA256.hex(w.bytes)
    }
}

nonisolated enum IntradayDownsideBreadthArtifactCodec {
    static func encode(_ artifact: IntradayDownsideBreadthFrozenArtifact) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(artifact)
    }
    static func decode(_ data: Data) throws -> IntradayDownsideBreadthFrozenArtifact {
        try JSONDecoder().decode(IntradayDownsideBreadthFrozenArtifact.self, from: data)
    }
    static func sha256(_ data: Data) -> String { IDBSHA256.hex(Array(data)) }
}

/// Formal consumers only load and look up frozen targets; no factor or schedule builder is called.
nonisolated struct IntradayDownsideBreadthArtifactLoader {
    let artifact: IntradayDownsideBreadthFrozenArtifact

    static func load(data: Data, enforceFormalRuntime: Bool = true) throws -> Self {
        let artifact = try IntradayDownsideBreadthArtifactCodec.decode(data)
        guard artifact.schemaVersion == 1, artifact.trialID == IntradayDownsideBreadthStrategy.trialID,
              artifact.strategyID == IntradayDownsideBreadthStrategy.strategyID,
              artifact.strategyVersion == IntradayDownsideBreadthStrategy.strategyVersion,
              artifact.lineage == IntradayDownsideBreadthStrategy.lineage,
              artifact.assetOrder == IntradayDownsideBreadthStrategy.assetOrder,
              artifact.signalAssetOrder == IntradayDownsideBreadthStrategy.signalAssetOrder,
              artifact.lookback == 63, artifact.reviewStep == 21 else {
            throw IntradayDownsideBreadthError.invalidInput("artifact identity")
        }
        if enforceFormalRuntime && artifact.runtime != .formal {
            throw IntradayDownsideBreadthError.runtimeMismatch("artifact runtime")
        }
        let eligibleExecutionDates = artifact.executableDates.filter { $0 > artifact.anchorDate }
        guard let firstExecutionDate = eligibleExecutionDates.first,
              let finalExecutionDate = eligibleExecutionDates.last else {
            throw IntradayDownsideBreadthError.invalidInput("formal windows have no execution range")
        }
        let windowSpecifications: [(String, String?)] = [
            ("full", nil),
            ("since_2016_08_31", "2016-08-31"),
            ("since_2020_01_01", "2020-01-01"),
            ("since_2022_01_01", "2022-01-01")
        ]
        let expectedWindows = try windowSpecifications.map { id, requestedStart in
            guard let actualStart = eligibleExecutionDates.first(where: {
                $0 >= max(firstExecutionDate, requestedStart ?? firstExecutionDate)
            }) else {
                throw IntradayDownsideBreadthError.invalidInput("empty formal window \(id)")
            }
            return IntradayDownsideBreadthWindow(
                id: id, requestedStart: requestedStart,
                actualStart: actualStart, actualEnd: finalExecutionDate
            )
        }
        guard artifact.actualWindows == expectedWindows else {
            throw IntradayDownsideBreadthError.invalidInput("exact four-window contract")
        }
        guard artifact.anchorDate == artifact.reviews.first?.date,
              artifact.signalCommonDates == Array(Set(artifact.signalCommonDates)).sorted(),
              artifact.executableDates == Array(Set(artifact.executableDates)).sorted(),
              artifact.provenance.map(\.symbol) == artifact.assetOrder,
              artifact.provenance.allSatisfy({ $0.symbol == "gold_cny" || !$0.rowLevelSourceProof }),
              artifact.reviews.map(\.date) == artifact.reviews.map(\.date).sorted() else {
            throw IntradayDownsideBreadthError.invalidInput("artifact dates/provenance")
        }
        guard let anchorOrdinal = artifact.signalCommonDates.firstIndex(of: artifact.anchorDate) else {
            throw IntradayDownsideBreadthError.invalidInput("anchor ordinal")
        }
        var previous = Dictionary(uniqueKeysWithValues: IntradayDownsideBreadthStrategy.Variant.allCases.map {
            ($0, Array(repeating: 0.0, count: artifact.assetOrder.count))
        })
        for (reviewIndex, review) in artifact.reviews.enumerated() {
            let expectedOrdinal = anchorOrdinal + reviewIndex * IntradayDownsideBreadthStrategy.reviewStep
            guard artifact.signalCommonDates.indices.contains(expectedOrdinal),
                  artifact.signalCommonDates[expectedOrdinal] == review.date,
                  review.assets.map(\.symbol) == artifact.signalAssetOrder else {
                throw IntradayDownsideBreadthError.invalidInput("review identity")
            }
            let expectedDates = Array(artifact.signalCommonDates[(expectedOrdinal - 62)...expectedOrdinal])
            for asset in review.assets {
                guard asset.currency == "CNY", asset.bars.count == 63,
                      asset.bars.map(\.date) == expectedDates,
                      asset.bars.allSatisfy({ $0.date <= review.date && !$0.sourceID.isEmpty }) else {
                    throw IntradayDownsideBreadthError.invalidInput("review bars")
                }
                let recomputed: [Double] = try asset.bars.map { bar in
                    guard let x = IntradayDownsideBreadthFactor.intradayLogReturn(
                        open: bar.open.value, high: bar.high.value, low: bar.low.value, close: bar.close.value
                    ), x.bitPattern == bar.x.value.bitPattern else {
                        throw IntradayDownsideBreadthError.invalidInput("frozen x")
                    }
                    return x
                }
                guard let mean = IntradayDownsideBreadthFactor.mean(recomputed),
                      mean.bitPattern == asset.mean.value.bitPattern else {
                    throw IntradayDownsideBreadthError.invalidInput("frozen mean")
                }
            }
            func breadthTarget(_ count: Int) -> [Double] {
                let gold = Double(count) / 2.0
                let equity = (1.0 - gold) / 2.0
                return [gold, equity, equity]
            }
            let negative = review.assets.reduce(0) { $0 + ($1.mean.value < 0 ? 1 : 0) }
            let positive = review.assets.reduce(0) { $0 + ($1.mean.value > 0 ? 1 : 0) }
            let expectedTargets: [IntradayDownsideBreadthStrategy.Variant: [Double]] = [
                .candidate: breadthTarget(negative),
                .natural: Array(repeating: 1.0 / 3.0, count: 3),
                .placebo: breadthTarget(positive)
            ]
            for variant in IntradayDownsideBreadthStrategy.Variant.allCases {
                let target = review.target(variant); let values = target.weights.map(\.value)
                guard target.weights.map(\.symbol) == artifact.assetOrder, target.suppressed == !target.event,
                      zip(values, expectedTargets[variant]!).allSatisfy({ $0.bitPattern == $1.bitPattern }),
                      values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), values.reduce(0, +) <= 1 else {
                    throw IntradayDownsideBreadthError.invalidInput("target")
                }
                let event = zip(previous[variant]!, values).contains { $0.bitPattern != $1.bitPattern }
                guard event == target.event else { throw IntradayDownsideBreadthError.invalidInput("target event") }
                previous[variant] = values
            }
            let nextReview = artifact.reviews.indices.contains(reviewIndex + 1) ? artifact.reviews[reviewIndex + 1].date : nil
            let requiredDays = IntradayDownsideBreadthStrategy.Variant.allCases.reduce(into: 0) { required, variant in
                let values = review.target(variant).weights.map(\.value)
                let prior = reviewIndex == 0
                    ? Array(repeating: 0.0, count: artifact.assetOrder.count)
                    : artifact.reviews[reviewIndex - 1].target(variant).weights.map(\.value)
                guard review.target(variant).event else { return }
                let hasSell = zip(prior, values).contains { $0 > $1 }
                let hasBuy = zip(prior, values).contains { $0 < $1 }
                required = max(required, hasSell && hasBuy ? 2 : 1)
            }
            let capacity = artifact.executableDates.reduce(into: 0) { count, date in
                guard date > review.date && (nextReview.map { date < $0 } ?? true) else { return }
                count += 1
            }
            guard capacity >= requiredDays else {
                throw IntradayDownsideBreadthError.queueIncomplete("frozen execution capacity")
            }
        }
        let expected = IDBFingerprints(
            header: IDBFingerprint.header(artifact), input: IDBFingerprint.input(artifact),
            candidate: IDBFingerprint.variant(artifact, .candidate), natural: IDBFingerprint.variant(artifact, .natural),
            placebo: IDBFingerprint.variant(artifact, .placebo), full: IDBFingerprint.full(artifact)
        )
        guard artifact.fingerprints == expected else {
            throw IntradayDownsideBreadthError.fingerprintMismatch("artifact")
        }
        return .init(artifact: artifact)
    }

    func target(variant: IntradayDownsideBreadthStrategy.Variant, reviewDate: String) -> [String: Double]? {
        guard let review = artifact.reviews.first(where: { $0.date == reviewDate }), review.target(variant).event else { return nil }
        return review.target(variant).valuesBySymbol
    }
}

nonisolated struct IntradayDownsideBreadthExecutionTrace: Equatable {
    let reviewDate: String
    let completionDate: String
}

nonisolated struct IntradayDownsideBreadthSimulationValidation {
    let simulation: BacktestDailySimulationResult
    let trace: [IntradayDownsideBreadthExecutionTrace]
}

/// Contract adapter around the App's one shared simulator. The observation mask is narrowed
/// to frozen joint canonical execution dates, so OHLC-only and forward-filled dates cannot fill.
nonisolated enum IntradayDownsideBreadthSharedSimulator {
    static func run(
        artifact: IntradayDownsideBreadthFrozenArtifact,
        variant: IntradayDownsideBreadthStrategy.Variant,
        frame: MarketDataFrame,
        execution: BacktestExecutionConfig
    ) throws -> IntradayDownsideBreadthSimulationValidation {
        let required = Set(IntradayDownsideBreadthStrategy.assetOrder)
        guard !execution.allowsFinancedExposure, execution.financingAnnualRate == 0,
              !frame.dates.isEmpty, zip(frame.dates, frame.dates.dropFirst()).allSatisfy({ $0 < $1 }),
              frame.dates.indices.contains(frame.simulationRange.lowerBound), frame.dates.indices.contains(frame.simulationRange.upperBound),
              Set(frame.tradableSymbols).count == frame.tradableSymbols.count,
              required.isSubset(of: Set(frame.tradableSymbols)), required.isSubset(of: Set(frame.optionBySymbol.keys)),
              !artifact.executableDates.isEmpty else {
            throw IntradayDownsideBreadthError.invalidInput("shared simulator frame coverage")
        }
        let frozenExecutable = Set(artifact.executableDates)
        var narrowedObserved = frame.observedBySymbol
        for symbol in IntradayDownsideBreadthStrategy.assetOrder {
            guard let prices = frame.pricesBySymbol[symbol], prices.count == frame.dates.count,
                  prices.allSatisfy({ $0.isFinite && $0 > 0 }),
                  let observed = frame.observedBySymbol[symbol], observed.count == frame.dates.count else {
                throw IntradayDownsideBreadthError.invalidInput("shared simulator series \(symbol)")
            }
            narrowedObserved[symbol] = frame.dates.indices.map { index in
                frozenExecutable.contains(frame.dates[index].recordDateString)
                    && IntradayDownsideBreadthStrategy.assetOrder.allSatisfy { frame.observedBySymbol[$0]?[index] == true }
            }
        }
        let narrowedFrame = MarketDataFrame(
            dates: frame.dates, pricesBySymbol: frame.pricesBySymbol, observedBySymbol: narrowedObserved,
            ohlcBySymbol: frame.ohlcBySymbol, tradableSymbols: frame.tradableSymbols,
            optionBySymbol: frame.optionBySymbol, simulationRange: frame.simulationRange
        )
        let events = artifact.reviews.filter { $0.target(variant).event }
        let eventByDate = Dictionary(uniqueKeysWithValues: events.map { ($0.date, $0.target(variant).valuesBySymbol) })
        var activated: [String] = []
        var activeReview: String?
        var trace: [IntradayDownsideBreadthExecutionTrace] = []
        guard let simulation = BacktestDailySimulator.run(
            frame: narrowedFrame, execution: execution,
            provider: StrategyTargetProvider { eventByDate[$0.signalDate.recordDateString] ?? [:] },
            rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
            contextualRebalanceDecision: { context in
                let review = context.signalDate.recordDateString
                let event = eventByDate[review] != nil
                if event { activated.append(review); activeReview = review }
                return .init(shouldRebalance: event, refreshOverlay: false)
            },
            didExecuteTarget: { index in
                guard let review = activeReview, frame.dates.indices.contains(index) else { return }
                trace.append(.init(reviewDate: review, completionDate: frame.dates[index].recordDateString)); activeReview = nil
            }
        ) else { throw IntradayDownsideBreadthError.queueIncomplete("shared simulator rejected frame") }
        let expected = events.map(\.date)
        guard activeReview == nil, activated == expected, trace.map(\.reviewDate) == expected else {
            throw IntradayDownsideBreadthError.queueIncomplete("pending target suppressed or incomplete")
        }
        let reviews = artifact.reviews.map(\.date)
        for item in trace {
            guard item.completionDate > item.reviewDate, frozenExecutable.contains(item.completionDate),
                  let index = reviews.firstIndex(of: item.reviewDate) else {
                throw IntradayDownsideBreadthError.queueIncomplete("invalid completion")
            }
            if reviews.indices.contains(index + 1), item.completionDate >= reviews[index + 1] {
                throw IntradayDownsideBreadthError.queueIncomplete("completion reached next review")
            }
        }
        return .init(simulation: simulation, trace: trace)
    }
}

// Compact dependency-free SHA-256 shared by App source and freeze command.
nonisolated private struct IDBSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]
    static func hex(_ input: [UInt8]) -> String {
        var bytes = input; let bitLength = UInt64(bytes.count) * 8; bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var w = Array(repeating: UInt32(0), count: 64)
            for i in 0..<16 { let j = offset + i * 4; w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j+1]) << 16 | UInt32(bytes[j+2]) << 8 | UInt32(bytes[j+3]) }
            for i in 16..<64 { let s0 = w[i-15].rr(7) ^ w[i-15].rr(18) ^ (w[i-15] >> 3); let s1 = w[i-2].rr(17) ^ w[i-2].rr(19) ^ (w[i-2] >> 10); w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1 }
            var v = h
            for i in 0..<64 { let s1 = v[4].rr(6) ^ v[4].rr(11) ^ v[4].rr(25); let ch = (v[4] & v[5]) ^ ((~v[4]) & v[6]); let t1 = v[7] &+ s1 &+ ch &+ k[i] &+ w[i]; let s0 = v[0].rr(2) ^ v[0].rr(13) ^ v[0].rr(22); let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]); let t2 = s0 &+ maj; v = [t1 &+ t2,v[0],v[1],v[2],v[3] &+ t1,v[4],v[5],v[6]] }
            for i in 0..<8 { h[i] &+= v[i] }
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}

private extension UInt32 { func rr(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) } }
