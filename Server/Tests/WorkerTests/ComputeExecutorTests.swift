import Foundation
import XCTest
@testable import AssetTimeMachineBacktestWorker
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class ComputeExecutorTests: XCTestCase {
    private struct Harness {
        let root: URL
        let marker: URL
        let executor: BacktestComputeExecutor

        init(timeout: Int = 30) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("atm-compute-cancellation-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            marker = root.appendingPathComponent("process-ids")
            let executable = root.appendingPathComponent("slow-compute")
            let quotedMarker = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            try Data("#!/bin/sh\necho $$ >> \(quotedMarker)\nexec /bin/sleep 30\n".utf8)
                .write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let configuration = WorkerConfiguration(
                port: 0, authenticationToken: "isolated-test", storageDirectory: root,
                fixtureURL: nil, historyURL: URL(string: "https://invalid.example/history")!,
                nfciURL: URL(string: "https://invalid.example/macro")!,
                computeExecutableURL: executable, queueLimit: 2,
                runTimeoutSeconds: timeout, cacheTTLSeconds: 60
            )
            executor = try BacktestComputeExecutor(configuration: configuration)
        }

        func start() -> Task<Void, Error> {
            Task {
                _ = try await executor.prewarm(
                    strategyID: "isolated-test", datasetFileURL: root.appendingPathComponent("unused.json"),
                    datasetHash: "isolated", dataStale: true
                )
            }
        }

        func waitForProcess() async throws -> Int32 {
            for _ in 0..<200 {
                if let contents = try? String(contentsOf: marker, encoding: .utf8),
                   let first = contents.split(separator: "\n").first,
                   let pid = Int32(first) {
                    return pid
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: "ComputeExecutorTests", code: 1)
        }

        func assertReleased(pid: Int32, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(kill(pid, 0), -1, "Computation child survived cancellation", file: file, line: line)
            XCTAssertEqual(errno, ESRCH, file: file, line: line)
            let files = try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent("compute-tmp").path
            )
            XCTAssertTrue(files.isEmpty, "Temporary computation files survived", file: file, line: line)
        }
    }

    func testCancellationDuringPollingReapsProcessAndDeletesTemporaryFiles() async throws {
        let harness = try Harness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let task = harness.start()
        let pid = try await harness.waitForProcess()
        // Cancel while the executor is suspended in its polling sleep.
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        do { try await task.value; XCTFail("Cancelled computation returned successfully") }
        catch is CancellationError {}
        try harness.assertReleased(pid: pid)
    }

    func testCancelledQueuedInvocationNeverStartsAnotherProcess() async throws {
        let harness = try Harness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let first = harness.start()
        let pid = try await harness.waitForProcess()
        let queued = harness.start()
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        first.cancel()
        for task in [first, queued] {
            do { try await task.value; XCTFail("Cancelled computation returned successfully") }
            catch is CancellationError {}
        }
        let processIDs = try String(contentsOf: harness.marker, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(processIDs.count, 1)
        try harness.assertReleased(pid: pid)
    }

    func testTimeoutReapsProcessAndDeletesTemporaryFiles() async throws {
        let harness = try Harness(timeout: 1)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let task = harness.start()
        let pid = try await harness.waitForProcess()
        do { try await task.value; XCTFail("Timed out computation returned successfully") }
        catch is WorkerTimeoutError {}
        try harness.assertReleased(pid: pid)
    }
}
