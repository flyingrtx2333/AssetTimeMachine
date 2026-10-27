import AppKit
import AuthenticationServices
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private func nativeCloudErrorText(_ message: String) -> String {
    guard message.contains(NSURLErrorDomain) else { return message }
    if message.contains("-1009") { return AppLocalization.string("网络未连接") }
    if message.contains("-1001") { return AppLocalization.string("连接超时，请重试") }
    if message.contains("-999") { return AppLocalization.string("操作已取消") }
    return AppLocalization.string("网络连接失败，请重试")
}

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
                           group: item.category?.group ?? .financial, icon: AssetItemService.resolvedIconKey(for: item),
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

enum NativeRecordDestination: Equatable {
    case snapshot(UUID)
    case today
}

private struct NativeLedgerColumns {
    static let horizontalInset: CGFloat = 12
    static let menuWidth: CGFloat = 22
    let quantity: CGFloat
    let unitPrice: CGFloat
    let amount: CGFloat

    init(width: CGFloat) {
        let innerWidth = max(0, width - Self.horizontalInset * 2)
        quantity = max(80, min(136, innerWidth * 0.17))
        unitPrice = max(96, min(152, innerWidth * 0.18))
        amount = max(116, min(196, innerWidth * 0.22))
    }
}

struct NativeRecordsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AssetCategory.createdAt) private var categories: [AssetCategory]
    @ObservedObject var history: NativeHistoryModel
    @ObservedObject var cloud: AssetTimeMachineCloudStore
    @ObservedObject var editor: NativeRecordEditor
    @Binding var requestedDestination: NativeRecordDestination?
    @State private var addingGroup: AssetGroup?
    @State private var deleteRecord = false
    @State private var deletingItem: NativeRecordEditor.Row?
    @State private var confirmsDiscard = false
    @State private var ledgerWidth: CGFloat = 752

    private func money(_ value: Double) -> String { value.formatted(.currency(code: "CNY").precision(.fractionLength(2))) }
    private func total(_ group: AssetGroup) -> Double {
        editor.rows.filter { $0.group == group }.reduce(0) { $0 + editor.displayedAmount(for: $1) }
    }
    private var selectedIndex: Int? { history.summaries.firstIndex { $0.id == editor.snapshotID } }
    private var ledgerColumns: NativeLedgerColumns { NativeLedgerColumns(width: ledgerWidth) }

    @State private var collapsedGroups: Set<AssetGroup> = []
    @State private var showsUnfilled = false
    @State private var expandedZeroGroups: Set<AssetGroup> = []
    @State private var pendingDestination: NativeRecordDestination?
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
                metric("净资产", value: total(.financial) + total(.physical) - total(.liability), emphasized: true)
                Rectangle().fill(NativeHomeStyle.line).frame(width: 0.5, height: 18)
                metric("总资产", value: total(.financial) + total(.physical))
                Rectangle().fill(NativeHomeStyle.line).frame(width: 0.5, height: 18)
                metric("负债", value: total(.liability))
                Spacer(minLength: 0)
            }.padding(.vertical, 12)
            if editor.snapshotID != nil {
                VStack(spacing: 0) {
                    columnHeadings
                    Divider()
                    ScrollView {
                        VStack(spacing: 0) {
                            groupPanel(.financial)
                            groupPanel(.physical).padding(.top, 4)
                            groupPanel(.liability).padding(.top, 4)
                            if !unfilled.isEmpty {
                                Button {
                                    withAnimation(NativeStyle.Motion.records(reduced)) { showsUnfilled.toggle() }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "chevron.right").rotationEffect(.degrees(showsUnfilled ? 90 : 0))
                                        Text("未填写 (\(unfilled.count))")
                                        Spacer()
                                    }.padding(.horizontal, 12).frame(height: 28)
                                }.buttonStyle(.plain).foregroundStyle(NativeHomeStyle.secondary)
                                if showsUnfilled {
                                    VStack(spacing: 0) { ForEach(unfilled) { accountRow($0) } }
                                        .transition(disclosureTransition)
                                }
                            }
                        }.padding(.bottom, 8)
                    }.scrollIndicators(.automatic)
                }
                .background(NativePalette.canvas)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if width > 0 { ledgerWidth = width }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NativePalette.line, lineWidth: 0.7))
            } else {
                ContentUnavailableView("暂无记录", systemImage: "calendar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .font(NativeStyle.FontRole.body)
        .padding(.horizontal, NativeStyle.Layout.pageInset).padding(.top, 16).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeOutsideClickDismissal())
        .modifier(NativeWorkspaceSurface())
        .animation(NativeStyle.Motion.records(reduced), value: editor.isDirty)
        .animation(NativeStyle.Motion.records(reduced), value: editor.error)
        .animation(NativeStyle.Motion.records(reduced), value: editor.savedAt)
        .task {
            if requestedDestination != nil { openRequestedDestination() }
            else if !editor.isDirty { editor.load(id: editor.snapshotID ?? history.summaries.last?.id, container: context.container) }
        }
        .onChange(of: requestedDestination) { _, destination in if destination != nil { openRequestedDestination() } }
        .onChange(of: history.generation) { _, _ in
            let id = history.summaries.contains { $0.id == editor.snapshotID } ? editor.snapshotID : history.summaries.last?.id
            editor.load(id: id, container: context.container)
        }
        .sheet(item: $addingGroup) { group in
            NativeAddItemSheet(categories: categories, initialGroup: group, onSaved: refresh)
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmsDiscard) {
            Button("放弃修改", role: .destructive) {
                let destination = pendingDestination
                pendingDestination = nil
                withAnimation(NativeStyle.Motion.records(reduced)) {
                    editor.discard()
                    if let destination { performDestination(destination) }
                    else { editor.load(id: editor.snapshotID, container: context.container) }
                }
            }
        }
        .onChange(of: confirmsDiscard) { _, presented in if !presented { pendingDestination = nil } }
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
        HStack(spacing: 8) {
            Button { moveDate(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).frame(width: 22, height: 28)
                .accessibilityLabel("上一条记录").disabled((selectedIndex ?? 0) == 0)
            Menu {
                Section("最近记录") {
                    ForEach(Array(history.summaries.suffix(90).reversed()), id: \.id) { snapshot in
                        Button(snapshot.date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))) {
                            selectDestination(.snapshot(snapshot.id))
                        }
                    }
                }
            } label: {
                Label(editor.date.map { $0.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) } ?? "暂无记录",
                      systemImage: "calendar")
                    .monospacedDigit().lineLimit(1)
            }.menuStyle(.borderedButton).fixedSize()
                .disabled(history.summaries.isEmpty).accessibilityLabel("选择记录日期")
                .accessibilityValue(editor.date.map { $0.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) } ?? "暂无记录")
            Button { moveDate(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).frame(width: 22, height: 28)
                .accessibilityLabel("下一条记录").disabled((selectedIndex ?? 0) >= history.summaries.count - 1)
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button { addingGroup = .financial } label: { Label("添加资产", systemImage: "plus") }
                .buttonStyle(.bordered).controlSize(.regular).disabled(editor.isDirty)
            Spacer(minLength: 8)
            if editor.isDirty {
                Text("修改 \(editor.drafts.count) 项").font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                Button("放弃修改") { pendingDestination = nil; confirmsDiscard = true }
                    .buttonStyle(.bordered).controlSize(.regular)
                Button("保存更改", action: saveChanges)
                    .keyboardShortcut("s", modifiers: .command).modifier(NativeRecordsPrimary())
            }
            Menu {
                Button("删除这天的记录", role: .destructive) { deleteRecord = true }
                    .disabled(editor.isDirty || editor.snapshotID == nil)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                .accessibilityLabel("记录操作")
        }.frame(height: 30)
    }
    private func metric(_ title: String, value: Double, emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NativeStyle.Space.sm) {
            Text(title).font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            Text(money(value)).font(emphasized ? NativeStyle.FontRole.bodyStrong : NativeStyle.FontRole.body).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
                .contentTransition(reduced ? .opacity : .numericText())
        }.frame(maxWidth: .infinity, alignment: .leading)
            .animation(NativeStyle.Motion.records(reduced), value: value)
    }
    private var columnHeadings: some View {
        HStack(spacing: NativeStyle.Space.sm) {
            Text("资产").frame(maxWidth: .infinity, alignment: .leading)
            Text("数量").padding(.horizontal, 7).frame(width: ledgerColumns.quantity, alignment: .trailing)
            Text("单价 (¥)").padding(.horizontal, 7).frame(width: ledgerColumns.unitPrice, alignment: .trailing)
            Text("金额 (¥)").padding(.horizontal, 7).frame(width: ledgerColumns.amount, alignment: .trailing)
            Color.clear.frame(width: NativeLedgerColumns.menuWidth)
        }.font(NativeStyle.FontRole.caption).foregroundStyle(NativeHomeStyle.secondary)
            .padding(.horizontal, NativeLedgerColumns.horizontalInset).frame(height: 26).background(NativePalette.surface)
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
                    }.font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                        .padding(.horizontal, 12).frame(height: NativeStyle.Layout.ledgerGroupHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(group.displayName + (collapsedGroups.contains(group) ? "，展开" : "，收起"))
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
        NativeLedgerRow(row: row, columns: ledgerColumns, draft: Binding(
            get: { editor.drafts[row.id] ?? row.draft },
            set: { editor.update(row, draft: $0) }
        ), dirty: editor.drafts[row.id] != nil, alternating: (editor.rows.firstIndex(where: { $0.id == row.id }) ?? 0).isMultiple(of: 2), canDelete: !editor.isDirty,
        delete: { deletingItem = row })
    }
    private var footer: some View {
        VStack(spacing: NativeStyle.Space.md) {
            Rectangle().fill(NativeHomeStyle.line).frame(height: 0.5)
            HStack(spacing: 10) {
                Group {
                    if let error = editor.error { Text(error).foregroundStyle(AssetTheme.negative) }
                    else if !editor.isDirty { Text(savedStatus).foregroundStyle(NativeHomeStyle.secondary).help(cloud.errorMessage ?? cloud.indicatorLabel) }
                }.font(NativeStyle.FontRole.caption).transition(.opacity)
                Spacer(minLength: 4)
            }.frame(minHeight: 18)
        }
    }

    private func saveChanges() {
        withAnimation(NativeStyle.Motion.records(reduced)) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            if editor.save(container: context.container) { refresh() }
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
        selectDestination(.snapshot(history.summaries[index + offset].id))
    }
    private func openRequestedDestination() {
        guard let destination = requestedDestination else { return }
        requestedDestination = nil
        selectDestination(destination)
    }
    private func selectDestination(_ destination: NativeRecordDestination) {
        if case .snapshot(let id) = destination, id == editor.snapshotID { return }
        if editor.isDirty { pendingDestination = destination; confirmsDiscard = true }
        else { withAnimation(NativeStyle.Motion.records(reduced)) { performDestination(destination) } }
    }
    private func performDestination(_ destination: NativeRecordDestination) {
        switch destination {
        case .snapshot(let id): editor.load(id: id, container: context.container)
        case .today: recordToday()
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
    let columns: NativeLedgerColumns
    @Binding var draft: NativeRecordEditor.Draft
    let dirty: Bool
    let alternating: Bool
    let canDelete: Bool
    let delete: () -> Void
    private var reduced: Bool { systemReduced || NativeHomeStyle.previewReduced }
    private var active: Bool { hovered || focused != nil }

    var body: some View {
        HStack(spacing: NativeStyle.Space.sm) {
            HStack(spacing: 5) {
                NativeAssetIcon(key: row.icon, group: row.group, title: row.name)
                Text(row.name).lineLimit(2).lineSpacing(-2).truncationMode(.middle).help(row.name)
                if dirty { Circle().fill(NativeHomeStyle.accent).frame(width: 3, height: 3) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if row.method == .directAmount {
                Text("—").foregroundStyle(NativePalette.secondary.opacity(0.6))
                    .padding(.horizontal, 7).frame(width: columns.quantity, alignment: .trailing)
                Text("—").foregroundStyle(NativePalette.secondary.opacity(0.6))
                    .padding(.horizontal, 7).frame(width: columns.unitPrice, alignment: .trailing)
                field("金额", text: $draft.amount, width: columns.amount)
            } else {
                field("数量", text: $draft.quantity, width: columns.quantity)
                if row.autoPriceSymbol != nil {
                    Text(row.price.map { $0.formatted(.number.precision(.fractionLength(2...6))) } ?? "—")
                        .monospacedDigit().padding(.horizontal, 7).frame(width: columns.unitPrice, alignment: .trailing)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(NativeHomeStyle.secondary)
                        .accessibilityLabel(row.name + " 行情单价，只读")
                        .accessibilityValue(row.price.map { String($0) } ?? "—")
                        .help("当日行情价格")
                } else {
                    field("单价", text: $draft.price, width: columns.unitPrice)
                }
                Text(amountPreview).monospacedDigit().padding(.horizontal, 7).frame(width: columns.amount, alignment: .trailing)
                    .contentTransition(reduced ? .opacity : .numericText())
                    .animation(NativeStyle.Motion.records(reduced), value: amountPreview)
            }
            Menu { Button("删除资产项目", role: .destructive, action: delete).disabled(!canDelete) }
                label: { Image(systemName: "ellipsis").foregroundStyle(NativeHomeStyle.secondary).opacity(active ? 1 : 0.3).frame(width: NativeLedgerColumns.menuWidth, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(row.name + "操作")
        }.font(NativeStyle.FontRole.body).padding(.horizontal, NativeLedgerColumns.horizontalInset).frame(height: NativeStyle.Layout.ledgerRowHeight)
            .background(active ? NativePalette.softGold : (alternating ? NativePalette.surface.opacity(0.55) : .clear))
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
            .background(NativePalette.canvas.opacity(focused == name ? 1 : 0), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: NativeStyle.Radius.control).strokeBorder(
                focused == name ? NativeHomeStyle.accent.opacity(0.85) : NativeHomeStyle.line.opacity(hovered ? 0.7 : 0), lineWidth: 0.8))
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
        _selectedCategoryID = State(initialValue: categories.first(where: { $0.group == initialGroup })?.id)
    }

    var body: some View {
        NativeSheet(title: "添加资产", width: 416, cancel: { dismiss() }) {
            VStack(spacing: 8) {
                NativeFormRow(title: "资产名称") {
                    TextField("资产名称", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                        .onSubmit { if !name.trimmingCharacters(in: .whitespaces).isEmpty { save() } }
                }
                NativeFormRow(title: "类型") {
                    NativeFormPicker(title: "类型", options: AssetGroup.allCases.map(\.displayName),
                                     selectedIndex: AssetGroup.allCases.firstIndex(of: selectedGroup) ?? 0) {
                        selectedGroup = AssetGroup.allCases[$0]
                    }.frame(height: 26)
                }
                NativeFormRow(title: "计价方式") {
                    NativeFormPicker(title: "计价方式", options: ValuationMethod.allCases.map(\.displayName),
                                     selectedIndex: ValuationMethod.allCases.firstIndex(of: valuationMethod) ?? 0) {
                        valuationMethod = ValuationMethod.allCases[$0]
                    }.frame(height: 26)
                }
                if valuationMethod == .quantityAndUnitPrice {
                    NativeFormRow(title: "行情代码") {
                        TextField("可选", text: $marketSymbol).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("行情代码（可选）")
                    }
                }
                NativeFormRow(title: "分类") {
                    let available = categories.filter { $0.group == selectedGroup }
                    NativeFormPicker(title: "分类", options: [AppLocalization.string("新建分类")] + available.map(\.name),
                                     selectedIndex: available.firstIndex(where: { $0.id == selectedCategoryID }).map { $0 + 1 } ?? 0) {
                        selectedCategoryID = $0 == 0 ? nil : available[$0 - 1].id
                    }.frame(height: 26)
                }
                if selectedCategoryID == nil {
                    NativeFormRow(title: "新分类名称") {
                        TextField("新分类名称", text: $newCategory).textFieldStyle(.roundedBorder)
                    }
                }
                if let error { Text(error).foregroundStyle(AssetTheme.negative).font(NativeStyle.FontRole.caption) }
            }
        } footer: {
            NativeSheetActions(cancel: { dismiss() }, title: "添加", submit: save,
                               disabled: name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { nameFocused = true }
        .onExitCommand { dismiss() }
        .onChange(of: selectedGroup) { _, group in
            selectedCategoryID = categories.first(where: { $0.group == group })?.id
        }
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
    let openCloudSync: () -> Void
    @State private var showsLogin = false
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("账户与同步").font(NativeStyle.FontRole.captionStrong).foregroundStyle(NativePalette.secondary)
                    Button(action: openCloudSync) {
                        HStack(spacing: 10) {
                            Image(systemName: cloud.indicatorState.cloudSymbolName)
                                .foregroundStyle(cloud.indicatorState.symbolColor).frame(width: 22)
                            Text("云同步")
                            Spacer(minLength: 12)
                            Text(cloud.currentUser.map { $0.displayName + " · " + cloud.indicatorLabel } ?? cloud.indicatorLabel)
                                .foregroundStyle(NativePalette.secondary).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.right").font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                        }.padding(.horizontal, 14).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("云同步")
                        .accessibilityValue(cloud.indicatorLabel)
                        .background(NativePalette.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(NativePalette.line, lineWidth: 0.7))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("本机数据").font(NativeStyle.FontRole.captionStrong).foregroundStyle(NativePalette.secondary)
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(NativePalette.secondary).frame(width: 22)
                        Text("\(history.summaries.count) 条历史记录")
                        Spacer(minLength: 12)
                        Button("导入记录", action: importJSON).buttonStyle(.bordered).controlSize(.regular)
                        Button("导出记录", action: exportJSON).buttonStyle(.bordered).controlSize(.regular)
                    }.padding(.horizontal, 14).frame(minHeight: 48)
                        .background(NativePalette.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(NativePalette.line, lineWidth: 0.7))
                    Group {
                        if let message { Text(message).foregroundStyle(AssetTheme.positive) }
                        if let error { Text(error).foregroundStyle(AssetTheme.negative) }
                    }.font(NativeStyle.FontRole.caption).textSelection(.enabled)
                }
            }
            .font(NativeStyle.FontRole.body)
            .frame(maxWidth: 680)
            .padding(NativeStyle.Layout.pageInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .modifier(NativeWorkspaceSurface())
        .task {
            if AppPreviewSession.isActive, ProcessInfo.processInfo.arguments.contains("-macLoginCapture") { showsLogin = true }
        }
        .sheet(isPresented: $showsLogin) {
            NativeAccountChoice(cloud: cloud, allowsOffline: false) { showsLogin = false }
                .environment(\.modelContext, context)
        }
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

struct NativeCloudSyncView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloud: AssetTimeMachineCloudStore
    @State private var showsLogin = false
    @State private var confirmsRestore = false
    @State private var confirmsOwnership = false
    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var showsEntryReview = false

    private var busy: Bool { cloud.isWorking || isExporting }
    private var sheetHeight: CGFloat {
        if showsEntryReview { return 440 }
        let errorHeight: CGFloat = cloud.errorMessage?.isEmpty == false ? 40 : 0
        guard cloud.currentUser != nil else { return 176 + errorHeight }
        return min(472, 280 + CGFloat(min(cloud.backups.count, 3)) * 38 + errorHeight
                   + (cloud.requiresLocalOwnershipConfirmation ? 34 : 0))
    }
    private var title: String {
        switch cloud.indicatorState {
        case .healthy: AppLocalization.string("云同步已启用")
        case .checking: cloud.indicatorLabel
        case .warning: AppLocalization.string("同步状态需处理")
        case .idle: AppLocalization.string("启用云同步")
        }
    }

    var body: some View {
        Group {
            if showsLogin {
                NativeAccountChoice(cloud: cloud, allowsOffline: false, width: 448) { showsLogin = false }
                    .environment(\.modelContext, context)
            } else if showsEntryReview, let review = cloud.entryConflictReview {
                NativeSheet("同步差异", width: 448, height: sheetHeight, close: { showsEntryReview = false }) {
                    CloudSyncEntryReviewView(review: review, busy: busy,
                        cancel: { showsEntryReview = false }) { choices in
                        if await cloud.confirmEntryConflicts(reviewID: review.id, choices: choices, from: context) {
                            showsEntryReview = false
                        }
                    }.id(review.id)
                }
            } else {
                NativeSheet("云同步", width: 448, height: sheetHeight, close: { dismiss() }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: cloud.indicatorState.cloudSymbolName)
                                    .font(NativeStyle.FontRole.metric)
                                    .foregroundStyle(cloud.indicatorState.symbolColor)
                                    .frame(width: 24, height: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title).font(NativeStyle.FontRole.bodyStrong)
                                    if let date = cloud.lastSyncAt {
                                        Text(AppLocalization.format("最近同步 %@", date.formatted(date: .abbreviated, time: .shortened)))
                                            .font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if cloud.isWorking { ProgressView().controlSize(.small) }
                            }
                            if let error = cloud.errorMessage, !error.isEmpty {
                                Label(nativeCloudErrorText(error), systemImage: "exclamationmark.triangle.fill")
                                    .font(NativeStyle.FontRole.body).foregroundStyle(AssetTheme.negative)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(error)
                            }
                            if cloud.entryConflictReview != nil {
                                Button(AppLocalization.string("查看差异")) { showsEntryReview = true }
                                    .buttonStyle(.borderedProminent).tint(NativePalette.accent).disabled(busy)
                            }
                            if cloud.currentUser == nil {
                                if !cloud.isSessionPending {
                                    action("登录", symbol: "person.crop.circle", primary: true) { showsLogin = true }
                                        .disabled(busy)
                                }
                            } else {
                                if cloud.requiresLocalOwnershipConfirmation {
                                    action("关联并同步本机记录", symbol: "link", primary: true) { confirmsOwnership = true }
                                        .disabled(busy)
                                }
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack {
                                        Text(AppLocalization.string("最近备份")).font(NativeStyle.FontRole.captionStrong).foregroundStyle(NativePalette.secondary)
                                        Spacer()
                                        Button { Task { await refresh() } } label: {
                                            Label(AppLocalization.string("刷新"), systemImage: "arrow.clockwise")
                                        }
                                        .buttonStyle(.borderless).controlSize(.small)
                                        .disabled(busy)
                                    }.frame(height: 28)
                                    if cloud.backups.isEmpty {
                                        Text(AppLocalization.string("暂无云端备份"))
                                            .font(NativeStyle.FontRole.body).foregroundStyle(NativePalette.secondary)
                                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                    } else {
                                        ForEach(Array(cloud.backups.prefix(3))) { backup in
                                            HStack(spacing: 8) {
                                                Image(systemName: backup.isLatest == 1 ? "icloud.fill" : "clock.arrow.circlepath")
                                                    .foregroundStyle(NativePalette.secondary).frame(width: 20)
                                                Text(backup.uploadedAt.formatted(date: .abbreviated, time: .shortened))
                                                    .font(NativeStyle.FontRole.body).monospacedDigit().lineLimit(1)
                                                Spacer(minLength: 8)
                                                if let size = backup.fileSize {
                                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                        .font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                                                }
                                                if backup.isLatest == 1 {
                                                    Text(AppLocalization.string("最新")).font(NativeStyle.FontRole.micro)
                                                        .foregroundStyle(NativePalette.accent)
                                                }
                                            }.frame(height: 36)
                                            .accessibilityElement(children: .combine)
                                            Divider()
                                        }
                                    }
                                }
                                HStack(spacing: 8) {
                                    action("导出本机记录", symbol: "square.and.arrow.up") { Task { await exportRecords() } }
                                    if !cloud.backups.isEmpty {
                                        action("恢复最近一次备份", symbol: "arrow.clockwise.icloud") { confirmsRestore = true }
                                    }
                                }
                                .disabled(busy)
                                if let exportMessage {
                                    Text(exportMessage).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.positive)
                                }
                                HStack {
                                    Text(cloud.currentUser?.displayName ?? "")
                                        .font(NativeStyle.FontRole.caption).foregroundStyle(NativePalette.secondary)
                                    Spacer()
                                    Button(AppLocalization.string("退出登录")) { cloud.logout() }
                                        .buttonStyle(.borderless).controlSize(.small).disabled(busy)
                                }.padding(.top, 4)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 448, height: showsLogin ? nil : sheetHeight)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(NativeWorkspaceSurface())
        .task { await refresh() }
        .onChange(of: cloud.entryConflictReview?.id) { _, id in
            if id == nil { showsEntryReview = false }
        }
        .alert(AppLocalization.format("确认关联至 %@？", cloud.currentUser?.displayName ?? "—"), isPresented: $confirmsOwnership) {
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确认并同步")) { Task { await cloud.authorizeLocalDataForCurrentAccount(from: context) } }
        } message: {
            Text(AppLocalization.string("确认本机记录属于当前账户？合并前会保留备份；冲突时暂停，不覆盖两端记录。"))
        }
        .alert(AppLocalization.string("从云端恢复最新备份？"), isPresented: $confirmsRestore) {
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("恢复备份"), role: .destructive) {
                Task { await cloud.restoreLatestBackup(into: context) }
            }
        } message: {
            Text(AppLocalization.string("会使用云端最新备份更新本机记录。"))
        }
    }

    @ViewBuilder private func action(_ title: String, symbol: String, primary: Bool = false, perform: @escaping () -> Void) -> some View {
        let button = Button(action: perform) {
            Label(AppLocalization.string(title), systemImage: symbol)
                .font(NativeStyle.FontRole.body)
        }.controlSize(.regular)
        if primary { button.modifier(NativeWorkspacePrimary()) }
        else { button.buttonStyle(.bordered) }
    }

    private func refresh() async {
        guard !AppPreviewSession.isActive, !cloud.isWorking else { return }
        await cloud.refreshIfNeeded(from: context)
    }

    private func exportRecords() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await cloud.exportLocalRecords(from: context)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "AssetTimeMachine-Local.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            exportMessage = AppLocalization.string("导出成功")
        } catch { cloud.errorMessage = error.localizedDescription }
    }
}

struct NativeAccountChoice: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @ObservedObject var cloud: AssetTimeMachineCloudStore
    var allowsOffline = true
    var width: CGFloat = 416
    let done: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var isShowingPassword = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case username, password }
    private var canLogin: Bool { !username.isEmpty && !password.isEmpty && !cloud.isWorking }

    var body: some View {
        NativeSheet(title: "登录资产时光机", width: width, cancel: done) {
            VStack(spacing: 8) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    Task {
                        await cloud.handleAppleSignIn(result, from: context)
                        if cloud.currentUser != nil { done() }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 32).disabled(cloud.isWorking || AppPreviewSession.isActive)
                Button {
                    isShowingPassword.toggle()
                    focusedField = isShowingPassword ? .username : nil
                } label: {
                    HStack {
                        Text("账号登录")
                        Spacer()
                        Image(systemName: isShowingPassword ? "chevron.down" : "chevron.right")
                    }.frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(isShowingPassword ? "已展开" : "已收起")
                if isShowingPassword {
                    NativeFormRow(title: "账号") {
                        TextField("账号", text: $username).focused($focusedField, equals: .username)
                            .onSubmit { focusedField = .password }
                            .modifier(AccountFieldStyle())
                    }
                    NativeFormRow(title: "密码") {
                        SecureField("密码", text: $password).focused($focusedField, equals: .password)
                            .onSubmit { if canLogin { login() } }
                            .modifier(AccountFieldStyle())
                    }
                }
                if cloud.isWorking { ProgressView().controlSize(.small) }
                if let error = cloud.errorMessage {
                    Text(nativeCloudErrorText(error)).font(NativeStyle.FontRole.caption).foregroundStyle(AssetTheme.negative)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(4)
                        .help(error)
                }
            }
        } footer: {
            HStack(spacing: 12) {
                Button(AppLocalization.string(allowsOffline ? "先在本机使用" : "取消"), action: done)
                    .keyboardShortcut(.cancelAction).buttonStyle(.bordered).controlSize(.regular)
                Spacer()
                if isShowingPassword {
                    Button("登录", action: login).modifier(NativeWorkspacePrimary())
                        .disabled(!canLogin || AppPreviewSession.isActive).keyboardShortcut(.defaultAction)
                }
            }
        }
        .onExitCommand(perform: done)
        .task {
            if AppPreviewSession.isActive, ProcessInfo.processInfo.arguments.contains("-macLoginExpanded") {
                isShowingPassword = true; focusedField = .username
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
