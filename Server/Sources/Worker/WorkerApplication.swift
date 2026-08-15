import AssetTimeMachineBacktestCore
import Foundation
import Hummingbird
import HTTPTypes

@main
struct AssetTimeMachineBacktestWorker {
    static func main() async throws {
        let configuration = try WorkerConfiguration.load()
        let computeExecutor = try BacktestComputeExecutor(configuration: configuration)
        let datasetStore = BacktestDatasetStore(
            configuration: configuration,
            computeExecutor: computeExecutor
        )
        try await datasetStore.bootstrap()
        let coordinator = try BacktestJobCoordinator(
            configuration: configuration,
            datasetStore: datasetStore,
            computeExecutor: computeExecutor
        )
        await coordinator.loadPersistedCache()

        let router = Router(context: WorkerRequestContext.self)
        router.get("health") { _, _ -> WorkerHealthResponse in
            let datasetHealth = await datasetStore.health()
            let jobHealth = await coordinator.health()
            return WorkerHealthResponse(
                status: datasetHealth.hash == nil ? "unavailable" : "ok",
                engineVersion: PublicBacktestCore.engineVersion,
                datasetHash: datasetHealth.hash,
                dataCutoff: datasetHealth.cutoff,
                dataStale: datasetHealth.stale,
                queueDepth: jobHealth.queueDepth,
                running: jobHealth.running,
                cacheEntries: jobHealth.cacheEntries
            )
        }
        router.get("strategies") { request, _ -> PublicBacktestCatalogResponse in
            try authorize(request: request, configuration: configuration)
            return try await datasetStore.catalog()
        }
        router.get("forward-snapshots") { request, _ -> EditedResponse<WorkerForwardSnapshotsResponse> in
            try authorize(request: request, configuration: configuration)
            do {
                let snapshots = try await datasetStore.forwardSnapshots(decisionAt: Date())
                return EditedResponse(
                    status: .ok,
                    headers: [.cacheControl: "no-store"],
                    response: snapshots
                )
            } catch let error as PublicBacktestCoreError {
                throw mappedHTTPError(error)
            } catch is WorkerTimeoutError {
                throw WorkerHTTPError(status: .serviceUnavailable, detail: "Forward strategy computation timed out")
            } catch {
                throw WorkerHTTPError(status: .serviceUnavailable, detail: "Forward strategy computation failed")
            }
        }
        router.post("runs") { request, context -> EditedResponse<WorkerRunEnvelope> in
            try authorize(request: request, configuration: configuration)
            let input: PublicBacktestRunRequest
            do {
                input = try await request.decode(as: PublicBacktestRunRequest.self, context: context)
            } catch {
                throw WorkerHTTPError(status: .badRequest, detail: "Invalid backtest request")
            }
            do {
                let submission = try await coordinator.submit(input)
                return EditedResponse(
                    status: submission.cacheHit ? .ok : .accepted,
                    headers: [.cacheControl: "no-store"],
                    response: submission.envelope
                )
            } catch WorkerCoordinatorError.queueFull {
                throw WorkerHTTPError(status: .tooManyRequests, detail: "Backtest queue is full")
            } catch let error as PublicBacktestCoreError {
                throw mappedHTTPError(error)
            }
        }
        router.get("runs/{runID}") { request, context -> EditedResponse<WorkerRunEnvelope> in
            try authorize(request: request, configuration: configuration)
            guard let runID = context.parameters.get("runID", as: String.self), !runID.isEmpty else {
                throw WorkerHTTPError(status: .badRequest, detail: "Missing run identifier")
            }
            do {
                return EditedResponse(
                    status: .ok,
                    headers: [.cacheControl: "no-store"],
                    response: try await coordinator.status(runID: runID)
                )
            } catch WorkerCoordinatorError.expiredRun {
                throw WorkerHTTPError(status: .gone, detail: "Backtest run expired")
            } catch WorkerCoordinatorError.unknownRun {
                throw WorkerHTTPError(status: .notFound, detail: "Backtest run not found")
            }
        }

        let refreshTask = Task {
            await runDailyRefresh(datasetStore: datasetStore)
        }
        defer { refreshTask.cancel() }

        let application = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: configuration.port))
        )
        try await application.runService()
    }

    private static func authorize(request: Request, configuration: WorkerConfiguration) throws {
        guard !configuration.authenticationToken.isEmpty else { return }
        let headerName = HTTPField.Name("X-Backtest-Token")!
        guard request.headers[headerName] == configuration.authenticationToken else {
            throw WorkerHTTPError(status: .unauthorized, detail: "Unauthorized")
        }
    }

    private static func mappedHTTPError(_ error: PublicBacktestCoreError) -> WorkerHTTPError {
        switch error {
        case .invalidDate, .invalidInitialCash:
            return WorkerHTTPError(status: .badRequest, detail: error.localizedDescription)
        case .invalidRange, .unknownStrategy:
            return WorkerHTTPError(status: .unprocessableContent, detail: error.localizedDescription)
        case .invalidDataset, .invalidMacroData, .computationFailed:
            return WorkerHTTPError(status: .serviceUnavailable, detail: "Backtest service is unavailable")
        }
    }

    private static func runDailyRefresh(datasetStore: BacktestDatasetStore) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: durationUntilNextRefresh())
                try await datasetStore.refresh()
            } catch is CancellationError {
                return
            } catch {
                await datasetStore.markRefreshFailure(error)
            }
        }
    }

    private static func durationUntilNextRefresh(now: Date = Date()) -> Duration {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        var target = calendar.dateComponents([.year, .month, .day], from: now)
        target.hour = 7
        target.minute = 30
        target.second = 0
        var next = calendar.date(from: target) ?? now.addingTimeInterval(24 * 60 * 60)
        if next <= now {
            next = calendar.date(byAdding: .day, value: 1, to: next) ?? now.addingTimeInterval(24 * 60 * 60)
        }
        return .seconds(max(1, Int(next.timeIntervalSince(now))))
    }
}
