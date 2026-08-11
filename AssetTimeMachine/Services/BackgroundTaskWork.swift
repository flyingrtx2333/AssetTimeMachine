import Foundation
import SwiftData

/// Starts async work without inheriting the caller's actor. This is especially important when
/// constructing a SwiftData `@ModelActor`: creating it from MainActor can bind its ModelContext
/// executor to the UI queue even though later calls use `await`.
nonisolated enum BackgroundTaskWork {
    static func run<Value: Sendable>(
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            return value
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Runs stack-heavy synchronous work away from MainActor on a dedicated thread.
    /// Swift cooperative-pool threads have a comparatively small stack; the strategy
    /// engine's large value-type configuration graph can overflow it before the actual
    /// simulation starts. A dedicated stack keeps that work off the UI thread without
    /// coupling correctness to the cooperative executor's implementation limits.
    static func runSynchronousOnLargeStack<Value: Sendable>(
        stackSize: Int = 16 * 1_024 * 1_024,
        qualityOfService: QualityOfService = .utility,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()

        let value = try await withCheckedThrowingContinuation { continuation in
            let workerThread = Thread {
                autoreleasepool {
                    do {
                        continuation.resume(returning: try operation())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            workerThread.name = "AssetTimeMachine.StrategyComputation"
            workerThread.stackSize = max(stackSize, 1_024 * 1_024)
            workerThread.qualityOfService = qualityOfService
            workerThread.start()
        }

        try Task.checkCancellation()
        return value
    }
}

/// A decoder-local parser whose Foundation formatter instances never escape the
/// owning JSONDecoder. JSONDecoder invokes its custom date closure serially, so the
/// unchecked conformance only bridges Foundation's legacy non-Sendable annotations.
nonisolated final class FlexibleAPIDateParser: @unchecked Sendable {
    private let fractionalISO8601 = ISO8601DateFormatter()
    private let iso8601 = ISO8601DateFormatter()
    private let localDate = DateFormatter()

    init() {
        fractionalISO8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso8601.formatOptions = [.withInternetDateTime]
        localDate.calendar = Calendar(identifier: .gregorian)
        localDate.locale = Locale(identifier: "en_US_POSIX")
        localDate.timeZone = TimeZone(identifier: "Asia/Shanghai")
        localDate.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    }

    func date(from value: String) -> Date? {
        fractionalISO8601.date(from: value)
            ?? iso8601.date(from: value)
            ?? localDate.date(from: value)
    }
}

/// Synchronously observes every SwiftData commit so background readers can detect a
/// graph that changed while they were materializing a value snapshot. Delivery uses
/// the saving thread (`queue: nil`), avoiding a delayed MainActor revision update.
nonisolated final class ModelStoreRevisionClock: @unchecked Sendable {
    static let shared = ModelStoreRevisionClock()

    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            lock.lock()
            revision &+= 1
            lock.unlock()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func currentRevision() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }
}

/// Serializes deferred writes performed by feature views with destructive cloud
/// reconciliation on the shared UI ModelContext. A fixed delay cannot provide this
/// guarantee: a delayed save could otherwise resume while an import has yielded and
/// accidentally commit the import's partially-mutated object graph.
@MainActor
final class ModelContextMutationBarrier {
    static let shared = ModelContextMutationBarrier()

    private enum ExclusivePhase {
        case normal
        case draining(UUID)
        case exclusive(UUID)
    }

    private var phase: ExclusivePhase = .normal
    private var pendingWriteIDs: Set<UUID> = []
    private var activeEditorDraftIDs: Set<UUID> = []
    private var pendingWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var availabilityWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    var hasPendingWrites: Bool {
        !pendingWriteIDs.isEmpty
    }

    var hasBlockingEditorDraft: Bool {
        !activeEditorDraftIDs.isEmpty
    }

    /// Registers work before its unstructured Task is created, closing the race in
    /// which cloud sync samples an idle context immediately before a delayed save starts.
    func beginDeferredWrite() -> UUID {
        let id = UUID()
        pendingWriteIDs.insert(id)
        return id
    }

    func waitUntilWriteIsAllowed(_ id: UUID) async throws {
        guard pendingWriteIDs.contains(id) else { return }
        while case .exclusive = phase {
            await withCheckedContinuation { continuation in
                availabilityWaiters.append(continuation)
            }
            try Task.checkCancellation()
        }
    }

    func finishDeferredWrite(_ id: UUID) {
        guard pendingWriteIDs.remove(id) != nil else { return }
        guard pendingWriteIDs.isEmpty else { return }
        let waiters = pendingWriteWaiters
        pendingWriteWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    /// Returns nil once an import has started draining. Callers must not present a
    /// new editor in that state; an editor registered earlier blocks the import.
    func beginEditorDraft() -> UUID? {
        guard case .normal = phase else { return nil }
        let id = UUID()
        activeEditorDraftIDs.insert(id)
        return id
    }

    func finishEditorDraft(_ id: UUID) {
        activeEditorDraftIDs.remove(id)
    }

    func waitForPendingWrites() async throws {
        while !pendingWriteIDs.isEmpty {
            await withCheckedContinuation { continuation in
                pendingWriteWaiters.append(continuation)
            }
            try Task.checkCancellation()
        }
    }

    func beginExclusiveDrain() throws -> UUID {
        guard case .normal = phase,
              activeEditorDraftIDs.isEmpty else {
            throw ImportExportConsistencyError.storeChanged
        }
        let id = UUID()
        phase = .draining(id)
        return id
    }

    func enterExclusive(_ id: UUID) async throws {
        guard case .draining(let ownerID) = phase, ownerID == id else {
            throw ImportExportConsistencyError.storeChanged
        }
        guard activeEditorDraftIDs.isEmpty else {
            throw ImportExportConsistencyError.storeChanged
        }

        try await waitForPendingWrites()
        guard case .draining(let ownerID) = phase,
              ownerID == id,
              activeEditorDraftIDs.isEmpty else {
            throw ImportExportConsistencyError.storeChanged
        }
        phase = .exclusive(id)
    }

    func finishExclusive(_ id: UUID) {
        switch phase {
        case .draining(let ownerID):
            guard ownerID == id else { return }
        case .exclusive(let ownerID):
            guard ownerID == id else { return }
        case .normal:
            return
        }

        phase = .normal
        let waiters = availabilityWaiters
        availabilityWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }
}
