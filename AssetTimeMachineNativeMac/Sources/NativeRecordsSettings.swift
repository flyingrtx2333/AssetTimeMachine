import AppKit
import AuthenticationServices
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NativeRecordEditor: ObservableObject {
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let category: String
        let group: AssetGroup
        let icon: String?
        let method: ValuationMethod
        let amount: Double?
        let quantity: Double?
        let price: Double?
        let note: String
        let entryUpdatedAt: Date?
        var total: Double { amount ?? ((quantity ?? 0) * (price ?? 0)) }
        var isEmpty: Bool { amount == nil && quantity == nil && price == nil }
        var draft: Draft {
            Draft(amount: amount.map { $0.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(2))) } ?? "",
                  quantity: quantity.map { String($0) } ?? "",
                  price: price.map { String($0) } ?? "")
        }
    }
    struct Draft: Equatable {
        var amount: String
        var quantity: String
        var price: String
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var drafts: [UUID: Draft] = [:]
    @Published private(set) var snapshotID: UUID?
    @Published private(set) var date: Date?
    @Published var error: String?
    @Published private(set) var savedAt: Date?
    private var draftToken: UUID?
    var isDirty: Bool { !drafts.isEmpty }

    deinit {
        if let token = draftToken {
            Task { @MainActor in ModelContextMutationBarrier.shared.finishEditorDraft(token) }
        }
    }

    func displayedAmount(for row: Row) -> Double {
        guard let draft = drafts[row.id] else { return row.total }
        func parse(_ text: String) -> Double? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
            return value.isEmpty ? 0 : Double(value)
        }
        let amount: Double?
        if row.method == .quantityAndUnitPrice {
            if let quantity = parse(draft.quantity), let price = parse(draft.price) { amount = quantity * price }
            else { amount = nil }
        } else { amount = parse(draft.amount) }
        return amount.flatMap { $0.isFinite ? $0 : nil } ?? row.total
    }

    func load(id: UUID?, container: ModelContainer) {
        guard !isDirty else { return }
        error = nil
        guard let id else { rows = []; snapshotID = nil; date = nil; return }
        do {
            let context = ModelContext(container)
            var request = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
            request.fetchLimit = 1
            guard let snapshot = try context.fetch(request).first else {
                throw failure("记录已不存在，请重新选择日期")
            }
            let items = try context.fetch(FetchDescriptor<AssetItem>(sortBy: [SortDescriptor(\AssetItem.sortOrder), SortDescriptor(\AssetItem.createdAt)]))
            let entries = Dictionary(snapshot.entries.compactMap { entry in
                entry.item.map { ($0.id, entry) }
            }, uniquingKeysWith: { first, _ in first })
            rows = items.filter(\.isActive).map { item in
                let entry = entries[item.id]
                return Row(id: item.id, name: item.name, category: item.category?.name ?? "资产",
                           group: item.category?.group ?? .financial, icon: item.iconName,
                           method: item.valuationMethod, amount: entry?.amount,
                           quantity: entry?.quantity, price: entry?.unitPrice, note: entry?.note ?? "",
                           entryUpdatedAt: entry?.updatedAt)
            }
            snapshotID = id
            date = snapshot.date
        } catch { self.error = error.localizedDescription }
    }

    func update(_ row: Row, draft: Draft) {
        if draftToken == nil {
            guard let token = ModelContextMutationBarrier.shared.beginEditorDraft() else {
                error = "数据正在更新，请稍后编辑"
                return
            }
            draftToken = token
        }
        if draft == row.draft { drafts.removeValue(forKey: row.id) }
        else { drafts[row.id] = draft }
        error = nil
        if drafts.isEmpty { releaseDraft() }
    }
    func discard() {
        drafts = [:]
        error = nil
        releaseDraft()
    }
    private func releaseDraft() {
        if let draftToken { ModelContextMutationBarrier.shared.finishEditorDraft(draftToken) }
        draftToken = nil
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "NativeRecordEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func number(_ text: String, name: String) throws -> Double? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        if clean.isEmpty { return nil }
        guard let value = Double(clean), value.isFinite else { throw failure("\(name)：请输入有效数字") }
        return value
    }
    @discardableResult
    func save(container: ModelContainer) -> Bool {
        guard isDirty, let id = snapshotID else { return false }
        do {
            // Validate every draft before touching any model. A single context.save commits the batch.
            var changes: [(Row, Double?, Double?, Double?)] = []
            for row in rows where drafts[row.id] != nil {
                let draft = drafts[row.id]!
                if row.method == .quantityAndUnitPrice {
                    let quantity = try number(draft.quantity, name: row.name + " 数量")
                    let price = try number(draft.price, name: row.name + " 单价")
                    guard (quantity == nil) == (price == nil) else { throw failure("\(row.name)：请同时填写数量和单价") }
                    if let quantity, let price, !(quantity * price).isFinite { throw failure("\(row.name)：金额超出有效范围") }
                    changes.append((row, nil, quantity, price))
                } else {
                    changes.append((row, try number(draft.amount, name: row.name), nil, nil))
                }
            }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            var request = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
            request.fetchLimit = 1
            guard let snapshot = try context.fetch(request).first else { throw failure("记录已被删除，草稿已保留") }
            let allItems = try context.fetch(FetchDescriptor<AssetItem>())
            for (row, amount, quantity, price) in changes {
                guard let item = allItems.first(where: { $0.id == row.id }), item.isActive else {
                    throw failure("\(row.name)：资产已变更，草稿已保留")
                }
                let current = snapshot.entries.first(where: { $0.item?.id == row.id })
                guard current?.updatedAt == row.entryUpdatedAt,
                      item.valuationMethod == row.method else {
                    throw failure("\(row.name)：记录已在其他位置更新，请放弃草稿后重新载入")
                }
                try SnapshotService.upsertEntry(snapshot: snapshot, item: item, amount: amount,
                    quantity: quantity, unitPrice: price, note: row.note, saveChanges: false, in: context)
            }
            try context.save()
            discard()
            savedAt = .now
            load(id: id, container: container)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct NativeRecordsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AssetCategory.createdAt) private var categories: [AssetCategory]
    @ObservedObject var history: NativeHistoryModel
    @ObservedObject var cloud: AssetTimeMachineCloudStore
    @ObservedObject var editor: NativeRecordEditor
    @State private var addingGroup: AssetGroup?
    @State private var expandedGroups: Set<AssetGroup> = []
    @State private var deleteRecord = false
    @State private var deletingItem: NativeRecordEditor.Row?
    @State private var confirmsDiscard = false

    private func money(_ value: Double) -> String { value.formatted(.currency(code: "CNY").precision(.fractionLength(2))) }
    private func total(_ group: AssetGroup) -> Double {
        editor.rows.filter { $0.group == group }.reduce(0) { $0 + editor.displayedAmount(for: $1) }
    }
    private var selectedIndex: Int? { history.summaries.firstIndex { $0.id == editor.snapshotID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                NativePageHeader(title: "记录", subtitle: nil)
                Button("添加资产", systemImage: "plus") { addingGroup = .financial }
                    .disabled(editor.isDirty)
                Button("记录今日资产", systemImage: "calendar.badge.plus", action: recordToday)
                    .disabled(editor.isDirty)
                    .buttonStyle(.borderedProminent).tint(AssetTheme.gold)
            }
            HStack(spacing: 10) {
                Button { moveDate(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(editor.isDirty || (selectedIndex ?? 0) == 0)
                Text(editor.date.map { $0.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) } ?? "暂无记录")
                    .font(.system(size: 12, weight: .semibold))
                Button { moveDate(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(editor.isDirty || (selectedIndex ?? 0) >= history.summaries.count - 1)
                Spacer()
                Text("净资产").foregroundStyle(.secondary)
                Text(money(total(.financial) + total(.physical) - total(.liability))).fontWeight(.semibold).monospacedDigit()
                Menu {
                    Button("删除这天的记录", role: .destructive) { deleteRecord = true }
                        .disabled(editor.isDirty || editor.snapshotID == nil)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 20)
            }
            .font(.system(size: 11))
            if editor.snapshotID != nil {
                GeometryReader { geometry in
                    ScrollView {
                        HStack(alignment: .top, spacing: 12) {
                            groupPanel(.financial, minimumHeight: geometry.size.height - 2)
                                .frame(width: (geometry.size.width - 12) * 0.57)
                            VStack(spacing: 12) {
                                groupPanel(.physical, minimumHeight: (geometry.size.height - 14) / 2)
                                groupPanel(.liability, minimumHeight: (geometry.size.height - 14) / 2)
                            }.frame(maxWidth: .infinity)
                        }.padding(.bottom, 2)
                    }
                }
            } else {
                ContentUnavailableView("暂无记录", systemImage: "calendar", description: Text("点击“记录今日资产”开始。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .padding(22)
        .task {
            if !editor.isDirty { editor.load(id: editor.snapshotID ?? history.summaries.last?.id, container: context.container) }
        }
        .onChange(of: history.generation) { _, _ in
            let id = history.summaries.contains { $0.id == editor.snapshotID } ? editor.snapshotID : history.summaries.last?.id
            editor.load(id: id, container: context.container)
        }
        .sheet(item: $addingGroup) { group in
            NativeAddItemSheet(categories: categories, initialGroup: group, onSaved: refresh)
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmsDiscard) {
            Button("放弃修改", role: .destructive) {
                editor.discard()
                editor.load(id: editor.snapshotID, container: context.container)
            }
        }
        .confirmationDialog("删除这天的资产记录？", isPresented: $deleteRecord) {
            Button("删除记录", role: .destructive) { removeRecord() }
        } message: { Text("此操作会参与云端同步。") }
        .confirmationDialog("删除资产项目及其历史记录？", isPresented: Binding(
            get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } }
        )) {
            Button("删除资产项目", role: .destructive) { if let item = deletingItem { removeItem(item.id) }; deletingItem = nil }
        } message: { Text("删除后会参与云端同步。") }
    }

    private func groupPanel(_ group: AssetGroup, minimumHeight: CGFloat = 0) -> some View {
        let rows = editor.rows.filter { $0.group == group }
        // Keep a row in place while typing; regroup only after a successful save.
        let filled = rows.filter { !$0.isEmpty }
        let empty = rows.filter { $0.isEmpty }
        return NativeCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: groupSymbol(group))
                        .font(.system(size: 18)).foregroundStyle(AssetTheme.gold)
                        .frame(width: 32, height: 32).background(NativePalette.softGold, in: RoundedRectangle(cornerRadius: 8))
                    Text(group.displayName).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 2)
                    Text(money(total(group))).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }.padding(.bottom, 16)
                Divider()
                ForEach(filled) { row in accountRow(row); Divider() }
                if filled.isEmpty && !expandedGroups.contains(group) {
                    Text("暂无已填写项目").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                }
                if expandedGroups.contains(group) {
                    ForEach(empty) { row in accountRow(row); Divider() }
                }
                Spacer(minLength: 0)
                HStack {
                    Button { addingGroup = group } label: { Label("添加", systemImage: "plus") }
                        .disabled(editor.isDirty)
                    Spacer(minLength: 2)
                    if !empty.isEmpty {
                        Button {
                            if !expandedGroups.insert(group).inserted { expandedGroups.remove(group) }
                        } label: {
                            HStack(spacing: 3) {
                                Text("未填写 (\(empty.count))")
                                Image(systemName: expandedGroups.contains(group) ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
                .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.top, 12)
            }.frame(minHeight: max(0, minimumHeight - 28), alignment: .top)
        }
    }
    private func groupSymbol(_ group: AssetGroup) -> String {
        switch group { case .financial: "banknote"; case .physical: "house"; case .liability: "creditcard" }
    }
    private func accountRow(_ row: NativeRecordEditor.Row) -> some View {
        NativeLedgerRow(row: row, draft: Binding(
            get: { editor.drafts[row.id] ?? row.draft },
            set: { editor.update(row, draft: $0) }
        ), dirty: editor.drafts[row.id] != nil, canDelete: !editor.isDirty,
        delete: { deletingItem = row })
    }
    private var footer: some View {
        NativeCard {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    if let error = editor.error {
                        Text(error).foregroundStyle(AssetTheme.negative)
                    } else if editor.isDirty {
                        Text("修改 \(editor.drafts.count) 项 · 尚未保存").foregroundStyle(AssetTheme.gold)
                    } else {
                        Label(editor.savedAt == nil ? "已载入本机记录" : "已保存至本机", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    if editor.isDirty { Text("切换页面会保留草稿").font(.system(size: 9)).foregroundStyle(.secondary) }
                }.font(.system(size: 11))
                Spacer(minLength: 4)
                if editor.isDirty { Button("放弃修改") { confirmsDiscard = true }.controlSize(.small) }
                Button("保存更改") {
                    if editor.save(container: context.container) { refresh() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent).tint(AssetTheme.gold)
                .disabled(!editor.isDirty)
            }
        }
    }
    private func moveDate(_ offset: Int) {
        guard let index = selectedIndex, history.summaries.indices.contains(index + offset) else { return }
        editor.load(id: history.summaries[index + offset].id, container: context.container)
    }
    private func refresh() {
        editor.load(id: editor.snapshotID ?? history.summaries.last?.id, container: context.container)
        Task {
            await history.load(from: context.container, force: true)
            cloud.scheduleAutoSync(from: context)
        }
    }
    private func recordToday() {
        guard let token = ModelContextMutationBarrier.shared.beginEditorDraft() else {
            editor.error = "数据正在更新，请稍后重试"; return
        }
        defer { ModelContextMutationBarrier.shared.finishEditorDraft(token) }
        do {
            let snapshot = try SnapshotService.createSnapshot(on: .now, in: context)
            editor.load(id: snapshot.id, container: context.container)
            refresh()
        } catch { editor.error = error.localizedDescription }
    }
    private func removeRecord() {
        guard let id = editor.snapshotID else { return }
        guard let token = ModelContextMutationBarrier.shared.beginEditorDraft() else {
            editor.error = "数据正在更新，请稍后重试"; return
        }
        defer { ModelContextMutationBarrier.shared.finishEditorDraft(token) }
        do {
            let edit = ModelContext(context.container)
            var request = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
            request.fetchLimit = 1
            if let snapshot = try edit.fetch(request).first {
                try SyncDeletionService.record(entityID: id, kind: .snapshot, in: edit)
                edit.delete(snapshot)
                try edit.save()
            }
            editor.load(id: nil, container: context.container)
            Task {
                await history.load(from: context.container, force: true)
                editor.load(id: history.summaries.last?.id, container: context.container)
                cloud.scheduleAutoSync(from: context)
            }
        } catch { editor.error = error.localizedDescription }
    }
    private func removeItem(_ id: UUID) {
        guard let token = ModelContextMutationBarrier.shared.beginEditorDraft() else {
            editor.error = "数据正在更新，请稍后重试"; return
        }
        defer { ModelContextMutationBarrier.shared.finishEditorDraft(token) }
        do {
            let edit = ModelContext(context.container)
            var request = FetchDescriptor<AssetItem>(predicate: #Predicate { $0.id == id })
            request.fetchLimit = 1
            if let item = try edit.fetch(request).first {
                try SyncDeletionService.record(entityID: id, kind: .item, in: edit)
                edit.delete(item)
                try edit.save()
            }
            refresh()
        } catch { editor.error = error.localizedDescription }
    }
}

private struct NativeLedgerRow: View {
    let row: NativeRecordEditor.Row
    @Binding var draft: NativeRecordEditor.Draft
    let dirty: Bool
    let canDelete: Bool
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon.frame(width: 25, height: 25)
                Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(row.name)
                if dirty { Circle().fill(AssetTheme.gold).frame(width: 4, height: 4) }
                Spacer(minLength: 4)
                if row.method == .directAmount {
                    field("金额", text: $draft.amount).frame(width: 105)
                } else {
                    Text(amountPreview).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                Menu { Button("删除资产项目", role: .destructive, action: delete).disabled(!canDelete) }
                    label: { Image(systemName: "ellipsis").font(.system(size: 12)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 16)
            }
            if row.method == .quantityAndUnitPrice {
                HStack(spacing: 5) {
                    Text("数量").foregroundStyle(.secondary)
                    field("数量", text: $draft.quantity)
                    Text("×").foregroundStyle(.secondary)
                    field("单价", text: $draft.price)
                }.font(.system(size: 10)).padding(.leading, 33)
            }
        }.padding(.vertical, 13)
    }
    private var amountPreview: String {
        let q = Double(draft.quantity.replacingOccurrences(of: ",", with: ""))
        let p = Double(draft.price.replacingOccurrences(of: ",", with: ""))
        guard let q, let p, (q * p).isFinite else { return "—" }
        return (q * p).formatted(.currency(code: "CNY").precision(.fractionLength(2)))
    }
    private func field(_ name: String, text: Binding<String>) -> some View {
        HStack(spacing: 3) {
            if name == "金额" { Text("¥").foregroundStyle(.secondary) }
            TextField(name, text: text)
                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .accessibilityLabel("\(row.name) \(name)")
        }
            .font(.system(size: 12)).monospacedDigit()
            .padding(.horizontal, 7).frame(height: 28)
            .background(NativePalette.canvas, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(dirty ? AssetTheme.gold.opacity(0.7) : NativePalette.line))
    }
    @ViewBuilder private var icon: some View {
        if let key = row.icon, key.hasPrefix("icon_"), let image = NSImage(named: key) {
            Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            let fallback = row.group == .physical ? "house.fill" : (row.group == .liability ? "creditcard.fill" : "banknote.fill")
            let symbol = row.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? fallback
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(AssetTheme.gold)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NativePalette.softGold, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct NativeAddItemSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let categories: [AssetCategory]
    let onSaved: () -> Void
    @State private var name = ""
    @State private var newCategory = ""
    @State private var selectedGroup: AssetGroup = .financial
    @State private var selectedCategoryID: UUID?
    @State private var valuationMethod: ValuationMethod = .directAmount
    @State private var marketSymbol = ""
    @State private var error: String?

    init(categories: [AssetCategory], initialGroup: AssetGroup = .financial, onSaved: @escaping () -> Void) {
        self.categories = categories
        self.onSaved = onSaved
        _selectedGroup = State(initialValue: initialGroup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加资产").font(.system(size: 18, weight: .semibold))
            TextField("资产名称", text: $name)
            Picker("类型", selection: $selectedGroup) {
                ForEach(AssetGroup.allCases) { group in Text(group.displayName).tag(group) }
            }
            Picker("计价方式", selection: $valuationMethod) {
                ForEach(ValuationMethod.allCases) { method in Text(method.displayName).tag(method) }
            }
            if valuationMethod == .quantityAndUnitPrice {
                TextField("行情代码（可选）", text: $marketSymbol)
            }
            Picker("分类", selection: $selectedCategoryID) {
                Text("新建分类").tag(Optional<UUID>.none)
                ForEach(categories.filter { $0.group == selectedGroup }) { category in
                    Text(category.name).tag(Optional(category.id))
                }
            }
            if selectedCategoryID == nil { TextField("新分类名称", text: $newCategory) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加", action: save).buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 390)
    }
    private func save() {
        guard let token = ModelContextMutationBarrier.shared.beginEditorDraft() else {
            error = "数据正在更新，请稍后重试"; return
        }
        defer { ModelContextMutationBarrier.shared.finishEditorDraft(token) }
        do {
            let category: AssetCategory
            if let selectedCategoryID, let existing = categories.first(where: { $0.id == selectedCategoryID }) {
                category = existing
            } else {
                let categoryName = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !categoryName.isEmpty else { error = "请输入分类名称"; return }
                category = AssetCategory(name: categoryName, group: selectedGroup)
                context.insert(category)
            }
            let item = AssetItem(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 valuationMethod: valuationMethod, sortOrder: category.items.count,
                                 category: category)
            let symbol = marketSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
            if !symbol.isEmpty { item.marketAssetSymbol = symbol }
            context.insert(item)
            try context.save()
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct NativeSettingsView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject var history: NativeHistoryModel
    @ObservedObject var cloud: AssetTimeMachineCloudStore
    @State private var showsLogin = false
    @State private var error: String?
    @State private var message: String?
    @State private var showRestoreConfirmation = false
    @State private var showOwnershipConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                NativePageHeader(title: "设置", subtitle: "账户、同步与本机数据")
                NativeCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("云同步").font(.system(size: 14, weight: .semibold))
                        Text(cloud.currentUser?.displayName ?? "未登录 · 可继续本机使用")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if let status = cloud.statusMessage { Text(status).font(.caption).foregroundStyle(AssetTheme.positive) }
                        if let error = cloud.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                        HStack {
                            if cloud.currentUser == nil { Button("登录", action: { showsLogin = true }) }
                            else {
                                if cloud.requiresLocalOwnershipConfirmation {
                                    Button("关联并同步本机记录") { showOwnershipConfirmation = true }
                                }
                                Button("立即同步") { cloud.scheduleAutoSync(from: context, quietly: false, delayNanoseconds: 0) }
                                Button("恢复最新备份") { showRestoreConfirmation = true }
                                Button("退出登录") { cloud.logout() }
                            }
                        }
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("本机数据").font(.system(size: 14, weight: .semibold))
                        Text("\(history.summaries.count) 条历史记录")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack {
                            Button("导出 JSON", action: exportJSON)
                            Button("导入 JSON", action: importJSON)
                        }
                        if let message { Text(message).font(.caption).foregroundStyle(AssetTheme.positive) }
                        if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            }.padding(24)
        }
        .sheet(isPresented: $showsLogin) {
            NativeAccountChoice(cloud: cloud) { showsLogin = false }
                .environment(\.modelContext, context)
        }
        .alert("确认关联到当前账户？", isPresented: $showOwnershipConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认并同步") { Task { await cloud.authorizeLocalDataForCurrentAccount(from: context) } }
        } message: { Text("本机记录将上传到当前账户的云端备份。请确认这是你的账户。") }
        .confirmationDialog("从云端恢复最新备份？", isPresented: $showRestoreConfirmation) {
            Button("恢复备份") {
                Task {
                    await cloud.restoreLatestBackup(into: context)
                    await history.load(from: context.container, force: true)
                }
            }
        } message: { Text("会使用云端最新备份更新本机记录。") }
    }
    private func exportJSON() {
        error = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AssetTimeMachine-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let versioned = try await ImportExportService.exportPayloadCooperatively(from: context)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(versioned.payload).write(to: url, options: .atomic)
                message = "已导出到 \(url.lastPathComponent)"
            } catch { self.error = error.localizedDescription }
        }
    }
    private func importJSON() {
        error = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                try await ImportExportService.importJSON(data, into: context)
                await history.load(from: context.container, force: true)
                cloud.scheduleAutoSync(from: context)
                message = "已导入 \(url.lastPathComponent)"
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct NativeAccountChoice: View {
    @Environment(\.modelContext) private var context
    @ObservedObject var cloud: AssetTimeMachineCloudStore
    let done: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var isShowingPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("资产时光机").font(.system(size: 20, weight: .semibold))
            Text("登录以同步手机数据，或先在本机使用。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task {
                    await cloud.handleAppleSignIn(result, from: context)
                    if cloud.currentUser != nil { done() }
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 36)
            DisclosureGroup("使用已有账户登录", isExpanded: $isShowingPassword) {
                VStack(spacing: 9) {
                    TextField("账户", text: $username)
                    SecureField("密码", text: $password)
                    Button("登录") {
                        Task {
                            await cloud.login(username: username, password: password)
                            if cloud.currentUser != nil {
                                cloud.scheduleAutoSync(from: context, quietly: false, delayNanoseconds: 0)
                                done()
                            }
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || cloud.isWorking)
                }.padding(.top, 6)
            }
            if let error = cloud.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("不登录，先在本机使用", action: done)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 380)
    }
}
