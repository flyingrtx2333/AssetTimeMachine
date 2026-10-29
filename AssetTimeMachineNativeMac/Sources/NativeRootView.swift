import AppKit
import AuthenticationServices
import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum NativePage: String, CaseIterable, Identifiable {
    case home = "首页", records = "记录", timeMachine = "时光机", quant = "量化", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: "house"
        case .records: "square.and.pencil"
        case .timeMachine: "clock.arrow.circlepath"
        case .quant: "chart.xyaxis.line"
        case .settings: "gearshape"
        }
    }
}

private final class NativePreviewTokenStore: CloudTokenStore {
    func loadAccessToken() -> String? { nil }
    func loadRefreshToken() -> String? { nil }
    func save(accessToken: String, refreshToken: String?) throws {}
    func clear() throws {}
}

/// Test-only presentation barrier: includes the SwiftUI update and AppKit drawing turn.
private final class NativeHoverSamples: ObservableObject {
    var milliseconds: [Double] = []
}

private struct NativeHoverPresentationProbe: NSViewRepresentable {
    let startedAt: UInt64
    let samples: NativeHoverSamples

    final class ProbeView: NSView {
        var startedAt: UInt64 = 0
        var lastRequest: UInt64 = 0
        var samples: NativeHoverSamples?
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard startedAt != 0 else { return }
            samples?.milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            startedAt = 0
        }
    }

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        guard startedAt != 0, view.lastRequest != startedAt else { return }
        view.lastRequest = startedAt
        view.samples = samples
        view.startedAt = startedAt
        view.needsDisplay = true
    }
}

@MainActor
final class NativeHistoryModel: ObservableObject {
    @Published private(set) var summaries: [TimeMachineSnapshotProjection] = []
    @Published private(set) var generation = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var requestedRevision: UInt64?

    func load(from container: ModelContainer, force: Bool = false) async {
        let revision = ModelStoreRevisionClock.shared.currentRevision()
        if !force, requestedRevision == revision { return }
        requestedRevision = revision
        loading = true
        error = nil
        do {
            summaries = try await BackgroundTaskWork.run {
                try await MacSnapshotSummaryCache.shared.projections(in: container, revision: revision)
            }
            guard NativeStaticTrendCanvas.validatesExtrema(summaries) else {
                throw NSError(domain: "NativeTrendSampler", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "历史曲线采样校验失败"])
            }
            generation &+= 1
        } catch {
            self.error = error.localizedDescription
            requestedRevision = nil
        }
        loading = false
    }
}

struct NativeRootView: View {
    let startsOffline: Bool
    var isWorkspaceFixtureHost = false
    @Environment(\.modelContext) private var context
    @StateObject private var cloud = NativeRootView.makeCloudStore()
    @StateObject private var history = NativeHistoryModel()
    @StateObject private var quant = NativeQuantStore()
    @State private var page: NativePage = .home
    @State private var recordEditor = NativeRecordEditor()
    @State private var requestedRecord: NativeRecordDestination?
    @State private var showsAccountChoice = false
    @State private var showsCloudSync = false
    @State private var applicationIsActive = NSApp.isActive
    @State private var hasMadeAccountChoice = UserDefaults.standard.bool(forKey: "nativeMac.hasMadeAccountChoice")
    @Environment(\.scenePhase) private var scenePhase
    @State private var performanceTourStarted = false
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    private var reducedMotion: Bool {
        systemReducedMotion || (AppPreviewSession.isActive && ProcessInfo.processInfo.arguments.contains("-macHomeReduceMotion"))
    }

    private var allowsCloudRefresh: Bool {
        !AppPreviewSession.isActive && applicationIsActive && scenePhase == .active
            && cloud.hasToken && (!startsOffline || cloud.currentUser != nil)
    }

    private static func makeCloudStore() -> AssetTimeMachineCloudStore {
        guard AppPreviewSession.isActive else { return AssetTimeMachineCloudStore() }
        // Fixture tours must not read or migrate the signed-in user's credentials.
        let defaults = UserDefaults(suiteName: "com.flyingrtx.AssetTimeMachine.preview.\(UUID().uuidString)")!
        return AssetTimeMachineCloudStore(tokenStore: NativePreviewTokenStore(), defaults: defaults)
    }

    var body: some View {
        Group {
                    switch page {
                    case .home: NativeHomeView(history: history, cloud: cloud, openRecords: { page = .records }, openRecord: { id in
                        requestedRecord = .snapshot(id)
                        page = .records
                    }, openCloudSync: { showsCloudSync = true })
                    case .records: NativeRecordsView(history: history, cloud: cloud, editor: recordEditor, requestedDestination: $requestedRecord)
                    case .timeMachine: NativeTimeMachineView(history: history)
                    case .quant: NativeQuantView(store: quant)
                    case .settings: NativeSettingsView(history: history, cloud: cloud, openCloudSync: { showsCloudSync = true })
                    }
        }
        .disabled(cloud.isApplyingLocalData)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePalette.canvas)
        .transition(.opacity)
        .background {
            NativeWindowToolbar(page: $page, cloudSymbol: cloud.indicatorState.cloudSymbolName,
                cloudLabel: cloud.indicatorLabel, isEnabled: !cloud.isApplyingLocalData,
                openCloud: { showsCloudSync = true }, newRecord: {
                    requestedRecord = .today
                    page = .records
                }).frame(width: 0, height: 0)
            ForEach(NativePage.allCases) { destination in
                Button(destination.rawValue) { page = destination }
                    .keyboardShortcut(KeyEquivalent(Character(String((NativePage.allCases.firstIndex(of: destination) ?? 0) + 1))), modifiers: .command)
                    .disabled(cloud.isApplyingLocalData)
                    .hidden().accessibilityHidden(true).frame(width: 0, height: 0)
            }
        }
        .animation(NativeStyle.Motion.home(reducedMotion), value: page)
        .frame(minWidth: NativeStyle.Layout.windowMinWidth, minHeight: NativeStyle.Layout.windowMinHeight)
        .tint(NativePalette.accent)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-openQuantTab") { page = .quant }
            if ProcessInfo.processInfo.arguments.contains("-openCloudSync") { showsCloudSync = true }
            if AppPreviewSession.isActive {
                NSApplication.shared.activate(ignoringOtherApps: true)
                if ProcessInfo.processInfo.arguments.contains("-macHomeSmallWindow") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        if let window = NSApp.windows.first(where: { $0.isVisible }) {
                            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: NativeStyle.Layout.windowMinWidth, height: 620)), display: true)
                        }
                    }
                }
            }
        }
        .task {
            await history.load(from: context.container)
            let captureArgs = ProcessInfo.processInfo.arguments
            if AppPreviewSession.isActive, captureArgs.contains("-macWorkspaceInMemory"),
               let i = captureArgs.firstIndex(of: "-macQuantProbe"), captureArgs.indices.contains(i + 1) {
                guard isWorkspaceFixtureHost else { return }
                let proof = await NativeQuantProbe.run(store: quant, context: context, fixture: URL(fileURLWithPath: captureArgs[i + 1]))
                if let data = try? JSONSerialization.data(withJSONObject: proof) {
                    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
                }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { page = .quant }
                if let window = NSApp.windows.first(where: { $0.title == "资产时光机 · 独立样例" }) {
                    await NativeQuantProbe.capture(window: window, store: quant)
                }
                return
            }
            if AppPreviewSession.isActive,
               let i = captureArgs.firstIndex(of: "-macWorkspaceCaptureDir"), captureArgs.indices.contains(i + 1) {
                if captureArgs.contains("-macWorkspaceInMemory") && !isWorkspaceFixtureHost { return }
                await captureWorkspace(to: URL(fileURLWithPath: captureArgs[i + 1], isDirectory: true))
            }
            let recordArguments = ProcessInfo.processInfo.arguments
            if AppPreviewSession.isActive,
               let index = recordArguments.firstIndex(of: "-macCloudSyncProbe"), recordArguments.indices.contains(index + 1) {
                let result = await NativeCloudSyncProbe.run()
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data([10]))
                    try? data.write(to: URL(fileURLWithPath: recordArguments[index + 1]))
                }
                return
            }
            if AppPreviewSession.isActive,
               let index = recordArguments.firstIndex(of: "-macRecordEditorProbe"),
               recordArguments.indices.contains(index + 1) {
                let result = NativeRecordEditorProbe.run(container: context.container)
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: recordArguments[index + 1]))
                }
                await history.load(from: context.container, force: true)
                page = .records
            } else if AppPreviewSession.isActive && recordArguments.contains("-macRecordsPreview") {
                page = .records
            }
            if !AppPreviewSession.isActive && !startsOffline {
                if !hasMadeAccountChoice && !cloud.hasToken { showsAccountChoice = true }
            }
            if ProcessInfo.processInfo.arguments.contains("-macPerfAutoBrowse"), !performanceTourStarted {
                performanceTourStarted = true
                Task { await runPerformanceTour() }
            }
            let arguments = ProcessInfo.processInfo.arguments
            if AppPreviewSession.isActive,
               let index = arguments.firstIndex(of: "-macPerfMutationOutput"),
               arguments.indices.contains(index + 1),
               let importIndex = arguments.firstIndex(of: "-macPerfImportJSON"),
               arguments.indices.contains(importIndex + 1) {
                let outcome = await NativeMutationProbe.run(
                    context: context, history: history,
                    importJSON: URL(fileURLWithPath: arguments[importIndex + 1])
                )
                if let data = try? JSONSerialization.data(withJSONObject: outcome, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: arguments[index + 1]))
                }
            }
            if AppPreviewSession.isActive,
               let index = arguments.firstIndex(of: "-macPerfVideoOutput"),
               arguments.indices.contains(index + 1) {
                let destination = URL(fileURLWithPath: arguments[index + 1])
                do {
                    let temporary = try await NativeTrendVideoExporter.export(history.summaries)
                    try FileManager.default.copyItem(at: temporary, to: destination)
                    try? FileManager.default.removeItem(at: temporary)
                } catch {
                    NSLog("[NativeMac] video probe failed: %@", String(describing: error))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            applicationIsActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            applicationIsActive = false
        }
        .onChange(of: allowsCloudRefresh, initial: true) { _, active in
            if !AppPreviewSession.isActive { cloud.setAutomaticSyncActive(active) }
        }
        .task(id: allowsCloudRefresh) {
            guard allowsCloudRefresh else { return }
            while !Task.isCancelled {
                if !cloud.isWorking && !cloud.requiresLocalOwnershipConfirmation {
                    await cloud.refreshIfNeeded(from: context)
                }
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
        .onChange(of: cloud.localDataRevision) { _, _ in
            Task {
                await history.load(from: context.container, force: true)
                NSLog("[NativeMac] cloud records refreshed count=%ld latest=%@", history.summaries.count,
                      history.summaries.last?.date.ISO8601Format() ?? "none")
            }
        }
        .onChange(of: cloud.lastSyncAt) { _, date in
            guard let date else { return }
            NSLog("[NativeMac] cloud backup applied uploaded=%@", date.ISO8601Format())
        }
        .sheet(isPresented: $showsAccountChoice) {
            NativeAccountChoice(cloud: cloud) {
                hasMadeAccountChoice = true
                UserDefaults.standard.set(true, forKey: "nativeMac.hasMadeAccountChoice")
                showsAccountChoice = false
            }
            .environment(\.modelContext, context)
        }
        .sheet(isPresented: $showsCloudSync) {
            NativeCloudSyncView(cloud: cloud)
                .environment(\.modelContext, context)
        }
    }

    // Isolated fixture-only native capture: never operates an authenticated account.
    private func captureWorkspace(to directory: URL) async {
        let stdoutCapture = ProcessInfo.processInfo.arguments.contains("-macWorkspaceCaptureStdout")
        if !stdoutCapture {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { NSLog("[WorkspaceCapture] directory: %@", error.localizedDescription); return }
        }
        try? await Task.sleep(for: .milliseconds(700))
        guard let window = NSApp.windows.first(where: { $0.title == "资产时光机 · 独立样例" })
                ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        let small = ProcessInfo.processInfo.arguments.contains("-macHomeSmallWindow")
        let args = ProcessInfo.processInfo.arguments
        func dimension(_ key: String, fallback: CGFloat) -> CGFloat {
            guard let i = args.firstIndex(of: key), args.indices.contains(i + 1),
                  let value = Double(args[i + 1]), value.isFinite else { return fallback }
            return max(key == "-macCaptureWidth" ? NativeStyle.Layout.windowMinWidth : 620, CGFloat(value))
        }
        window.setFrame(NSRect(origin: window.frame.origin,
            size: NSSize(width: dimension("-macCaptureWidth", fallback: small ? NativeStyle.Layout.windowMinWidth : 820),
                         height: dimension("-macCaptureHeight", fallback: small ? 620 : 660))), display: true)
        if ProcessInfo.processInfo.arguments.contains("-macCloudCapture") {
            let originalPage = page
            cloud.currentUser = AssetTimeMachineCloudUser(id: 42, userName: "示例账户", userEmail: nil)
            let now = Date()
            cloud.lastSyncAt = now
            cloud.backups = (0..<3).map { index in
                AssetTimeMachineCloudBackup(id: 3 - index, fileName: nil, fileSize: 2_200_000,
                    storageURL: nil, uploadedAt: now.addingTimeInterval(Double(-index) * 3600),
                    lastDownloadedAt: nil, isLatest: index == 0 ? 1 : 0, note: nil)
            }
            // Presentation fixtures use an isolated store; they never submit credentials or backups.
            if args.contains("-macCloudSyncingCapture") { cloud.isWorking = true }
            if args.contains("-macCloudErrorCapture") {
                cloud.errorMessage = URLError(.notConnectedToInternet).localizedDescription
            }
            showsCloudSync = true
            try? await Task.sleep(for: .seconds(1))
            if let view = window.attachedSheet?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]),
                   let encoded = try? JSONSerialization.data(withJSONObject: [
                    "page": "cloud", "png": data.base64EncodedString(),
                    "keptCurrentPage": page == originalPage,
                    "fixtureOnly": true
                   ]) {
                    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
                }
            }
            return
        }
        if AppPreviewSession.isActive, ProcessInfo.processInfo.arguments.contains("-macLoginCapture") {
            if args.contains("-macLoginErrorCapture") {
                cloud.errorMessage = URLError(.cannotConnectToHost).localizedDescription
            }
            page = .settings
            try? await Task.sleep(for: .seconds(1))
            if let view = window.attachedSheet?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]),
                   let encoded = try? JSONSerialization.data(withJSONObject: ["page": "login", "png": data.base64EncodedString()]) {
                    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
                }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-macWorkspaceEditorCheck") {
            let result = NativeRecordEditorProbe.run(container: context.container)
            if let encoded = try? JSONSerialization.data(withJSONObject: ["recordEditorChecks": result]) {
                FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
            }
            await history.load(from: context.container, force: true)
            recordEditor.load(id: history.summaries.last?.id, container: context.container)
        }
        for destination in [NativePage.records, .timeMachine, .quant, .settings, .home] {
            page = destination
            try? await Task.sleep(for: .milliseconds(850))
            if let data = NativeWindowCapture.png(window) {
                if stdoutCapture {
                    let record = ["page": destination.rawValue, "png": data.base64EncodedString()]
                    if let encoded = try? JSONSerialization.data(withJSONObject: record) {
                        FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
                    }
                } else {
                    do { try data.write(to: directory.appending(path: "\(destination.rawValue).png"), options: .atomic) }
                    catch { NSLog("[WorkspaceCapture] file: %@", error.localizedDescription) }
                }
            }
        }
        page = .records

    }
    private func runPerformanceTour() async {
        let arguments = ProcessInfo.processInfo.arguments
        let rounds: Int = {
            guard let index = arguments.firstIndex(of: "-macPerfContinuousRounds"),
                  arguments.indices.contains(index + 1) else { return 1 }
            return min(max(Int(arguments[index + 1]) ?? 1, 1), 10)
        }()
        for round in 1...rounds {
            for destination in [NativePage.records, .timeMachine, .quant, .settings, .home] {
                page = destination
                try? await Task.sleep(for: destination == .timeMachine ? .seconds(5) : .seconds(1))
            }
            if let index = arguments.firstIndex(of: "-macPerfRoundMarkerPrefix"),
               arguments.indices.contains(index + 1) {
                try? "finished".write(toFile: "\(arguments[index + 1])-\(round).done",
                                      atomically: true, encoding: .utf8)
            }
            if round < rounds { try? await Task.sleep(for: .seconds(32)) }
        }
        if let index = arguments.firstIndex(of: "-macPerfCompletePath"), arguments.indices.contains(index + 1) {
            try? "finished".write(toFile: arguments[index + 1], atomically: true, encoding: .utf8)
        }
    }

}

/// AppKit owns the window chrome, so preview windows and restored application windows
/// share the same real toolbar without adding a second header to every page.
private struct NativeWindowToolbar: NSViewRepresentable {
    @Binding var page: NativePage
    let cloudSymbol: String
    let cloudLabel: String
    let isEnabled: Bool
    let openCloud: () -> Void
    let newRecord: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.owner = self
        if let window = view.window { context.coordinator.attach(to: window) }
        context.coordinator.update()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
        if coordinator.window?.toolbar === coordinator.toolbar { coordinator.window?.toolbar = nil }
    }

    final class Anchor: NSView {
        weak var coordinator: Coordinator?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator?.attach(to: window) }
        }
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        static let brand = NSToolbarItem.Identifier("native.workspace.brand")
        static let navigation = NSToolbarItem.Identifier("native.workspace.navigation")
        static let cloud = NSToolbarItem.Identifier("native.workspace.cloud")
        static let add = NSToolbarItem.Identifier("native.workspace.add")
        var owner: NativeWindowToolbar
        weak var window: NSWindow?
        let toolbar = NSToolbar(identifier: "native.workspace.toolbar")
        private var navigation: NSSegmentedControl?
        private var cloud: NSButton?
        private var add: NSButton?

        init(_ owner: NativeWindowToolbar) {
            self.owner = owner
            super.init()
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.sizeMode = .regular
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
        }
        func attach(to window: NSWindow) {
            guard self.window !== window || window.toolbar !== toolbar else { update(); return }
            self.window = window
            window.toolbarStyle = .unifiedCompact
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .line
            window.toolbar = toolbar
            update()
        }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.brand, .flexibleSpace, Self.navigation, .flexibleSpace, Self.cloud, Self.add]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.isBordered = false
            if #available(macOS 26.0, *) { item.style = .plain }
            switch identifier {
            case Self.brand:
                let mark = NSImageView(image: NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)!)
                mark.imageScaling = .scaleProportionallyDown
                mark.translatesAutoresizingMaskIntoConstraints = false
                mark.widthAnchor.constraint(equalToConstant: 16).isActive = true
                mark.heightAnchor.constraint(equalToConstant: 16).isActive = true
                let title = NSTextField(labelWithString: AppLocalization.string("资产时光机"))
                title.font = .systemFont(ofSize: 13, weight: .medium)
                let stack = NSStackView(views: [mark, title])
                stack.spacing = 6; stack.alignment = .centerY
                stack.frame = NSRect(x: 0, y: 0, width: 110, height: 28)
                item.view = stack
                item.visibilityPriority = .low
            case Self.navigation:
                let control = NSSegmentedControl(labels: NativePage.allCases.map { AppLocalization.string($0.rawValue) },
                    trackingMode: .selectOne, target: self, action: #selector(selectPage(_:)))
                control.segmentStyle = .rounded
                control.font = .systemFont(ofSize: 13)
                control.selectedSegmentBezelColor = NSColor(NativePalette.accent)
                for index in NativePage.allCases.indices { control.setWidth(58, forSegment: index) }
                control.frame = NSRect(x: 0, y: 0, width: 294, height: 28)
                control.setAccessibilityIdentifier("native.workspace.navigation")
                navigation = control; item.view = control
                item.visibilityPriority = .high
            case Self.cloud:
                item.label = AppLocalization.string("云同步")
                let button = NSButton(image: NSImage(systemSymbolName: owner.cloudSymbol, accessibilityDescription: AppLocalization.string("云同步"))!,
                                      target: self, action: #selector(showCloud))
                button.bezelStyle = .texturedRounded; button.isBordered = false
                button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
                cloud = button; item.view = button
                item.visibilityPriority = .high
            case Self.add:
                let button = NSButton(title: AppLocalization.string("新增记录"), target: self, action: #selector(createRecord))
                button.bezelStyle = .rounded; button.controlSize = .regular
                button.font = .systemFont(ofSize: 13, weight: .medium)
                button.bezelColor = NSColor(NativePalette.accent)
                button.frame = NSRect(x: 0, y: 0, width: 86, height: 28)
                add = button; item.view = button
                item.visibilityPriority = .high
                if #available(macOS 26.0, *) {
                    item.style = .prominent
                    item.backgroundTintColor = NSColor(NativePalette.accent)
                }
            default: return nil
            }
            update()
            return item
        }
        func update() {
            navigation?.selectedSegment = NativePage.allCases.firstIndex(of: owner.page) ?? 0
            navigation?.isEnabled = owner.isEnabled
            navigation?.selectedSegmentBezelColor = NSColor(NativePalette.accent)
            cloud?.image = NSImage(systemSymbolName: owner.cloudSymbol, accessibilityDescription: AppLocalization.string("云同步"))
            cloud?.toolTip = owner.cloudLabel
            cloud?.setAccessibilityLabel(AppLocalization.string("云同步") + "，" + owner.cloudLabel)
            cloud?.isEnabled = owner.isEnabled
            add?.isEnabled = owner.isEnabled
            add?.bezelColor = owner.page == .home ? NSColor(NativePalette.accent) : nil
            if #available(macOS 26.0, *), let item = toolbar.items.first(where: { $0.itemIdentifier == Self.add }) {
                item.style = owner.page == .home ? .prominent : .plain
                item.backgroundTintColor = owner.page == .home ? NSColor(NativePalette.accent) : nil
            }
        }
        @objc private func selectPage(_ sender: NSSegmentedControl) {
            guard owner.isEnabled, NativePage.allCases.indices.contains(sender.selectedSegment) else { return }
            owner.page = NativePage.allCases[sender.selectedSegment]
        }
        @objc private func showCloud() { if owner.isEnabled { owner.openCloud() } }
        @objc private func createRecord() { if owner.isEnabled { owner.newRecord() } }
    }
}

struct NativePageHeader: View {
    let title: String
    let subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(NativeStyle.FontRole.pageTitle)
            if let subtitle { Text(subtitle).font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NativePalette.surface, in: RoundedRectangle(cornerRadius: NativeStyle.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.panel).strokeBorder(NativePalette.line))
    }
}

private func money(_ value: Double) -> String {
    value.formatted(.currency(code: "CNY").precision(.fractionLength(2)))
}

private func displayDate(_ date: Date) -> String {
    date.formatted(Date.FormatStyle().year().month().day().locale(Locale(identifier: "zh_CN")))
}

struct NativeTimeMachineView: View {
    private struct DetailRow: Identifiable {
        let id: UUID
        let name: String
        let amount: Double
        let order: Int
        let icon: String?
        let group: AssetGroup?
    }
    @Environment(\.modelContext) private var context
    @ObservedObject var history: NativeHistoryModel
    @State private var selectedIndex: Int?
    @State private var hoveredIndex: Int?
    @State private var selectedSnapshot: AssetSnapshot?
    @State private var detailRows: [DetailRow] = []
    @State private var detailError: String?
    @State private var videoTask: Task<Void, Never>?
    @State private var isExportingVideo = false
    @State private var videoError: String?
    @State private var detailFetchSamples: [Double] = []
    @StateObject private var hoverSamples = NativeHoverSamples()
    @State private var hoverStartedAt: UInt64 = 0
    @State private var visibleMonths = 6
    @State private var chartData: [TimeMachineSnapshotProjection] = []
    @State private var chartStart = 0
    @State private var chartRevision = 0
    @State private var showsGoldEquivalent = false

    private var summaries: [TimeMachineSnapshotProjection] { history.summaries }
    private var activeIndex: Int? { hoveredIndex ?? selectedIndex }
    private var active: TimeMachineSnapshotProjection? {
        guard let activeIndex, summaries.indices.contains(activeIndex) else { return nil }
        return summaries[activeIndex]
    }
    private var chartSelectedIndex: Int? {
        guard let selectedIndex else { return nil }
        let translated = selectedIndex - chartStart
        return chartData.indices.contains(translated) ? translated : nil
    }
    private var selectedNet: Double {
        guard let selectedIndex, summaries.indices.contains(selectedIndex) else { return 0 }
        return summaries[selectedIndex].totalAssets - summaries[selectedIndex].totalLiabilities
    }
    private var dateRailIndices: [Int] {
        guard !summaries.isEmpty else { return [] }
        let center = selectedIndex ?? summaries.count - 1
        let lower = max(0, min(center - 4, summaries.count - 9))
        return Array(lower..<min(lower + 9, summaries.count))
    }

    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Namespace private var dateSelection
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                            HStack(spacing: NativeStyle.Space.sm) {
                                Button { stepDate(-1) } label: { Image(systemName: "chevron.left") }
                                    .disabled((selectedIndex ?? 0) <= 0)
                                Text(active.map { displayDate($0.date) } ?? "选择日期").font(NativeStyle.FontRole.body).monospacedDigit()
                                Button { stepDate(1) } label: { Image(systemName: "chevron.right") }
                                    .disabled(summaries.isEmpty || (selectedIndex ?? 0) >= summaries.count - 1)
                            }.controlSize(.small)
                        Spacer()
                        if history.loading || isExportingVideo { ProgressView().controlSize(.small) }
                        Picker("时间范围", selection: $visibleMonths) {
                            Text("近6个月").tag(6); Text("近1年").tag(12); Text("近5年").tag(60); Text("全部").tag(1200)
                        }.labelsHidden().frame(width: 120)
                        Button("导出视频", systemImage: "play.rectangle") { startVideoExport() }
                            .modifier(NativeWorkspacePrimary()).disabled(isExportingVideo || summaries.count < 2)
                    }.frame(height: NativeStyle.Control.height)
                    HStack(spacing: NativeStyle.Space.section) {
                        NativeWorkspaceMetric(title: "净资产", value: (active?.totalAssets ?? 0) - (active?.totalLiabilities ?? 0), primary: true)
                        NativeWorkspaceMetric(title: "总资产", value: active?.totalAssets ?? 0)
                        NativeWorkspaceMetric(title: "负债", value: active?.totalLiabilities ?? 0)
                        NativeWorkspaceMetric(title: "较上次", value: activeDifference)
                    }
                    HStack(spacing: 16) {
                        Label { Text("总资产") } icon: { Circle().fill(NativePalette.chartSecondary).frame(width: 6, height: 6) }
                        Label { Text("净资产") } icon: { Circle().fill(NativePalette.accent).frame(width: 6, height: 6) }
                        Toggle(isOn: $showsGoldEquivalent) {
                            HStack(spacing: 6) {
                                Circle().fill(AssetTheme.positive).frame(width: 6, height: 6)
                                Text(AppLocalization.string("等值黄金"))
                                if showsGoldEquivalent {
                                    Text(active.flatMap(NativeGoldEquivalentPlot.value)
                                        .map { $0.formatted(.number.precision(.fractionLength(0...4))) + " g" } ?? "—")
                                        .monospacedDigit()
                                }
                            }
                        }.toggleStyle(.button).tint(NativePalette.accent).controlSize(.small)
                    }.font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                    NativePanoramaTrend(summaries: chartData, revision: "\(chartRevision)",
                        showsGoldEquivalent: showsGoldEquivalent, selection: chartSelectedIndex,
                        onHover: { local in hoveredIndex = local.map { $0 + chartStart } },
                        onSelect: { selectedIndex = $0 + chartStart; hoveredIndex = nil })
                        .frame(height: min(240, max(160, geometry.size.height * 0.3)))
                    HStack(spacing: NativeStyle.Space.xxs) {
                        ForEach(dateRailIndices, id: \.self) { index in
                            Button { selectedIndex = index; hoveredIndex = nil } label: {
                                Text(dateRailLabel(at: index)).font(NativeStyle.FontRole.caption).lineLimit(1).minimumScaleFactor(0.75)
                                    .frame(maxWidth: .infinity).frame(height: NativeStyle.Control.height)
                                    .foregroundStyle(selectedIndex == index ? NativeHomeStyle.accent : NativeHomeStyle.secondary)
                                    .overlay(alignment: .bottom) {
                                        if selectedIndex == index {
                                            if reducedMotion || NativeHomeStyle.previewReduced { Rectangle().fill(NativeHomeStyle.accent).frame(height: 1) }
                                            else { Rectangle().fill(NativeHomeStyle.accent).frame(height: 1).matchedGeometryEffect(id: "date", in: dateSelection) }
                                        }
                                    }
                            }.help(money(summaries[index].totalAssets - summaries[index].totalLiabilities))
                                .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
                        }
                    }
                    Divider()
                    HStack {
                        Text("当天资产明细").font(NativeStyle.FontRole.section)
                        Spacer()
                        Text("\(detailRows.count) 项").font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                    }
                    LazyVStack(spacing: 0) {
                        if selectedSnapshot != nil {
                            ForEach(detailRows) { entry in
                                NativeHomeHoverRow {
                                    HStack {
                                        NativeAssetIcon(key: entry.icon, group: entry.group, title: entry.name)
                                        Text(entry.name).lineLimit(2)
                                        Spacer()
                                        Text(money(entry.amount)).monospacedDigit()
                                    }.font(NativeStyle.FontRole.body).frame(minHeight: NativeStyle.Layout.ledgerRowHeight)
                                }
                                Divider()
                            }
                        } else {
                            Text(detailError ?? "选择日期查看明细").foregroundStyle(NativePalette.secondary)
                        }
                    }
                    if let detailError { Text(detailError).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.accentOrange) }
                    if let videoError { Text(videoError).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.accentOrange) }
                }.padding(NativeStyle.Layout.pageInset)
            }
        }.modifier(NativeWorkspaceSurface())
        .animation(NativeStyle.Motion.home(reducedMotion || NativeHomeStyle.previewReduced), value: selectedIndex)
        .animation(NativeStyle.Motion.home(reducedMotion || NativeHomeStyle.previewReduced), value: isExportingVideo)
        .overlay(alignment: .topLeading) {
            if AppPreviewSession.isActive,
               ProcessInfo.processInfo.arguments.contains("-macPerfInteractionOutput") {
                NativeHoverPresentationProbe(startedAt: hoverStartedAt, samples: hoverSamples)
                    .frame(width: 1, height: 1).allowsHitTesting(false)
            }
        }
        .onChange(of: selectedIndex) { _, newIndex in loadDetail(at: newIndex) }
        .onChange(of: visibleMonths) { _, _ in rebuildChartData() }
        .onChange(of: history.generation) { _, _ in rebuildChartData() }
        .onChange(of: summaries.count) { _, count in
            if selectedIndex == nil, count > 0 { selectedIndex = count - 1 }
        }
        .onAppear {
            rebuildChartData()
            if selectedIndex == nil, !summaries.isEmpty { selectedIndex = summaries.count - 1 }
        }
        .onDisappear {
            selectedSnapshot = nil
            detailRows = []
            chartData = []
            hoveredIndex = nil
            videoTask?.cancel()
            videoTask = nil
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-macPerfAutoBrowse"), summaries.count > 1 else { return }
            visibleMonths = 1200
            try? await Task.sleep(for: .milliseconds(100))
            let step = max(1, summaries.count / 150)
            for (position, index) in stride(from: 0, to: summaries.count, by: step).enumerated() {
                guard !Task.isCancelled else { break }
                hoverStartedAt = DispatchTime.now().uptimeNanoseconds
                hoveredIndex = index
                if position.isMultiple(of: 15) { selectedIndex = index }
                try? await Task.sleep(for: .milliseconds(15))
            }
            hoveredIndex = nil
            selectedIndex = summaries.count - 1
            try? await Task.sleep(for: .milliseconds(100))
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-macPerfInteractionOutput"),
               arguments.indices.contains(index + 1), !detailFetchSamples.isEmpty {
                let sorted = detailFetchSamples.sorted()
                let position = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
                var result: [String: Double] = [
                    "detailFetchP95Milliseconds": sorted[position],
                    "sampleCount": Double(sorted.count)
                ]
                let hover = hoverSamples.milliseconds.sorted()
                if !hover.isEmpty {
                    let p95 = min(hover.count - 1, Int(ceil(Double(hover.count) * 0.95)) - 1)
                    result["hoverPresentationP95Milliseconds"] = hover[p95]
                    result["hoverSampleCount"] = Double(hover.count)
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: arguments[index + 1]))
                }
            }
        }
    }
    private var activeDifference: Double {
        guard let index = activeIndex, index > 0 else { return 0 }
        let current = summaries[index], previous = summaries[index - 1]
        return current.totalAssets - current.totalLiabilities - previous.totalAssets + previous.totalLiabilities
    }
    private func stepDate(_ delta: Int) {
        guard !summaries.isEmpty else { return }
        selectedIndex = min(summaries.count - 1, max(0, (selectedIndex ?? summaries.count - 1) + delta))
        hoveredIndex = nil
    }
    private func rebuildChartData() {
        chartRevision &+= 1
        hoveredIndex = nil
        guard !summaries.isEmpty else {
            chartStart = 0
            chartData = []
            return
        }
        chartStart = chartStartIndex
        chartData = Array(summaries[chartStart...])
    }
    private var chartStartIndex: Int {
        guard let last = summaries.last else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .month, value: -visibleMonths, to: last.date) ?? .distantPast
        var lower = 0
        var upper = summaries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if summaries[middle].date < cutoff { lower = middle + 1 } else { upper = middle }
        }
        return min(lower, summaries.count - 1)
    }
    private func reportRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(NativePalette.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(NativeStyle.FontRole.caption)
    }
    private func dateRailLabel(at index: Int) -> String {
        let day = summaries[index].date
        let repeated = (index > 0 && Calendar.current.isDate(day, inSameDayAs: summaries[index - 1].date))
            || (index + 1 < summaries.count && Calendar.current.isDate(day, inSameDayAs: summaries[index + 1].date))
        if repeated { return day.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()) }
        return day.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
    private func loadDetail(at index: Int?) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            if AppPreviewSession.isActive, ProcessInfo.processInfo.arguments.contains("-macPerfInteractionOutput") {
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                detailFetchSamples.append(Double(elapsed) / 1_000_000)
            }
        }
        selectedSnapshot = nil
        detailRows = []
        detailError = nil
        guard let index, summaries.indices.contains(index) else { return }
        let id = summaries[index].id
        do {
            var descriptor = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            selectedSnapshot = try context.fetch(descriptor).first
            if let selectedSnapshot {
                let amounts = PortfolioCalculator.metrics(for: selectedSnapshot)
                let summary = summaries[index]
                if abs(amounts.totalAssets - summary.totalAssets) > 0.01
                    || abs(amounts.totalLiabilities - summary.totalLiabilities) > 0.01 {
                    detailError = "所选日期明细与历史汇总不一致，请重新载入。"
                    self.selectedSnapshot = nil
                } else {
                    detailRows = selectedSnapshot.entries
                        .filter { abs($0.resolvedAmount) > 0.005 }
                        .map { DetailRow(id: $0.id, name: $0.item?.name ?? "未知资产",
                                         amount: $0.resolvedAmount, order: $0.item?.sortOrder ?? 0,
                                         icon: $0.item.map { AssetItemService.resolvedIconKey(for: $0) }, group: $0.item?.category?.group) }
                        .sorted { $0.order < $1.order }
                }
            }
        } catch { detailError = error.localizedDescription }
    }

    private func startVideoExport() {
        guard videoTask == nil else { return }
        videoError = nil
        isExportingVideo = true
        let source = summaries
        videoTask = Task {
            do {
                let temporaryURL = try await NativeTrendVideoExporter.export(source)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                try Task.checkCancellation()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.mpeg4Movie]
                panel.nameFieldStringValue = "资产时光机趋势.mp4"
                if panel.runModal() == .OK, let destination = panel.url {
                    try FileManager.default.copyItem(at: temporaryURL, to: destination)
                    NSWorkspace.shared.open(destination)
                }
            } catch is CancellationError {
                // Leaving Time Machine cancels video generation and releases its frame buffers.
            } catch {
                videoError = error.localizedDescription
            }
            isExportingVideo = false
            videoTask = nil
        }
    }
}

struct NativeStaticTrendCanvas: View, Equatable {
    let summaries: [TimeMachineSnapshotProjection]
    let revision: UInt64
    private let gold = NativePalette.chartSecondary
    private let green = NativePalette.accent

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
            && lhs.summaries.count == rhs.summaries.count
            && lhs.summaries.first?.id == rhs.summaries.first?.id
            && lhs.summaries.last?.id == rhs.summaries.last?.id
    }

    var body: some View {
        Canvas { graphics, size in
            guard summaries.count > 1 else { return }
            let sampled = Self.sample(summaries, limit: 600)
            let allValues = sampled.flatMap { [$0.element.totalAssets, $0.element.totalAssets - $0.element.totalLiabilities] }
            let low = (allValues.min() ?? 0) * 0.95
            let high = max((allValues.max() ?? 1) * 1.05, low + 1)
            let start = summaries[0].date.timeIntervalSinceReferenceDate
            let end = summaries[summaries.count - 1].date.timeIntervalSinceReferenceDate
            let plot = CGRect(x: 48, y: 6, width: max(size.width - 56, 1), height: max(size.height - 30, 1))
            for tick in 0...3 {
                let fraction = Double(tick) / 3
                let y = plot.maxY - fraction * plot.height
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                graphics.stroke(grid, with: .color(.secondary.opacity(0.22)), lineWidth: 0.7)
                let amount = low + fraction * (high - low)
                let label = amount.formatted(.number.notation(.compactName).precision(.fractionLength(0)))
                graphics.draw(Text(label).font(NativeStyle.FontRole.chartLabel).foregroundStyle(NativePalette.secondary),
                              at: CGPoint(x: 0, y: y), anchor: .leading)
            }
            for tick in 0...3 {
                let ratio = Double(tick) / 3
                let x = plot.minX + ratio * plot.width
                let date = Date(timeIntervalSinceReferenceDate: start + ratio * (end - start))
                graphics.draw(Text(date.formatted(.dateTime.month(.abbreviated).year()))
                    .font(NativeStyle.FontRole.chartLabel).foregroundStyle(NativePalette.secondary),
                              at: CGPoint(x: x, y: plot.maxY + 11),
                              anchor: tick == 0 ? .leading : (tick == 3 ? .trailing : .center))
            }
            func point(_ entry: (offset: Int, element: TimeMachineSnapshotProjection), net: Bool) -> CGPoint {
                let x = plot.minX + (entry.element.date.timeIntervalSinceReferenceDate - start)
                    / max(end - start, 1) * plot.width
                let value = net ? entry.element.totalAssets - entry.element.totalLiabilities : entry.element.totalAssets
                return CGPoint(x: x, y: plot.maxY - (value - low) / (high - low) * plot.height)
            }
            for net in [false, true] {
                var path = Path()
                for (position, entry) in sampled.enumerated() {
                    let p = point(entry, net: net)
                    if position == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                graphics.stroke(path, with: .color(net ? green : gold), lineWidth: 1.6)
            }
        }
    }

    /// Keeps the first, last, and both extrema of each bucket; at most 600 points.
    static func validatesExtrema(_ source: [TimeMachineSnapshotProjection]) -> Bool {
        guard !source.isEmpty else { return true }
        let reduced = sample(source, limit: 600).map(\.element)
        guard reduced.count <= 600,
              reduced.first?.id == source.first?.id,
              reduced.last?.id == source.last?.id else { return false }
        let sourceAssets = source.map(\.totalAssets)
        let reducedAssets = reduced.map(\.totalAssets)
        let sourceNet = source.map { $0.totalAssets - $0.totalLiabilities }
        let reducedNet = reduced.map { $0.totalAssets - $0.totalLiabilities }
        return sourceAssets.min() == reducedAssets.min()
            && sourceAssets.max() == reducedAssets.max()
            && sourceNet.min() == reducedNet.min()
            && sourceNet.max() == reducedNet.max()
    }

    /// Keeps the first, last, and both extrema of each bucket; at most 600 points.
    static func sample(_ source: [TimeMachineSnapshotProjection], limit: Int) -> [EnumeratedSequence<[TimeMachineSnapshotProjection]>.Element] {
        if source.count <= limit { return Array(source.enumerated()) }
        let interior = source.count - 2
        let buckets = max(1, (limit - 2) / 4)
        var indices = [0]
        for bucket in 0..<buckets {
            let start = 1 + interior * bucket / buckets
            let end = min(source.count - 1, 1 + interior * (bucket + 1) / buckets)
            guard start < end else { continue }
            let slice = start..<end
            let assetsLow = slice.min(by: { source[$0].totalAssets < source[$1].totalAssets })!
            let assetsHigh = slice.max(by: { source[$0].totalAssets < source[$1].totalAssets })!
            let netLow = slice.min(by: { source[$0].totalAssets - source[$0].totalLiabilities < source[$1].totalAssets - source[$1].totalLiabilities })!
            let netHigh = slice.max(by: { source[$0].totalAssets - source[$0].totalLiabilities < source[$1].totalAssets - source[$1].totalLiabilities })!
            indices.append(contentsOf: Set([assetsLow, assetsHigh, netLow, netHigh]).sorted())
        }
        indices.append(source.count - 1)
        return indices.map { (offset: $0, element: source[$0]) }
    }
}
