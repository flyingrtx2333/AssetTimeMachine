import AssetTimeMachineBacktestCore
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ActiveDatasetSnapshot: Sendable {
    let dataset: PublicBacktestDataset
    let defaultResults: [String: PublicBacktestResult]
    let datasetFileURL: URL
}

actor BacktestDatasetStore {
    private let configuration: WorkerConfiguration
    private let computeExecutor: BacktestComputeExecutor
    private let fileManager = FileManager.default
    private var active: ActiveDatasetSnapshot?
    private var lastRefreshError: String?

    init(configuration: WorkerConfiguration, computeExecutor: BacktestComputeExecutor) {
        self.configuration = configuration
        self.computeExecutor = computeExecutor
    }

    func bootstrap() async throws {
        try fileManager.createDirectory(
            at: configuration.storageDirectory,
            withIntermediateDirectories: true
        )

        if configuration.fixtureURL == nil {
            let persistedURLs = [
                configuration.storageDirectory.appendingPathComponent("dataset-current.json"),
                configuration.storageDirectory.appendingPathComponent("dataset-previous.json"),
            ]
            for persistedURL in persistedURLs {
                guard active == nil,
                      let persistedData = try? Data(contentsOf: persistedURL),
                      !persistedData.isEmpty else { continue }
                do {
                    active = try await validateAndPrewarm(
                        data: persistedData,
                        datasetFileURL: persistedURL,
                        dataStale: true
                    )
                } catch {
                    lastRefreshError = "persisted snapshot rejected: \(error.localizedDescription)"
                }
            }
        }

        do {
            try await refresh()
        } catch {
            lastRefreshError = error.localizedDescription
            if let current = active {
                active = ActiveDatasetSnapshot(
                    dataset: current.dataset.markingStale(true),
                    defaultResults: current.defaultResults,
                    datasetFileURL: current.datasetFileURL
                )
            } else {
                throw error
            }
        }
    }

    func refresh() async throws {
        let data = try await fetchDatasetData()
        let hash = sha256Hex(data)
        if let current = active, current.dataset.datasetHash == hash {
            active = ActiveDatasetSnapshot(
                dataset: current.dataset.markingStale(false),
                defaultResults: current.defaultResults,
                datasetFileURL: current.datasetFileURL
            )
            lastRefreshError = nil
            return
        }

        let candidateURL = configuration.storageDirectory.appendingPathComponent("dataset-candidate-\(UUID().uuidString.lowercased()).json")
        try data.write(to: candidateURL, options: .atomic)
        defer { try? fileManager.removeItem(at: candidateURL) }
        let candidate = try await validateAndPrewarm(
            data: data,
            datasetFileURL: candidateURL,
            dataStale: false
        )
        let persistedURL = configuration.storageDirectory.appendingPathComponent("dataset-current.json")
        let previousURL = configuration.storageDirectory.appendingPathComponent("dataset-previous.json")
        if let oldData = try? Data(contentsOf: persistedURL), !oldData.isEmpty {
            try oldData.write(to: previousURL, options: .atomic)
        }
        try data.write(to: persistedURL, options: .atomic)
        active = ActiveDatasetSnapshot(
            dataset: candidate.dataset,
            defaultResults: candidate.defaultResults,
            datasetFileURL: persistedURL
        )
        lastRefreshError = nil
    }

    func markRefreshFailure(_ error: Error) {
        lastRefreshError = error.localizedDescription
        if let current = active {
            active = ActiveDatasetSnapshot(
                dataset: current.dataset.markingStale(true),
                defaultResults: current.defaultResults,
                datasetFileURL: current.datasetFileURL
            )
        }
    }

    func snapshot() throws -> ActiveDatasetSnapshot {
        guard let active else { throw WorkerStartupError.datasetUnavailable }
        return active
    }

    func catalog() throws -> PublicBacktestCatalogResponse {
        guard let active else { throw WorkerStartupError.datasetUnavailable }
        return try PublicBacktestCore.catalog(
            dataset: active.dataset,
            defaultResults: active.defaultResults
        )
    }

    func health() -> (hash: String?, cutoff: String?, stale: Bool, refreshError: String?) {
        (
            active?.dataset.datasetHash,
            active?.dataset.dataCutoff,
            active?.dataset.dataStale ?? true,
            lastRefreshError
        )
    }

    private func validateAndPrewarm(
        data: Data,
        datasetFileURL: URL,
        dataStale: Bool
    ) async throws -> ActiveDatasetSnapshot {
        let hash = sha256Hex(data)
        let dataset = try await Task.detached(priority: .userInitiated) {
            try PublicBacktestCore.loadDataset(
                from: data,
                datasetHash: hash,
                dataStale: dataStale
            )
        }.value

        var defaults: [String: PublicBacktestResult] = [:]
        for strategyID in PublicBacktestCore.strategyIDs {
            let result = try await computeExecutor.prewarm(
                strategyID: strategyID,
                datasetFileURL: datasetFileURL,
                datasetHash: dataset.datasetHash,
                dataStale: dataStale
            )
            defaults[strategyID] = result
        }
        guard defaults.count == PublicBacktestCore.strategyIDs.count else {
            throw PublicBacktestCoreError.invalidDataset("not every public strategy passed preflight")
        }
        return ActiveDatasetSnapshot(
            dataset: dataset,
            defaultResults: defaults,
            datasetFileURL: datasetFileURL
        )
    }

    private func fetchDatasetData() async throws -> Data {
        if let fixtureURL = configuration.fixtureURL {
            return try Data(contentsOf: fixtureURL)
        }
        var request = URLRequest(url: configuration.historyURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              !data.isEmpty,
              data.count <= 30 * 1024 * 1024 else {
            throw PublicBacktestCoreError.invalidDataset("upstream response failed size or status checks")
        }
        return data
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
