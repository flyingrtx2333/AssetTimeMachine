import AssetTimeMachineBacktestCore
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum ComputeExecutorError: Error, LocalizedError {
    case processFailed(String)
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .processFailed(let detail):
            return detail.isEmpty
                ? "The isolated Swift computation process failed"
                : "The isolated Swift computation process failed: \(detail)"
        case .invalidResult:
            return "The isolated Swift computation returned an invalid result"
        }
    }
}

actor BacktestComputeExecutor {
    private let configuration: WorkerConfiguration
    private let temporaryDirectory: URL
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: WorkerConfiguration) throws {
        self.configuration = configuration
        self.temporaryDirectory = configuration.storageDirectory.appendingPathComponent("compute-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    func prewarm(
        strategyID: String,
        datasetFileURL: URL,
        datasetHash: String,
        dataStale: Bool
    ) async throws -> PublicBacktestResult {
        try await execute(
            PublicBacktestComputeInvocation(
                mode: .prewarm,
                datasetPath: datasetFileURL.path,
                datasetHash: datasetHash,
                dataStale: dataStale,
                strategyID: strategyID
            ),
            as: PublicBacktestResult.self,
            timeoutSeconds: configuration.runTimeoutSeconds
        )
    }

    func run(
        request: PublicBacktestRunRequest,
        datasetFileURL: URL,
        datasetHash: String,
        dataStale: Bool
    ) async throws -> PublicBacktestResult {
        try await execute(
            PublicBacktestComputeInvocation(
                mode: .run,
                datasetPath: datasetFileURL.path,
                datasetHash: datasetHash,
                dataStale: dataStale,
                request: request
            ),
            as: PublicBacktestResult.self,
            timeoutSeconds: configuration.runTimeoutSeconds
        )
    }

    func forward(
        strategyID: String,
        datasetFileURL: URL,
        datasetHash: String,
        dataStale: Bool,
        macroFileURL: URL,
        decisionAt: Date
    ) async throws -> PublicForwardStrategySnapshot {
        try await execute(
            PublicBacktestComputeInvocation(
                mode: .forward,
                datasetPath: datasetFileURL.path,
                datasetHash: datasetHash,
                dataStale: dataStale,
                strategyID: strategyID,
                macroPath: macroFileURL.path,
                decisionAt: decisionAt
            ),
            as: PublicForwardStrategySnapshot.self,
            timeoutSeconds: max(configuration.runTimeoutSeconds, 180)
        )
    }

    private func execute<Response: Decodable>(
        _ invocation: PublicBacktestComputeInvocation,
        as responseType: Response.Type,
        timeoutSeconds: Int
    ) async throws -> Response {
        await acquire()
        defer { release() }
        try Task.checkCancellation()

        let identifier = UUID().uuidString.lowercased()
        let invocationURL = temporaryDirectory.appendingPathComponent(identifier + "-request.json")
        let resultURL = temporaryDirectory.appendingPathComponent(identifier + "-result.json")
        let errorURL = temporaryDirectory.appendingPathComponent(identifier + "-stderr.log")
        defer {
            try? FileManager.default.removeItem(at: invocationURL)
            try? FileManager.default.removeItem(at: resultURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let encoder = PublicBacktestComputeCodec.makeEncoder()
        try encoder.encode(invocation).write(to: invocationURL, options: .atomic)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }

        let process = Process()
        process.executableURL = configuration.computeExecutableURL
        process.arguments = [invocationURL.path, resultURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        try process.run()
        // Sleep can throw cancellation before the loop reaches its next check.
        // Every exit must reap the child before removing its input/output files.
        defer { if process.isRunning { terminate(process) } }

        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while process.isRunning {
            if Task.isCancelled {
                throw CancellationError()
            }
            if Date() >= deadline {
                throw WorkerTimeoutError.timedOut
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0,
              let data = try? Data(contentsOf: resultURL) else {
            let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
            let detail = String(data: errorData.prefix(1_000), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ComputeExecutorError.processFailed(detail)
        }
        let decoder = PublicBacktestComputeCodec.makeDecoder()
        guard let result = try? decoder.decode(responseType, from: data) else {
            throw ComputeExecutorError.invalidResult
        }
        return result
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    private nonisolated func terminate(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0, kill(pid, 0) == 0 else { return }
        _ = kill(pid, SIGTERM)
        usleep(100_000)
        if kill(pid, 0) == 0 {
            _ = kill(pid, SIGKILL)
        }
        // Foundation reaps Process asynchronously. In cancellation tests its
        // run-loop wait outlived an already-reaped child; inspect the OS PID.
        // Bound cleanup and inspect the OS process instead of blocking forever.
        for _ in 0..<200 {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            usleep(10_000)
        }
    }
}
