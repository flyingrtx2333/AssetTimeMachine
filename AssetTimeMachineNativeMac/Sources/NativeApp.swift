import SwiftData
import SwiftUI
import AuthenticationServices

@main
struct AssetTimeMachineNativeApp: App {
    @State private var store = NativeStoreBootstrap()
    @State private var startsOffline = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if !AppPreviewSession.isActive, !arguments.contains("-macCloudRecovery"),
           !arguments.contains("-macRecoveryReport"),
           let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            exit(0)
        }
        if ProcessInfo.processInfo.arguments.contains("-macRecoveryReport") {
            let opened = NativeStoreBootstrap()
            if let container = opened.container {
                NativeRecoveryReport.run(context: ModelContext(container))
            } else { print("Recovery report failed: " + (opened.error ?? "store unavailable")) }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-macCloudRecovery") {
                if let container = store.container {
                    NativeCloudRecoveryView().modelContainer(container)
                } else {
                    Text(store.error ?? "无法备份本机数据库").padding(30)
                }
            } else if let container = store.container {
                NativeRootView(startsOffline: startsOffline)
                    .modelContainer(container)
                    .frame(minWidth: 900, minHeight: 620)
            } else if store.isMissingStore {
                NativeFreshStartView { useOffline in
                    let opened = NativeStoreBootstrap(createFresh: true)
                    if opened.container != nil {
                        startsOffline = useOffline
                        UserDefaults.standard.set(useOffline, forKey: "nativeMac.hasMadeAccountChoice")
                    }
                    store = opened
                }
            } else {
                ContentUnavailableView("本机数据无法打开", systemImage: "externaldrive.badge.exclamationmark", description: Text(store.error ?? "未知错误"))
                    .frame(width: 820, height: 560)
            }
        }
        .defaultSize(width: 1040, height: 720)
    }
}

private struct NativeFreshStartView: View {
    let start: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 31))
                .foregroundStyle(AssetTheme.gold)
            Text("欢迎使用资产时光机")
                .font(.system(size: 21, weight: .semibold))
            Text("选择开始方式。已有手机数据可以登录同步；也可以先在本机记录，之后随时登录。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("登录并同步手机数据") { start(false) }
                .buttonStyle(.borderedProminent)
                .tint(AssetTheme.gold)
            Button("不登录，先在本机使用") { start(true) }
                .buttonStyle(.bordered)
        }
        .padding(30)
        .frame(width: 410)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NativeCloudRecoveryView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var cloud = AssetTimeMachineCloudStore()
    @State private var archived = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("核对手机与 Mac 数据").font(.system(size: 20, weight: .semibold))
            Text(ProcessInfo.processInfo.arguments.contains("-macRecoverFromCloud")
                 ? "本机记录已备份。将以已核对的手机云端版本更新 Mac，不上传资产数据。"
                 : "本机记录已备份。请登录手机使用的同一个账户，读取云端历史。此页面不会上传或恢复资产数据。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !archived {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    Task {
                        await cloud.handleAppleSignIn(result, from: context)
                        if cloud.currentUser != nil { archived = await cloud.archiveRecovery() }
                    }
                }
                .frame(height: 36)
                .disabled(cloud.isWorking)
                if cloud.hasToken {
                    Button("重新读取云端历史") {
                        Task { archived = await cloud.archiveRecovery() }
                    }
                }
            }
            if let message = cloud.statusMessage { Text(message).font(.system(size: 12)) }
            if let error = cloud.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }
        .padding(28)
        .frame(width: 420)
        .task {
            if cloud.hasToken {
                if ProcessInfo.processInfo.arguments.contains("-macRecoverFromCloud") {
                    archived = await cloud.recoverArchivedLatest(into: context)
                } else { archived = await cloud.archiveRecovery() }
            }
        }
    }
}

@MainActor
private enum NativeRecoveryReport {
    static func run(context: ModelContext) {
        do {
            guard let path = UserDefaults.standard.string(forKey: "nativeMac.recoveryArchivePath") else {
                print("Recovery archive not found"); return
            }
            let folder = URL(fileURLWithPath: path)
            let local = try ImportExportService.exportPayload(from: context)
            let decoder = JSONDecoder()
            let parser = FlexibleAPIDateParser()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                guard let date = parser.date(from: value) else { throw URLError(.cannotParseResponse) }
                return date
            }
            let latest = try decoder.decode(AssetTimeMachineCloudLatestBackup.self,
                                            from: Data(contentsOf: folder.appendingPathComponent("latest.json")))
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let localFile = folder.appendingPathComponent("local.json")
            try encoder.encode(local).write(to: localFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localFile.path)
            print("Archive: " + folder.path)
            let history = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("history.json"))) as? [[String: Any]] ?? []
            for record in history {
                let metadata = record["metadata_json"] as? [String: Any] ?? [:]
                print("Backup id=\(record["id"] ?? "?") time=\(record["uploaded_at"] ?? "?") device=\(metadata["device_name"] ?? "?") latest=\(record["is_latest"] ?? "?")")
            }
            let remote = latest.payload
            let remoteIDs = Set(remote.snapshots.map(\.id))
            let localIDs = Set(local.snapshots.map(\.id))
            print("Snapshot counts local=\(local.snapshots.count) remote=\(remote.snapshots.count) local-only=\(localIDs.subtracting(remoteIDs).count) remote-only=\(remoteIDs.subtracting(localIDs).count)")
            let localEntries = Dictionary(local.snapshots.flatMap(\.entries).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var remoteNewer = 0, localNewer = 0, tied = 0
            for entry in remote.snapshots.flatMap(\.entries) {
                guard let prior = localEntries[entry.id],
                      prior.amount != entry.amount || prior.quantity != entry.quantity
                        || prior.unitPrice != entry.unitPrice || prior.note != entry.note else { continue }
                if prior.updatedAt < entry.updatedAt { remoteNewer += 1 }
                else if prior.updatedAt > entry.updatedAt { localNewer += 1 }
                else { tied += 1 }
            }
            print("Changed entries remote-newer=\(remoteNewer) local-newer=\(localNewer) tied=\(tied)")
            for (label, payload) in [("Local", local), ("Cloud", remote)] {
                if let snapshot = payload.snapshots.max(by: { $0.date < $1.date }) {
                    print("\(label) newest day=\(snapshot.date.ISO8601Format()) updated=\(snapshot.updatedAt.ISO8601Format()) entries=\(snapshot.entries.count)")
                }
            }
            print("Same content: \(SyncMergeService.isSameContent(local, remote))")
        } catch { print("Recovery report failed: " + error.localizedDescription) }
    }
}
