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
        let autoPriceSymbol: String?
        let amount: Double?
        let quantity: Double?
        let price: Double?
        let note: String
        let entryUpdatedAt: Date?
        var total: Double { amount ?? ((quantity ?? 0) * (price ?? 0)) }
        var isEmpty: Bool { amount == nil && quantity == nil && (autoPriceSymbol != nil || price == nil) }
        var isZeroBalance: Bool { !isEmpty && total == 0 && (method == .directAmount ? amount == 0 : quantity == 0) }
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
                           method: item.valuationMethod, autoPriceSymbol: item.autoPricedMarketSymbol, amount: entry?.amount,
                           quantity: entry?.quantity, price: entry?.unitPrice, note: entry?.note ?? "",
                           entryUpdatedAt: entry?.updatedAt)
            }
            snapshotID = id
            date = snapshot.date
        } catch { self.error = error.localizedDescription }
    }

    func update(_ row: Row, draft proposed: Draft) {
        var draft = proposed
        // Market-derived prices belong to the dated snapshot, never to a manual draft.
        if row.autoPriceSymbol != nil { draft.price = row.draft.price }
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
                    let price = row.autoPriceSymbol == nil
                        ? try number(draft.price, name: row.name + " 单价") : row.price
                    if row.autoPriceSymbol != nil && quantity != nil && price == nil {
                        throw failure("\(row.name)：这天缺少行情价格")
                    }
                    if row.autoPriceSymbol == nil, (quantity == nil) != (price == nil) {
                        throw failure("\(row.name)：请同时填写数量和单价")
                    }
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
                      item.valuationMethod == row.method,
                      item.autoPricedMarketSymbol == row.autoPriceSymbol else {
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
    @State private var deleteRecord = false
    @State private var deletingItem: NativeRecordEditor.Row?
    @State private var confirmsDiscard = false

    private func money(_ value: Double) -> String { value.formatted(.currency(code: "CNY").precision(.fractionLength(2))) }
    private func total(_ group: AssetGroup) -> Double {
        editor.rows.filter { $0.group == group }.reduce(0) { $0 + editor.displayedAmount(for: $1) }
    }
    private var selectedIndex: Int? { history.summaries.firstIndex { $0.id == editor.snapshotID } }

    @State private var collapsedGroups: Set<AssetGroup> = []
    @State private var showsUnfilled = false
    @State private var expandedZeroGroups: Set<AssetGroup> = []
    @State private var pendingSnapshotID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private var reduced: Bool { reducedMotion || NativeHomeStyle.previewReduced }
    private var unfilled: [NativeRecordEditor.Row] { editor.rows.filter(\.isEmpty) }
    private var disclosureTransition: AnyTransition {
        reduced ? .opacity : .offset(y: -6).combined(with: .opacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: NativeStyle.Space.lg) {
                metric("净资产", value: total(.financial) + total(.physical) - total(.liability))
                Rectangle().fill(NativeHomeStyle.line).frame(width: 0.5, height: 18)
                metric("总资产", value: total(.financial) + total(.physical))
                Rectangle().fill(NativeHomeStyle.line).frame(width: 0.5, height: 18)
                metric("负债", value: total(.liability))
                Spacer(minLength: 0)
            }.padding(.top, NativeStyle.Space.sm).padding(.bottom, NativeStyle.Space.sm)
            if editor.snapshotID != nil {
                columnHeadings
                ScrollView {
                    VStack(spacing: 0) {
                        groupPanel(.financial)
                        groupPanel(.physical).padding(.top, 10)
                        groupPanel(.liability).padding(.top, 10)
                        if !unfilled.isEmpty {
                            Button {
                                withAnimation(NativeStyle.Motion.records(reduced)) { showsUnfilled.toggle() }
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "chevron.right").rotationEffect(.degrees(showsUnfilled ? 90 : 0))
                                    Text("未填写 (\(unfilled.count))")
                                    Spacer()
                                }.padding(.horizontal, NativeStyle.Space.sm).frame(height: 36)
                            }.foregroundStyle(NativeHomeStyle.secondary)
                            if showsUnfilled {
                                VStack(spacing: 0) { ForEach(unfilled) { accountRow($0) } }
                                    .transition(disclosureTransition)
                            }
                        }
                    }.padding(.bottom, NativeStyle.Space.md)
                }.scrollIndicators(.hidden)
            } else {
                ContentUnavailableView("暂无记录", systemImage: "calendar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .font(NativeStyle.FontRole.body)
        .frame(maxWidth: NativeStyle.Layout.ledgerMaxWidth, alignment: .leading)
        .padding(.horizontal, NativeStyle.Layout.pageInset).padding(.top, NativeStyle.Layout.pageInset).padding(.bottom, NativeStyle.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeOutsideClickDismissal())
        .buttonStyle(NativeRecordsButtonStyle())
        .modifier(NativeWorkspaceSurface())
        .animation(NativeStyle.Motion.records(reduced), value: editor.isDirty)
        .animation(NativeStyle.Motion.records(reduced), value: editor.error)
        .animation(NativeStyle.Motion.records(reduced), value: editor.savedAt)
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
                let destination = pendingSnapshotID ?? editor.snapshotID
                pendingSnapshotID = nil
                withAnimation(NativeStyle.Motion.records(reduced)) {
                    editor.discard()
                    editor.load(id: destination, container: context.container)
                }
            }
        }
        .onChange(of: confirmsDiscard) { _, presented in if !presented { pendingSnapshotID = nil } }
        .confirmationDialog("删除这天的资产记录？", isPresented: $deleteRecord) {
            Button("删除记录", role: .destructive) { removeRecord() }
        } message: { Text("此操作会参与云端同步。") }
        .confirmationDialog("删除资产项目及其历史记录？", isPresented: Binding(
            get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } }
        )) {
            Button("删除资产项目", role: .destructive) { if let item = deletingItem { removeItem(item.id) }; deletingItem = nil }
        } message: { Text("删除后会参与云端同步。") }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("记录").font(NativeStyle.FontRole.pageTitle)
            HStack(spacing: 10) {
                Button { moveDate(-1) } label: { Image(systemName: "chevron.left").frame(width: 18, height: 24) }
                    .accessibilityLabel("上一条记录").disabled((selectedIndex ?? 0) == 0)
                Text(editor.date.map { $0.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) } ?? "暂无记录")
                    .monospacedDigit().lineLimit(1).frame(minWidth: 116)
                    .contentTransition(.opacity)
                Button { moveDate(1) } label: { Image(systemName: "chevron.right").frame(width: 18, height: 24) }
                    .accessibilityLabel("下一条记录").disabled((selectedIndex ?? 0) >= history.summaries.count - 1)
            }.padding(.horizontal, NativeStyle.Space.xxs)
                .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).stroke(NativeHomeStyle.line, lineWidth: 0.7))
            Menu {
                Button("删除这天的记录", role: .destructive) { deleteRecord = true }
                    .disabled(editor.isDirty || editor.snapshotID == nil)
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("记录操作")
            Spacer(minLength: 6)
            Button("添加资产") { addingGroup = .financial }
                .padding(.horizontal, NativeStyle.Space.lg).frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).stroke(NativeHomeStyle.line, lineWidth: 0.7))
                .disabled(editor.isDirty)
            Button("记录今日资产", action: recordToday).modifier(NativeRecordsPrimary()).disabled(editor.isDirty)
        }.frame(height: NativeStyle.Control.fieldHeight)
    }
    private func metric(_ title: String, value: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NativeStyle.Space.sm) {
            Text(title).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            Text(money(value)).font(NativeStyle.FontRole.subheadingStrong).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
                .contentTransition(reduced ? .opacity : .numericText())
        }.fixedSize(horizontal: true, vertical: false)
            .animation(NativeStyle.Motion.records(reduced), value: value)
    }
    private var columnHeadings: some View {
        HStack(spacing: NativeStyle.Space.sm) {
            Text("资产").frame(maxWidth: .infinity, alignment: .leading)
            Text("数量").frame(width: NativeStyle.Layout.quantityWidth, alignment: .trailing)
            Text("单价 (¥)").frame(width: NativeStyle.Layout.unitPriceWidth, alignment: .trailing)
            Text("金额 (¥)").frame(width: NativeStyle.Layout.amountWidth, alignment: .trailing)
            Color.clear.frame(width: 22)
        }.font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            .padding(.horizontal, NativeStyle.Space.sm).frame(height: 26)
    }
    @ViewBuilder private func groupPanel(_ group: AssetGroup) -> some View {
        let filled = editor.rows.filter { $0.group == group && !$0.isEmpty }
        let balances = filled.filter { !$0.isZeroBalance }
        let zeroBalances = filled.filter(\.isZeroBalance)
        if !filled.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(NativeStyle.Motion.records(reduced)) {
                        if !collapsedGroups.insert(group).inserted { collapsedGroups.remove(group) }
                    }
                } label: {
                    HStack(spacing: NativeStyle.Space.sm) {
                        Text(group.displayName).fontWeight(.medium)
                        Text("(\(filled.count))").foregroundStyle(NativeHomeStyle.secondary)
                        Spacer()
                        Text(total(group).formatted(.number.precision(.fractionLength(2)))).monospacedDigit()
                            .contentTransition(reduced ? .opacity : .numericText())
                        Image(systemName: "chevron.down").rotationEffect(.degrees(collapsedGroups.contains(group) ? -90 : 0))
                            .foregroundStyle(NativeHomeStyle.secondary).frame(width: 22)
                    }.padding(.horizontal, NativeStyle.Space.sm).frame(height: NativeStyle.Layout.ledgerGroupHeight)
                        .background(NativeHomeStyle.text.opacity(0.025))
                }.accessibilityLabel(group.displayName + (collapsedGroups.contains(group) ? "，展开" : "，收起"))
                if !collapsedGroups.contains(group) {
                    VStack(spacing: 0) { ForEach(balances) { accountRow($0) } }
                        .transition(disclosureTransition)
                    if !zeroBalances.isEmpty {
                        Button {
                            withAnimation(NativeStyle.Motion.records(reduced)) {
                                if !expandedZeroGroups.insert(group).inserted { expandedZeroGroups.remove(group) }
                            }
                        } label: {
                            HStack(spacing: NativeStyle.Space.xs) {
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(expandedZeroGroups.contains(group) ? 90 : 0))
                                Text("零余额 (\(zeroBalances.count))")
                                Spacer()
                            }.font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
                                .padding(.horizontal, NativeStyle.Space.sm).frame(height: NativeStyle.Layout.ledgerRowHeight)
                        }.accessibilityLabel(group.displayName + "，零余额" + (expandedZeroGroups.contains(group) ? "，收起" : "，展开"))
                        if expandedZeroGroups.contains(group) {
                            VStack(spacing: 0) { ForEach(zeroBalances) { accountRow($0) } }
                                .transition(disclosureTransition)
                        }
                    }
                }
            }.animation(NativeStyle.Motion.records(reduced), value: total(group))
        }
    }
    private func accountRow(_ row: NativeRecordEditor.Row) -> some View {
        NativeLedgerRow(row: row, draft: Binding(
            get: { editor.drafts[row.id] ?? row.draft },
            set: { editor.update(row, draft: $0) }
        ), dirty: editor.drafts[row.id] != nil, canDelete: !editor.isDirty,
        delete: { deletingItem = row })
    }
    private var footer: some View {
        VStack(spacing: NativeStyle.Space.md) {
            Rectangle().fill(NativeHomeStyle.line).frame(height: 0.5)
            HStack(spacing: 10) {
                Group {
                    if let error = editor.error { Text(error).foregroundStyle(AssetTheme.negative) }
                    else if editor.isDirty { Text("修改 \(editor.drafts.count) 项").foregroundStyle(NativeHomeStyle.secondary) }
                    else { Text(savedStatus).foregroundStyle(NativeHomeStyle.secondary).help(cloud.errorMessage ?? cloud.indicatorLabel) }
                }.font(NativeStyle.FontRole.caption).transition(.opacity)
                Spacer(minLength: 4)
                if editor.isDirty {
                    Button("放弃修改") { pendingSnapshotID = nil; confirmsDiscard = true }
                        .padding(.horizontal, NativeStyle.Space.md).transition(.opacity)
                }
                Button("保存更改") {
                    withAnimation(NativeStyle.Motion.records(reduced)) {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        if editor.save(container: context.container) { refresh() }
                    }
                }.keyboardShortcut("s", modifiers: .command).modifier(NativeRecordsPrimary()).disabled(!editor.isDirty)
            }.frame(minHeight: 34)
        }
    }

    private var savedStatus: String {
        guard let savedAt = editor.savedAt else { return "已载入本机记录" }
        if cloud.isSessionPending { return "已存本机 · 正在连接云端" }
        guard cloud.currentUser != nil, cloud.hasToken else { return "已存本机 · 未登录" }
        if cloud.requiresLocalOwnershipConfirmation { return "已存本机 · 待确认同步" }
        if cloud.errorMessage?.isEmpty == false { return "已存本机 · 同步失败" }
        if cloud.isWorking { return "已存本机 · 正在同步" }
        if cloud.indicatorState == .checking { return "已存本机 · 等待同步" }
        if let syncedAt = cloud.lastSyncAt, syncedAt >= savedAt { return "已同步云端" }
        return "已存本机 · 等待同步"
    }

    private func moveDate(_ offset: Int) {
        guard let index = selectedIndex, history.summaries.indices.contains(index + offset) else { return }
        let destination = history.summaries[index + offset].id
        if editor.isDirty { pendingSnapshotID = destination; confirmsDiscard = true }
        else {
            withAnimation(NativeStyle.Motion.records(reduced)) {
                editor.load(id: destination, container: context.container)
            }
        }
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
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @FocusState private var focused: String?
    @State private var hovered = false
    let row: NativeRecordEditor.Row
    @Binding var draft: NativeRecordEditor.Draft
    let dirty: Bool
    let canDelete: Bool
    let delete: () -> Void
    private var reduced: Bool { systemReduced || NativeHomeStyle.previewReduced }
    private var active: Bool { hovered || focused != nil }

    var body: some View {
        HStack(spacing: NativeStyle.Space.sm) {
            HStack(spacing: 5) {
                Text(row.name).lineLimit(1).help(row.name)
                if dirty { Circle().fill(NativeHomeStyle.accent).frame(width: 3, height: 3) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if row.method == .directAmount {
                Color.clear.frame(width: NativeStyle.Layout.quantityWidth)
                Color.clear.frame(width: NativeStyle.Layout.unitPriceWidth)
                field("金额", text: $draft.amount, width: NativeStyle.Layout.amountWidth)
            } else {
                field("数量", text: $draft.quantity, width: NativeStyle.Layout.quantityWidth)
                if row.autoPriceSymbol != nil {
                    Text(row.price.map { $0.formatted(.number.precision(.fractionLength(2...6))) } ?? "—")
                        .monospacedDigit().frame(width: NativeStyle.Layout.unitPriceWidth, alignment: .trailing)
                        .foregroundStyle(NativeHomeStyle.secondary)
                        .accessibilityLabel(row.name + " 行情单价，只读")
                        .accessibilityValue(row.price.map { String($0) } ?? "—")
                        .help("当日行情价格")
                } else {
                    field("单价", text: $draft.price, width: NativeStyle.Layout.unitPriceWidth)
                }
                Text(amountPreview).monospacedDigit().frame(width: NativeStyle.Layout.amountWidth, alignment: .trailing)
                    .contentTransition(reduced ? .opacity : .numericText())
                    .animation(NativeStyle.Motion.records(reduced), value: amountPreview)
            }
            Menu { Button("删除资产项目", role: .destructive, action: delete).disabled(!canDelete) }
                label: { Image(systemName: "ellipsis").foregroundStyle(NativeHomeStyle.secondary).opacity(active ? 1 : 0.3).frame(width: 22, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(row.name + "操作")
        }.font(NativeStyle.FontRole.body).padding(.horizontal, NativeStyle.Space.sm).frame(height: NativeStyle.Layout.ledgerRowHeight)
            .background(NativeHomeStyle.accent.opacity(active ? 0.075 : 0))
            .overlay(alignment: .bottom) { Rectangle().fill(NativeHomeStyle.line.opacity(active ? 0.8 : 0.18)).frame(height: 0.5) }
            .onHover { hovered = $0 }
            .animation(NativeStyle.Motion.records(reduced), value: active)
    }
    private var amountPreview: String {
        let q = Double(draft.quantity.replacingOccurrences(of: ",", with: ""))
        let p = Double(draft.price.replacingOccurrences(of: ",", with: ""))
        guard let q, let p, (q * p).isFinite else { return "—" }
        return (q * p).formatted(.number.precision(.fractionLength(2)))
    }
    private func field(_ name: String, text: Binding<String>, width: CGFloat) -> some View {
        let display = Binding<String>(get: {
            let raw = text.wrappedValue
            guard focused != name, !raw.isEmpty,
                  let value = Double(raw.replacingOccurrences(of: ",", with: "")), value.isFinite else { return raw }
            return value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(name == "数量" ? 0...6 : 2...6)))
        }, set: { text.wrappedValue = $0 })
        return TextField("—", text: display)
            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
            .accessibilityLabel("\(row.name) \(name)")
            .focused($focused, equals: name)
            .font(NativeStyle.FontRole.body).monospacedDigit()
            .foregroundStyle(name == "金额" || focused == name ? NativeHomeStyle.text : NativeHomeStyle.secondary)
            .padding(.horizontal, 7).frame(width: width, height: NativeStyle.Layout.ledgerFieldHeight)
            .background(NativeHomeStyle.text.opacity(active ? 0.025 : 0), in: RoundedRectangle(cornerRadius: NativeStyle.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).strokeBorder(
                focused == name ? NativeHomeStyle.accent.opacity(0.85) : NativeHomeStyle.line.opacity(active ? 1 : 0), lineWidth: 0.8))
            .animation(NativeStyle.Motion.records(reduced), value: focused)
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
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @FocusState private var nameFocused: Bool

    init(categories: [AssetCategory], initialGroup: AssetGroup = .financial, onSaved: @escaping () -> Void) {
        self.categories = categories
        self.onSaved = onSaved
        _selectedGroup = State(initialValue: initialGroup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加资产").font(NativeStyle.FontRole.dialogTitle)
            TextField("资产名称", text: $name).focused($nameFocused)
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
            if let error { Text(error).foregroundStyle(AssetTheme.negative).font(NativeStyle.FontRole.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加", action: save).buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 390).modifier(NativeWorkspaceSurface())
        .onAppear { nameFocused = true }
        .onExitCommand { dismiss() }
        .animation(NativeStyle.Motion.home(reducedMotion || NativeHomeStyle.previewReduced), value: valuationMethod)
        .animation(NativeStyle.Motion.home(reducedMotion || NativeHomeStyle.previewReduced), value: selectedCategoryID)
        .animation(NativeStyle.Motion.home(reducedMotion || NativeHomeStyle.previewReduced), value: error)
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
                        Text("云同步").font(NativeStyle.FontRole.sectionStrong)
                        Text(cloud.currentUser?.displayName ?? "未登录 · 可继续本机使用")
                            .font(NativeStyle.FontRole.body).foregroundStyle(NativePalette.secondary)
                        if let status = cloud.statusMessage { Text(status).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.positive) }
                        if let error = cloud.errorMessage { Text(error).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.negative) }
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
                        Text("本机数据").font(NativeStyle.FontRole.sectionStrong)
                        Text("\(history.summaries.count) 条历史记录")
                            .font(NativeStyle.FontRole.body).foregroundStyle(NativePalette.secondary)
                        HStack {
                            Button("导出 JSON", action: exportJSON)
                            Button("导入 JSON", action: importJSON)
                        }
                        if let message { Text(message).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.positive) }
                        if let error { Text(error).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.negative) }
                    }
                }
            }.padding(NativeStyle.Space.section)
        }
        .task {
            if AppPreviewSession.isActive, ProcessInfo.processInfo.arguments.contains("-macLoginCapture") {
                showsLogin = true
            }
        }
        .sheet(isPresented: $showsLogin) {
            NativeAccountChoice(cloud: cloud, allowsOffline: false) { showsLogin = false }
                .environment(\.modelContext, context)
        }
        .alert("确认关联到当前账户？", isPresented: $showOwnershipConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认并同步") { Task { await cloud.authorizeLocalDataForCurrentAccount(from: context) } }
        } message: { Text("确认本机记录属于当前账户？合并前会保留备份；冲突时暂停，不覆盖两端记录。") }
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @ObservedObject var cloud: AssetTimeMachineCloudStore
    var allowsOffline = true
    let done: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var isShowingPassword = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case username, password }
    private var canLogin: Bool { !username.isEmpty && !password.isEmpty && !cloud.isWorking }

    var body: some View {
        VStack(spacing: 0) {
            Image("brand_logo")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: NativeStyle.Radius.panel))
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    Button(action: done) {
                        Image(systemName: "xmark")
                            .font(NativeStyle.FontRole.captionStrong)
                            .foregroundStyle(NativeHomeStyle.secondary)
                            .frame(width: 28, height: 28)
                            .background(NativeHomeStyle.text.opacity(0.045), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(NativeHomeButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭")
                }
            Text("登录资产时光机")
                .font(NativeStyle.FontRole.pageTitle)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, NativeStyle.Space.xl)
                .padding(.bottom, 30)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task {
                    await cloud.handleAppleSignIn(result, from: context)
                    if cloud.currentUser != nil { done() }
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 42)
            .clipShape(RoundedRectangle(cornerRadius: NativeStyle.Radius.field))
            .disabled(cloud.isWorking || AppPreviewSession.isActive)

            Button {
                withAnimation(NativeStyle.Motion.home(reducedMotion || NativeHomeStyle.previewReduced)) {
                    isShowingPassword.toggle()
                }
                focusedField = isShowingPassword ? .username : nil
            } label: {
                HStack {
                    Text("账号登录").font(NativeStyle.FontRole.action)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(NativeStyle.FontRole.microStrong)
                        .rotationEffect(.degrees(isShowingPassword ? 90 : 0))
                }
                .foregroundStyle(NativeHomeStyle.secondary)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(NativeHomeButtonStyle())
            .accessibilityValue(isShowingPassword ? "已展开" : "已收起")
            .padding(.top, NativeStyle.Space.sm)

            if isShowingPassword {
                VStack(spacing: 10) {
                    TextField("账号", text: $username)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                        .modifier(AccountFieldStyle(isFocused: focusedField == .username))
                    SecureField("密码", text: $password)
                        .focused($focusedField, equals: .password)
                        .onSubmit { if canLogin { login() } }
                        .modifier(AccountFieldStyle(isFocused: focusedField == .password))
                    Button(action: login) {
                        HStack(spacing: NativeStyle.Space.sm) {
                            if cloud.isWorking { ProgressView().controlSize(.small) }
                            Text("登录")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .font(NativeStyle.FontRole.action)
                        .foregroundStyle(NativePalette.onAccent)
                        .background(NativeHomeStyle.accent, in: RoundedRectangle(cornerRadius: NativeStyle.Radius.field))
                    }
                    .buttonStyle(NativeHomeButtonStyle())
                    .disabled(!canLogin || AppPreviewSession.isActive)
                    .padding(.top, NativeStyle.Space.xxs)
                }
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .offset(y: reducedMotion ? 0 : -6)))
            }
            if let error = cloud.errorMessage {
                Text(error).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
            }
            if allowsOffline {
                Rectangle().fill(NativeHomeStyle.line).frame(height: 1)
                    .padding(.top, NativeStyle.Space.sm)
                Button("先在本机使用", action: done)
                    .font(NativeStyle.FontRole.caption)
                    .foregroundStyle(NativeHomeStyle.secondary)
                    .buttonStyle(NativeHomeButtonStyle())
                    .padding(.top, NativeStyle.Space.xl)
            }
        }
        .padding(NativeStyle.Space.page)
        .frame(width: 368)
        .foregroundStyle(NativeHomeStyle.text)
        .background(NativeHomeStyle.ink)
        .tint(NativeHomeStyle.accent)
        .task {
            if AppPreviewSession.isActive, ProcessInfo.processInfo.arguments.contains("-macLoginExpanded") {
                isShowingPassword = true
            }
        }
    }

    private func login() {
        guard canLogin else { return }
        Task {
            await cloud.login(username: username, password: password)
            if cloud.currentUser != nil {
                cloud.scheduleAutoSync(from: context, quietly: false, delayNanoseconds: 0)
                done()
            }
        }
    }
}
