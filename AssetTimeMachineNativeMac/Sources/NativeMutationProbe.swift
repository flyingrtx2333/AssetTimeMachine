import Foundation
import SwiftData

/// Runs only with an explicit isolated fixture store; never touches the signed account.
@MainActor
enum NativeMutationProbe {
    static func run(context: ModelContext, history: NativeHistoryModel, importJSON: URL) async -> [String: Any] {
        guard AppPreviewSession.isActive,
              let latest = history.summaries.last else {
            return ["error": "isolated test store required"]
        }
        let baselineCount = history.summaries.count
        let baselineAssets = latest.totalAssets
        do {
            let id = latest.id
            var descriptor = FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let snapshot = try context.fetch(descriptor).first,
                  let entry = snapshot.entries.first(where: { $0.item?.category?.group != .liability && $0.item != nil }),
                  let item = entry.item else { return ["error": "fixture has no editable entry"] }
            let originalAmount = entry.amount
            let originalQuantity = entry.quantity
            let originalUnitPrice = entry.unitPrice
            let originalNote = entry.note
            let changedAmount = entry.resolvedAmount + 77
            try SnapshotService.upsertEntry(snapshot: snapshot, item: item,
                                            amount: changedAmount, note: originalNote, in: context)
            await history.load(from: context.container, force: true)
            let editInvalidated = abs((history.summaries.last?.totalAssets ?? 0) - baselineAssets - 77) < 0.01

            try SnapshotService.upsertEntry(snapshot: snapshot, item: item,
                                            amount: originalAmount, quantity: originalQuantity,
                                            unitPrice: originalUnitPrice, note: originalNote, in: context)
            await history.load(from: context.container, force: true)
            let restoreInvalidated = abs((history.summaries.last?.totalAssets ?? 0) - baselineAssets) < 0.01

            try SyncDeletionService.record(entityID: snapshot.id, kind: .snapshot, in: context)
            context.delete(snapshot)
            try context.save()
            await history.load(from: context.container, force: true)
            let deleteInvalidated = history.summaries.count == baselineCount - 1

            let data = try Data(contentsOf: importJSON)
            try await ImportExportService.importJSON(data, into: context, replaceExisting: true)
            await history.load(from: context.container, force: true)
            let importInvalidated = history.summaries.count == baselineCount
                && abs((history.summaries.last?.totalAssets ?? 0) - baselineAssets) < 0.01
            return ["editInvalidated": editInvalidated,
                    "restoreInvalidated": restoreInvalidated,
                    "deleteInvalidated": deleteInvalidated,
                    "importInvalidated": importInvalidated,
                    "baselineCount": baselineCount,
                    "finalCount": history.summaries.count]
        } catch {
            return ["error": error.localizedDescription]
        }
    }
}

/// Explicit opt-in fixture for the C-layout record editor. Never runs against an account store.
@MainActor
enum NativeRecordEditorProbe {
    static func run(container: ModelContainer) -> [String: Bool] {
        guard AppPreviewSession.isActive else { return ["isolatedStore": false] }
        var results: [String: Bool] = [:]
        do {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            for item in try context.fetch(FetchDescriptor<AssetItem>()) { item.isActive = false }
            try context.save()
            let financial = AssetCategory(name: "金融资产", group: .financial)
            let physical = AssetCategory(name: "实物资产", group: .physical)
            let liability = AssetCategory(name: "负债", group: .liability)
            [financial, physical, liability].forEach(context.insert)
            let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30))!
            let snapshot = AssetSnapshot(date: day)
            context.insert(snapshot)
            let specs: [(String, AssetCategory, String, Double?, Bool)] = [
                ("招商银行活期", financial, "icon_bank_card", 12800, false),
                ("招商银行理财", financial, "icon_bank_card", 80000, false),
                ("微信", financial, "icon_wechat", 1260, false),
                ("支付宝", financial, "icon_alipay", 3520, false),
                ("金ETF", financial, "icon_gold", 20000, true),
                ("标普500ETF", financial, "chart.line.uptrend.xyaxis", 15800, false),
                ("房产", physical, "house.fill", 0, false),
                ("车辆", physical, "car.fill", 0, false),
                ("信用卡负债", liability, "icon_credit_card", 2400, false),
                ("花呗", liability, "icon_huabei", 0, false),
                ("备用银行卡", financial, "icon_bank_card", nil, false),
                ("车位", physical, "parkingsign.circle", nil, false)
            ]
            for (index, spec) in specs.enumerated() {
                let item = AssetItem(name: spec.0, valuationMethod: spec.4 ? .quantityAndUnitPrice : .directAmount,
                                     sortOrder: index, category: spec.1)
                item.iconName = spec.2
                context.insert(item)
                let entry = AssetEntry(amount: spec.4 ? nil : spec.3,
                    quantity: spec.4 ? 200 : nil, unitPrice: spec.4 ? 100 : nil,
                    note: "fixture note", snapshot: snapshot, item: item)
                context.insert(entry)
            }
            try context.save()
            let editor = NativeRecordEditor()
            editor.load(id: snapshot.id, container: container)
            let cash = editor.rows.first { $0.name == "招商银行活期" }!
            let gold = editor.rows.first { $0.name == "金ETF" }!
            var cashDraft = cash.draft; cashDraft.amount = "13000"
            var goldDraft = gold.draft; goldDraft.quantity = "invalid"
            editor.update(cash, draft: cashDraft)
            editor.update(gold, draft: goldDraft)
            results["draftBlocksSync"] = ModelContextMutationBarrier.shared.hasBlockingEditorDraft
            let invalidSaved = editor.save(container: container)
            let fresh = NativeRecordEditor(); fresh.load(id: snapshot.id, container: container)
            results["invalidBatchNoPartialWrite"] = !invalidSaved && fresh.rows.first { $0.id == cash.id }?.amount == 12800
            results["failedSaveRetainsDrafts"] = editor.drafts.count == 2
            editor.load(id: snapshot.id, container: container)
            results["reloadRetainsDirtyDraft"] = editor.drafts[cash.id]?.amount == "13000"
            goldDraft.quantity = "210"; goldDraft.price = "100"
            editor.update(gold, draft: goldDraft)
            results["batchSave"] = editor.save(container: container)
            fresh.load(id: snapshot.id, container: container)
            results["amountAndQuantityPersisted"] = fresh.rows.first { $0.id == cash.id }?.amount == 13000
                && fresh.rows.first { $0.id == gold.id }?.total == 21000
            results["notePreserved"] = fresh.rows.allSatisfy { $0.note == "fixture note" }
            results["saveReleasesDraftBarrier"] = !ModelContextMutationBarrier.shared.hasBlockingEditorDraft
            let currentCash = editor.rows.first { $0.id == cash.id }!
            var blank = currentCash.draft; blank.amount = ""
            editor.update(currentCash, draft: blank)
            results["clearAmount"] = editor.save(container: container)
                && editor.rows.first { $0.id == cash.id }?.amount == nil
            let cleared = editor.rows.first { $0.id == cash.id }!
            var pending = cleared.draft; pending.amount = "111"
            editor.update(cleared, draft: pending)
            let other = ModelContext(container)
            let sid = snapshot.id
            let otherSnapshot = try other.fetch(FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.id == sid })).first!
            let otherEntry = otherSnapshot.entries.first { $0.item?.id == cash.id }!
            otherEntry.amount = 12345; otherEntry.updatedAt = Date().addingTimeInterval(1)
            try other.save()
            results["conflictDoesNotOverwrite"] = !editor.save(container: container) && editor.isDirty
            editor.discard()
            results["discardReleasesBarrier"] = !ModelContextMutationBarrier.shared.hasBlockingEditorDraft
            // Restore the illustrative values for reproducible UI review.
            editor.load(id: snapshot.id, container: container)
            for row in editor.rows {
                if row.id == cash.id { var d = row.draft; d.amount = "12800"; editor.update(row, draft: d) }
                if row.id == gold.id { var d = row.draft; d.quantity = "200"; editor.update(row, draft: d) }
            }
            results["fixtureRestored"] = editor.save(container: container)
        } catch {
            NSLog("[NativeRecordEditorProbe] %@", error.localizedDescription)
            results["unexpectedError"] = false
        }
        return results
    }
}

// All HTTP requests in this probe are intercepted; it never uses real credentials or user stores.
private final class NativeCloudProbeTokens: CloudTokenStore {
    var access: String?; var refresh: String? = "synthetic-refresh"
    init(_ token: String = "synthetic-access") { access = token }
    func loadAccessToken() -> String? { access }
    func loadRefreshToken() -> String? { refresh }
    func save(accessToken: String, refreshToken: String?) throws { access = accessToken; refresh = refreshToken }
    func clear() throws { access = nil; refresh = nil }
}

private final class NativeCloudMockServer: @unchecked Sendable {
    let lock = NSLock()
    var payload: ExportPayload
    var head = 100
    var latestReads = 0; var uploads = 0; var acceptedUploads = 0; var refreshes = 0
    var offline = false; var rejectRefresh = false; var alwaysConflict = false; var noHead = false
    var beforeNextUpload: (() -> Void)?
    init(_ payload: ExportPayload) { self.payload = payload }

    func change(_ itemID: UUID, to amount: Double) {
        let changed = payload.snapshots.map { snapshot in
            ExportPayload.SnapshotPayload(id: snapshot.id, date: snapshot.date, note: snapshot.note,
                createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt,
                goldAnchorPriceCNY: nil, goldAnchorPriceDate: nil, btcAnchorPriceUSD: nil,
                btcAnchorPriceDate: nil, nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceDate: nil,
                usdPerCNY: nil, usdPerCNYDate: nil, marketAnchorsUpdatedAt: nil,
                entries: snapshot.entries.map { entry in
                    ExportPayload.EntryPayload(id: entry.id, amount: entry.itemID == itemID ? amount : entry.amount,
                        quantity: entry.quantity, unitPrice: entry.unitPrice, note: entry.note,
                        createdAt: entry.createdAt, updatedAt: entry.itemID == itemID ? .now : entry.updatedAt,
                        itemID: entry.itemID)
                })
        }
        payload = ExportPayload(exportedAt: .now, categories: payload.categories, items: payload.items,
                                snapshots: changed, deletions: payload.deletions)
        head += 1
    }

    func metadata() -> [String: Any] {
        ["id": head, "uploaded_at": "2026-09-30T00:00:00Z", "is_latest": 1,
         "file_name": "synthetic.json", "file_size": 100, "note": "isolated test"]
    }

    func response(_ request: URLRequest, body: Data?) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        if offline { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        var status = 200
        var object: Any
        if path.hasSuffix("/auth/refresh") {
            refreshes += 1
            status = rejectRefresh ? 401 : 200
            object = rejectRefresh ? ["detail": "synthetic expired session"]
                : ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "token_type": "bearer"]
        } else if request.value(forHTTPHeaderField: "Authorization")?.contains("synthetic-expired") == true {
            status = 401; object = ["detail": "synthetic expired access"]
        } else if path.hasSuffix("/cloud/latest") {
            latestReads += 1
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var value = metadata()
            value["payload"] = try JSONSerialization.jsonObject(with: encoder.encode(payload))
            if noHead { status = 404; object = ["detail": "no backup"] }
            else { object = value }
        } else if path.hasSuffix("/cloud/history") {
            if noHead { object = [[String: Any]]() } else { object = [metadata()] }
        }
        else if path.hasSuffix("/cloud/upload") {
            uploads += 1
            let action = beforeNextUpload; beforeNextUpload = nil; action?()
            let value = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any] ?? [:]
            let submittedBase = value["base_backup_id"] as? Int
            let baseConflict = noHead ? submittedBase != nil : submittedBase != head
            if alwaysConflict || baseConflict {
                status = 409; object = ["detail": "synthetic cloud head changed"]
            } else {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                payload = try decoder.decode(ExportPayload.self,
                    from: JSONSerialization.data(withJSONObject: value["payload"]!))
                head += 1; noHead = false; acceptedUploads += 1; object = metadata()
            }
        } else if path.hasSuffix("/users/me") { object = ["id": 11, "user_name": "Synthetic A"] }
        else { throw URLError(.unsupportedURL) }
        return (status, try JSONSerialization.data(withJSONObject: object))
    }
}

private final class NativeCloudMockProtocol: URLProtocol {
    nonisolated(unsafe) static var server: NativeCloudMockServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.server else { throw URLError(.unsupportedURL) }
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(buffer, count: count)
                }
                body = data
            }
            let (status, data) = try server.response(request, body: body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
enum NativeCloudSyncProbe {
    static func run() async -> [String: Any] {
        precondition(AppPreviewSession.isActive && ProcessInfo.processInfo.arguments.contains("-macCloudSyncProbe"))
        var checks: [String: Bool] = [:]
        let suite = "CloudSyncProbe-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); AssetTimeMachineCloudAPI.removeIsolatedTransport(); NativeCloudMockProtocol.server = nil }
        do {
            let schema = Schema([AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self,
                                 BacktestRecord.self, SyncDeletionTombstone.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            let context = ModelContext(container); context.autosaveEnabled = false
            let category = AssetCategory(name: "Synthetic", group: .financial)
            let a = AssetItem(name: "Synthetic A", category: category)
            let b = AssetItem(name: "Synthetic B", category: category)
            let snapshot = AssetSnapshot(date: Calendar.current.startOfDay(for: .now))
            context.insert(category); context.insert(a); context.insert(b); context.insert(snapshot)
            context.insert(AssetEntry(amount: 10, updatedAt: Date().addingTimeInterval(1000), snapshot: snapshot, item: a))
            context.insert(AssetEntry(amount: 20, updatedAt: Date().addingTimeInterval(1000), snapshot: snapshot, item: b))
            try context.save()
            let aID = a.id, bID = b.id, snapshotID = snapshot.id
            func local() async throws -> ExportPayload { try await ImportExportService.exportPayloadCooperatively(from: context).payload }
            func amount(_ payload: ExportPayload, _ itemID: UUID) -> Double? {
                payload.snapshots.flatMap(\.entries).first { $0.itemID == itemID }?.amount
            }
            func edit(_ itemID: UUID, _ value: Double) throws {
                let items = try context.fetch(FetchDescriptor<AssetItem>())
                let snapshots = try context.fetch(FetchDescriptor<AssetSnapshot>())
                guard let item = items.first(where: { $0.id == itemID }), let day = snapshots.first(where: { $0.id == snapshotID }) else { throw URLError(.cannotParseResponse) }
                try SnapshotService.upsertEntry(snapshot: day, item: item, amount: value, in: context)
            }
            let server = NativeCloudMockServer(try await local())
            NativeCloudMockProtocol.server = server
            AssetTimeMachineCloudAPI.installIsolatedTransport(NativeCloudMockProtocol.self)
            let tokens = NativeCloudProbeTokens()
            let cloud = AssetTimeMachineCloudStore(tokenStore: tokens, defaults: defaults, isolatedTest: true)
            cloud.currentUser = AssetTimeMachineCloudUser(id: 11, userName: "Synthetic A", userEmail: nil)
            _ = await cloud.runIsolatedSync(from: context)
            checks["initialMatchBindsOwnerWithoutUpload"] = defaults.integer(forKey: "assettimemachine.cloud.localOwnerUserID") == 11 && server.uploads == 0 && cloud.errorMessage == nil
            server.change(bID, to: 25)
            let reads = server.latestReads
            _ = await cloud.runIsolatedSync(from: context)
            let pulled = try await local()
            checks["unchangedLocalStillPullsRemote"] = server.latestReads > reads && amount(pulled, bID) == 25 && server.uploads == 0
            try edit(aID, 11)
            server.beforeNextUpload = { server.change(bID, to: 30) }
            let before = server.uploads
            _ = await cloud.runIsolatedSync(from: context)
            let retried = try await local()
            checks["cloud409RefetchesAndMergesBeforeRetry"] = server.uploads == before + 2 && amount(retried, aID) == 11 && amount(retried, bID) == 30 && cloud.errorMessage == nil
            checks["oneAcceptedUploadAfterConflict"] = server.acceptedUploads == 1
            let draft = ModelContextMutationBarrier.shared.beginEditorDraft()!
            let draftReads = server.latestReads
            let draftCompleted = await cloud.runIsolatedSync(from: context)
            checks["unsavedDraftBlocksNetworkAndImport"] = !draftCompleted && server.latestReads == draftReads
            ModelContextMutationBarrier.shared.finishEditorDraft(draft)
            try edit(aID, 12)
            server.offline = true
            let offlineRemote = server.payload
            _ = await cloud.runIsolatedSync(from: context)
            checks["offlinePreservesBothCopiesAndShowsError"] = amount(try await local(), aID) == 12 && SyncMergeService.isSameContent(server.payload, offlineRemote) && cloud.errorMessage != nil
            server.offline = false
            _ = await cloud.runIsolatedSync(from: context)
            checks["reconnectThenSyncPublishesSavedEdit"] = amount(server.payload, aID) == 12 && cloud.errorMessage == nil
            try edit(aID, 13)
            server.change(aID, to: 99)
            let conflictsUploads = server.uploads
            _ = await cloud.runIsolatedSync(from: context)
            checks["sameEntryConflictPreservesBothAndDoesNotUpload"] = amount(try await local(), aID) == 13 && amount(server.payload, aID) == 99 && server.uploads == conflictsUploads && cloud.errorMessage != nil
            await cloud.restoreLatestBackup(into: context)
            let afterRestore = try await local()
            checks["explicitRestoreCreatesSafetyBackup"] = defaults.string(forKey: "assettimemachine.cloud.lastLocalSafetyBackup").map { FileManager.default.fileExists(atPath: $0) } == true && SyncMergeService.isSameContent(afterRestore, server.payload)
            let baselineFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("CloudSyncProbe-" + String(ObjectIdentifier(defaults).hashValue))
                .appendingPathComponent("account-11.json")
            let baselineData = try Data(contentsOf: baselineFile)
            try edit(aID, 14)
            let protectedPayload = try await local(), protectedUploads = server.uploads
            try Data("invalid baseline".utf8).write(to: baselineFile)
            _ = await cloud.runIsolatedSync(from: context)
            let afterCorrupt = try await local()
            checks["corruptBaselineStopsWithoutDataChanges"] = cloud.errorMessage != nil && server.uploads == protectedUploads && SyncMergeService.isSameContent(afterCorrupt, protectedPayload)
            try FileManager.default.removeItem(at: baselineFile)
            _ = await cloud.runIsolatedSync(from: context)
            let afterMissing = try await local()
            checks["missingBaselineStopsDivergentMerge"] = cloud.errorMessage != nil && server.uploads == protectedUploads && SyncMergeService.isSameContent(afterMissing, protectedPayload)
            try baselineData.write(to: baselineFile, options: .atomic)
            server.alwaysConflict = true
            let maxBefore = server.uploads
            _ = await cloud.runIsolatedSync(from: context)
            let afterLimit = try await local()
            checks["repeated409StopsAfterThreeAttempts"] = server.uploads == maxBefore + 3 && cloud.errorMessage != nil && amount(afterLimit, aID) == 14
            server.alwaysConflict = false
            _ = await cloud.runIsolatedSync(from: context)
            let expired = NativeCloudProbeTokens("synthetic-expired")
            let refreshed = AssetTimeMachineCloudStore(tokenStore: expired, defaults: defaults, isolatedTest: true)
            refreshed.currentUser = cloud.currentUser
            _ = await refreshed.runIsolatedSync(from: context)
            checks["expiredAccessRefreshesAndRetries"] = server.refreshes == 1 && expired.access == "synthetic-access" && refreshed.errorMessage == nil
            let accountPayload = try await local(), accountUploads = server.uploads
            refreshed.currentUser = AssetTimeMachineCloudUser(id: 12, userName: "Synthetic B", userEmail: nil)
            _ = await refreshed.runIsolatedSync(from: context)
            let afterSwitch = try await local()
            checks["accountSwitchBlocksImportAndUpload"] = server.uploads == accountUploads && SyncMergeService.isSameContent(afterSwitch, accountPayload) && refreshed.errorMessage != nil
            refreshed.currentUser = cloud.currentUser
            refreshed.logout()
            checks["logoutClearsSyncStatusButRetainsDataOwner"] = defaults.object(forKey: "assettimemachine.cloud.lastSyncAt") == nil && defaults.integer(forKey: "assettimemachine.cloud.localOwnerUserID") == 11 && refreshed.currentUser == nil
            server.rejectRefresh = true
            let rejected = NativeCloudProbeTokens("synthetic-expired")
            let invalid = AssetTimeMachineCloudStore(tokenStore: rejected, defaults: defaults, isolatedTest: true)
            invalid.currentUser = cloud.currentUser
            _ = await invalid.runIsolatedSync(from: context)
            checks["expiredRefreshDoesNotUploadAndRequiresLogin"] = rejected.access == nil && invalid.currentUser == nil && invalid.errorMessage != nil && server.uploads == accountUploads
            server.rejectRefresh = false
            let freshSuite = "CloudSyncFresh-" + UUID().uuidString
            let freshDefaults = UserDefaults(suiteName: freshSuite)!
            defer { freshDefaults.removePersistentDomain(forName: freshSuite) }
            let freshContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            let freshContext = ModelContext(freshContainer); freshContext.autosaveEnabled = false
            let empty = try await ImportExportService.exportPayloadCooperatively(from: freshContext).payload
            server.payload = empty; server.noHead = true
            let fresh = AssetTimeMachineCloudStore(tokenStore: NativeCloudProbeTokens(), defaults: freshDefaults, isolatedTest: true)
            fresh.currentUser = cloud.currentUser
            let emptyUploads = server.uploads
            _ = await fresh.runIsolatedSync(from: freshContext)
            checks["emptyFirstRunDoesNotUpload"] = server.uploads == emptyUploads && fresh.errorMessage == nil && fresh.lastSyncAt == nil
            freshDefaults.removeObject(forKey: "assettimemachine.cloud.localOwnerUserID")
            let freshCategory = AssetCategory(name: "Synthetic new", group: .financial)
            let freshItem = AssetItem(name: "Synthetic new", category: freshCategory)
            let freshSnapshot = AssetSnapshot(date: .now)
            freshContext.insert(freshCategory); freshContext.insert(freshItem); freshContext.insert(freshSnapshot)
            freshContext.insert(AssetEntry(amount: 123, snapshot: freshSnapshot, item: freshItem))
            try freshContext.save()
            _ = await fresh.runIsolatedSync(from: freshContext)
            checks["unclaimedLocalDataNeedsConfirmation"] = fresh.requiresLocalOwnershipConfirmation && server.uploads == emptyUploads && fresh.errorMessage != nil
            server.noHead = false
            await fresh.authorizeLocalDataForCurrentAccount(from: freshContext)
            checks["cloudAppearsBeforeAssociationBlocksUpload"] = fresh.errorMessage != nil && server.uploads == emptyUploads && freshDefaults.object(forKey: "assettimemachine.cloud.localOwnerUserID") == nil
            server.noHead = true
            _ = await fresh.runIsolatedSync(from: freshContext)
            await fresh.authorizeLocalDataForCurrentAccount(from: freshContext)
            for _ in 0..<100 {
                if server.uploads > emptyUploads && !fresh.isWorking { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            checks["explicitAssociationBacksUpThenUploads"] = server.acceptedUploads == 4 && fresh.errorMessage == nil && freshDefaults.integer(forKey: "assettimemachine.cloud.localOwnerUserID") == 11 && freshDefaults.string(forKey: "assettimemachine.cloud.lastLocalSafetyBackup").map { FileManager.default.fileExists(atPath: $0) } == true
            return ["checks": checks, "allPassed": checks.values.allSatisfy { $0 }, "count": checks.count,
                    "latestReads": server.latestReads, "uploads": server.uploads, "acceptedUploads": server.acceptedUploads]
        } catch { return ["checks": checks, "allPassed": false, "error": error.localizedDescription] }
    }
}
