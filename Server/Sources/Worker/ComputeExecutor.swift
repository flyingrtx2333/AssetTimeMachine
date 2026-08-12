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
        try await execute(PublicBacktestComputeInvocation(
            mode: .prewarm,
            datasetPath: datasetFileURL.path,
            datasetHash: datasetHash,
            dataStale: dataStale,
            strategyID: strategyID
        ))
    }

    func run(
        request: PublicBacktestRunRequest,
        datasetFileURL: URL,
        datasetHash: String,
        dataStale: Bool
    ) async throws -> PublicBacktestResult {
        try await execute(PublicBacktestComputeInvocation(
            mode: .run,
            datasetPath: datasetFileURL.path,
            datasetHash: datasetHash,
            dataStale: dataStale,
            request: request
        ))
    }

    private func execute(_ invocation: PublicBacktestComputeInvocation) async throws -> PublicBacktestResult {
        await acquire()
        defer { release() }

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

        let deadline = Date().addingTimeInterval(Double(configuration.runTimeoutSeconds))
        while process.isRunning {
            if Task.isCancelled {
                terminate(process)
                throw CancellationError()
            }
            if Date() >= deadline {
                terminate(process)
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
        guard let result = try? decoder.decode(PublicBacktestResult.self, from: data) else {
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
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        usleep(100_000)
        if process.isRunning {
            _ = kill(pid, SIGKILL)
        }
        process.waitUntilExit()
    }
}
