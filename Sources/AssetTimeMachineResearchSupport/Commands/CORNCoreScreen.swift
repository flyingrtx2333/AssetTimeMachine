import Foundation
import CoreFoundation
import CryptoKit
import AssetTimeMachineBacktestCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// One frozen single CORN5/rho0.1 source export; finance only loads its qualified targets.
public enum CORNCoreScreen {
    public static let coreSymbols = RiskParityCoreScreen.coreSymbols
    public static let candidateID = "corn5-rho01-three-core-daily-next-close"
    public static let equalID = "equal-core100-corn5rho01-daily-close-control"
    public static let cashID = "cny-cash-corn5rho01-native2001"
    public static let qualID = ChaikinMoneyFlowScreen.qualID
    public static var savedControlIDs: [String] { ChaikinMoneyFlowScreen.savedControlIDs }
    public typealias PriceBar = RiskParityCoreScreen.PriceBar
    public typealias FXPoint = RiskParityCoreScreen.FXPoint
    public typealias Quote = RiskParityCoreScreen.Quote
    public typealias NativePreparation = RiskParityCoreScreen.NativePreparation
    public typealias Decision = RiskParityCoreScreen.Decision
    public typealias Completion = RiskParityCoreScreen.Completion
    public typealias NativeRun = RiskParityCoreScreen.NativeRun
    public typealias Role = RiskParityCoreScreen.Role
    public static let window = 5
    public static let rho = 0.1
    public static let updateCap = 1024
    public static let bisectionCap = 64
    public static let studyPath = "/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/fixed-corn5-rho01-core-2026-10-10"
    public static let primitivePath = "/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/fixed-rp63-core-2026-10-10/SOURCE_PRIMITIVES.json"
    public static let primitiveSHA = "290d8a36402dcc467b6450370b72e4baae6f222a6e432e927f123d732f546946"
    public static let accountsPath = "/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/fixed-rp63-core-2026-10-10/ACCOUNTS.json"
    public static let accountsSHA = "a898b763729cb57bd1586e29a8efd17ad5eb7ded042c7ad6b19f685a381ef7c7"
    public static let engineeringPath = "/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/source-admission-corn-2026-10-10-root/ENGINEERING_PROPOSAL_V3.json"
    public static let engineeringSHA = "51040be69fd47adbd388a6914d353167d1eab3f961547e86eabb116aa36e50b2"
    static let signalsName = "SOURCE_NATIVE_SIGNALS.json"
    static let correlationsName = "SOURCE_CORRELATIONS.bin"
    static let manifestName = "SOURCE_EXPORT_MANIFEST.json"
    static let sourceSignalSchema = "fixed-corn5-rho01-core-source-signal-v2"
    static let correlationSchema = "corn5-rho01-correlation-fixed10byte-le-v1"
    static let manifestSchema = "fixed-corn5-rho01-source-export-manifest-v1"

    static func invalid(_ message: String) -> BacktestConfigurationError {
        .invalidParameter("CORN5RHO01 " + message)
    }
    @inline(never) static func finite(_ x: Double) throws -> Double {
        guard x.isFinite else { throw invalid("nonfinite primitive; no fallback") }
        return x
    }
    @inline(never) static func add(_ a: Double, _ b: Double) throws -> Double {
        _ = try finite(a); _ = try finite(b)
        return try finite(a + b)
    }
    @inline(never) static func subtract(_ a: Double, _ b: Double) throws -> Double {
        _ = try finite(a); _ = try finite(b)
        return try finite(a - b)
    }
    @inline(never) static func multiply(_ a: Double, _ b: Double) throws -> Double {
        _ = try finite(a); _ = try finite(b)
        let x = try finite(a * b)
        guard a == 0 || b == 0 || x != 0 else { throw invalid("observable nonzero multiply underflow") }
        return x
    }
    @inline(never) static func divide(_ a: Double, _ b: Double) throws -> Double {
        _ = try finite(a); _ = try finite(b)
        guard b != 0 else { throw invalid("division by zero") }
        let x = try finite(a / b)
        guard a == 0 || x != 0 else { throw invalid("observable nonzero divide underflow") }
        return x
    }
    @inline(never) static func root(_ x: Double) throws -> Double {
        _ = try finite(x)
        guard x >= 0 else { throw invalid("negative square root") }
        let result = try finite(sqrt(x))
        guard x == 0 || result != 0 else { throw invalid("positive square root underflow") }
        return result
    }
    static func sum(_ xs: [Double]) throws -> Double {
        var result = 0.0
        for x in xs { result = try add(result, x) }
        return result
    }
    static func positive(_ x: Double) throws -> Double {
        guard x.isFinite, x > 0 else { throw invalid("strictly positive finite domain") }
        return x
    }
    static func bits(_ x: Double) -> String { String(format: "%016llx", x.bitPattern) }
    static func vectorBits(_ xs: [Double]) -> [String] { xs.map(bits) }

    struct Correlation {
        let value: Double?
        let zeroVariance: Bool
        let matched: Bool
    }
    /// Mathematical zero-variance domain is checked before any Pearson arithmetic.
    static func pearson(_ a: [Double], _ b: [Double]) throws -> Correlation {
        guard a.count == 15, b.count == 15,
              a.allSatisfy({ $0.isFinite && $0 > 0 }),
              b.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw invalid("Pearson positive finite15-leaf windows") }
        if a.allSatisfy({ $0 == a[0] }) || b.allSatisfy({ $0 == b[0] }) {
            return .init(value: nil, zeroVariance: true, matched: false)
        }
        let ma = try divide(sum(a), 15), mb = try divide(sum(b), 15)
        var ca: [Double] = [], cb: [Double] = []
        for k in 0..<15 { ca.append(try subtract(a[k], ma)); cb.append(try subtract(b[k], mb)) }
        var cross = 0.0, aa = 0.0, bb = 0.0
        for k in 0..<15 {
            cross = try add(cross, multiply(ca[k], cb[k]))
            aa = try add(aa, multiply(ca[k], ca[k]))
            bb = try add(bb, multiply(cb[k], cb[k]))
        }
        if aa == 0 || bb == 0 { return .init(value: nil, zeroVariance: true, matched: false) }
        let ra = try root(aa), rb = try root(bb)
        let denominator = try positive(multiply(ra, rb))
        let value = try divide(cross, denominator)
        return .init(value: value, zeroVariance: false, matched: value >= rho)
    }
    static func dot(_ weights: [Double], _ row: [Double]) throws -> Double {
        guard weights.count == 3, row.count == 3 else { throw invalid("direct three-coordinate dot") }
        var result = 0.0
        for j in 0..<3 { result = try add(result, multiply(weights[j], row[j])) }
        return try positive(result)
    }
    static func checkSimplex(_ weights: [Double]) throws -> (Double, Double, [Int]) {
        guard weights.count == 3,
              weights.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw invalid("finite strict nonnegative three-simplex") }
        let total = try sum(weights), error = try subtract(total, 1)
        let support = weights.indices.filter { weights[$0] > 0 }
        guard abs(error) <= 1e-12, !support.isEmpty else { throw invalid("simplex feasibility; no normalization rescue") }
        return (total, error, support)
    }
    struct Certificate {
        let simplexSum: Double
        let sumError: Double
        let support: [Int]
        let gradients: [Double]
        let receiver: Int
        let donor: Int
        let gmax: Double
        let supportGmin: Double
        let H: Double
        let weightedGradientSum: Double
        let globalGap: Double
        let passed: Bool
    }
    static func certificate(_ weights: [Double], rows: [[Double]]) throws -> Certificate {
        guard !rows.isEmpty, rows.allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0.isFinite && $0 > 0 }) }) else {
            throw invalid("nonempty positive conditional rows")
        }
        let (total, error, support) = try checkSimplex(weights)
        var g: [Double] = []
        for j in 0..<3 {
            var numerator = 0.0
            for row in rows { numerator = try add(numerator, divide(row[j], dot(weights, row))) }
            g.append(try divide(numerator, Double(rows.count)))
        }
        var receiver = 0, donor = support[0]
        for j in 1..<3 where g[j] > g[receiver] { receiver = j }
        for j in support.dropFirst() where g[j] < g[donor] { donor = j }
        let h = try subtract(g[receiver], g[donor])
        var q = 0.0
        for j in 0..<3 { q = try add(q, multiply(weights[j], g[j])) }
        let gap = try subtract(g[receiver], q)
        return .init(simplexSum: total, sumError: error, support: support, gradients: g,
            receiver: receiver, donor: donor, gmax: g[receiver], supportGmin: g[donor],
            H: h, weightedGradientSum: q, globalGap: gap,
            passed: h <= 1e-10 && gap >= -1e-12 && gap <= 1e-10)
    }
    static func trial(_ before: [Double], receiver: Int, donor: Int, delta: Double) throws -> [Double] {
        guard receiver != donor, delta.isFinite, delta >= 0, delta <= before[donor] else { throw invalid("legal directed pair") }
        var after = before
        after[receiver] = try add(before[receiver], delta)
        after[donor] = try subtract(before[donor], delta)
        _ = try checkSimplex(after)
        return after
    }
    static func derivative(_ before: [Double], rows: [[Double]], receiver: Int, donor: Int, delta: Double) throws -> Double {
        let weights = try trial(before, receiver: receiver, donor: donor, delta: delta)
        var numerator = 0.0
        for row in rows {
            let difference = try subtract(row[receiver], row[donor])
            numerator = try add(numerator, divide(difference, dot(weights, row)))
        }
        return try divide(numerator, Double(rows.count))
    }
    struct PairUpdate {
        let ordinal: Int
        let receiver: Int
        let donor: Int
        let beforeWeights: [Double]
        let beforeGradients: [Double]
        let delta: Double
        let derivative0: Double
        let derivativeUpper: Double
        let lo: Double?
        let hi: Double?
        let mid: Double?
        let bisectionIterations: Int
        let stopReason: String
        let afterWeights: [Double]
    }
    static func pairUpdate(_ before: [Double], rows: [[Double]], certificate c: Certificate, ordinal: Int) throws -> PairUpdate {
        let r = c.receiver, d = c.donor
        guard !c.passed, r != d else { throw invalid("uncertified pair direction") }
        let upper = before[d]
        let d0 = try derivative(before, rows: rows, receiver: r, donor: d, delta: 0)
        let du = try derivative(before, rows: rows, receiver: r, donor: d, delta: upper)
        guard d0 > 0 else { throw invalid("uncertified nonpositive derivative at0") }
        var delta = 0.0, finalLo: Double? = nil, finalHi: Double? = nil, finalMid: Double? = nil
        var count = 0, reason: String
        if du >= 0 {
            delta = upper; reason = "upper-endpoint"
        } else {
            var lo = 0.0, hi = upper, returned = false
            delta = 0; reason = "iteration64"
            for iteration in 1...bisectionCap {
                count = iteration
                let difference = try subtract(hi, lo), half = try divide(difference, 2), mid = try add(lo, half)
                if mid == lo || mid == hi {
                    delta = mid; finalLo = lo; finalHi = hi; finalMid = mid
                    reason = "representable-mid"; returned = true; break
                }
                let dm = try derivative(before, rows: rows, receiver: r, donor: d, delta: mid)
                if dm > 0 { lo = mid } else { hi = mid }
            }
            if !returned {
                let difference = try subtract(hi, lo), half = try divide(difference, 2), mid = try add(lo, half)
                delta = mid; finalLo = lo; finalHi = hi; finalMid = mid
            }
        }
        let after = try trial(before, receiver: r, donor: d, delta: delta)
        guard delta != 0,
              after[r].bitPattern != before[r].bitPattern || after[d].bitPattern != before[d].bitPattern else {
            throw invalid("uncertified zero or representably unchanged pair update")
        }
        return .init(ordinal: ordinal, receiver: r, donor: d, beforeWeights: before,
            beforeGradients: c.gradients, delta: delta, derivative0: d0, derivativeUpper: du,
            lo: finalLo, hi: finalHi, mid: finalMid, bisectionIterations: count,
            stopReason: reason, afterWeights: after)
    }
    struct Solution {
        let rawWeights: [Double]
        let normalizedWeights: [Double]
        let sumBefore: Double
        let sumAfter: Double
        let initial: Certificate?
        let preNormalization: Certificate?
        let postNormalization: Certificate?
        let trace: [PairUpdate]?
    }
    static func sourceSolution(rows: [[Double]]) throws -> Solution {
        let u = try divide(1, 3)
        var weights = [u, u, u]
        _ = try checkSimplex(weights)
        var initial: Certificate?, current: Certificate?, trace: [PairUpdate]?
        if !rows.isEmpty {
            let c = try certificate(weights, rows: rows)
            initial = c; current = c; trace = []
            if !c.passed {
                for ordinal in 1...updateCap {
                    let pair = try pairUpdate(weights, rows: rows, certificate: current!, ordinal: ordinal)
                    trace!.append(pair); weights = pair.afterWeights
                    current = try certificate(weights, rows: rows)
                    if current!.passed { break }
                }
            }
            guard current!.passed else { throw invalid("1024 completed updates exhausted; no certificate") }
        }
        let total = try sum(weights)
        var normalized: [Double] = []
        for j in 0..<3 { normalized.append(try divide(weights[j], total)) }
        let after = try checkSimplex(normalized).0
        var final: Certificate?
        if !rows.isEmpty {
            final = try certificate(normalized, rows: rows)
            guard final!.passed else { throw invalid("once-normalized full certificate failed; no rescue") }
        }
        return .init(rawWeights: weights, normalizedWeights: normalized, sumBefore: total,
            sumAfter: after, initial: initial, preNormalization: current, postNormalization: final, trace: trace)
    }

    /// Typed JSON avoids NSNumber/Bool ambiguity and preserves negativezero across independent readers.
    indirect enum JSONValue {
        case null, bool(Bool), integer(Int), unsigned(UInt64), number(Double), string(String)
        case array([JSONValue]), object([String: JSONValue])
        func data() throws -> Data {
            switch self {
            case .null: return Data("null".utf8)
            case .bool(let v): return Data((v ? "true" : "false").utf8)
            case .integer(let v): return Data(String(v).utf8)
            case .unsigned(let v): return Data(String(v).utf8)
            case .number(let v):
                guard v.isFinite else { throw CORNCoreScreen.invalid("JSON nonfinite number") }
                let text = v == 0 && v.sign == .minus ? "-0.0" : String(v)
                guard let decoded = Double(text), decoded.bitPattern == v.bitPattern else { throw CORNCoreScreen.invalid("JSON Binary64 roundtrip") }
                return Data(text.utf8)
            case .string(let v): return try JSONEncoder().encode(v)
            case .array(let values):
                var d = Data("[".utf8)
                for (i, v) in values.enumerated() { if i != 0 { d.append(44) }; d.append(try v.data()) }
                d.append(93); return d
            case .object(let values):
                var d = Data("{".utf8)
                for (i, key) in values.keys.sorted().enumerated() {
                    if i != 0 { d.append(44) }
                    d.append(try JSONEncoder().encode(key)); d.append(58); d.append(try values[key]!.data())
                }
                d.append(125); return d
            }
        }
    }
    static func doubles(_ values: [Double]) -> JSONValue { .array(values.map(JSONValue.number)) }
    static func bitStrings(_ values: [Double]) -> JSONValue { .array(vectorBits(values).map(JSONValue.string)) }
    static func optional(_ value: Double?) -> JSONValue { value.map(JSONValue.number) ?? .null }
    static func optionalBits(_ value: Double?) -> JSONValue { value.map { .string(bits($0)) } ?? .null }
    static func certificateJSON(_ c: Certificate?) -> JSONValue {
        guard let c else { return .null }
        return .object([
            "applicable": .bool(true), "simplexSum": .number(c.simplexSum), "sumError": .number(c.sumError),
            "support": .array(c.support.map(JSONValue.integer)), "gradients3": doubles(c.gradients),
            "gmax": .number(c.gmax), "supportGmin": .number(c.supportGmin), "H": .number(c.H),
            "weightedGradientSum": .number(c.weightedGradientSum), "globalGap": .number(c.globalGap), "passed": .bool(c.passed),
            "gradients3Bits": bitStrings(c.gradients), "simplexSumBits": .string(bits(c.simplexSum)),
            "sumErrorBits": .string(bits(c.sumError)), "gmaxBits": .string(bits(c.gmax)),
            "supportGminBits": .string(bits(c.supportGmin)), "HBits": .string(bits(c.H)),
            "weightedGradientSumBits": .string(bits(c.weightedGradientSum)), "globalGapBits": .string(bits(c.globalGap))
        ])
    }
    static func pairJSON(_ p: PairUpdate) -> JSONValue {
        .object([
            "ordinal": .integer(p.ordinal), "receiver": .integer(p.receiver), "donor": .integer(p.donor),
            "beforeWeights3": doubles(p.beforeWeights), "beforeGradients3": doubles(p.beforeGradients),
            "delta": .number(p.delta), "derivative0": .number(p.derivative0), "derivativeUpper": .number(p.derivativeUpper),
            "lo": optional(p.lo), "hi": optional(p.hi), "mid": optional(p.mid),
            "bisectionIterations": .integer(p.bisectionIterations), "stopReason": .string(p.stopReason),
            "afterWeights3": doubles(p.afterWeights), "beforeWeights3Bits": bitStrings(p.beforeWeights),
            "beforeGradients3Bits": bitStrings(p.beforeGradients), "deltaBits": .string(bits(p.delta)),
            "derivative0Bits": .string(bits(p.derivative0)), "derivativeUpperBits": .string(bits(p.derivativeUpper)),
            "loBits": optionalBits(p.lo), "hiBits": optionalBits(p.hi), "midBits": optionalBits(p.mid),
            "afterWeights3Bits": bitStrings(p.afterWeights)
        ])
    }
    static func correlationBytes(_ c: Correlation) throws -> Data {
        let rawBits: UInt64
        if c.zeroVariance {
            guard c.value == nil, !c.matched else { throw invalid("zeroVariance correlation encoding") }
            rawBits = 0
        } else {
            guard let value = c.value, value.isFinite, c.matched == (value >= rho) else { throw invalid("finite correlation encoding") }
            rawBits = value.bitPattern
        }
        var d = Data()
        for shift in 0..<8 { d.append(UInt8(truncatingIfNeeded: rawBits >> (shift * 8))) }
        d.append(c.zeroVariance ? 1 : 0); d.append(c.matched ? 1 : 0)
        return d
    }
    static func shaFile(_ path: String) throws -> String {
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? h.close() }
        var digest = SHA256()
        while let data = try h.read(upToCount: 1 << 20), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func jsonObject(_ path: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else {
            throw invalid("metadata JSON object " + path)
        }
        return object
    }
    static func metadataInteger(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              ["q", "i", "s", "l", "Q", "I", "S", "L"].contains(String(cString: n.objCType)) else { return nil }
        return Int(n.stringValue)
    }
    static func metadataBoolean(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    static func metadataTimestamp(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: value) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)
    }
    static func exclusive(_ path: String, data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        try handle.close()
        try syncDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }
    static func syncDirectory(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }

    struct Gate: Decodable {
        struct Binary: Decodable { let path: String; let sha256: String; let bytes: Int }
        let status: String
        let stage: String
        let candidateID: String
        let sourceOnly: Bool
        let financialExecution: Bool
        let allowedAttemptBudget: Int
        let command: [String]
        let wrapper_command: [String]
        let cwd: String
        let envOverrides: [String: String]
        let files_sha256: [String: String]
        let admittedAt: String
        let appCommit: String
        let appCheckout: String
        let codeFiles: [String: String]
        let retainedBinary: Binary
        let source_export_first_execution_authorized: Bool?
    }
    static let inputBindings = [
        primitivePath: primitiveSHA,
        accountsPath: accountsSHA,
        "/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/fixed-rp63-core-2026-10-10/inputs/history.json": "86c62407994fdc49ec41ba891a44373201335a4ff0670310a6098c2b1de2dedb",
        "/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/fixed-rp63-core-2026-10-10/inputs/saved-dmi-native-full.json": "2555a5234bc949de465e00781b39a05871edf9ef28a1bc03002ce4551f15d2ce"
    ]
    static let contractBindings = [
        studyPath + "/PRE_SPECIFICATION.json": "9201fac3ddab173bab73dd18367e308ed21a82ba985e7881057aa63acea7a142",
        studyPath + "/DECLARATION.json": "21f54415a142541de622912d2a8851c758c762c86bb814c12aa27e2ab456af30",
        studyPath + "/INPUT_FREEZE.json": "1702c497f5aa21276d5457621b8904e7eaa9b8e49ea6572bcfc19a299b0c1faf",
        studyPath + "/IMPLEMENTATION_INTERFACE.json": "e18bdac00aa237c9928792f7952815e076b44448cad87930300ea0813406e28c",
        engineeringPath: engineeringSHA
    ]
    static func validateMap(_ files: [String: String]) throws {
        guard !files.isEmpty else { throw invalid("empty actual binding map") }
        for (path, sha) in files {
            let u = URL(fileURLWithPath: path)
            guard path.hasPrefix("/"), u.standardizedFileURL.path == path,
                  u.resolvingSymlinksInPath().path == path, try shaFile(path) == sha else { throw invalid("physical binding " + path) }
        }
    }
    static func requireBinding(_ path: String, sha: String? = nil, files: [String: String]) throws {
        guard let bound = files[path], sha == nil || bound == sha else { throw invalid("missing direct admission binding " + path) }
        guard try shaFile(path) == bound else { throw invalid("changed admission binding " + path) }
    }
    static func readGate(_ path: String, sourceCommit: String, exporting: Bool) throws -> Gate {
        let expected = studyPath + (exporting ? "/ROOT_SOURCE_EXPORT_ADMISSION.json" : "/RUN_ADMISSION.json")
        guard path == expected else { throw invalid("exact stage admission path") }
        let gate = try JSONDecoder().decode(Gate.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard gate.status == (exporting ? "PASS_CORN5_RHO01_CORE_SOURCE_EXPORT_ADMISSION" : "PASS_CORN5_RHO01_CORE_FINANCIAL_ADMISSION"),
              gate.candidateID == candidateID, gate.sourceOnly == exporting, gate.financialExecution == !exporting,
              gate.allowedAttemptBudget == 1, gate.command == CommandLine.arguments,
              gate.wrapper_command == ["rtk", "proxy"] + gate.command,
              gate.cwd == FileManager.default.currentDirectoryPath, gate.cwd == studyPath,
              gate.appCommit == sourceCommit, gate.appCheckout == "/Users/xiangjunsheng/AssetTimeMachine",
              !gate.admittedAt.isEmpty, gate.retainedBinary.path == gate.command.first,
              try shaFile(gate.retainedBinary.path) == gate.retainedBinary.sha256,
              (try FileManager.default.attributesOfItem(atPath: gate.retainedBinary.path)[.size] as? NSNumber)?.intValue == gate.retainedBinary.bytes else {
            throw invalid("actual runtime/command/cwd/stage/binary admission")
        }
        if exporting {
            guard gate.stage == "source-export", gate.source_export_first_execution_authorized == true else { throw invalid("source-export first authority") }
        }
        for (name, value) in gate.envOverrides {
            guard ProcessInfo.processInfo.environment[name] == value else { throw invalid("task environment override " + name) }
        }
        try validateMap(gate.files_sha256); try validateMap(gate.codeFiles)
        for (p, h) in gate.codeFiles { try requireBinding(p, sha: h, files: gate.files_sha256) }
        for (p, h) in inputBindings { try requireBinding(p, sha: h, files: gate.files_sha256) }
        for (p, h) in contractBindings { try requireBinding(p, sha: h, files: gate.files_sha256) }
        try requireBinding(gate.retainedBinary.path, sha: gate.retainedBinary.sha256, files: gate.files_sha256)
        for name in ["TEST_RECEIPT.json", "BUILD_RECEIPT.json", "RELEASE_BINARY_RETENTION_RECEIPT.json", "SOURCE_MODEL_API_CONTRACT_ENV_V2.json"] {
            try requireBinding(studyPath + "/" + name, files: gate.files_sha256)
        }
        for name in ["TEST_RECEIPT.json", "BUILD_RECEIPT.json"] { try verifyReceipt(studyPath + "/" + name, files: gate.files_sha256) }
        return gate
    }
    static func gzipDigest(_ path: String) throws -> (String, Int) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rtk", "proxy", "gzip", "-dc", path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        var digest = SHA256(), count = 0
        while let data = try pipe.fileHandleForReading.read(upToCount: 1 << 20), !data.isEmpty {
            digest.update(data: data); count += data.count
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw invalid("exact gzip decompression") }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
    /// Actual standard receipt fields are validated, never replaced by a made-up execution wrapper.
    static func verifyReceipt(_ path: String, files: [String: String], expectedStatus: String? = nil) throws {
        try requireBinding(path, files: files)
        let r = try jsonObject(path)
        guard expectedStatus == nil || r["status"] as? String == expectedStatus,
              metadataInteger(r["actual_exit_code"]) == 0, let tool = r["tool_execution"] as? [String: Any],
              metadataInteger(tool["actual_exit_code"]) == 0, let returns = tool["actual_tool_returns"] as? [[String: Any]],
              !returns.isEmpty, metadataInteger(returns.last?["exit_code"]) == 0,
              let contextPath = r["execution_context_path"] as? String,
              let contextSHA = r["execution_context_sha256"] as? String,
              let streams = r["streams"] as? [String: [String: Any]], Set(streams.keys) == ["stdout", "stderr"] else {
            throw invalid("genuine completed actual receipt " + path)
        }
        try requireBinding(contextPath, sha: contextSHA, files: files)
        for name in ["stdout", "stderr"] {
            let s = streams[name]!
            guard let rawPath = s["path"] as? String, let rawSHA = s["sha256"] as? String,
                  let gzipPath = s["gzip_path"] as? String, let gzipSHA = s["gzip_sha256"] as? String else {
                throw invalid("actual raw/gzip stream fields")
            }
            try requireBinding(rawPath, sha: rawSHA, files: files)
            try requireBinding(gzipPath, sha: gzipSHA, files: files)
            guard try gzipDigest(gzipPath).0 == rawSHA else { throw invalid("raw/gzip exact stream") }
        }
        if let nativePath = tool["native_tool_returns_path"] as? String, let nativeSHA = tool["native_tool_returns_sha256"] as? String {
            try requireBinding(nativePath, sha: nativeSHA, files: files)
            let native = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: nativePath)))
            guard NSDictionary(dictionary: ["native": native]).isEqual(to: ["native": returns]) else { throw invalid("physical native returns chain") }
        } else if expectedStatus != nil { throw invalid("mandatory source native returns file") }
    }
    static func verifySavedQualification(files: [String: String]) throws {
        let reportPath = studyPath + "/SOURCE_MODEL_REVIEW.json"
        let receiptPath = studyPath + "/SOURCE_MODEL_REVIEW_RECEIPT.json"
        let exportReceipt = studyPath + "/SOURCE_EXPORT_RECEIPT.json"
        for p in [reportPath, receiptPath, exportReceipt, studyPath + "/" + signalsName,
                  studyPath + "/" + manifestName, studyPath + "/" + correlationsName, studyPath + "/" + correlationsName + ".gz"] {
            try requireBinding(p, files: files)
        }
        try verifyReceipt(exportReceipt, files: files, expectedStatus: "PASS_CORN5_RHO01_CORE_SOURCE_ONLY_EXPORT_ACTUAL_TOOL")
        try verifyReceipt(receiptPath, files: files, expectedStatus: "PASS_CORN5_RHO01_CORE_SOURCE_REFERENCE_ACTUAL_TOOL")
        let report = try jsonObject(reportPath), receipt = try jsonObject(receiptPath), exported = try jsonObject(exportReceipt)
        guard report["status"] as? String == "PASS_CORN5_RHO01_CORE_INDEPENDENT_SOURCE_NUMERICAL_REVIEW",
              metadataBoolean(report["numerical_qualification_passed"]) == true,
              metadataBoolean(report["source_only"]) == true, metadataBoolean(report["source_optimization_performed"]) == false,
              metadataBoolean(report["financial_execution_performed"]) == false, metadataBoolean(report["NAV_or_performance_computed"]) == false,
              metadataInteger(report["source_signal_count"]) == 6452,
              (report["blockers"] as? [Any])?.isEmpty == true, metadataInteger(report["mismatches"]) == 0,
              receipt["review_path"] as? String == reportPath, receipt["review_sha256"] as? String == files[reportPath],
              let reviewed = report["reviewed_files_sha256"] as? [String: String],
              receipt["source_files_before"] as? [String: String] == reviewed,
              receipt["source_files_after"] as? [String: String] == reviewed else { throw invalid("saved completed independent source qualification") }
        guard report["source_files_before"] as? [String: String] == reviewed,
              report["source_files_after"] as? [String: String] == reviewed,
              report["execution_context_path"] as? String == receipt["execution_context_path"] as? String,
              report["execution_context_sha256"] as? String == receipt["execution_context_sha256"] as? String,
              metadataBoolean(receipt["financial_execution_performed"]) == false else { throw invalid("source report actual context and immutable files") }
        try validateMap(reviewed)
        for (p, h) in reviewed { try requireBinding(p, sha: h, files: files) }
        let api = try jsonObject(studyPath + "/SOURCE_MODEL_API_CONTRACT_ENV_V2.json")
        guard let paths = api["paths"] as? [String: String] else { throw invalid("exact qualified source API paths") }
        for (pKey, hKey, key) in [
            ("correlations_path", "correlations_sha256", "correlations"),
            ("export_manifest_path", "export_manifest_sha256", "export_manifest"),
            ("export_receipt_path", "export_receipt_sha256", "export_receipt"),
            ("reference_admission_path", "reference_admission_sha256", "reference_gate"),
            ("compiled_verifier_path", "compiled_verifier_sha256", "compiled_binary")
        ] {
            guard let p = paths[key], report[pKey] as? String == p, report[hKey] as? String == files[p] else {
                throw invalid("qualified reference linked artifact " + key)
            }
            try requireBinding(p, sha: report[hKey] as? String, files: files)
        }
        guard let certificatePath = report["independent_certificate_path"] as? String,
              let certificateSHA = report["independent_certificate_sha256"] as? String else { throw invalid("independent full KKT certificate artifact") }
        try requireBinding(certificatePath, sha: certificateSHA, files: files)
        let sourceGatePath = studyPath + "/ROOT_SOURCE_EXPORT_ADMISSION.json"
        let exportGate = try jsonObject(sourceGatePath)
        guard exported["export_gate_path"] as? String == sourceGatePath,
              exported["export_gate_sha256"] as? String == files[sourceGatePath],
              exportGate["status"] as? String == "PASS_CORN5_RHO01_CORE_SOURCE_EXPORT_ADMISSION",
              metadataBoolean(exportGate["sourceOnly"]) == true, metadataBoolean(exportGate["financialExecution"]) == false,
              metadataBoolean(exportGate["source_export_first_execution_authorized"]) == true,
              metadataInteger(exportGate["allowedAttemptBudget"]) == 1,
              let sourceFiles = exportGate["files_sha256"] as? [String: String],
              exported["source_files_before"] as? [String: String] == sourceFiles,
              exported["source_files_after"] as? [String: String] == sourceFiles else { throw invalid("original genuine source export admission") }
        for (p,h) in sourceFiles { try requireBinding(p, sha: h, files: files) }
        let sourceContext = try jsonObject(exported["execution_context_path"] as! String)
        guard metadataInteger(sourceContext["actual_exit_code"]) == 0, metadataBoolean(sourceContext["sourceOnly"]) == true,
              metadataBoolean(sourceContext["financialExecution"]) == false,
              sourceContext["command"] as? [String] == exportGate["command"] as? [String],
              sourceContext["cwd"] as? String == exportGate["cwd"] as? String,
              sourceContext["envOverrides"] as? [String: String] == exportGate["envOverrides"] as? [String: String],
              sourceContext["files_before"] as? [String: String] == sourceFiles,
              sourceContext["files_after"] as? [String: String] == sourceFiles else { throw invalid("actual exporter runtime context") }
        let referenceGate = try jsonObject(paths["reference_gate"]!)
        let referenceContext = try jsonObject(receipt["execution_context_path"] as! String)
        guard referenceGate["status"] as? String == api["reference_admission_status"] as? String,
              metadataBoolean(referenceGate["sourceOnly"]) == true, metadataBoolean(referenceGate["financialExecution"]) == false,
              metadataBoolean(referenceGate["source_reference_first_execution_authorized"]) == true,
              metadataInteger(referenceGate["allowedAttemptBudget"]) == 1,
              referenceContext["mode"] as? String == "source-reference-verification",
              metadataInteger(referenceContext["actual_exit_code"]) == 0, metadataBoolean(referenceContext["financial_execution_performed"]) == false,
              referenceContext["files_before"] as? [String: String] == reviewed,
              referenceContext["files_after"] as? [String: String] == reviewed,
              referenceContext["command"] as? [String] == referenceGate["command"] as? [String],
              referenceContext["cwd"] as? String == referenceGate["cwd"] as? String,
              referenceContext["envOverrides"] as? [String: String] == referenceGate["envOverrides"] as? [String: String],
              let referenceFiles = referenceGate["files_sha256"] as? [String: String] else { throw invalid("genuine saved reference context/admission") }
        for (p,h) in referenceFiles { try requireBinding(p, sha: h, files: files) }
        for (pKey, hKey, p) in [
            ("source_signal_path", "source_signal_sha256", studyPath + "/" + signalsName),
            ("correlation_path", "correlation_sha256", studyPath + "/" + correlationsName),
            ("manifest_path", "manifest_sha256", studyPath + "/" + manifestName)
        ] {
            guard exported[pKey] as? String == p, exported[hKey] as? String == files[p] else { throw invalid("actual export artifact link") }
        }
        guard report["source_dump_path"] as? String == studyPath + "/" + signalsName,
              report["source_dump_sha256"] as? String == files[studyPath + "/" + signalsName],
              report["export_manifest_sha256"] as? String == files[studyPath + "/" + manifestName] else { throw invalid("source review artifact identity") }
        let stream = (receipt["streams"] as! [String: [String: Any]])["stdout"]!
        guard try Data(contentsOf: URL(fileURLWithPath: stream["path"] as! String)) == Data(contentsOf: URL(fileURLWithPath: reportPath)) else {
            throw invalid("actual source report full stdout")
        }
    }
    private struct Input: Decodable {
        let schema: String; let cutoff: String; let baseline: String
        let role_to_source_symbol: [String: String]; let source_history_sha256: String
        let series: [String: [Bar]]; let original_strictprior_FX_observations: [FX]
        let funded_union_calendar: [String]; let saved_long_comparison_dates: [String]; let saved_short_comparison_dates: [String]
        struct Bar: Decodable { let date: String; let valuation_price: Double }
        struct FX: Decodable { let date: String; let usd_per_cny: Double }
    }
    private static func prepare(_ input: Input) throws -> NativePreparation {
        guard input.schema == "fixed-rp63-core-source-primitives-v1", input.cutoff == "2026-10-06", input.baseline == "2001-06-25",
              input.role_to_source_symbol == ["gold_cny": "gold_cny", "nasdaq": "nasdaq_composite", "sp500": "sp500"],
              input.source_history_sha256 == inputBindings["/Users/xiangjunsheng/FlyingrtxFast/research/asset-time-machine/workspace/studies/fixed-rp63-core-2026-10-10/inputs/history.json"],
              coreSymbols.map({ input.series[$0]?.count ?? 0 }) == [6423,6732,6743],
              input.funded_union_calendar.count == 6452, input.funded_union_calendar.first == "2001-06-25",
              input.funded_union_calendar.last == "2026-10-06" else { throw invalid("frozen native primitive contract") }
        func date(_ day: String) throws -> Date {
            guard let d = BacktestSeriesAlignment.historicalSeriesDate(from: day) else { throw invalid("canonical source session") }; return d
        }
        var bars: [String: [PriceBar]] = [:]
        for symbol in coreSymbols { bars[symbol] = try input.series[symbol]!.map { .init(date: try date($0.date), price: $0.valuation_price) } }
        let fx = try input.original_strictprior_FX_observations.map { FXPoint(date: try date($0.date), usdPerCNY: $0.usd_per_cny) }
        return try RiskParityCoreScreen.nativePreparation(barsBySymbol: bars, fxPoints: fx, fundedDates: input.funded_union_calendar.map(date))
    }
    struct QualifiedSignal: Decodable {
        let signalIndex: Int; let sourceDate: String; let sourceTimestamp: String
        let rawWeights3: [Double]; let rawWeights3Bits: [String]
        let sourceNormalizedWeights3: [Double]; let sourceNormalizedWeights3Bits: [String]
        let rawTarget: [String: Double]; let cleanedTarget: [String: Double]
    }
    static func runAccount(preparation: NativePreparation, signals: [QualifiedSignal], role: Role) throws -> NativeRun {
        let dates = preparation.frame.dates
        guard signals.count == dates.count, signals.enumerated().allSatisfy({
            $0.offset == $0.element.signalIndex &&
            $0.element.sourceDate == BacktestSeriesAlignment.historicalSeriesDateString(from: dates[$0.offset]) &&
            $0.element.sourceTimestamp == ISO8601DateFormatter().string(from: dates[$0.offset])
        }) else { throw invalid("saved funded signal clock") }
        return try RobustMedianReversionCoreScreen.simulate(preparation: preparation,
            buyReason: role == .candidate ? "fixed CORN5RHO01 core close research" : "fixed CORN5RHO01 daily core close control") { context in
            switch role {
            case .candidate: return signals[context.signalIndex].cleanedTarget
            case .equal: return Dictionary(uniqueKeysWithValues: coreSymbols.map { ($0, 1.0 / 3) })
            case .cash: return [:]
            }
        }
    }
    static func checkedRow(_ id: String, states: [BacktestDailyState], trades: [AdvancedBacktestTrade],
                           windows: [(String, String, String)]) throws -> DailyScreenOutput.Row {
        try RobustMedianReversionCoreScreen.checkedRow(id, states: states, trades: trades, windows: windows)
    }
    static func providerClean(_ target: [String: Double]) -> [String: Double] { RiskParityCoreScreen.providerClean(target) }
    final class ArtifactWriter {
        let path: String
        let temporary: String
        let handle: FileHandle
        init(_ path: String) throws {
            self.path = path; temporary = path + ".partial"
            guard !FileManager.default.fileExists(atPath: path) else { throw invalid("original artifact already exists") }
            let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        func write(_ data: Data) throws { try handle.write(contentsOf: data) }
        func seal() throws {
            guard fsync(handle.fileDescriptor) == 0 else { throw POSIXError(.EIO) }
            try handle.close()
            guard link(temporary, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try syncDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            guard unlink(temporary) == 0 else { throw POSIXError(.EIO) }
            try syncDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        }
    }
    static func stringMap(_ map: [String: String]) -> JSONValue { .object(map.mapValues(JSONValue.string)) }
    static func jsonMetadata(_ any: Any) throws -> JSONValue {
        if any is NSNull { return .null }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] { return .array(try a.map(jsonMetadata)) }
        if let d = any as? [String: Any] { return .object(try d.mapValues(jsonMetadata)) }
        if let n = any as? NSNumber {
            if String(cString: n.objCType) == "c" { return .bool(n.boolValue) }
            if ["q","i","s","l","Q","I","S","L"].contains(String(cString: n.objCType)) { return .integer(n.intValue) }
            return .number(n.doubleValue)
        }
        throw invalid("unsupported metadata JSON type")
    }
    static func provenance(_ q: Quote) -> (JSONValue, [String]) {
        let day = BacktestSeriesAlignment.historicalSeriesDateString(from:)
        let iso = ISO8601DateFormatter().string(from:)
        let fields = [String(q.index), q.symbol, day(q.sourceDate), iso(q.sourceDate), q.quoteToday ? "1" : "0",
            String(q.quoteAgeDays), bits(q.originalCanonicalPrice), q.fxDate.map(day) ?? "null",
            q.fxDate.map(iso) ?? "null", q.usdPerCNY.map(bits) ?? "null", q.fxAgeDays.map(String.init) ?? "null", bits(q.cnyClose)]
        let object: JSONValue = .object([
            "symbol": .string(q.symbol), "sourceQuoteDate": .string(day(q.sourceDate)), "sourceQuoteTimestamp": .string(iso(q.sourceDate)),
            "quoteToday": .bool(q.quoteToday), "quoteAgeDays": .integer(q.quoteAgeDays),
            "originalCanonicalPrice": .number(q.originalCanonicalPrice), "originalCanonicalPriceBits": .string(bits(q.originalCanonicalPrice)),
            "fxDate": q.fxDate.map { .string(day($0)) } ?? .null, "fxTimestamp": q.fxDate.map { .string(iso($0)) } ?? .null,
            "usdPerCNY": optional(q.usdPerCNY), "usdPerCNYBits": optionalBits(q.usdPerCNY),
            "fxAgeDays": q.fxAgeDays.map(JSONValue.integer) ?? .null, "cnyClose": .number(q.cnyClose), "cnyCloseBits": .string(bits(q.cnyClose))
        ])
        return (object, fields)
    }
    public static func exportSource(primitivesPath: String, outputPath: String, sourceCommit: String, sourceAdmissionPath: String) throws {
        guard primitivesPath == primitivePath, outputPath == studyPath else { throw invalid("exact pure source paths") }
        let gate = try readGate(sourceAdmissionPath, sourceCommit: sourceCommit, exporting: true)
        for name in [signalsName, correlationsName, correlationsName + ".gz", manifestName] {
            guard !FileManager.default.fileExists(atPath: studyPath + "/" + name),
                  !FileManager.default.fileExists(atPath: studyPath + "/" + name + ".partial") else { throw invalid("source output/preexisting partial") }
        }
        let started = ISO8601DateFormatter().string(from: Date())
        let reservation = JSONValue.object(["candidateID": .string(candidateID), "source_export_attempt": .integer(1),
            "retries": .integer(0), "source_admission_path": .string(sourceAdmissionPath),
            "source_admission_sha256": .string(try shaFile(sourceAdmissionPath)),
            "command": .array(gate.command.map(JSONValue.string)), "started_at": .string(started)])
        try exclusive(studyPath + "/SOURCE_EXPORT_RESERVATION.json", data: reservation.data())
        // First primitive decode/date/frame/arithmetic is strictly after durable exclusive reservation.
        guard fegetround() == FE_TONEAREST else { throw invalid("Binary64 round-to-nearest-even") }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: primitivesPath)))
        let prep = try prepare(input), frame = prep.frame
        let quoteGroups = Dictionary(grouping: prep.quotes, by: \.symbol)
        var prices: [[Double]] = [], relatives: [[Double]] = []
        for s in frame.dates.indices {
            let p = try coreSymbols.map { try positive(frame.pricesBySymbol[$0]![s]) }; prices.append(p)
            if s > 0 {
                var row: [Double] = []
                for j in 0..<3 { row.append(try positive(divide(p[j], prices[s - 1][j]))) }
                relatives.append(row)
            }
        }
        func flattened(first: Int, last: Int) -> [Double] {
            var result: [Double] = []
            for j in 0..<3 { for s in first...last { result.append(relatives[s - 1][j]) } }
            return result
        }
        let signalWriter = try ArtifactWriter(studyPath + "/" + signalsName)
        let correlationWriter = try ArtifactWriter(studyPath + "/" + correlationsName)
        try signalWriter.write(Data("[".utf8))
        var binBuffer = Data(), offset: UInt64 = 0, sourceOffsets: [JSONValue] = []
        var calendarBytes = Data("corn5-rho01-native-calendar-v1\n".utf8)
        var provenanceBytes = Data("corn5-rho01-quote-provenance-v1\n".utf8)
        for T in frame.dates.indices {
            let day = BacktestSeriesAlignment.historicalSeriesDateString(from: frame.dates[T])
            calendarBytes.append(Data((day + "\n").utf8))
            var provenanceObjects: [JSONValue] = []
            for symbol in coreSymbols {
                let q = quoteGroups[symbol]![T]
                guard q.index == T, q.date == frame.dates[T], q.cnyClose.bitPattern == prices[T][coreSymbols.firstIndex(of: symbol)!].bitPattern else {
                    throw invalid("source quote/frame order")
                }
                let (object, fields) = provenance(q)
                guard fields.allSatisfy({ !$0.contains("\t") && !$0.contains("\n") }) else { throw invalid("canonical provenance field") }
                provenanceObjects.append(object); provenanceBytes.append(Data((fields.joined(separator: "\t") + "\n").utf8))
            }
            var matched: [Int] = [], matchedRows: [[Double]] = [], zeroCount = 0
            let firstOffset = offset
            if T >= 7 {
                let current = flattened(first: T - 4, last: T)
                for i in 6...T {
                    let c = try pearson(flattened(first: i - 5, last: i - 1), current)
                    binBuffer.append(try correlationBytes(c)); offset += 1
                    if c.zeroVariance { zeroCount += 1 }
                    if c.matched { matched.append(i); matchedRows.append(relatives[i - 1]) }
                    if binBuffer.count >= 1 << 20 { try correlationWriter.write(binBuffer); binBuffer.removeAll(keepingCapacity: true) }
                }
                sourceOffsets.append(.object(["signalIndex": .integer(T), "firstSuccessorIndex": .integer(6),
                    "lastSuccessorIndex": .integer(T), "recordOffset": .unsigned(firstOffset),
                    "byteOffset": .unsigned(firstOffset * 10), "recordCount": .integer(T - 5)]))
            }
            let solution = try sourceSolution(rows: matchedRows)
            let target = Dictionary(uniqueKeysWithValues: coreSymbols.enumerated().map { ($0.element, solution.normalizedWeights[$0.offset]) })
            let clean = providerClean(target)
            let phase = T == 0 ? "initial" : T <= 6 ? "warmup" : matched.isEmpty ? "empty" : "optimized"
            let row: JSONValue = .object([
                "signalIndex": .integer(T), "sourceDate": .string(day), "sourceTimestamp": .string(ISO8601DateFormatter().string(from: frame.dates[T])),
                "historyT": .integer(T), "phase": .string(phase), "candidateFirstIndex": T >= 7 ? .integer(6) : .null,
                "candidateLastIndex": T >= 7 ? .integer(T) : .null, "candidateCount": T >= 7 ? .integer(T - 5) : .null,
                "correlationRecordOffset": T >= 7 ? .unsigned(firstOffset) : .null,
                "correlationRecordCount": T >= 7 ? .integer(T - 5) : .null, "zeroVarianceCount": T >= 7 ? .integer(zeroCount) : .null,
                "matchedSuccessorIndices": T >= 7 ? .array(matched.map(JSONValue.integer)) : .null,
                "matchedCount": T >= 7 ? .integer(matched.count) : .null, "rawWeights3": doubles(solution.rawWeights),
                "sourceNormalizedWeights3": doubles(solution.normalizedWeights), "sourceWeightSumBefore": .number(solution.sumBefore),
                "sourceWeightSumAfter": .number(solution.sumAfter), "rawTarget": .object(target.mapValues(JSONValue.number)),
                "cleanedTarget": .object(clean.mapValues(JSONValue.number)), "initialCertificate": certificateJSON(solution.initial),
                "preNormalizationCertificate": certificateJSON(solution.preNormalization), "postNormalizationCertificate": certificateJSON(solution.postNormalization),
                "completedPairUpdates": solution.trace.map { .integer($0.count) } ?? .null,
                "pairTrace": solution.trace.map { .array($0.map(pairJSON)) } ?? .null,
                "earliestExecutionIndex": .integer(T + 1), "priceProvenance": .array(provenanceObjects),
                "prices3": doubles(prices[T]), "prices3Bits": bitStrings(prices[T]),
                "relative3": T > 0 ? doubles(relatives[T - 1]) : .null, "relative3Bits": T > 0 ? bitStrings(relatives[T - 1]) : .null,
                "rawWeights3Bits": bitStrings(solution.rawWeights), "sourceNormalizedWeights3Bits": bitStrings(solution.normalizedWeights),
                "sourceWeightSumBeforeBits": .string(bits(solution.sumBefore)), "sourceWeightSumAfterBits": .string(bits(solution.sumAfter))
            ])
            if T != 0 { try signalWriter.write(Data(",".utf8)) }
            try signalWriter.write(row.data())
        }
        try signalWriter.write(Data("]\n".utf8)); try signalWriter.seal()
        try correlationWriter.write(binBuffer); try correlationWriter.seal()
        let gzipWriter = try ArtifactWriter(studyPath + "/" + correlationsName + ".gz")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rtk", "proxy", "gzip", "-n", "-c", studyPath + "/" + correlationsName]
        process.standardOutput = gzipWriter.handle
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw invalid("source correlation gzip") }
        try gzipWriter.seal()
        let corrSHA = try shaFile(studyPath + "/" + correlationsName)
        let decompressed = try gzipDigest(studyPath + "/" + correlationsName + ".gz")
        let corrSize = (try FileManager.default.attributesOfItem(atPath: studyPath + "/" + correlationsName)[.size] as! NSNumber).intValue
        guard decompressed.0 == corrSHA, decompressed.1 == corrSize, UInt64(corrSize) == offset * 10 else { throw invalid("lossless full correlation stream") }
        let signalsSize = (try FileManager.default.attributesOfItem(atPath: studyPath + "/" + signalsName)[.size] as! NSNumber).intValue
        let gzipSize = (try FileManager.default.attributesOfItem(atPath: studyPath + "/" + correlationsName + ".gz")[.size] as! NSNumber).intValue
        let engineering = try jsonObject(engineeringPath)
        let manifest: JSONValue = .object([
            "schema": .string(manifestSchema), "candidateID": .string(candidateID),
            "sourceOnly": .bool(true), "financialExecution": .bool(false), "NAVOrPerformanceComputed": .bool(false),
            "schemaVersions": .object(["signals": .string(sourceSignalSchema), "correlations": .string(correlationSchema)]),
            "nativeFrame": .object(["count": .integer(frame.dates.count), "startSourceDate": .string(input.funded_union_calendar.first!),
                "endSourceDate": .string(input.funded_union_calendar.last!), "calendarSha256": .string(ResearchRunEvidence.sha256(calendarBytes)),
                "quoteProvenanceSha256": .string(ResearchRunEvidence.sha256(provenanceBytes))]),
            "assetOrder": .array(coreSymbols.map(JSONValue.string)), "window": .integer(window), "rho": .number(rho),
            "inputBindings": stringMap(inputBindings), "contractBindings": stringMap(contractBindings),
            "implementationBindings": .object(["appCommit": .string(gate.appCommit), "appCheckout": .string(gate.appCheckout),
                "codeFiles": stringMap(gate.codeFiles), "retainedBinary": .object(["path": .string(gate.retainedBinary.path),
                    "sha256": .string(gate.retainedBinary.sha256), "bytes": .integer(gate.retainedBinary.bytes)]),
                "sourceExportGate": .object(["path": .string(sourceAdmissionPath), "sha256": .string(try shaFile(sourceAdmissionPath))])]),
            "signals": .object(["path": .string(studyPath + "/" + signalsName), "sha256": .string(try shaFile(studyPath + "/" + signalsName)),
                "bytes": .integer(signalsSize), "recordCount": .integer(frame.dates.count), "schema": .string(sourceSignalSchema)]),
            "correlations": .object(["path": .string(studyPath + "/" + correlationsName), "sha256": .string(corrSHA), "bytes": .integer(corrSize),
                "recordBytes": .integer(10), "recordCount": .unsigned(offset), "schema": .string(correlationSchema),
                "gzipPath": .string(studyPath + "/" + correlationsName + ".gz"), "gzipSha256": .string(try shaFile(studyPath + "/" + correlationsName + ".gz")),
                "gzipBytes": .integer(gzipSize), "exactGzipRoundtrip": .bool(true)]),
            "correlationSources": .array(sourceOffsets), "numericContract": try jsonMetadata(engineering["numerical_contract"]!),
            "exportContext": .object(["startedAt": .string(started), "completedAt": .string(ISO8601DateFormatter().string(from: Date())),
                "command": .array(gate.command.map(JSONValue.string)), "cwd": .string(gate.cwd), "envOverrides": stringMap(gate.envOverrides)])
        ])
        try validateMap(gate.files_sha256)
        let manifestWriter = try ArtifactWriter(studyPath + "/" + manifestName); try manifestWriter.write(manifest.data()); try manifestWriter.seal()
        print("CORN_SOURCE_EXPORT_COMPLETE \(studyPath + "/" + manifestName)")
    }

    private struct Sources: Decodable {
        let schema: String; let files: [File]
        struct File: Decodable { let path: String; let sha256: String; let ids: [String] }
    }
    private struct Saved: Decodable { let id: String; let dailyStates: [BacktestDailyState] }
    private struct Account {
        let id: String; let states: [BacktestDailyState]; let trades: [AdvancedBacktestTrade]; let savedObject: [String: Any]?
    }
    private static func cashObject(_ s: CashYieldSummary) -> [String: Any] {
        let date = ISO8601DateFormatter().string(from:)
        return ["title": s.title, "source": s.source, "sourceDetail": s.sourceDetail,
            "startDate": s.startDate.map(date) as Any? ?? NSNull(), "endDate": s.endDate.map(date) as Any? ?? NSNull(),
            "latestRateDate": s.latestRateDate.map(date) as Any? ?? NSNull(),
            "latestAnnualRate": s.latestAnnualRate, "averageAnnualRate": s.averageAnnualRate,
            "averageCashRatio": s.averageCashRatio, "totalCashInterest": s.totalCashInterest,
            "ratePoints": s.ratePoints.map { ["date": date($0.date), "annualRate": $0.annualRate] as [String: Any] }]
    }

    /// Finance consumes a completed Root reservation and the immutable source proof.
    static func requireFinancialReservation(_ gate: Gate, admissionPath: String) throws {
        let r = try jsonObject(studyPath + "/RUN_RESERVATION.json")
        guard r["run_admission_path"] as? String == admissionPath,
              r["run_admission_sha256"] as? String == (try shaFile(admissionPath)),
              r["candidateID"] as? String == candidateID,
              r["command"] as? [String] == gate.command,
              metadataInteger(r["financial_attempt"]) == 1, metadataInteger(r["retry_budget"]) == 0,
              let started = r["started_at"] as? String, metadataTimestamp(started) != nil else {
            throw invalid("existing Root durable single financial reservation")
        }
    }
    static func validateSavedTargets(_ signals: [QualifiedSignal], preparation: NativePreparation) throws {
        guard signals.count == preparation.frame.dates.count else { throw invalid("saved source full6452") }
        for (i,s) in signals.enumerated() {
            guard s.signalIndex == i, s.sourceDate == BacktestSeriesAlignment.historicalSeriesDateString(from: preparation.frame.dates[i]),
                  s.sourceTimestamp == ISO8601DateFormatter().string(from: preparation.frame.dates[i]),
                  s.rawWeights3.count == 3, s.sourceNormalizedWeights3.count == 3,
                  s.rawWeights3Bits == vectorBits(s.rawWeights3),
                  s.sourceNormalizedWeights3Bits == vectorBits(s.sourceNormalizedWeights3),
                  s.rawWeights3.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  s.sourceNormalizedWeights3.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  Set(s.rawTarget.keys) == Set(coreSymbols) else { throw invalid("saved source target/clock/bit protocol") }
            for (j,symbol) in coreSymbols.enumerated() {
                guard s.rawTarget[symbol]!.bitPattern == s.sourceNormalizedWeights3[j].bitPattern else { throw invalid("full unchanged three source targets") }
            }
            let expected = providerClean(s.rawTarget)
            guard Set(s.cleanedTarget.keys) == Set(expected.keys),
                  expected.allSatisfy({ s.cleanedTarget[$0.key]?.bitPattern == $0.value.bitPattern }) else {
                throw invalid("unchanged saved first provider clean")
            }
        }
    }
    public static func run(primitivesPath: String, accountsPath: String, outputPath: String, sourceCommit: String,
                           qualifiedSourcePath: String, sourceManifestPath: String) throws {
        guard primitivesPath == primitivePath, accountsPath == Self.accountsPath, outputPath == studyPath + "/run",
              qualifiedSourcePath == studyPath + "/" + signalsName, sourceManifestPath == studyPath + "/" + manifestName else {
            throw invalid("exact financial input/output/source paths")
        }
        let admissionPath = studyPath + "/RUN_ADMISSION.json"
        let gate = try readGate(admissionPath, sourceCommit: sourceCommit, exporting: false)
        try requireFinancialReservation(gate, admissionPath: admissionPath)
        try verifySavedQualification(files: gate.files_sha256)
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: primitivesPath))
        let savedRaw = try Data(contentsOf: URL(fileURLWithPath: accountsPath))
        let qualifiedRaw = try Data(contentsOf: URL(fileURLWithPath: qualifiedSourcePath))
        let input = try JSONDecoder().decode(Input.self, from: raw)
        let sources = try JSONDecoder().decode(Sources.self, from: savedRaw)
        guard ResearchRunEvidence.sha256(raw) == primitiveSHA, ResearchRunEvidence.sha256(savedRaw) == accountsSHA,
              sources.schema == "fixed-rp63-core-saved-v1", !sources.files.isEmpty,
              sources.files.flatMap(\.ids) == savedControlIDs, savedControlIDs.count == 31,
              sources.files.allSatisfy({ inputBindings[$0.path] == $0.sha256 && $0.sha256 == "2555a5234bc949de465e00781b39a05871edf9ef28a1bc03002ce4551f15d2ce" }) else {
            throw invalid("original31 whole saved source binding")
        }
        let preparation = try prepare(input)
        let signalEvidence = try JSONDecoder().decode([QualifiedSignal].self, from: qualifiedRaw)
        try validateSavedTargets(signalEvidence, preparation: preparation)
        var accounts: [Account] = [], decisions: [String: [Decision]] = [:], completions: [String: [Completion]] = [:]
        var cashEvidence: [String: Any] = [:], targetAudits: [String: [String: Int]] = [:]
        var accounting: [String: [[String: Any]]] = [:], fills: [String: [[String: Any]]] = [:]
        let iso = ISO8601DateFormatter().string(from:)
        for (id, role) in [(candidateID, Role.candidate), (equalID, Role.equal), (cashID, Role.cash)] {
            let run = try runAccount(preparation: preparation, signals: signalEvidence, role: role)
            let simulation = run.simulation
            decisions[id] = run.decisions; completions[id] = run.completions
            cashEvidence[id] = cashObject(simulation.cashYieldSummary)
            targetAudits[id] = ["desired_accepted_mismatches": run.targetMismatchCount, "state_count": simulation.dailyStates.count]
            accounts.append(.init(id: id, states: simulation.dailyStates, trades: simulation.trades, savedObject: nil))
            accounting[id] = simulation.dailyStates.enumerated().map { index, state in
                let previous = index > 0 ? simulation.dailyStates[index - 1] : nil
                let period = previous.map { CashYieldCNY.periodReturn(from: $0.date, to: state.date) } ?? 0
                let interest = previous.map { max($0.cash, 0) * period } ?? 0
                let units = Dictionary(uniqueKeysWithValues: coreSymbols.map { symbol in
                    (symbol, (state.holdingsBySymbol[symbol] ?? 0) / preparation.frame.pricesBySymbol[symbol]![index])
                })
                let held = coreSymbols.reduce(0.0) { $0 + (state.holdingsBySymbol[$1] ?? 0) }
                return ["index": index, "date": iso(state.date), "targetWeights": state.targetWeights, "cash": state.cash,
                    "holdingsBySymbol": state.holdingsBySymbol, "unitsBySymbol": units, "portfolioValue": state.portfolioValue,
                    "grossExposure": held / state.portfolioValue, "cashInterest": interest,
                    "cashPeriodReturn": period, "cashAnnualRate": previous.map { CashYieldCNY.annualRate(on: $0.date) } as Any? ?? NSNull()]
            }
            fills[id] = simulation.trades.enumerated().map { order, trade in
                let buy = trade.action == .buy
                let fee = buy ? trade.cashAmount * 0.00025 : trade.units * trade.price * 0.00025
                return ["order": order, "date": iso(trade.date), "symbol": trade.assetSymbol, "action": buy ? "buy" : "sell",
                    "price": trade.price, "units": trade.units, "cashAmount": trade.cashAmount,
                    "cashDelta": buy ? -trade.cashAmount : trade.cashAmount, "fee": fee]
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var selectedIDs: [String] = []
        for file in sources.files {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
            guard ResearchRunEvidence.sha256(data) == file.sha256,
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BacktestConfigurationError.invalidParameter("CORN5RHO01 saved raw hash/rows") }
            let rows = try decoder.decode([Saved].self, from: data)
            for id in file.ids {
                let matches = rows.filter { $0.id == id }, rawMatches = objects.filter { $0["id"] as? String == id }
                guard matches.count == 1, rawMatches.count == 1, !matches[0].dailyStates.isEmpty,
                      zip(matches[0].dailyStates, matches[0].dailyStates.dropFirst()).allSatisfy({ $0.date < $1.date }), !selectedIDs.contains(id) else {
                    throw BacktestConfigurationError.invalidParameter("CORN5RHO01 saved identity/state order")
                }
                selectedIDs.append(id); accounts.append(.init(id: id, states: matches[0].dailyStates, trades: [], savedObject: rawMatches[0]))
            }
        }
        guard selectedIDs == savedControlIDs, accounts.count == 34 else { throw BacktestConfigurationError.invalidParameter("CORN5RHO01 one candidate / 3 fresh / 31 saved") }
        let text = BacktestSeriesAlignment.historicalSeriesDateString(from:)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func object(_ row: DailyScreenOutput.Row, account: Account) throws -> [String: Any] {
            var result = try JSONSerialization.jsonObject(with: encoder.encode(row)) as! [String: Any]
            if let saved = account.savedObject { result["trades"] = saved["trades"] ?? [] }
            return result
        }
        func comparison(_ selected: [Account]) throws -> ([[String: Any]], [Date]) {
            let common = selected.reduce(Set(selected[0].states.map(\.date))) { $0.intersection(Set($1.states.map(\.date))) }.sorted()
            guard common.count > 252 else { throw BacktestConfigurationError.missingData("CORN5RHO01 complete mechanical comparison calendar") }
            let commonSet = Set(common), last = common.last!
            let ten = BacktestSeriesAlignment.historicalSeriesCalendar.date(byAdding: .year, value: -10, to: last)!
            let windows = [("full", text(common.first!), text(last)), ("trailing10Y", text(ten), text(last)),
                ("since2020", "2020-01-01", text(last)), ("since2022", "2022-01-01", text(last)),
                ("crisis2008", "2008-01-01", "2008-12-31"), ("crisis2020", "2020-01-01", "2020-12-31"), ("crisis2022", "2022-01-01", "2022-12-31")]
            return (try selected.map { a in
                let states = a.states.filter { commonSet.contains($0.date) }
                let row = a.savedObject == nil ? try checkedRow(a.id, states: states, trades: a.trades, windows: windows)
                    : try DailyScreenOutput.row(a.id, states: states, trades: a.trades, windows: windows)
                return try object(row, account: a)
            }, common)
        }
        let (longRows, longDates) = try comparison(accounts.filter { $0.id != qualID })
        let (allRows, allDates) = try comparison(accounts)
        guard longDates.map(text) == input.saved_long_comparison_dates, longDates.count == 5595,
              text(longDates.first!) == "2002-09-18", text(longDates.last!) == "2026-09-30",
              allDates.map(text) == input.saved_short_comparison_dates, allDates.count == 3086,
              text(allDates.first!) == "2013-07-18", text(allDates.last!) == "2026-09-30" else {
            throw BacktestConfigurationError.invalidParameter("CORN5RHO01 no comparison-day deletion")
        }
        let nativeRows = try accounts.map { a -> [String: Any] in
            if let saved = a.savedObject { return saved }
            return try object(checkedRow(a.id, states: a.states, trades: a.trades,
                windows: [("native_full", text(a.states.first!.date), text(a.states.last!.date))]), account: a)
        }
        var quoteObjects = try JSONSerialization.jsonObject(with: encoder.encode(preparation.quotes)) as! [[String: Any]]
        for i in quoteObjects.indices { for key in ["fxDate", "usdPerCNY", "cnyPerUSD", "fxAgeDays"] where quoteObjects[i][key] == nil { quoteObjects[i][key] = NSNull() } }
        var decisionObjects = try JSONSerialization.jsonObject(with: encoder.encode(decisions)) as! [String: [[String: Any]]]
        for id in decisionObjects.keys { for i in decisionObjects[id]!.indices {
            for key in ["requestedTarget", "pendingBefore", "pendingAfter"] where decisionObjects[id]![i][key] == nil { decisionObjects[id]![i][key] = NSNull() }
        } }
        let frameObject: [String: Any] = ["dates": preparation.frame.dates.map(text), "prices": preparation.frame.pricesBySymbol,
            "execution_prices": preparation.executionPrices, "observed": preparation.frame.observedBySymbol,
            "core_symbol_order": coreSymbols, "simulation_first": 0, "simulation_last": preparation.frame.dates.count - 1]
        var outputs: [String: Data] = [:]
        for (name, object) in [("result.json", longRows as Any), ("native-full.json", nativeRows as Any), ("all20.json", allRows as Any),
            ("decisions.json", decisionObjects as Any), ("quotes.json", quoteObjects as Any),
            ("native-frame.json", frameObject as Any), ("cash-yield.json", cashEvidence as Any), ("accounting.json", accounting as Any), ("fill-audit.json", fills as Any)] {
            outputs[name] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        outputs["completion-events.json"] = try encoder.encode(completions)
        outputs["signals.json"] = qualifiedRaw
        let hashes = outputs.mapValues(ResearchRunEvidence.sha256)

        let evidence: [String: Any] = [
            "completed_at": iso(Date()), "source_commit": sourceCommit,
            "evidence_class": "RELATED_D0_WHOLE_CORN5_RHO01_CONDITIONAL_LOG_OPTIMAL_BINARY64_KKT_AND_NEXT_CLOSE_ADAPTATION",
            "formal_validation": false, "recommendation_eligible": false,
            "execution_version": BacktestExecutionVersion.defaultEngineVersion,
            "pre_specification_sha256": contractBindings[studyPath + "/PRE_SPECIFICATION.json"]!,
            "source_engineering_proposal_sha256": engineeringSHA,
            "original_definition": "LiHoiGopalkrishnan2011_CORN_SINGLE_W5_RHO01_THREE_CORE",
            "signal_schema": sourceSignalSchema, "window": window, "rho": rho,
            "maximum_actual_updates": updateCap, "bisection_cap": bisectionCap,
            "H_tolerance": 1e-10, "global_gap_lower": -1e-12, "global_gap_upper": 1e-10, "simplex_tolerance": 1e-12,
            "saved_source_only": true, "source_matching_or_optimizer_reexecuted": false,
            "source_signal_path": qualifiedSourcePath, "source_signal_sha256": gate.files_sha256[qualifiedSourcePath]!,
            "source_manifest_path": sourceManifestPath, "source_manifest_sha256": gate.files_sha256[sourceManifestPath]!,
            "source_model_review_sha256": gate.files_sha256[studyPath + "/SOURCE_MODEL_REVIEW.json"]!,
            "source_model_review_receipt_sha256": gate.files_sha256[studyPath + "/SOURCE_MODEL_REVIEW_RECEIPT.json"]!,
            "source_export_receipt_sha256": gate.files_sha256[studyPath + "/SOURCE_EXPORT_RECEIPT.json"]!,
            "correlation_path": studyPath + "/" + correlationsName, "correlation_sha256": gate.files_sha256[studyPath + "/" + correlationsName]!,
            "run_admission_path": admissionPath, "run_admission_sha256": try shaFile(admissionPath),
            "run_reservation_sha256": try shaFile(studyPath + "/RUN_RESERVATION.json"),
            "model_policy": "Single frozen source export: inclusive ordered Pearson membership and mean-log pairwise KKT certification; finance loads unchanged saved signals and applies only the original target provider/account engine",
            "failure_diagnostic_policy": "Unchanged RMR DailyScreenOutput nine clauses/order/Dictionary.values.reduce/thresholds and first failure diagnostic; successful metric path unchanged",
            "primitives_sha256": ResearchRunEvidence.sha256(raw), "accounts_sha256": ResearchRunEvidence.sha256(savedRaw),
            "binary_sha256": gate.retainedBinary.sha256, "output_sha256": hashes,
            "candidate_count": 1, "new_funded_account_count": 3, "saved_control_count": 31, "account_count": 34,
            "parameter_search_budget": 0, "retry_budget": 0, "native_state_count": 6452,
            "native_start": "2001-06-25", "native_end": "2026-10-06",
            "long_common_dates": longDates.map(text), "all20_common_dates": allDates.map(text),
            "long_comparison_count": longRows.count, "all20_comparison_count": allRows.count, "long_excluded_id": qualID,
            "saved_control_ids": selectedIDs, "saved_source_files": sources.files.map { ["path": $0.path, "sha256": $0.sha256, "ids": $0.ids] as [String: Any] },
            "target_audits": targetAudits, "fee_rate": 0.00025, "slippage_rate": 0, "cash": "CashYieldCNY",
            "primary_metric": "App complete funded-native daily NAV Sharpe Rf=0",
            "primary": ["threshold": 1.2, "require_native_full": true, "require_long_common19_sharpe_at_least_1_2": true,
                        "require_beat_strongest19": true, "all20_supplement_only": true],
            "strongest19_control_ids": BacktestProductStrategyCatalog.curatedTemplateIDs + BacktestProductStrategyCatalog.basicTemplateIDs,
            "price_policy": "Original canonical CNY close frame and strictly prior quote-day FX fixing <=14 days; carried mark retained; fill only genuine observations",
            "cadence_policy": "One native funded account; index0cash, earliest execution1 of source0; full matching signal7 earliestexec8; daily latestprior replacespending; long/supp only mechanical states filters",
            "ideal_book_actual_NAV_identity_claimed": false, "old_RP_GMV_Cover_control_parity_claimed": false,
            "units_policy": "Original genuine account states and ordered fills; derived units unchanged",
            "limitations": ["Related D0, no author SQP numerical parity, OOS or Sharpe guarantee.",
                "Three-core adaptation with original costs/settlement/cash; no fourth cash return asset or NAV feedback.",
                "Price proxies and original historical/vintage limitations; no dividends/tax/USD wallet/FX spread; 31 original whole account objects preserved."]
        ]
        outputs["evidence.json"] = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        guard outputs.count == 12 else { throw invalid("exact12 financial outputs") }
        try validateMap(gate.files_sha256)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try syncDirectory(studyPath)
        for name in outputs.keys.sorted() {
            let writer = try ArtifactWriter(output.appendingPathComponent(name).path)
            try writer.write(outputs[name]!); try writer.seal()
        }
        print("CORN_FINANCIAL_RUN_COMPLETE native6452/long5595/supp3086; 1 candidate, 3 fresh, 31 unchanged saved.")
    }
}
