import AssetTimeMachineBacktestCore
import Crypto
import Foundation

struct WorkerSubmission: Sendable {
    let envelope: WorkerRunEnvelope
    let cacheHit: Bool
}

enum WorkerCoordinatorError: Error, LocalizedError {
    case queueFull
    case unknownRun
    case expiredRun

    var errorDescription: String? {
        switch self {
        case .queueFull:
            return "The backtest queue is full"
        case .unknownRun:
            return "The backtest run does not exist"
        case .expiredRun:
            return "The backtest run has expired"
        }
    }
}

actor BacktestJobCoordinator {
    private struct QueuedJob: Sendable {
        let runID: String
        let key: String
        let request: PublicBacktestRunRequest
        let dataset: PublicBacktestDataset
        let datasetFileURL: URL
        let createdAt: Date
    }

    private struct JobRecord: Sendable {
        let runID: String
        let key: String
        var status: WorkerRunStatus
        var result: PublicBacktestResult?
        var error: WorkerRunError?
        let createdAt: Date
        var completedAt: Date?
    }

    private struct CacheRecord: Codable, Sendable {
        let key: String
        let runID: String
        let completedAt: Date
        let result: PublicBacktestResult
    }

    private let configuration: WorkerConfiguration
    private let datasetStore: BacktestDatasetStore
    private let computeExecutor: BacktestComputeExecutor
    private let cacheDirectory: URL
    private let fileManager = FileManager.default
    private var queue: [QueuedJob] = []
    private var recordsByID: [String: JobRecord] = [:]
    private var runIDByKey: [String: String] = [:]
    private var cacheByKey: [String: CacheRecord] = [:]
    private var expiredRunIDs: Set<String> = []
    private var processing = false

    init(
        configuration: WorkerConfiguration,
        datasetStore: BacktestDatasetStore,
        computeExecutor: BacktestComputeExecutor
    ) throws {
        self.configuration = configuration
        self.datasetStore = datasetStore
        self.computeExecutor = computeExecutor
        self.cacheDirectory = configuration.storageDirectory.appendingPathComponent("result-cache", isDirectory: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func submit(_ request: PublicBacktestRunRequest) async throws -> WorkerSubmission {
        cleanupExpired()
        let snapshot = try await datasetStore.snapshot()
        let key = cacheKey(request: request, datasetHash: snapshot.dataset.datasetHash)

        if let cached = cacheByKey[key], !isExpired(cached.completedAt) {
            let result = PublicBacktestCore.applyingCurrentDatasetState(
                to: cached.result,
                dataset: snapshot.dataset
            )
            return WorkerSubmission(
                envelope: WorkerRunEnvelope(
                    runID: cached.runID,
                    status: .succeeded,
                    pollAfterMilliseconds: nil,
                    queuePosition: nil,
                    error: nil,
                    result: result
                ),
                cacheHit: true
            )
        }

        if let existingRunID = runIDByKey[key], let existing = recordsByID[existingRunID] {
            return WorkerSubmission(
                envelope: envelope(for: existing),
                cacheHit: existing.status == .succeeded
            )
        }

        guard queue.count < configuration.queueLimit else {
            throw WorkerCoordinatorError.queueFull
        }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let runID = "run_" + String(key.prefix(20)) + "_" + String(suffix.prefix(12))
        let now = Date()
        let job = QueuedJob(
            runID: runID,
            key: key,
            request: request,
            dataset: snapshot.dataset,
            datasetFileURL: snapshot.datasetFileURL,
            createdAt: now
        )
        queue.append(job)
        let record = JobRecord(
            runID: runID,
            key: key,
            status: .queued,
            result: nil,
            error: nil,
            createdAt: now,
            completedAt: nil
        )
        recordsByID[runID] = record
        runIDByKey[key] = runID
        scheduleProcessorIfNeeded()
        return WorkerSubmission(envelope: envelope(for: record), cacheHit: false)
    }

    func status(runID: String) async throws -> WorkerRunEnvelope {
        cleanupExpired()
        if expiredRunIDs.contains(runID) { throw WorkerCoordinatorError.expiredRun }
        guard var record = recordsByID[runID] else { throw WorkerCoordinatorError.unknownRun }
        if record.status == .succeeded,
           let result = record.result,
           let snapshot = try? await datasetStore.snapshot(),
           result.datasetHash == snapshot.dataset.datasetHash {
            record.result = PublicBacktestCore.applyingCurrentDatasetState(
                to: result,
                dataset: snapshot.dataset
            )
        }
        return envelope(for: record)
    }

    func health() -> (queueDepth: Int, running: Bool, cacheEntries: Int) {
        cleanupExpired()
        return (queue.count, processing, cacheByKey.count)
    }

    private func scheduleProcessorIfNeeded() {
        guard !processing else { return }
        processing = true
        Task { await processLoop() }
    }

    private func processLoop() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            guard var record = recordsByID[job.runID] else { continue }
            record.status = .running
            recordsByID[job.runID] = record
            do {
                let result = try await computeExecutor.run(
                    request: job.request,
                    datasetFileURL: job.datasetFileURL,
                    datasetHash: job.dataset.datasetHash,
                    dataStale: job.dataset.dataStale
                )
                let completedAt = Date()
                record.status = .succeeded
                record.result = result
                record.completedAt = completedAt
                recordsByID[job.runID] = record
                let cache = CacheRecord(
                    key: job.key,
                    runID: job.runID,
                    completedAt: completedAt,
                    result: result
                )
                cacheByKey[job.key] = cache
                persist(cache)
            } catch is WorkerTimeoutError {
                record.status = .failed
                record.error = WorkerRunError(code: "timeout", message: "Backtest exceeded the 60 second hard timeout")
                record.completedAt = Date()
                recordsByID[job.runID] = record
                runIDByKey[job.key] = nil
            } catch is CancellationError {
                record.status = .failed
                record.error = WorkerRunError(code: "cancelled", message: "Backtest was cancelled")
                record.completedAt = Date()
                recordsByID[job.runID] = record
                runIDByKey[job.key] = nil
            } catch {
                record.status = .failed
                record.error = WorkerRunError(code: "computation_failed", message: publicErrorMessage(error))
                record.completedAt = Date()
                recordsByID[job.runID] = record
                runIDByKey[job.key] = nil
            }
        }
        processing = false
    }

    private func envelope(for record: JobRecord) -> WorkerRunEnvelope {
        let queuePosition: Int?
        if record.status == .queued {
            queuePosition = queue.firstIndex(where: { $0.runID == record.runID }).map { $0 + (processing ? 1 : 0) }
        } else {
            queuePosition = nil
        }
        return WorkerRunEnvelope(
            runID: record.runID,
            status: record.status,
            pollAfterMilliseconds: record.status == .queued || record.status == .running ? 1000 : nil,
            queuePosition: queuePosition,
            error: record.error,
            result: record.status == .succeeded ? record.result : nil
        )
    }

    private func cacheKey(request: PublicBacktestRunRequest, datasetHash: String) -> String {
        let requestData = (try? PublicBacktestComputeCodec.makeEncoder().encode(request)) ?? Data()
        let canonical = [
            PublicBacktestCore.engineVersion,
            datasetHash,
            requestData.base64EncodedString()
        ].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func isExpired(_ date: Date) -> Bool {
        Date().timeIntervalSince(date) >= Double(configuration.cacheTTLSeconds)
    }

    private func cleanupExpired() {
        for (key, cache) in cacheByKey where isExpired(cache.completedAt) {
            cacheByKey[key] = nil
            expiredRunIDs.insert(cache.runID)
            recordsByID[cache.runID] = nil
            runIDByKey[key] = nil
            try? fileManager.removeItem(at: cacheFileURL(for: key))
        }
        for (runID, record) in recordsByID {
            guard let completedAt = record.completedAt, isExpired(completedAt) else { continue }
            expiredRunIDs.insert(runID)
            recordsByID[runID] = nil
            runIDByKey[record.key] = nil
        }
        if expiredRunIDs.count > 2_000 {
            expiredRunIDs.removeAll(keepingCapacity: true)
        }
    }

    private func persist(_ cache: CacheRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: cacheFileURL(for: cache.key), options: .atomic)
    }

    private nonisolated func cacheFileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key + ".json")
    }

    func loadPersistedCache() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(CacheRecord.self, from: data),
                  !isExpired(record.completedAt) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            cacheByKey[record.key] = record
            let jobRecord = JobRecord(
                runID: record.runID,
                key: record.key,
                status: .succeeded,
                result: record.result,
                error: nil,
                createdAt: record.completedAt,
                completedAt: record.completedAt
            )
            recordsByID[record.runID] = jobRecord
            runIDByKey[record.key] = record.runID
        }
    }

    private func publicErrorMessage(_ error: Error) -> String {
        switch error {
        case PublicBacktestCoreError.invalidInitialCash:
            return "Initial cash is outside the public range"
        case PublicBacktestCoreError.invalidDate:
            return "A request date is invalid"
        case PublicBacktestCoreError.invalidRange:
            return "The requested date range is unavailable"
        case PublicBacktestCoreError.unknownStrategy:
            return "The requested strategy is unavailable"
        default:
            return "The Swift backtest engine could not produce a result"
        }
    }
}
