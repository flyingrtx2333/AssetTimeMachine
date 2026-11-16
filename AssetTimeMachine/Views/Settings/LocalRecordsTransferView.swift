import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private struct LocalRecordsImportPreview: Identifiable {
    let id = UUID()
    let filename: String
    let payload: ExportPayload
}

struct LocalRecordsTransferView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.locale) private var locale
    @ObservedObject var cloudStore: AssetTimeMachineCloudStore
    @State private var showsImporter = false
    @State private var showsExporter = false
    @State private var document: CloudRecordsDocument?
    @State private var filename = "AssetTimeMachine"
    @State private var preview: LocalRecordsImportPreview?
    @State private var isBusy = false
    @State private var error: String?
    @State private var message: String?
    @State private var showsCloudSync = false

    var body: some View {
        List {
            Section {
                Button { exportBeforeImport(false) } label: {
                    Label(AppLocalization.string("导出 JSON"), systemImage: "square.and.arrow.up")
                }
                Button { showsImporter = true } label: {
                    Label(AppLocalization.string("从 JSON 恢复"), systemImage: "square.and.arrow.down")
                }
                if cloudStore.hasBeforeJSONImportBackup {
                    Button { exportBeforeImport(true) } label: {
                        Label(AppLocalization.string("导出恢复前备份"), systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .disabled(isBusy || cloudStore.isWorking)

            if isBusy { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(error).foregroundStyle(AssetTheme.negative) }
            if let message { Text(message).foregroundStyle(AssetTheme.positive) }
            if cloudStore.localRestoreNeedsCloudConfirmation {
                Section {
                    Text(AppLocalization.string("已恢复本机记录，云同步已暂停。请核对后重新关联。"))
                    Button(AppLocalization.string("云同步")) { showsCloudSync = true }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AssetTheme.background)
        .tint(AssetTheme.goldSoft)
        .navigationTitle(AppLocalization.string("本机备份与恢复"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isBusy)
        .toolbar(.visible, for: .navigationBar)
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-previewLocalImportPath"), args.indices.contains(i + 1) {
                prepareImport(URL(fileURLWithPath: args[i + 1]))
            }
        }
        #endif
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): prepareImport(url)
            case .failure(let failure): show(failure)
            }
        }
        .fileExporter(isPresented: $showsExporter, document: document, contentType: .json,
            defaultFilename: filename) { result in
                switch result {
                case .success: message = AppLocalization.string("备份已导出")
                case .failure(let failure): show(failure)
                }
            }
        .sheet(item: $preview) { candidate in
            NavigationStack {
                List {
                    Section {
                        Text(candidate.filename).font(.headline).textSelection(.enabled)
                        LabeledContent(AppLocalization.string("资产项目"), value: String(candidate.payload.items.count))
                        LabeledContent(AppLocalization.string("历史记录"), value: String(candidate.payload.snapshots.count))
                        if let first = candidate.payload.snapshots.map(\.date).min(),
                           let last = candidate.payload.snapshots.map(\.date).max() {
                            Text(first.formatted(.dateTime.year().month().day().locale(locale)) + " – "
                                + last.formatted(.dateTime.year().month().day().locale(locale)))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Text(AppLocalization.string("将替换本机资产记录，并保留恢复前的 JSON 备份。"))
                        if cloudStore.hasToken || cloudStore.localRestoreNeedsCloudConfirmation {
                            Text(AppLocalization.string("云端记录不会被替换；自动同步将暂停，待你核对后重新关联。"))
                        }
                        Button(role: .destructive) { restore(candidate) } label: {
                            if isBusy { ProgressView() }
                            else { Text(AppLocalization.string("恢复这些记录")) }
                        }
                        .disabled(isBusy || cloudStore.isWorking)
                        if let error { Text(error).foregroundStyle(AssetTheme.negative) }
                    }
                }
                .navigationTitle(AppLocalization.string("确认恢复"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(AppLocalization.string("取消")) { preview = nil }.disabled(isBusy)
                    }
                }
                .interactiveDismissDisabled(isBusy)
            }
        }
        .sheet(isPresented: $showsCloudSync) {
            NavigationStack { AssetTimeMachineCloudPage(store: cloudStore) }
        }
    }

    private func show(_ failure: any Error) {
        guard (failure as NSError).code != NSUserCancelledError else { return }
        error = failure is DecodingError
            ? AppLocalization.string("JSON 备份格式或数值无效") : failure.localizedDescription
    }

    private func exportBeforeImport(_ beforeImport: Bool) {
        guard !isBusy else { return }
        isBusy = true; error = nil; message = nil
        Task {
            defer { isBusy = false }
            do {
                let data = beforeImport
                    ? try await cloudStore.exportBeforeJSONImportBackup()
                    : try await cloudStore.exportLocalRecords(from: context)
                document = CloudRecordsDocument(data: data)
                filename = "AssetTimeMachine-" + (beforeImport ? "BeforeRestore-" : "")
                    + Date().recordDateString
                showsExporter = true
            } catch { show(error) }
        }
    }

    private func prepareImport(_ url: URL) {
        guard !isBusy else { return }
        isBusy = true; error = nil; message = nil
        Task {
            defer { isBusy = false }
            do {
                let payload = try await ImportExportService.readLocalImportJSON(at: url)
                preview = LocalRecordsImportPreview(filename: url.lastPathComponent, payload: payload)
            } catch { show(error) }
        }
    }

    private func restore(_ candidate: LocalRecordsImportPreview) {
        guard !isBusy else { return }
        isBusy = true; error = nil; message = nil
        Task {
            defer { isBusy = false }
            do {
                try await cloudStore.restoreLocalRecords(candidate.payload, into: context)
                preview = nil
                message = AppLocalization.string("JSON 记录已恢复")
            } catch { show(error) }
        }
    }
}
