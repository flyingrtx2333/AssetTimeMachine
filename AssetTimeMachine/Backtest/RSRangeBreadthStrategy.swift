import Foundation

// MARK: - RS-RANGE-BREADTH-21-252-001 frozen protocol

/// Return-blind shared factor and immutable-schedule implementation.
///
/// Fingerprint byte grammar (`ATM_RS_RANGE_BREADTH_SCHEDULE_V1`): the digest begins with
/// the raw ASCII domain bytes `ATM_RS_RANGE_BREADTH_SCHEDULE_V1\0`. Every integer is U64
/// big-endian. Every floating-point value is its IEEE-754 binary64 `bitPattern` encoded as
/// U64 big-endian. Bool is one byte (`0` or `1`); enums are one byte. ASCII/UTF-8 byte
/// strings are U64 byte-length-prefixed; arrays are U64 count-prefixed. Optional doubles
/// use an explicit one-byte absent/present tag and absent values contribute no value bits.
/// Assets and weights are always encoded in `assetOrder`. Schedule fingerprints encode the
/// complete identity/input/header, every review date, each asset's exact 252 prepared CNY
/// OHLC rows (date, O/H/L/C bits, source ID, q optional tag/bits), long/short means, x
/// optional tag/bits and state, followed by that schedule's target bits and event/suppressed
/// flags. The combined fingerprint encodes all three targets in candidate/natural/placebo
/// order. JSON is only an audit transport and is never canonicalized or hashed.
nonisolated enum RSRangeBreadthStrategy {
    static let strategyID = "RS-RANGE-BREADTH-21-252-001"
    static let strategyVersion = "1"
    static let fingerprintDomain = "ATM_RS_RANGE_BREADTH_SCHEDULE_V1\0"
    static let assetOrder = ["gold_cny", "nasdaq", "sp500"]
    static let lookback = 252
    static let shortLookback = 21
    static let reviewStep = 21

    enum Variant: UInt8, Codable, CaseIterable {
        case candidate = 0
        case natural = 1
        case placebo = 2
    }
}

nonisolated enum RSRangeBreadthError: Error, Equatable, CustomStringConvertible {
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

nonisolated struct RSRangeBreadthRuntime: Codable, Equatable {
    let swiftVersion: String
    let target: String
    let osProduct: String
    let osVersion: String
    let osBuild: String

    static let formal = RSRangeBreadthRuntime(
        swiftVersion: "Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2)",
        target: "arm64-apple-macosx26.0",
        osProduct: "macOS",
        osVersion: "26.5.2",
        osBuild: "25F84"
    )
}

nonisolated struct RSRangeBreadthWindow: Codable, Equatable {
    let id: String
    let requestedStart: String?
    let actualStart: String
    let actualEnd: String
}

nonisolated struct RSRangeBreadthFreezeConfig: Codable, Equatable {
    let gitCommit: String
    let fixturePath: String
    let fixtureSHA256: String
    let manifestPath: String
    let manifestSHA256: String
    let runtime: RSRangeBreadthRuntime
    let actualWindows: [RSRangeBreadthWindow]
    let executableDates: [String]

    init(
        gitCommit: String,
        fixturePath: String,
        fixtureSHA256: String,
        manifestPath: String,
        manifestSHA256: String,
        runtime: RSRangeBreadthRuntime,
        actualWindows: [RSRangeBreadthWindow],
        executableDates: [String] = []
    ) {
        self.gitCommit = gitCommit
        self.fixturePath = fixturePath
        self.fixtureSHA256 = fixtureSHA256
        self.manifestPath = manifestPath
        self.manifestSHA256 = manifestSHA256
        self.runtime = runtime
        self.actualWindows = actualWindows
        self.executableDates = executableDates
    }
}

nonisolated struct RSRangeBreadthSignalBar: Equatable {
    let date: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let sourceID: String
}

nonisolated struct RSRangeBreadthAssetInput {
    let symbol: String
    let sourceID: String
    let currency: String
    let bars: [RSRangeBreadthSignalBar]
}

nonisolated enum RSRangeBreadthState: UInt8, Codable {
    case invalid = 0
    case calm = 1
    case expanding = 2
}

nonisolated struct RSRangeBreadthFactorValue {
    let longMean: Double?
    let shortMean: Double?
    let x: Double?
    let valid: Bool
    let state: RSRangeBreadthState
}

nonisolated enum RSRangeBreadthFactor {
    /// Exact operation order is frozen. No epsilon or rounding is permitted.
    static func dailyRS(open: Double, high: Double, low: Double, close: Double) -> Double? {
        guard open.isFinite, high.isFinite, low.isFinite, close.isFinite,
              min(open, high, low, close) > 0,
              high >= max(open, close, low),
              low <= min(open, close, high) else { return nil }
        let q = log(high / close) * log(high / open)
            + log(low / close) * log(low / open)
        guard q.isFinite else { return nil }
        return clampMicroNegative(q)
    }

    /// Valid geometry makes mathematical q nonnegative; any floating-point negative is
    /// therefore a numerical artifact and is clamped to positive zero.
    static func clampMicroNegative(_ q: Double) -> Double {
        q < 0 ? 0.0 : q
    }

    static func factor(qValues: [Double]) -> RSRangeBreadthFactorValue {
        guard qValues.count == RSRangeBreadthStrategy.lookback,
              qValues.allSatisfy(\.isFinite) else {
            return .init(longMean: nil, shortMean: nil, x: nil, valid: false, state: .invalid)
        }
        var longSum = 0.0
        for q in qValues { longSum += q }
        var shortSum = 0.0
        for q in qValues.suffix(RSRangeBreadthStrategy.shortLookback) { shortSum += q }
        let longMean = longSum / Double(RSRangeBreadthStrategy.lookback)
        let shortMean = shortSum / Double(RSRangeBreadthStrategy.shortLookback)
        guard longMean.isFinite, longMean > 0, shortMean.isFinite else {
            return .init(longMean: longMean.isFinite ? longMean : nil, shortMean: shortMean.isFinite ? shortMean : nil, x: nil, valid: false, state: .invalid)
        }
        let x = shortMean / longMean - 1
        guard x.isFinite else {
            return .init(longMean: longMean, shortMean: shortMean, x: nil, valid: false, state: .invalid)
        }
        return .init(longMean: longMean, shortMean: shortMean, x: x, valid: true, state: x <= 0 ? .calm : .expanding)
    }

    static func futureRSMean(_ qValues: ArraySlice<Double>) -> Double? {
        guard qValues.count == RSRangeBreadthStrategy.shortLookback,
              qValues.allSatisfy(\.isFinite) else { return nil }
        var sum = 0.0
        for q in qValues { sum += q }
        let value = sum / Double(RSRangeBreadthStrategy.shortLookback)
        return value.isFinite ? value : nil
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

nonisolated struct RSBitExactDouble: Codable, Equatable {
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
        var container = encoder.singleValueContainer()
        try container.encode(bits)
    }
    var value: Double { Double(bitPattern: UInt64(bits, radix: 16) ?? 0) }
}

nonisolated struct RSFrozenBar: Codable, Equatable {
    let date: String
    let open: RSBitExactDouble
    let high: RSBitExactDouble
    let low: RSBitExactDouble
    let close: RSBitExactDouble
    let sourceID: String
    let q: RSBitExactDouble?
}

nonisolated struct RSAssetReviewAudit: Codable, Equatable {
    let symbol: String
    let sourceID: String
    let currency: String
    let bars: [RSFrozenBar]
    let longMean: RSBitExactDouble?
    let shortMean: RSBitExactDouble?
    let x: RSBitExactDouble?
    let valid: Bool
    let state: RSRangeBreadthState
}

nonisolated struct RSWeight: Codable, Equatable {
    let symbol: String
    let bits: RSBitExactDouble
    var value: Double { bits.value }
}

nonisolated struct RSTargetAudit: Codable, Equatable {
    let weights: [RSWeight]
    let event: Bool
    let suppressed: Bool

    var valuesBySymbol: [String: Double] {
        Dictionary(uniqueKeysWithValues: weights.map { ($0.symbol, $0.value) })
    }
}

nonisolated struct RSReviewAudit: Codable, Equatable {
    let date: String
    let assets: [RSAssetReviewAudit]
    let candidate: RSTargetAudit
    let natural: RSTargetAudit
    let placebo: RSTargetAudit

    func target(_ variant: RSRangeBreadthStrategy.Variant) -> RSTargetAudit {
        switch variant {
        case .candidate: return candidate
        case .natural: return natural
        case .placebo: return placebo
        }
    }
}

nonisolated struct RSScheduleFingerprints: Codable, Equatable {
    let candidate: String
    let natural: String
    let placebo: String

    func value(_ variant: RSRangeBreadthStrategy.Variant) -> String {
        switch variant {
        case .candidate: return candidate
        case .natural: return natural
        case .placebo: return placebo
        }
    }
}

nonisolated struct RSRangeBreadthFrozenArtifact: Codable, Equatable {
    let schemaVersion: Int
    let strategyID: String
    let strategyVersion: String
    let gitCommit: String
    let fixturePath: String
    let fixtureSHA256: String
    let manifestPath: String
    let manifestSHA256: String
    let assetOrder: [String]
    let lookback: Int
    let shortLookback: Int
    let reviewStep: Int
    let anchorDate: String
    let runtime: RSRangeBreadthRuntime
    let actualWindows: [RSRangeBreadthWindow]
    let executableDates: [String]
    let reviews: [RSReviewAudit]
    let scheduleFingerprints: RSScheduleFingerprints
    let combinedFingerprint: String
}

nonisolated enum RSRangeBreadthScheduleBuilder {
    static func build(assets: [RSRangeBreadthAssetInput], config: RSRangeBreadthFreezeConfig) throws -> RSRangeBreadthFrozenArtifact {
        guard assets.map(\.symbol) == RSRangeBreadthStrategy.assetOrder else { throw RSRangeBreadthError.invalidInput("asset order") }
        guard config.fixtureSHA256.count == 64, config.manifestSHA256.count == 64 else { throw RSRangeBreadthError.invalidInput("SHA-256") }
        var barsByAsset: [[RSRangeBreadthSignalBar]] = []
        for asset in assets {
            guard asset.currency == "CNY", !asset.sourceID.isEmpty else { throw RSRangeBreadthError.invalidInput("metadata \(asset.symbol)") }
            let sorted = asset.bars.sorted { $0.date < $1.date }
            guard sorted.map(\.date) == asset.bars.map(\.date), Set(sorted.map(\.date)).count == sorted.count else {
                throw RSRangeBreadthError.invalidInput("bar order/duplicates \(asset.symbol)")
            }
            for bar in sorted {
                guard !bar.sourceID.isEmpty,
                      BacktestSeriesAlignment.historicalSeriesDate(from: bar.date) != nil,
                      RSRangeBreadthFactor.dailyRS(open: bar.open, high: bar.high, low: bar.low, close: bar.close) != nil else {
                    throw RSRangeBreadthError.invalidInput("bar \(asset.symbol) \(bar.date)")
                }
            }
            barsByAsset.append(sorted)
        }
        let dateSets = barsByAsset.map { Set($0.map(\.date)) }
        let common = dateSets.dropFirst().reduce(dateSets[0]) { $0.intersection($1) }.sorted()
        guard let anchorOrdinal = common.indices.first(where: { ordinal in
            let date = common[ordinal]
            return barsByAsset.allSatisfy { bars in bars.filter { $0.date <= date }.count >= RSRangeBreadthStrategy.lookback }
        }) else { throw RSRangeBreadthError.invalidInput("no anchor") }
        var reviewDates = stride(from: anchorOrdinal, to: common.count, by: RSRangeBreadthStrategy.reviewStep).map { common[$0] }
        if !config.executableDates.isEmpty {
            let executable = Set(config.executableDates)
            reviewDates = reviewDates.filter { review in executable.contains(where: { $0 > review }) }
        }
        var previous: [RSRangeBreadthStrategy.Variant: [Double]] = [:]
        var reviews: [RSReviewAudit] = []
        for reviewDate in reviewDates {
            var audits: [RSAssetReviewAudit] = []
            for (assetIndex, asset) in assets.enumerated() {
                let participating = Array(barsByAsset[assetIndex].prefix { $0.date <= reviewDate }.suffix(RSRangeBreadthStrategy.lookback))
                guard participating.count == RSRangeBreadthStrategy.lookback else { throw RSRangeBreadthError.invalidInput("lookback") }
                let frozenBars = participating.map { bar -> RSFrozenBar in
                    let q = RSRangeBreadthFactor.dailyRS(open: bar.open, high: bar.high, low: bar.low, close: bar.close)
                    return .init(date: bar.date, open: .init(bar.open), high: .init(bar.high), low: .init(bar.low), close: .init(bar.close), sourceID: bar.sourceID, q: q.map(RSBitExactDouble.init))
                }
                let factor = RSRangeBreadthFactor.factor(qValues: frozenBars.compactMap { $0.q?.value })
                audits.append(.init(
                    symbol: asset.symbol, sourceID: asset.sourceID, currency: asset.currency, bars: frozenBars,
                    longMean: factor.longMean.map(RSBitExactDouble.init), shortMean: factor.shortMean.map(RSBitExactDouble.init),
                    x: factor.x.map(RSBitExactDouble.init), valid: factor.valid, state: factor.state
                ))
            }
            let calm = audits.indices.filter { audits[$0].valid && audits[$0].state == .calm }
            let expanding = audits.indices.filter { audits[$0].valid && audits[$0].state == .expanding }
            func equalWeight(_ indices: [Int]) -> [Double] {
                guard !indices.isEmpty else { return Array(repeating: 0, count: assets.count) }
                let weight = 1.0 / Double(indices.count)
                return assets.indices.map { indices.contains($0) ? weight : 0 }
            }
            let targets: [RSRangeBreadthStrategy.Variant: [Double]] = [
                .candidate: equalWeight(calm),
                .natural: Array(repeating: 1.0 / 3.0, count: 3),
                .placebo: equalWeight(expanding)
            ]
            func audit(_ variant: RSRangeBreadthStrategy.Variant) -> RSTargetAudit {
                let target = targets[variant]!
                let old = previous[variant] ?? Array(repeating: 0.0, count: target.count)
                let event = zip(old, target).contains { $0.bitPattern != $1.bitPattern }
                previous[variant] = target
                return .init(weights: zip(RSRangeBreadthStrategy.assetOrder, target).map { .init(symbol: $0, bits: .init($1)) }, event: event, suppressed: !event)
            }
            reviews.append(.init(date: reviewDate, assets: audits, candidate: audit(.candidate), natural: audit(.natural), placebo: audit(.placebo)))
        }
        guard !reviews.isEmpty else { throw RSRangeBreadthError.invalidInput("no reviews") }
        let blank = RSScheduleFingerprints(candidate: "", natural: "", placebo: "")
        var artifact = RSRangeBreadthFrozenArtifact(
            schemaVersion: 1, strategyID: RSRangeBreadthStrategy.strategyID, strategyVersion: RSRangeBreadthStrategy.strategyVersion,
            gitCommit: config.gitCommit, fixturePath: config.fixturePath, fixtureSHA256: config.fixtureSHA256,
            manifestPath: config.manifestPath, manifestSHA256: config.manifestSHA256, assetOrder: RSRangeBreadthStrategy.assetOrder,
            lookback: RSRangeBreadthStrategy.lookback, shortLookback: RSRangeBreadthStrategy.shortLookback,
            reviewStep: RSRangeBreadthStrategy.reviewStep, anchorDate: reviews[0].date, runtime: config.runtime,
            actualWindows: config.actualWindows, executableDates: Array(Set(config.executableDates)).sorted(), reviews: reviews,
            scheduleFingerprints: blank, combinedFingerprint: ""
        )
        let fingerprints = RSScheduleFingerprints(
            candidate: RSRangeBreadthFingerprint.schedule(artifact, variant: .candidate),
            natural: RSRangeBreadthFingerprint.schedule(artifact, variant: .natural),
            placebo: RSRangeBreadthFingerprint.schedule(artifact, variant: .placebo)
        )
        artifact = artifact.replacing(fingerprints: fingerprints, combined: RSRangeBreadthFingerprint.combined(artifact))
        return artifact
    }
}

private extension RSRangeBreadthFrozenArtifact {
    func replacing(fingerprints: RSScheduleFingerprints? = nil, combined: String? = nil) -> Self {
        .init(schemaVersion: schemaVersion, strategyID: strategyID, strategyVersion: strategyVersion, gitCommit: gitCommit,
              fixturePath: fixturePath, fixtureSHA256: fixtureSHA256, manifestPath: manifestPath, manifestSHA256: manifestSHA256,
              assetOrder: assetOrder, lookback: lookback, shortLookback: shortLookback, reviewStep: reviewStep,
              anchorDate: anchorDate, runtime: runtime, actualWindows: actualWindows, executableDates: executableDates, reviews: reviews,
              scheduleFingerprints: fingerprints ?? scheduleFingerprints,
              combinedFingerprint: combined ?? combinedFingerprint)
    }
}

// Compact dependency-free SHA-256, used identically by the App source and freeze tool.
nonisolated private struct RSSHA256 {
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
        var bytes = input
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var w = Array(repeating: UInt32(0), count: 64)
            for i in 0..<16 {
                let j = offset + i * 4
                w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j+1]) << 16 | UInt32(bytes[j+2]) << 8 | UInt32(bytes[j+3])
            }
            for i in 16..<64 {
                let s0 = w[i-15].rotatedRight(7) ^ w[i-15].rotatedRight(18) ^ (w[i-15] >> 3)
                let s1 = w[i-2].rotatedRight(17) ^ w[i-2].rotatedRight(19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var v = h
            for i in 0..<64 {
                let s1 = v[4].rotatedRight(6) ^ v[4].rotatedRight(11) ^ v[4].rotatedRight(25)
                let ch = (v[4] & v[5]) ^ ((~v[4]) & v[6])
                let t1 = v[7] &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = v[0].rotatedRight(2) ^ v[0].rotatedRight(13) ^ v[0].rotatedRight(22)
                let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
                let t2 = s0 &+ maj
                v = [t1 &+ t2, v[0], v[1], v[2], v[3] &+ t1, v[4], v[5], v[6]]
            }
            for i in 0..<8 { h[i] &+= v[i] }
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}

private extension UInt32 {
    func rotatedRight(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) }
}

nonisolated private struct RSByteWriter {
    var bytes: [UInt8] = []
    mutating func u64(_ value: UInt64) { bytes.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init)) }
    mutating func integer(_ value: Int) { u64(UInt64(value)) }
    mutating func double(_ value: Double) { u64(value.bitPattern) }
    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }
    mutating func enumeration(_ value: UInt8) { bytes.append(value) }
    mutating func string(_ value: String) { let b = Array(value.utf8); u64(UInt64(b.count)); bytes.append(contentsOf: b) }
    mutating func optional(_ value: RSBitExactDouble?) { bool(value != nil); if let value { u64(UInt64(value.bits, radix: 16)!) } }
    mutating func arrayCount(_ count: Int) { u64(UInt64(count)) }
}

nonisolated enum RSRangeBreadthFingerprint {
    private static func header(_ artifact: RSRangeBreadthFrozenArtifact, into w: inout RSByteWriter) {
        w.bytes.append(contentsOf: RSRangeBreadthStrategy.fingerprintDomain.utf8)
        w.integer(artifact.schemaVersion)
        w.string(artifact.strategyID); w.string(artifact.strategyVersion); w.string(artifact.gitCommit)
        w.string(artifact.fixturePath); w.string(artifact.fixtureSHA256); w.string(artifact.manifestPath); w.string(artifact.manifestSHA256)
        w.arrayCount(artifact.assetOrder.count); artifact.assetOrder.forEach { w.string($0) }
        w.integer(artifact.lookback); w.integer(artifact.shortLookback); w.integer(artifact.reviewStep); w.string(artifact.anchorDate)
        w.string(artifact.runtime.swiftVersion); w.string(artifact.runtime.target); w.string(artifact.runtime.osProduct); w.string(artifact.runtime.osVersion); w.string(artifact.runtime.osBuild)
        w.arrayCount(artifact.actualWindows.count)
        for window in artifact.actualWindows { w.string(window.id); w.bool(window.requestedStart != nil); if let value = window.requestedStart { w.string(value) }; w.string(window.actualStart); w.string(window.actualEnd) }
        w.arrayCount(artifact.executableDates.count); artifact.executableDates.forEach { w.string($0) }
    }
    private static func reviewInputs(_ artifact: RSRangeBreadthFrozenArtifact, into w: inout RSByteWriter, targetVariants: [RSRangeBreadthStrategy.Variant]) {
        w.arrayCount(artifact.reviews.count)
        for review in artifact.reviews {
            w.string(review.date); w.arrayCount(review.assets.count)
            for asset in review.assets {
                w.string(asset.symbol); w.string(asset.sourceID); w.string(asset.currency); w.arrayCount(asset.bars.count)
                for bar in asset.bars {
                    w.string(bar.date); w.u64(UInt64(bar.open.bits, radix: 16)!); w.u64(UInt64(bar.high.bits, radix: 16)!); w.u64(UInt64(bar.low.bits, radix: 16)!); w.u64(UInt64(bar.close.bits, radix: 16)!); w.string(bar.sourceID); w.optional(bar.q)
                }
                w.optional(asset.longMean); w.optional(asset.shortMean); w.optional(asset.x); w.bool(asset.valid); w.enumeration(asset.state.rawValue)
            }
            w.arrayCount(targetVariants.count)
            for variant in targetVariants {
                w.enumeration(variant.rawValue)
                let target = review.target(variant); w.arrayCount(target.weights.count)
                for weight in target.weights { w.string(weight.symbol); w.u64(UInt64(weight.bits.bits, radix: 16)!) }
                w.bool(target.event); w.bool(target.suppressed)
            }
        }
    }
    static func schedule(_ artifact: RSRangeBreadthFrozenArtifact, variant: RSRangeBreadthStrategy.Variant) -> String {
        var w = RSByteWriter(); header(artifact, into: &w); reviewInputs(artifact, into: &w, targetVariants: [variant]); return RSSHA256.hex(w.bytes)
    }
    static func combined(_ artifact: RSRangeBreadthFrozenArtifact) -> String {
        var w = RSByteWriter(); header(artifact, into: &w); reviewInputs(artifact, into: &w, targetVariants: [.candidate, .natural, .placebo]); return RSSHA256.hex(w.bytes)
    }
}

nonisolated enum RSRangeBreadthArtifactCodec {
    static func encode(_ artifact: RSRangeBreadthFrozenArtifact) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(artifact)
    }
    static func decode(_ data: Data) throws -> RSRangeBreadthFrozenArtifact {
        try JSONDecoder().decode(RSRangeBreadthFrozenArtifact.self, from: data)
    }
    static func sha256(_ data: Data) -> String {
        RSSHA256.hex(Array(data))
    }
}

/// Formal consumers load this artifact once and perform date lookup only. This loader never
/// calls `RSRangeBreadthFactor` or `RSRangeBreadthScheduleBuilder` and therefore cannot
/// recompute or adapt a signal at runtime.
nonisolated struct RSRangeBreadthArtifactLoader {
    let artifact: RSRangeBreadthFrozenArtifact

    static func load(data: Data, enforceFormalRuntime: Bool = true) throws -> Self {
        let artifact = try RSRangeBreadthArtifactCodec.decode(data)
        guard artifact.schemaVersion == 1,
              artifact.strategyID == RSRangeBreadthStrategy.strategyID, artifact.strategyVersion == RSRangeBreadthStrategy.strategyVersion,
              artifact.assetOrder == RSRangeBreadthStrategy.assetOrder, artifact.lookback == 252, artifact.shortLookback == 21, artifact.reviewStep == 21 else {
            throw RSRangeBreadthError.invalidInput("artifact identity")
        }
        if enforceFormalRuntime, artifact.runtime != .formal { throw RSRangeBreadthError.runtimeMismatch("artifact runtime") }
        guard artifact.executableDates == Array(Set(artifact.executableDates)).sorted(),
              artifact.executableDates.allSatisfy({ BacktestSeriesAlignment.historicalSeriesDate(from: $0) != nil }),
              artifact.reviews.map(\.date) == Array(Set(artifact.reviews.map(\.date))).sorted(),
              artifact.anchorDate == artifact.reviews.first?.date,
              artifact.actualWindows.allSatisfy({ window in
                  BacktestSeriesAlignment.historicalSeriesDate(from: window.actualStart) != nil
                      && BacktestSeriesAlignment.historicalSeriesDate(from: window.actualEnd) != nil
                      && window.actualStart <= window.actualEnd
                      && window.requestedStart.map { BacktestSeriesAlignment.historicalSeriesDate(from: $0) != nil } ?? true
              }) else {
            throw RSRangeBreadthError.invalidInput("artifact dates")
        }
        var previous = Dictionary(uniqueKeysWithValues: RSRangeBreadthStrategy.Variant.allCases.map {
            ($0, Array(repeating: 0.0, count: RSRangeBreadthStrategy.assetOrder.count))
        })
        for review in artifact.reviews {
            guard BacktestSeriesAlignment.historicalSeriesDate(from: review.date) != nil,
                  review.assets.map(\.symbol) == RSRangeBreadthStrategy.assetOrder else {
                throw RSRangeBreadthError.invalidInput("review identity")
            }
            for asset in review.assets {
                guard asset.currency == "CNY", !asset.sourceID.isEmpty, asset.bars.count == artifact.lookback,
                      asset.bars.map(\.date) == asset.bars.map(\.date).sorted(),
                      Set(asset.bars.map(\.date)).count == asset.bars.count,
                      asset.bars.allSatisfy({
                          BacktestSeriesAlignment.historicalSeriesDate(from: $0.date) != nil
                              && $0.date <= review.date && !$0.sourceID.isEmpty
                      }) else {
                    throw RSRangeBreadthError.invalidInput("review bars")
                }
            }
            for variant in RSRangeBreadthStrategy.Variant.allCases {
                let target = review.target(variant)
                guard target.weights.map(\.symbol) == RSRangeBreadthStrategy.assetOrder,
                      target.suppressed == !target.event else {
                    throw RSRangeBreadthError.invalidInput("target identity")
                }
                let values = target.weights.map(\.value)
                guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), values.reduce(0, +) <= 1 else {
                    throw RSRangeBreadthError.invalidInput("target weights")
                }
                let expectedEvent = zip(previous[variant]!, values).contains { $0.bitPattern != $1.bitPattern }
                guard target.event == expectedEvent else { throw RSRangeBreadthError.invalidInput("target event") }
                previous[variant] = values
            }
        }
        for variant in RSRangeBreadthStrategy.Variant.allCases {
            guard artifact.scheduleFingerprints.value(variant) == RSRangeBreadthFingerprint.schedule(artifact, variant: variant) else {
                throw RSRangeBreadthError.fingerprintMismatch("schedule \(variant)")
            }
        }
        guard artifact.combinedFingerprint == RSRangeBreadthFingerprint.combined(artifact) else { throw RSRangeBreadthError.fingerprintMismatch("combined") }
        return .init(artifact: artifact)
    }

    func target(variant: RSRangeBreadthStrategy.Variant, reviewDate: String) -> [String: Double]? {
        guard let review = artifact.reviews.first(where: { $0.date == reviewDate }), review.target(variant).event else { return nil }
        return review.target(variant).valuesBySymbol
    }

    var reviewDates: [String] { artifact.reviews.map(\.date) }
}

nonisolated struct RSRangeBreadthExecutionTrace: Equatable {
    let reviewDate: String
    let completionDate: String
}

nonisolated struct RSRangeBreadthSimulationValidation {
    let simulation: BacktestDailySimulationResult
    let trace: [RSRangeBreadthExecutionTrace]
}

/// Uses the App's shared execution state machine; this is validation, not a second simulator.
nonisolated enum RSRangeBreadthSharedSimulator {
    static func run(
        artifact: RSRangeBreadthFrozenArtifact,
        variant: RSRangeBreadthStrategy.Variant,
        frame: MarketDataFrame,
        execution: BacktestExecutionConfig
    ) throws -> RSRangeBreadthSimulationValidation {
        let requiredSymbols = Set(RSRangeBreadthStrategy.assetOrder)
        guard requiredSymbols.isSubset(of: Set(frame.tradableSymbols)),
              requiredSymbols.isSubset(of: Set(frame.optionBySymbol.keys)),
              !artifact.executableDates.isEmpty else {
            throw RSRangeBreadthError.invalidInput("shared simulator frame coverage")
        }
        for symbol in RSRangeBreadthStrategy.assetOrder {
            guard let prices = frame.pricesBySymbol[symbol], prices.count == frame.dates.count,
                  prices.allSatisfy({ $0.isFinite && $0 > 0 }),
                  let observations = frame.observedBySymbol[symbol], observations.count == frame.dates.count else {
                throw RSRangeBreadthError.invalidInput("shared simulator series \(symbol)")
            }
        }
        let executableDates = Set(artifact.executableDates)
        let events = artifact.reviews.filter { $0.target(variant).event }
        let eventByDate = Dictionary(uniqueKeysWithValues: events.map { ($0.date, $0.target(variant).valuesBySymbol) })
        var activated: [String] = []
        var activeReview: String?
        var trace: [RSRangeBreadthExecutionTrace] = []
        guard let simulation = BacktestDailySimulator.run(
            frame: frame,
            execution: execution,
            provider: StrategyTargetProvider { context in eventByDate[context.signalDate.recordDateString] ?? [:] },
            rebalanceDecision: { _, _ in .init(shouldRebalance: false, refreshOverlay: false) },
            contextualRebalanceDecision: { context in
                let review = context.signalDate.recordDateString
                let shouldRebalance = eventByDate[review] != nil
                if shouldRebalance {
                    activated.append(review)
                    activeReview = review
                }
                return .init(shouldRebalance: shouldRebalance, refreshOverlay: false)
            },
            didExecuteTarget: { index in
                guard let review = activeReview, frame.dates.indices.contains(index) else { return }
                trace.append(.init(reviewDate: review, completionDate: frame.dates[index].recordDateString))
                activeReview = nil
            }
        ) else {
            throw RSRangeBreadthError.queueIncomplete("shared simulator rejected frame")
        }
        let expectedDates = events.map(\.date)
        guard activeReview == nil, activated == expectedDates, trace.map(\.reviewDate) == expectedDates else {
            throw RSRangeBreadthError.queueIncomplete("pending target suppressed or remained incomplete")
        }
        let allReviews = artifact.reviews.map(\.date)
        for item in trace {
            guard item.completionDate > item.reviewDate,
                  executableDates.contains(item.completionDate) else {
                throw RSRangeBreadthError.queueIncomplete("completion \(item.completionDate) is not a frozen execution date after review \(item.reviewDate)")
            }
            guard let reviewIndex = allReviews.firstIndex(of: item.reviewDate) else {
                throw RSRangeBreadthError.queueIncomplete("unknown review \(item.reviewDate)")
            }
            if allReviews.indices.contains(reviewIndex + 1), item.completionDate >= allReviews[reviewIndex + 1] {
                throw RSRangeBreadthError.queueIncomplete("completion \(item.completionDate) is not before next review \(allReviews[reviewIndex + 1])")
            }
        }
        return .init(simulation: simulation, trace: trace)
    }
}
