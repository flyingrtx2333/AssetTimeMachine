import SwiftData
import SwiftUI
import AuthenticationServices

@main
struct AssetTimeMachineNativeApp: App {
    @NSApplicationDelegateAdaptor(NativeDraftApplicationDelegate.self) private var draftDelegate
    @State private var store = NativeStoreBootstrap()
    @State private var startsOffline = false
    @AppStorage("app.appearanceMode") private var appearanceMode = "system"
    @StateObject private var languageStore = AppLanguageStore()
    @MainActor private static var workspaceFixtureWindow: NSWindow?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if AppPreviewSession.isActive {
            DispatchQueue.main.async {
                if arguments.contains("-macAppearanceLight") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
                if arguments.contains("-macAppearanceDark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
            }
        }
        // Explicit in-memory evidence session; production WindowGroup/auth remain unchanged.
        if AppPreviewSession.isActive, arguments.contains("-macWorkspaceInMemory"),
           arguments.contains("-macWorkspaceCaptureDir") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let fixture = NativeStoreBootstrap()
                guard let container = fixture.container else {
                    FileHandle.standardError.write(Data(("Workspace fixture: " + (fixture.error ?? "unavailable") + "\n").utf8))
                    return
                }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = "资产时光机 · 独立样例"
                let fixtureLanguage = AppLanguageStore()
                window.contentView = NSHostingView(rootView: NativeRootView(startsOffline: true, isWorkspaceFixtureHost: true)
                    .modelContainer(container).environmentObject(fixtureLanguage).environment(\.locale, fixtureLanguage.language.locale))
                window.contentMinSize = NSSize(width: NativeStyle.Layout.windowMinWidth, height: NativeStyle.Layout.windowMinHeight)
                window.center(); window.makeKeyAndOrderFront(nil)
                Self.workspaceFixtureWindow = window
                NSApp.activate(ignoringOtherApps: true)
            }
        }
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
            Group {
            if ProcessInfo.processInfo.arguments.contains("-macCloudRecovery") {
                if let container = store.container {
                    NativeCloudRecoveryView().modelContainer(container)
                } else {
                    Text(store.error ?? "无法备份本机数据库").padding(30)
                }
            } else if AppPreviewSession.isActive, store.container == nil {
                VStack(spacing: 14) {
                    Text("选择独立性能测试文件夹").font(NativeStyle.FontRole.sectionStrong)
                    Text("仅访问指定的测试数据与测量结果，不读取或同步账户数据。")
                        .font(NativeStyle.FontRole.body).foregroundStyle(NativePalette.secondary)
                    Button("选择测试文件夹") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let directory = panel.url {
                            do {
                                try NativeStoreBootstrap.grantPerformanceAccess(to: directory)
                                store = NativeStoreBootstrap()
                            } catch { NSLog("[NativeMac] test access failed: %@", error.localizedDescription) }
                        }
                    }
                }.padding(NativeStyle.Space.page)
            } else if let container = store.container {
                NativeRootView(startsOffline: startsOffline)
                    .modelContainer(container)
                    .frame(minWidth: NativeStyle.Layout.windowMinWidth, minHeight: NativeStyle.Layout.windowMinHeight)
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
            .environmentObject(languageStore)
            .environment(\.locale, languageStore.language.locale)
            .onAppear { applyAppearance() }
            .onChange(of: appearanceMode) { _, _ in applyAppearance() }
        }
        .defaultSize(width: 820, height: 620)
    }

    private func applyAppearance() {
        guard !AppPreviewSession.isActive else { return }
        switch appearanceMode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

@MainActor
final class NativeDraftApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NativeDraftWindowProtection.confirmAllWindows() ? .terminateNow : .terminateCancel
    }
}

/// Preserve SwiftUI's window delegate while adding the same save decision to close and quit.
struct NativeDraftWindowProtection: NSViewRepresentable {
    let hasChanges: () -> Bool
    let save: () -> Bool
    let discard: () -> Void
    @MainActor private static let windows = NSHashTable<Coordinator>.weakObjects()

    @MainActor static func confirmAllWindows() -> Bool {
        for coordinator in windows.allObjects where coordinator.window != nil {
            if !coordinator.confirmChanges() { return false }
        }
        return true
    }

    final class Anchor: NSView {
        weak var owner: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            owner?.attach(to: window)
        }
    }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        var protection: NativeDraftWindowProtection
        weak var window: NSWindow?
        weak var previousDelegate: (any NSWindowDelegate)?
        private var isConfirming = false
        private var isCheckingClose = false
        private var isForwarding = false

        init(_ protection: NativeDraftWindowProtection) { self.protection = protection }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else { return }
            // SwiftUI may wrap an installed delegate. Reinstalling into that same
            // window would capture the wrapper that already forwards back to us.
            guard window !== newWindow else { return }
            detach()
            window = newWindow
            if let previous = newWindow.delegate as? Coordinator {
                previousDelegate = previous.previousDelegate
            } else { previousDelegate = newWindow.delegate }
            newWindow.delegate = self
            NativeDraftWindowProtection.windows.add(self)
        }

        func detach() {
            if let window, window.delegate === self { window.delegate = previousDelegate }
            NativeDraftWindowProtection.windows.remove(self)
            window = nil
        }

        func confirmChanges() -> Bool {
            guard !isConfirming else { return false }
            window?.makeFirstResponder(nil)
            guard protection.hasChanges() else { return true }
            isConfirming = true
            defer { isConfirming = false }
            window?.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.messageText = AppLocalization.string("保存未完成的修改？")
            alert.informativeText = AppLocalization.string("关闭后，未保存的修改将丢失。")
            alert.addButton(withTitle: AppLocalization.string("保存更改"))
            alert.addButton(withTitle: AppLocalization.string("放弃修改"))
            let cancel = alert.addButton(withTitle: AppLocalization.string("取消"))
            cancel.keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn: return protection.save()
            case .alertSecondButtonReturn: protection.discard(); return true
            default: return false
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !isCheckingClose else { return true }
            isCheckingClose = true
            defer { isCheckingClose = false }
            return confirmChanges() && (previousDelegate?.windowShouldClose?(sender) ?? true)
        }

        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            guard !isForwarding, previousDelegate !== self else { return false }
            isForwarding = true
            defer { isForwarding = false }
            return previousDelegate?.responds(to: selector) ?? false
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            guard !isForwarding, previousDelegate !== self else { return nil }
            isForwarding = true
            defer { isForwarding = false }
            if previousDelegate?.responds(to: selector) == true { return previousDelegate }
            return super.forwardingTarget(for: selector)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor(); anchor.owner = context.coordinator
        return anchor
    }
    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.protection = self
        context.coordinator.attach(to: view.window)
    }
    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) { coordinator.detach() }
}

private struct NativeCloudRecoveryView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var cloud = AssetTimeMachineCloudStore()
    @State private var archived = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("核对手机与 Mac 数据").font(NativeStyle.FontRole.dialogTitle)
            Text(ProcessInfo.processInfo.arguments.contains("-macRecoverFromCloud")
                 ? "本机记录已备份。将以已核对的手机云端版本更新 Mac，不上传资产数据。"
                 : "本机记录已备份。请登录手机使用的同一个账户，读取云端历史。此页面不会上传或恢复资产数据。")
                .font(NativeStyle.FontRole.body).foregroundStyle(NativePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !archived {
                #if ATM_DIRECT_DISTRIBUTION
                NativeWebLoginButton(cloud: cloud) { archived = await cloud.archiveRecovery() }
                    .frame(height: 36)
                #else
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
                #endif
                if cloud.hasToken {
                    Button("重新读取云端历史") {
                        Task { archived = await cloud.archiveRecovery() }
                    }
                }
            }
            if let message = cloud.statusMessage { Text(message).font(NativeStyle.FontRole.body) }
            if let error = cloud.errorMessage { Text(error).font(NativeStyle.FontRole.body).foregroundStyle(AssetTheme.negative) }
        }
        .padding(NativeStyle.Space.page)
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
