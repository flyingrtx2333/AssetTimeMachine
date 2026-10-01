import Foundation
import SQLite3
import SwiftData

/// Opens an existing store only after a verified, SQLite-consistent backup.
/// A new store is created only after the user chooses how to start; unreadable stores stop startup.
@MainActor
final class NativeStoreBootstrap {
    private static var performanceAccess: URL?

    static func grantPerformanceAccess(to directory: URL) throws {
        precondition(AppPreviewSession.isActive)
        let data = try directory.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: "nativeMac.performanceDirectoryBookmark")
    }

    private static func accessPerformanceStore(_ url: URL) throws -> URL {
        if performanceAccess != nil { return url }
        if let data = UserDefaults.standard.data(forKey: "nativeMac.performanceDirectoryBookmark") {
            var stale = false
            let directory = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                    relativeTo: nil, bookmarkDataIsStale: &stale)
            if url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/"),
               directory.startAccessingSecurityScopedResource() {
                performanceAccess = directory
                if stale { try grantPerformanceAccess(to: directory) }
            }
        }
        return url
    }
    let container: ModelContainer?
    let error: String?
    let sourceURL: URL?
    let baselineSnapshotCount: Int
    let isMissingStore: Bool
    let isNewStore: Bool

    init(createFresh: Bool = false) {
        let schema = Schema([
            AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self,
            BacktestRecord.self, SyncDeletionTombstone.self
        ])
        do {
            let arguments = ProcessInfo.processInfo.arguments
            let testURL: URL? = {
                guard let index = arguments.firstIndex(of: "-macPerfStorePath"), arguments.indices.contains(index + 1) else { return nil }
                return URL(fileURLWithPath: arguments[index + 1])
            }()
            let url: URL
            let baseline: StoreSummary
            if let testURL {
                url = try Self.accessPerformanceStore(testURL)
                baseline = try Self.inspect(url)
            } else if createFresh {
                url = try Self.newStoreURL()
                baseline = StoreSummary(count: 0, entryCount: 0, amount: 0)
            } else {
                url = try Self.findExistingStore()
                NSLog("[NativeMac] selected existing store: %@", url.path)
                baseline = try Self.inspect(url)
                let defaults = UserDefaults.standard
                let priorSource = defaults.string(forKey: "nativeMac.verifiedBackupSource")
                let priorBackup = defaults.string(forKey: "nativeMac.verifiedBackupPath")
                if arguments.contains("-macCloudRecovery") || priorSource != url.path || priorBackup.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
                    let backup = try Self.makeVerifiedBackup(of: url, baseline: baseline)
                    defaults.set(url.path, forKey: "nativeMac.verifiedBackupSource")
                    defaults.set(backup.path, forKey: "nativeMac.verifiedBackupPath")
                    NSLog("[NativeMac] verified local store backup: %@, snapshots: %d", backup.path, baseline.count)
                }
            }
            let configuration = ModelConfiguration(schema: schema, url: url)
            let opened = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(opened)
            let postOpenCount = try context.fetchCount(FetchDescriptor<AssetSnapshot>())
            guard postOpenCount == baseline.count else {
                throw StoreError.validation("打开数据库后记录数改变：\(baseline.count) → \(postOpenCount)")
            }
            guard try Self.inspect(url) == baseline else {
                throw StoreError.validation("打开数据库后记录数量或金额发生改变")
            }
            container = opened
            sourceURL = url
            baselineSnapshotCount = baseline.count
            isMissingStore = false
            isNewStore = createFresh
            error = nil
        } catch {
            container = nil
            sourceURL = nil
            baselineSnapshotCount = 0
            isMissingStore = (error as? StoreError).map {
                if case .missing = $0 { return true }
                return false
            } ?? false
            isNewStore = false
            self.error = error.localizedDescription
        }
    }

    private struct StoreSummary: Equatable {
        let count: Int
        let entryCount: Int
        let amount: Double
    }

    private enum StoreError: LocalizedError {
        case missing
        case validation(String)
        var errorDescription: String? {
            switch self {
            case .missing: return "未找到原有资产数据库。为避免以空数据覆盖云端，请先确认旧版应用的数据位置。"
            case .validation(let detail): return "资产数据库校验失败：\(detail)。未进行同步。"
            }
        }
    }

    private static func findExistingStore() throws -> URL {
        let fm = FileManager.default
        var directories: [URL] = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.flyingrtx.AssetTimeMachine") {
            directories.append(group.appending(path: "Library/Application Support"))
            directories.append(group)
        }
        for directory in directories {
            let candidate = directory.appending(path: "default.store")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        throw StoreError.missing
    }

    private static func newStoreURL() throws -> URL {
        do {
            _ = try findExistingStore()
            throw StoreError.validation("已发现原有数据库，不能新建空数据")
        } catch StoreError.missing {
            // A truly new installation may create its first store after the user chooses a mode.
        }
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.flyingrtx.AssetTimeMachine"
        ) else {
            throw StoreError.validation("当前应用无法访问共享容器，请使用开发签名版")
        }
        let directory = group.appending(path: "Library/Application Support")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "default.store")
    }

    private static func inspect(_ url: URL) throws -> StoreSummary {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw StoreError.validation("无法读取 \(url.path)")
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT (SELECT COUNT(*) FROM ZASSETSNAPSHOT),
                   (SELECT COUNT(*) FROM ZASSETENTRY),
                   (SELECT COALESCE(SUM(COALESCE(ZAMOUNT, ZQUANTITY * ZUNITPRICE, 0)), 0) FROM ZASSETENTRY)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.validation("无法读取记录数量与金额：\(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.validation("数据库缺少资产记录") }
        let summary = StoreSummary(
            count: Int(sqlite3_column_int64(statement, 0)),
            entryCount: Int(sqlite3_column_int64(statement, 1)),
            amount: sqlite3_column_double(statement, 2)
        )
        guard summary.count >= 0, summary.entryCount >= 0, summary.amount.isFinite else {
            throw StoreError.validation("记录数量或金额无效")
        }
        return summary
    }

    private static func makeVerifiedBackup(of url: URL, baseline: StoreSummary) throws -> URL {
        let fm = FileManager.default
        let backupDirectory = url.deletingLastPathComponent().appending(path: "AssetTimeMachine-Backups")
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backup = backupDirectory.appending(path: "before-native-\(UUID().uuidString).store")
        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let source else { throw StoreError.validation("无法打开原始数据库进行备份") }
        defer { sqlite3_close(source) }
        guard sqlite3_open_v2(backup.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let destination else { throw StoreError.validation("无法创建备份") }
        defer { sqlite3_close(destination) }
        guard let job = sqlite3_backup_init(destination, "main", source, "main") else {
            throw StoreError.validation("无法启动备份")
        }
        let result = sqlite3_backup_step(job, -1)
        let finish = sqlite3_backup_finish(job)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw StoreError.validation("备份未完成") }
        guard try inspect(backup) == baseline else { throw StoreError.validation("备份记录或金额与原始数据不同") }
        return backup
    }
}
