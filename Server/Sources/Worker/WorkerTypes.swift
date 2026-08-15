import AssetTimeMachineBacktestCore
import Foundation
import Hummingbird

struct WorkerRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: Source) {
        self.coreContext = .init(source: source)
    }

    var requestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    var responseEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum WorkerRunStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case expired
}

struct WorkerRunError: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct WorkerRunEnvelope: Codable, Sendable {
    let runID: String
    let status: WorkerRunStatus
    let pollAfterMilliseconds: Int?
    let queuePosition: Int?
    let error: WorkerRunError?
    let result: PublicBacktestResult?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case status
        case pollAfterMilliseconds = "poll_after_ms"
        case queuePosition = "queue_position"
        case error
        case result
    }
}

extension WorkerRunEnvelope: ResponseEncodable {}

struct WorkerHealthResponse: Codable, Sendable {
    let status: String
    let engineVersion: String
    let datasetHash: String?
    let dataCutoff: String?
    let dataStale: Bool
    let queueDepth: Int
    let running: Bool
    let cacheEntries: Int
}

struct WorkerForwardSnapshotsResponse: Codable, Sendable {
    let generatedAt: Date
    let macroDatasetHash: String
    let snapshots: [PublicForwardStrategySnapshot]
}

extension WorkerHealthResponse: ResponseEncodable {}

extension PublicBacktestCatalogResponse: ResponseEncodable {}
extension WorkerForwardSnapshotsResponse: ResponseEncodable {}

struct WorkerErrorResponse: Codable, Sendable {
    let detail: String
}

struct WorkerHTTPError: HTTPResponseError, Sendable {
    let status: HTTPResponse.Status
    let detail: String

    func response(from request: Request, context: some RequestContext) throws -> Response {
        var response = try context.responseEncoder.encode(
            WorkerErrorResponse(detail: detail),
            from: request,
            context: context
        )
        response.status = status
        return response
    }
}

struct WorkerConfiguration: Sendable {
    let port: Int
    let authenticationToken: String
    let storageDirectory: URL
    let fixtureURL: URL?
    let historyURL: URL
    let nfciURL: URL
    let computeExecutableURL: URL
    let queueLimit: Int
    let runTimeoutSeconds: Int
    let cacheTTLSeconds: Int

    static func load() throws -> WorkerConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let token = environment["BACKTEST_WORKER_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let allowsInsecureLocal = environment["BACKTEST_ALLOW_INSECURE_LOCAL"] == "1"
        guard !token.isEmpty || allowsInsecureLocal else {
            throw WorkerStartupError.missingAuthenticationToken
        }

        let storagePath = environment["BACKTEST_STORAGE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storageDirectory = URL(fileURLWithPath: storagePath?.isEmpty == false ? storagePath! : "/var/lib/asset-time-machine-backtest", isDirectory: true)
        let fixtureURL = environment["ATM_HISTORY_FIXTURE"].flatMap { value -> URL? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
        }
        let defaultHistoryURL = "https://api.flyingrtx.com/api/v1/money/public/history?symbols=gold,nasdaq,sp500,dowjones,hsi,nikkei,oil_wti_cny,csi300,shanghai_composite,shenzhen_component,chinext,usd_per_cny&period=all&include_ohlc=true"
        guard let historyURL = URL(string: environment["BACKTEST_HISTORY_URL"] ?? defaultHistoryURL) else {
            throw WorkerStartupError.invalidHistoryURL
        }
        let defaultNFCIURL = "https://api.flyingrtx.com/api/v1/money/public/nfci-asof"
        guard let nfciURL = URL(string: environment["BACKTEST_NFCI_URL"] ?? defaultNFCIURL) else {
            throw WorkerStartupError.invalidNFCIURL
        }
        let defaultComputeURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("AssetTimeMachineBacktestCompute")
        let computeExecutableURL = environment["BACKTEST_COMPUTE_EXECUTABLE"].flatMap { value -> URL? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
        } ?? defaultComputeURL
        guard FileManager.default.isExecutableFile(atPath: computeExecutableURL.path) else {
            throw WorkerStartupError.computeExecutableUnavailable
        }
        return WorkerConfiguration(
            port: Int(environment["BACKTEST_WORKER_PORT"] ?? "8080") ?? 8080,
            authenticationToken: token,
            storageDirectory: storageDirectory,
            fixtureURL: fixtureURL,
            historyURL: historyURL,
            nfciURL: nfciURL,
            computeExecutableURL: computeExecutableURL,
            queueLimit: 20,
            runTimeoutSeconds: 60,
            cacheTTLSeconds: 24 * 60 * 60
        )
    }
}

enum WorkerStartupError: Error, LocalizedError {
    case missingAuthenticationToken
    case invalidHistoryURL
    case invalidNFCIURL
    case computeExecutableUnavailable
    case datasetUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAuthenticationToken:
            return "BACKTEST_WORKER_TOKEN is required unless BACKTEST_ALLOW_INSECURE_LOCAL=1"
        case .invalidHistoryURL:
            return "BACKTEST_HISTORY_URL is invalid"
        case .invalidNFCIURL:
            return "BACKTEST_NFCI_URL is invalid"
        case .computeExecutableUnavailable:
            return "AssetTimeMachineBacktestCompute is not executable"
        case .datasetUnavailable:
            return "No validated backtest dataset is available"
        }
    }
}

enum WorkerTimeoutError: Error, LocalizedError {
    case timedOut

    var errorDescription: String? { "Backtest exceeded the 60 second hard timeout" }
}
