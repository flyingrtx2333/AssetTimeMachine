#if DEBUG || os(macOS)
import Foundation
import SwiftData

private final class DeltaProbeTokens: CloudTokenStore {
    var access: String?
    var refresh: String?
    func loadAccessToken() -> String? { access }
    func loadRefreshToken() -> String? { refresh }
    func save(accessToken: String, refreshToken: String?) throws { access = accessToken; refresh = refreshToken }
    func clear() throws { access = nil; refresh = nil }
}

private final class DeltaProbeAccount {
    let userID: Int
    let accountID: String
    var cursor: Int64 = 1
    var backupID: Int
    var values: [CloudDocumentKey: CloudJSON]
    var versions: [CloudDocumentKey: Int64]
    var history: [Int: ExportPayload] = [:]
    var batches: [(Int64, [CloudDeltaDocument])] = []
    var receipts: [String: (Data, [String: Any])] = [:]
    var legacyReads = 0, legacyUploads = 0, deltaPulls = 0, accepted = 0, replays = 0
    var attempts: [CloudDeltaRequest] = []

    init(userID: Int, accountID: String, payload: ExportPayload) throws {
        self.userID = userID; self.accountID = accountID; backupID = userID * 100
        values = try CloudDocumentCodec.partition(payload)
        versions = values.mapValues { _ in 1 }
        history[backupID] = payload
    }

    func payload() throws -> ExportPayload { try CloudDocumentCodec.payload(values) }

    func commit(_ changes: [CloudDocumentKey: CloudJSON]) throws -> [CloudDeltaDocument] {
        cursor += 1; backupID += 1
        let documents = changes.sorted { $0.key.wireKey < $1.key.wireKey }.map { key, value in
            values[key] = value; versions[key] = cursor
            return CloudDeltaDocument(kind: key.kind, id: key.id, version: cursor, value: value)
        }
        batches.append((cursor, documents)); history[backupID] = try payload()
        return documents
    }
}

private final class DeltaProbeServer: @unchecked Sendable {
    let lock = NSLock()
    var accounts: [String: DeltaProbeAccount] = [:]
    var loseNextAcceptedResponse = false
    var roundNextBootstrapClock = false

    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: CloudDocumentCodec.encode(value))
    }

    private func metadata(_ account: DeltaProbeAccount, id: Int? = nil) -> [String: Any] {
        let selected = id ?? account.backupID
        return ["id": selected, "file_name": "synthetic-delta.json", "file_size": 100,
                "uploaded_at": "2026-09-30T00:00:00Z", "is_latest": selected == account.backupID ? 1 : 0,
                "storage_url": "https://storage.invalid/fixture/\(account.userID)/\(selected).json",
                "note": "isolated delta probe"]
    }

    func response(_ request: URLRequest, body: Data) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func argument(_ name: String) -> String? { query.first { $0.name == name }?.value }
        var status = 200
        let output: Any
        if path.hasPrefix("/fixture/") {
            let parts = path.split(separator: "/")
            guard parts.count == 3, let user = Int(parts[1]),
                  let backup = Int(parts[2].replacingOccurrences(of: ".json", with: "")),
                  let account = accounts.values.first(where: { $0.userID == user }),
                  let payload = account.history[backup], request.value(forHTTPHeaderField: "Authorization") == nil else {
                throw URLError(.resourceUnavailable)
            }
            output = try object(payload)
        } else if path.hasSuffix("/account/login") {
            let login = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            guard let name = login?["username"] as? String, accounts[name] != nil else { throw URLError(.userAuthenticationRequired) }
            output = ["access_token": "delta-" + name, "refresh_token": "delta-refresh-" + name, "token_type": "bearer"]
        } else {
            let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let name = token.replacingOccurrences(of: "Bearer delta-", with: "")
            guard let account = accounts[name] else { throw URLError(.userAuthenticationRequired) }
            if path.hasSuffix("/users/me") {
                output = ["id": account.userID, "user_name": "Synthetic " + name]
            } else if path.hasSuffix("/asset-time-machine/account") {
                output = ["account_id": account.accountID, "has_deletion_history": false, "requires_apple_authorization": false]
            } else if path.hasSuffix("/cloud/history") {
                let limit = Int(argument("limit") ?? "20") ?? 20
                output = account.history.keys.sorted(by: >).prefix(limit).map { metadata(account, id: $0) }
            } else if path.hasSuffix("/cloud/latest") {
                account.legacyReads += 1
                var value = metadata(account); value["payload"] = try object(account.payload()); output = value
            } else if path.hasSuffix("/cloud/upload") {
                account.legacyUploads += 1
                let wire = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                if (wire["base_backup_id"] as? Int) != account.backupID {
                    status = 409; output = ["detail": "云端数据已更新，请先重新同步"]
                } else {
                    let payload = try CloudDocumentCodec.decode(ExportPayload.self,
                        from: JSONSerialization.data(withJSONObject: wire["payload"]!))
                    let incoming = try CloudDocumentCodec.partition(payload)
                    var changed = incoming.filter { account.values[$0.key] != $0.value }
                    for key in account.values.keys where incoming[key] == nil { changed[key] = .null }
                    _ = try account.commit(changed)
                    output = metadata(account)
                }
            } else if path.hasSuffix("/cloud/sync/bootstrap") {
                if roundNextBootstrapClock {
                    // Reproduce an old MySQL JSON rendering changing one Double
                    // after acknowledgment, while retaining the exact same head ID.
                    for (key, value) in account.values where key.kind == "snapshot" {
                        guard case .object(var day) = value, case .array(var entries) = day["entries"] else { continue }
                        for index in entries.indices {
                            guard case .object(var entry) = entries[index], entry["amountEditedAt"] != nil else { continue }
                            entry["amountEditedAt"] = .number(1794838029.072898)
                            entries[index] = .object(entry)
                        }
                        day["entries"] = .array(entries); account.values[key] = .object(day)
                    }
                    account.history[account.backupID] = try account.payload()
                    roundNextBootstrapClock = false
                }
                output = ["protocol": 2, "account_id": account.accountID, "cursor": account.cursor,
                          "backup": metadata(account), "payload": try object(account.payload()),
                          "versions": Dictionary(uniqueKeysWithValues: account.versions.map { ($0.key.wireKey, $0.value) })]
            } else if path.hasSuffix("/cloud/sync/changes") {
                account.deltaPulls += 1
                let since = Int64(argument("since") ?? "-1") ?? -1
                let through = Int64(argument("through") ?? "\(account.cursor)") ?? -1
                if argument("account_id") != account.accountID || since < 1 || through > account.cursor || since > through {
                    status = 409; output = ["detail": "同步位置已变化，请重新核对"]
                } else {
                    let batches = try account.batches.filter { $0.0 > since && $0.0 <= through }.map {
                        ["revision": $0.0, "documents": try object($0.1)] as [String: Any]
                    }
                    output = ["protocol": 2, "account_id": account.accountID, "cursor": through,
                              "revision": through, "has_more": false, "batches": batches, "backup": metadata(account)]
                }
            } else if path.hasSuffix("/cloud/sync/commit") {
                let value = try CloudDocumentCodec.decode(CloudDeltaRequest.self, from: body)
                account.attempts.append(value)
                let canonical = try CloudDocumentCodec.encode(value)
                if let receipt = account.receipts[value.requestID] {
                    if receipt.0 != canonical {
                        status = 409; output = ["detail": "重复请求的内容不一致"]
                    } else { account.replays += 1; output = receipt.1 }
                } else if value.accountID != account.accountID || value.cursor != account.cursor
                            || value.changes.contains(where: { (account.versions[$0.key] ?? 0) != $0.baseVersion }) {
                    status = 409; output = ["detail": "云端数据已更新，请先重新同步"]
                } else {
                    let documents = try account.commit(Dictionary(uniqueKeysWithValues: value.changes.map { ($0.key, $0.value) }))
                    let response: [String: Any] = ["protocol": 2, "account_id": account.accountID,
                        "cursor": account.cursor, "backup": metadata(account), "documents": try object(documents)]
                    account.receipts[value.requestID] = (canonical, response); account.accepted += 1
                    if loseNextAcceptedResponse { loseNextAcceptedResponse = false; throw URLError(.networkConnectionLost) }
                    output = response
                }
            } else { throw URLError(.unsupportedURL) }
        }
        return (status, try JSONSerialization.data(withJSONObject: output))
    }

    func remoteAmount(_ amount: Double, dayID: UUID, itemID: UUID, account name: String = "a",
                      editClock: TimeInterval? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let account = accounts[name]!, key = CloudDocumentKey(kind: "snapshot", id: dayID.uuidString)
        guard case .object(var day) = account.values[key], case .array(var entries) = day["entries"] else { throw CocoaError(.coderReadCorrupt) }
        for index in entries.indices {
            guard case .object(var entry) = entries[index], entry["itemID"] == .string(itemID.uuidString) else { continue }
            entry["amount"] = .number(amount); entry["amountEditedAt"] = editClock.map(CloudJSON.number) ?? .null
            entry["updatedAt"] = .string("2026-11-16T08:00:00Z"); entries[index] = .object(entry)
        }
        day["entries"] = .array(entries); day["updatedAt"] = .string("2026-11-16T08:00:00Z")
        _ = try account.commit([key: .object(day)])
    }

    func remoteQuantity(_ quantity: Double, price: Double, dayID: UUID, itemID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let account = accounts["a"]!, key = CloudDocumentKey(kind: "snapshot", id: dayID.uuidString)
        guard case .object(var day) = account.values[key], case .array(var entries) = day["entries"] else { throw CocoaError(.coderReadCorrupt) }
        for index in entries.indices {
            guard case .object(var entry) = entries[index], entry["itemID"] == .string(itemID.uuidString) else { continue }
            entry["amount"] = .null; entry["quantity"] = .number(quantity); entry["unitPrice"] = .number(price)
            entry["quantityEditedAt"] = .number(200); entry["updatedAt"] = .string("2026-11-16T08:00:00Z")
            entries[index] = .object(entry)
        }
        day["entries"] = .array(entries); day["updatedAt"] = .string("2026-11-16T08:00:00Z")
        _ = try account.commit([key: .object(day)])
    }

    func remoteDelete(itemIDs: Set<UUID>, categoryID: UUID? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let account = accounts["a"]!
        var changes: [CloudDocumentKey: CloudJSON] = [:]
        for (key, value) in account.values where key.kind == "snapshot" {
            guard case .object(var day) = value, case .array(let entries) = day["entries"] else { continue }
            day["entries"] = .array(entries.filter { value in
                guard case .object(let entry) = value, case .string(let id) = entry["itemID"] else { return true }
                return UUID(uuidString: id).map { !itemIDs.contains($0) } ?? true
            })
            changes[key] = .object(day)
        }
        for id in itemIDs {
            changes[.init(kind: "item", id: id.uuidString)] = .null
            changes[.init(kind: "deletion", id: "item:" + id.uuidString)] = .object([
                "entityID": .string(id.uuidString), "entityKind": .string("item"),
                "deletedAt": .string("2026-11-16T08:00:00Z")])
        }
        if let categoryID {
            changes[.init(kind: "category", id: categoryID.uuidString)] = .null
            changes[.init(kind: "deletion", id: "category:" + categoryID.uuidString)] = .object([
                "entityID": .string(categoryID.uuidString), "entityKind": .string("category"),
                "deletedAt": .string("2026-11-16T08:00:00Z")])
        }
        _ = try account.commit(changes)
    }
}

private final class DeltaProbeProtocol: URLProtocol {
    nonisolated(unsafe) static var server: DeltaProbeServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let server = Self.server else { throw URLError(.unsupportedURL) }
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(buffer, count: count)
                }
            }
            let (status, data) = try server.response(request, body: body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
enum CloudDeltaProbe {
    private static var schema: Schema {
        Schema([AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self,
                BacktestRecord.self, SyncDeletionTombstone.self, CloudReplicaState.self, CloudReplicaDocument.self])
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let url: URL
        let defaults: UserDefaults
        let tokens: DeltaProbeTokens
        let cloud: AssetTimeMachineCloudStore
        let server: DeltaProbeServer
        let categoryID: UUID
        let itemIDs: [UUID]
        let dayIDs: [UUID]
    }

    private static func seed(_ context: ModelContext) throws -> (UUID, [UUID], [UUID]) {
        let category = AssetCategory(name: "Synthetic delta", group: .financial)
        let first = AssetItem(name: "Synthetic bank", category: category)
        let second = AssetItem(name: "Synthetic cash", category: category)
        context.insert(category); context.insert(first); context.insert(second)
        var days: [UUID] = []
        let origin = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_789_776_000))
        for index in 0..<2 {
            let snapshot = AssetSnapshot(date: Calendar.current.date(byAdding: .day, value: index, to: origin)!)
            context.insert(snapshot)
            context.insert(AssetEntry(amount: Double(10 + index), snapshot: snapshot, item: first))
            context.insert(AssetEntry(amount: Double(20 + index), snapshot: snapshot, item: second))
            days.append(snapshot.id)
        }
        try context.save()
        return (category.id, [first.id, second.id], days)
    }

    private static func edit(_ fixture: Fixture, amount: Double, legacyClock: Bool = false) throws {
        let dayID = fixture.dayIDs[0], itemID = fixture.itemIDs[0]
        let day = try fixture.context.fetch(FetchDescriptor<AssetSnapshot>()).first { $0.id == dayID }!
        let item = try fixture.context.fetch(FetchDescriptor<AssetItem>()).first { $0.id == itemID }!
        try SnapshotService.upsertEntry(snapshot: day, item: item, amount: amount, in: fixture.context)
        if legacyClock {
            day.entries.first { $0.item?.id == itemID }!.amountEditedAt = nil
            try fixture.context.save()
        }
    }

    private static func amount(_ context: ModelContext, day: UUID, item: UUID) throws -> Double? {
        try context.fetch(FetchDescriptor<AssetEntry>()).first { $0.snapshot?.id == day && $0.item?.id == item }?.amount
    }

    static func run() async throws -> [String: Bool] {
        precondition(AppPreviewSession.isActive && ProcessInfo.processInfo.arguments.contains("-macCloudSyncProbe"))
        #if os(macOS)
        let root = URL(fileURLWithPath: "/tmp/atm-delta-probe-" + UUID().uuidString, isDirectory: true)
        #else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atm-delta-probe-" + UUID().uuidString, isDirectory: true)
        #endif
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var stores: [AssetTimeMachineCloudStore] = [], suites: [(String, UserDefaults)] = []
        defer {
            for store in stores { store.setAutomaticSyncActive(false) }
            AssetTimeMachineCloudAPI.removeIsolatedTransport(); DeltaProbeProtocol.server = nil
            for (name, defaults) in suites {
                defaults.removePersistentDomain(forName: name)
                let baseline = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncProbe-" + String(ObjectIdentifier(defaults).hashValue))
                try? FileManager.default.removeItem(at: baseline)
            }
            try? FileManager.default.removeItem(at: root)
        }
        AssetTimeMachineCloudAPI.installIsolatedTransport(DeltaProbeProtocol.self)
        var checks: [String: Bool] = [:]

        func fixture(_ name: String, roundedBootstrapClock: Bool = false,
                     inheritanceDaysAgo: Int? = nil, automaticQuantity: Bool = false) async throws -> Fixture {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("records.store")
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = ModelContext(container); context.autosaveEnabled = false
            let (category, items, days) = try seed(context)
            if let inheritanceDaysAgo {
                let snapshots = try context.fetch(FetchDescriptor<AssetSnapshot>())
                let sourceDate = Calendar.current.date(byAdding: .day, value: -inheritanceDaysAgo,
                                                       to: Calendar.current.startOfDay(for: .now))!
                let source = snapshots.first { $0.id == days[1] }!
                source.date = sourceDate
                snapshots.first { $0.id == days[0] }!.date = Calendar.current.date(byAdding: .day, value: -1, to: sourceDate)!
                let item = try context.fetch(FetchDescriptor<AssetItem>()).first { $0.id == items[0] }!
                let entry = source.entries.first { $0.item?.id == item.id }!
                if automaticQuantity {
                    item.valuationMethod = .quantityAndUnitPrice; item.autoPricedAssetKind = .gold
                    entry.amount = nil; entry.quantity = 40; entry.unitPrice = 10; entry.quantityEditedAt = 100
                } else { entry.amount = 400; entry.amountEditedAt = 100 }
                try context.save()
            }
            if roundedBootstrapClock {
                let day = try context.fetch(FetchDescriptor<AssetSnapshot>()).first { $0.id == days[0] }!
                day.entries.first { $0.item?.id == items[0] }!.amountEditedAt = 1794838029.0728981
                try context.save()
            }
            let suite = "NativeDeltaProbe-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
            suites.append((suite, defaults))
            let server = DeltaProbeServer(), payload = try ImportExportService.exportPayload(from: context)
            server.accounts["a"] = try DeltaProbeAccount(userID: 11, accountID: "synthetic-a", payload: payload)
            server.accounts["b"] = try DeltaProbeAccount(userID: 12, accountID: "synthetic-b", payload: payload)
            server.roundNextBootstrapClock = roundedBootstrapClock
            DeltaProbeProtocol.server = server
            let tokens = DeltaProbeTokens()
            let cloud = AssetTimeMachineCloudStore(tokenStore: tokens, defaults: defaults, isolatedTest: true)
            cloud.setAutomaticSyncActive(false); stores.append(cloud)
            await cloud.login(username: "a", password: "synthetic")
            _ = await cloud.runIsolatedSync(from: context)
            let adopted = try CloudReplicaCache.state(scope: "11:synthetic-a", in: ModelContext(container))
            guard roundedBootstrapClock || adopted != nil else {
                throw NSError(domain: "NativeDeltaProbe", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Delta fixture adoption failed: " + (cloud.errorMessage ?? "no replica bookmark")])
            }
            return Fixture(container: container, context: context, url: url, defaults: defaults, tokens: tokens,
                           cloud: cloud, server: server, categoryID: category, itemIDs: items, dayIDs: days)
        }

        func inheritedDays(_ fixture: Fixture, count: Int = 1) throws -> [AssetSnapshot] {
            let source = try fixture.context.fetch(FetchDescriptor<AssetSnapshot>()).first { $0.id == fixture.dayIDs[1] }!
            return try (1...count).map { offset in
                try SnapshotService.createSnapshot(on: Calendar.current.date(byAdding: .day, value: offset, to: source.date)!,
                                                   in: fixture.context)
            }
        }

        func remoteAmount(_ account: DeltaProbeAccount, day: UUID, item: UUID) throws -> Double? {
            try account.payload().snapshots.first { $0.id == day }?.entries.first { $0.itemID == item }?.amount
        }

        for automatic in [false, true] {
            let name = automatic ? "quantity" : "amount"
            let local = try await fixture("local-inheritance-atomic-" + name,
                inheritanceDaysAgo: 1, automaticQuantity: automatic)
            let child = try inheritedDays(local)[0]
            let item = try local.context.fetch(FetchDescriptor<AssetItem>()).first { $0.id == local.itemIDs[0] }!
            let source = try local.context.fetch(FetchDescriptor<AssetSnapshot>()).first { $0.id == local.dayIDs[1] }!
            let sourceEntry = source.entries.first { $0.item?.id == item.id }!
            let childEntry = child.entries.first { $0.item?.id == item.id }!
            if automatic { childEntry.unitPrice = 12; try local.context.save() }
            let account = local.server.accounts["a"]!, reads = account.legacyReads, pulls = account.deltaPulls
            try SnapshotService.upsertEntry(snapshot: source, item: item,
                amount: automatic ? nil : 455, quantity: automatic ? 45.5 : nil,
                unitPrice: automatic ? 11 : nil, saveChanges: false, in: local.context)
            let beforeCommit = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, url: local.url)])
            let beforeContext = ModelContext(beforeCommit); beforeContext.autosaveEnabled = false
            let beforeEntries = try beforeContext.fetch(FetchDescriptor<AssetEntry>())
            let oldSource = beforeEntries.first { $0.snapshot?.id == source.id && $0.item?.id == item.id }
            let oldChild = beforeEntries.first { $0.snapshot?.id == child.id && $0.item?.id == item.id }
            let stagedValues = automatic
                ? sourceEntry.quantity == 45.5 && childEntry.quantity == 45.5 && childEntry.unitPrice == 12
                : sourceEntry.amount == 455 && childEntry.amount == 455
            let diskStillOld = automatic
                ? oldSource?.quantity == 40 && oldSource?.unitPrice == 10 && oldChild?.quantity == 40 && oldChild?.unitPrice == 12
                : oldSource?.amount == 400 && oldChild?.amount == 400
            checks["localInheritedRebaseStagesAtomically-" + name] = local.context.hasChanges && stagedValues
                && childEntry.inheritedFromEntryID == sourceEntry.id && diskStillOld
            try local.context.save()
            let afterCommit = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, url: local.url)])
            let afterContext = ModelContext(afterCommit); afterContext.autosaveEnabled = false
            let committed = try afterContext.fetch(FetchDescriptor<AssetEntry>())
            let savedSource = committed.first { $0.snapshot?.id == source.id && $0.item?.id == item.id }
            let savedChild = committed.first { $0.snapshot?.id == child.id && $0.item?.id == item.id }
            let diskUpdated = automatic
                ? savedSource?.quantity == 45.5 && savedSource?.unitPrice == 11
                    && savedChild?.quantity == 45.5 && savedChild?.unitPrice == 12
                : savedSource?.amount == 455 && savedChild?.amount == 455
            checks["localInheritedRebaseCommitsTogetherWithoutNetwork-" + name] = !local.context.hasChanges && diskUpdated
                && savedChild?.inheritedFromEntryID == sourceEntry.id && account.accepted == 0 && account.legacyUploads == 0
                && account.legacyReads == reads && account.deltaPulls == pulls
        }

        let inheritance = try await fixture("inheritance-startup", inheritanceDaysAgo: 1)
        let inheritanceAccount = inheritance.server.accounts["a"]!
        let today = try inheritedDays(inheritance)[0]
        let sourceEntry = try inheritance.context.fetch(FetchDescriptor<AssetEntry>()).first {
            $0.snapshot?.id == inheritance.dayIDs[1] && $0.item?.id == inheritance.itemIDs[0]
        }!
        let todayEntry = today.entries.first { $0.item?.id == inheritance.itemIDs[0] }!
        checks["deltaStartupTodayCopiesCachedYesterdayWithProvenance"] = todayEntry.amount == 400
            && todayEntry.inheritedFromEntryID == sourceEntry.id
        try inheritance.server.remoteAmount(455, dayID: inheritance.dayIDs[1], itemID: inheritance.itemIDs[0], editClock: 200)
        _ = await inheritance.cloud.runIsolatedSync(from: inheritance.context)
        let afterInheritance = ModelContext(inheritance.container)
        let inheritedYesterday = try amount(afterInheritance, day: inheritance.dayIDs[1], item: inheritance.itemIDs[0])
        let inheritedToday = try amount(afterInheritance, day: today.id, item: inheritance.itemIDs[0])
        checks["deltaStartupPullRebasesGenuineInheritedToday"] = inheritance.cloud.errorMessage == nil
            && inheritedYesterday == 455 && inheritedToday == 455
        let sentInheritance = inheritanceAccount.attempts.flatMap(\.changes)
        let inheritedRemoteToday = try remoteAmount(inheritanceAccount, day: today.id, item: inheritance.itemIDs[0])
        checks["deltaInheritedRepairUploadsOnlyAffectedToday"] = inheritanceAccount.accepted == 1
            && inheritanceAccount.legacyReads == 1 && inheritanceAccount.legacyUploads == 0
            && sentInheritance.count == 1 && sentInheritance.first?.kind == "snapshot"
            && sentInheritance.first?.id == today.id.uuidString && inheritedRemoteToday == 455
        checks["deltaInheritedRepairPreservesUnrelatedDay"] = try amount(afterInheritance,
            day: inheritance.dayIDs[0], item: inheritance.itemIDs[0]) == 10
            && remoteAmount(inheritanceAccount, day: inheritance.dayIDs[0], item: inheritance.itemIDs[0]) == 10
        let inheritedPayload = try ImportExportService.exportPayload(from: afterInheritance)
        let inheritedAccepted = inheritanceAccount.accepted, inheritedReads = inheritanceAccount.legacyReads
        _ = await inheritance.cloud.runIsolatedSync(from: inheritance.context)
        let inheritedReopened = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, url: inheritance.url)])
        let inheritedReopenedContext = ModelContext(inheritedReopened); inheritedReopenedContext.autosaveEnabled = false
        _ = try SnapshotService.createSnapshot(on: today.date, in: inheritedReopenedContext)
        let inheritedRestarted = AssetTimeMachineCloudStore(tokenStore: inheritance.tokens,
            defaults: inheritance.defaults, isolatedTest: true)
        inheritedRestarted.setAutomaticSyncActive(false); stores.append(inheritedRestarted)
        await inheritedRestarted.refreshSession(); _ = await inheritedRestarted.runIsolatedSync(from: inheritedReopenedContext)
        let inheritedAfterRestart = try ImportExportService.exportPayload(from: inheritedReopenedContext)
        checks["deltaInheritedRepairSurvivesIdlePullDayReopenAndRestart"] = inheritedRestarted.errorMessage == nil
            && inheritanceAccount.accepted == inheritedAccepted && inheritanceAccount.legacyReads == inheritedReads
            && SyncMergeService.isSameContent(inheritedPayload, inheritedAfterRestart)
            && inheritedAfterRestart.snapshots.first { $0.id == today.id }?.entries.first {
                $0.itemID == inheritance.itemIDs[0]
            }?.amount == 455

        let chain = try await fixture("inheritance-chain", inheritanceDaysAgo: 3)
        let chainDays = try inheritedDays(chain, count: 3), chainAccount = chain.server.accounts["a"]!
        try chain.server.remoteAmount(455, dayID: chain.dayIDs[1], itemID: chain.itemIDs[0], editClock: 200)
        _ = await chain.cloud.runIsolatedSync(from: chain.context)
        let chainContext = ModelContext(chain.container), chainRemote = try chainAccount.payload()
        let chainLocalValues = try chainDays.map { try amount(chainContext, day: $0.id, item: chain.itemIDs[0]) }
        checks["deltaInheritedRepairRebasesEntireCopiedDayChain"] = chain.cloud.errorMessage == nil
            && chainLocalValues.allSatisfy { $0 == 455 } && chainDays.allSatisfy { day in
                chainRemote.snapshots.first { $0.id == day.id }?.entries.first { $0.itemID == chain.itemIDs[0] }?.amount == 455
            }
        let chainChanges = chainAccount.attempts.flatMap(\.changes)
        checks["deltaInheritedChainUploadsOnlyItsDescendantDays"] = chainAccount.accepted == 1
            && chainAccount.legacyUploads == 0 && chainChanges.count == chainDays.count
            && chainChanges.allSatisfy { $0.kind == "snapshot" }
            && Set(chainChanges.map(\.id)) == Set(chainDays.map { $0.id.uuidString })

        for (name, value) in [("manual-edit", 500.0), ("confirmed-copy", 400.0), ("explicit-zero", 0.0)] {
            let manual = try await fixture("inheritance-" + name, inheritanceDaysAgo: 1)
            let child = try inheritedDays(manual)[0]
            let item = try manual.context.fetch(FetchDescriptor<AssetItem>()).first { $0.id == manual.itemIDs[0] }!
            try SnapshotService.upsertEntry(snapshot: child, item: item, amount: value, in: manual.context)
            let confirmed = child.entries.first { $0.item?.id == item.id }!.inheritedFromEntryID == nil
            try manual.server.remoteAmount(455, dayID: manual.dayIDs[1], itemID: item.id, editClock: 200)
            _ = await manual.cloud.runIsolatedSync(from: manual.context)
            let current = ModelContext(manual.container), account = manual.server.accounts["a"]!
            let localValue = try amount(current, day: child.id, item: item.id)
            let serverValue = try remoteAmount(account, day: child.id, item: item.id)
            let localSource = try amount(current, day: manual.dayIDs[1], item: item.id)
            let currentEntry = try current.fetch(FetchDescriptor<AssetEntry>()).first {
                $0.snapshot?.id == child.id && $0.item?.id == item.id
            }
            checks["deltaInheritedRepairPreserves-" + name] = confirmed && manual.cloud.errorMessage == nil
                && localValue == value && serverValue == value && localSource == 455
                && currentEntry?.inheritedFromEntryID == nil
        }

        let quantity = try await fixture("inheritance-auto-quantity", inheritanceDaysAgo: 1, automaticQuantity: true)
        let quantityDay = try inheritedDays(quantity)[0]
        let copiedQuantity = quantityDay.entries.first { $0.item?.id == quantity.itemIDs[0] }!
        copiedQuantity.unitPrice = 12; copiedQuantity.updatedAt = .now
        quantityDay.updatedAt = .now; try quantity.context.save()
        try quantity.server.remoteQuantity(45.5, price: 11, dayID: quantity.dayIDs[1], itemID: quantity.itemIDs[0])
        _ = await quantity.cloud.runIsolatedSync(from: quantity.context)
        let quantityContext = ModelContext(quantity.container)
        let repairedQuantity = try quantityContext.fetch(FetchDescriptor<AssetEntry>()).first {
            $0.snapshot?.id == quantityDay.id && $0.item?.id == quantity.itemIDs[0]
        }
        let remoteQuantityDay = try quantity.server.accounts["a"]!.payload().snapshots.first { $0.id == quantityDay.id }
        let remoteQuantity = remoteQuantityDay?.entries.first { $0.itemID == quantity.itemIDs[0] }
        checks["deltaInheritedQuantityRepairPreservesChildDatedQuote"] = quantity.cloud.errorMessage == nil
            && repairedQuantity?.quantity == 45.5 && repairedQuantity?.unitPrice == 12
            && repairedQuantity?.inheritedFromEntryID != nil && remoteQuantity?.quantity == 45.5
            && remoteQuantity?.unitPrice == 12

        for provenCopy in [true, false] {
            let name = provenCopy ? "proven-copy" : "unproven-marker"
            let broken = try await fixture("inheritance-existing-245-" + name, inheritanceDaysAgo: 1)
            let child = try inheritedDays(broken)[0], account = broken.server.accounts["a"]!
            let childEntry = child.entries.first { $0.item?.id == broken.itemIDs[0] }!
            if !provenCopy {
                // A marker by itself is insufficient: this value no longer equals
                // the acknowledged source, even though its old clocks still match.
                childEntry.amount = 399; try broken.context.save()
            }
            let oldBaseline = FileManager.default.temporaryDirectory
                .appendingPathComponent("CloudSyncProbe-" + String(ObjectIdentifier(broken.defaults).hashValue))
                .appendingPathComponent("account-11.json")
            let baseline = try CloudDocumentCodec.decode(ExportPayload.self, from: Data(contentsOf: oldBaseline))
            let baselineSource = baseline.snapshots.first { $0.id == broken.dayIDs[1] }?
                .entries.first { $0.itemID == broken.itemIDs[0] }?.amount
            let childPayload = try ImportExportService.exportDays([child.id], from: broken.context).snapshots[0]
            let childDocument = try account.commit([.init(kind: "snapshot", id: child.id.uuidString):
                                                     CloudDocumentCodec.json(childPayload)])
            try broken.server.remoteAmount(455, dayID: broken.dayIDs[1], itemID: broken.itemIDs[0], editClock: 200)
            let sourceDocument = account.batches.last!.1
            let remoteSource = try account.payload().snapshots.first { $0.id == broken.dayIDs[1] }!
            let remoteSourceEntry = remoteSource.entries.first { $0.itemID == broken.itemIDs[0] }!
            let imported = ModelContext(broken.container); imported.autosaveEnabled = false; imported.author = "atm.cloud.delta"
            let importedSource = try imported.fetch(FetchDescriptor<AssetSnapshot>()).first { $0.id == broken.dayIDs[1] }!
            let importedEntry = importedSource.entries.first { $0.item?.id == broken.itemIDs[0] }!
            importedEntry.amount = remoteSourceEntry.amount; importedEntry.amountEditedAt = remoteSourceEntry.amountEditedAt
            importedEntry.updatedAt = remoteSourceEntry.updatedAt; importedSource.updatedAt = remoteSource.updatedAt
            try CloudReplicaCache.update(childDocument + sourceDocument, scope: "11:synthetic-a", in: imported)
            let importedState = try CloudReplicaCache.state(scope: "11:synthetic-a", in: imported)!
            importedState.cursor = account.cursor
            try imported.save()
            // Model 245 having acknowledged every transaction: there is no dirty
            // day to trigger a repair, and both server and replica already hold it.
            let consumed = try await CloudDeltaHistoryReader(modelContainer: broken.container).scan(after: nil, collectChanges: false)
            let consumedMetadata = ModelContext(broken.container); consumedMetadata.author = "atm.cloud.replica"
            try CloudReplicaCache.state(scope: "11:synthetic-a", in: consumedMetadata)!.historyToken = consumed.token
            try consumedMetadata.save()
            broken.defaults.removeObject(forKey: "assettimemachine.cloud.inheritedRebase.v1.11:synthetic-a")
            broken.cloud.setAutomaticSyncActive(false)
            let upgradedContainer = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, url: broken.url)])
            let upgradedContext = ModelContext(upgradedContainer); upgradedContext.autosaveEnabled = false
            let upgradedCloud = AssetTimeMachineCloudStore(tokenStore: broken.tokens, defaults: broken.defaults, isolatedTest: true)
            upgradedCloud.setAutomaticSyncActive(false); stores.append(upgradedCloud)
            await upgradedCloud.refreshSession(); _ = await upgradedCloud.runIsolatedSync(from: upgradedContext)
            let upgradedValue = try amount(ModelContext(upgradedContainer), day: child.id, item: broken.itemIDs[0])
            let upgradedRemote = try remoteAmount(account, day: child.id, item: broken.itemIDs[0])
            let expected = provenCopy ? 455.0 : 399.0
            checks["deltaExisting245Repair-" + name] = baselineSource == 400 && upgradedCloud.errorMessage == nil
                && upgradedValue == expected && upgradedRemote == expected && account.accepted == (provenCopy ? 1 : 0)
                && account.legacyReads == 1 && account.legacyUploads == 0
            let repairedPayload = try ImportExportService.exportPayload(from: upgradedContext)
            let accepted = account.accepted, pullCount = account.deltaPulls
            _ = await upgradedCloud.runIsolatedSync(from: upgradedContext)
            let stablePayload = try ImportExportService.exportPayload(from: upgradedContext)
            checks["deltaExisting245RepairIsStable-" + name] = upgradedCloud.errorMessage == nil
                && account.accepted == accepted && account.deltaPulls > pullCount
                && SyncMergeService.isSameContent(repairedPayload, stablePayload)
        }

        let ordinary = try await fixture("ordinary")
        let account = ordinary.server.accounts["a"]!
        checks["deltaLegacyHeadAdoptedWithoutUpload"] = account.legacyReads == 1 && account.legacyUploads == 0
        try edit(ordinary, amount: 12)
        _ = await ordinary.cloud.runIsolatedSync(from: ordinary.context)
        checks["deltaOneAmountEditSendsOnlyItsDay"] = account.accepted == 1 && account.legacyUploads == 0
            && account.attempts.last?.changes.count == 1 && account.attempts.last?.changes.first?.kind == "snapshot"
            && account.attempts.last?.changes.first?.id == ordinary.dayIDs[0].uuidString
        checks["deltaOtherDayPreserved"] = try amount(ordinary.context, day: ordinary.dayIDs[1], item: ordinary.itemIDs[0]) == 11
        let reads = account.legacyReads, uploads = account.legacyUploads, pulls = account.deltaPulls
        ordinary.cloud.setAutomaticSyncActive(false)
        let reopened = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: ordinary.url)])
        let reopenedContext = ModelContext(reopened); reopenedContext.autosaveEnabled = false
        let restarted = AssetTimeMachineCloudStore(tokenStore: ordinary.tokens, defaults: ordinary.defaults, isolatedTest: true)
        restarted.setAutomaticSyncActive(false); stores.append(restarted)
        await restarted.refreshSession(); _ = await restarted.runIsolatedSync(from: reopenedContext)
        checks["deltaFreshContainerRestartAvoidsLegacyFullTransfer"] = restarted.errorMessage == nil
            && account.legacyReads == reads && account.legacyUploads == uploads && account.deltaPulls > pulls

        let tokenBeforeRemote = try CloudReplicaCache.state(scope: "11:synthetic-a", in: ModelContext(reopened))?.historyToken
        let acceptedBeforeRemote = account.accepted
        try ordinary.server.remoteAmount(24, dayID: ordinary.dayIDs[1], itemID: ordinary.itemIDs[1])
        _ = await restarted.runIsolatedSync(from: reopenedContext)
        let receivedState = try CloudReplicaCache.state(scope: "11:synthetic-a", in: ModelContext(reopened))
        let receivedToken = receivedState?.historyToken
        let receivedAmount = try amount(reopenedContext, day: ordinary.dayIDs[1], item: ordinary.itemIDs[1])
        checks["deltaRemoteImportAdvancesDurableHistoryBookmark"] = restarted.errorMessage == nil
            && receivedToken != nil && receivedToken != tokenBeforeRemote && receivedState?.cursor == account.cursor
            && receivedAmount == 24
        let receivedPayload = try ImportExportService.exportPayload(from: reopenedContext)
        _ = await restarted.runIsolatedSync(from: reopenedContext)
        let idleState = try CloudReplicaCache.state(scope: "11:synthetic-a", in: ModelContext(reopened))
        let idlePayload = try ImportExportService.exportPayload(from: reopenedContext)
        checks["deltaIdlePollDoesNotChurnHistoryBookmarkOrUpload"] = restarted.errorMessage == nil
            && idleState?.historyToken == receivedToken && idleState?.cursor == account.cursor
            && account.accepted == acceptedBeforeRemote && account.legacyReads == reads && account.legacyUploads == uploads
            && SyncMergeService.isSameContent(receivedPayload, idlePayload)
        let receiverReopened = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, url: ordinary.url)])
        let receiverContext = ModelContext(receiverReopened); receiverContext.autosaveEnabled = false
        let receiverRestarted = AssetTimeMachineCloudStore(tokenStore: ordinary.tokens, defaults: ordinary.defaults, isolatedTest: true)
        receiverRestarted.setAutomaticSyncActive(false); stores.append(receiverRestarted)
        await receiverRestarted.refreshSession(); _ = await receiverRestarted.runIsolatedSync(from: receiverContext)
        let receiverState = try CloudReplicaCache.state(scope: "11:synthetic-a", in: ModelContext(receiverReopened))
        let receiverPayload = try ImportExportService.exportPayload(from: receiverContext)
        checks["deltaReceiverRestartKeepsBookmarkDataAndNoUpload"] = receiverRestarted.errorMessage == nil
            && receiverState?.historyToken == receivedToken && receiverState?.cursor == account.cursor
            && account.accepted == acceptedBeforeRemote && account.legacyReads == reads && account.legacyUploads == uploads
            && SyncMergeService.isSameContent(receivedPayload, receiverPayload)

        let rounded = try await fixture("rounded-legacy-clock", roundedBootstrapClock: true)
        let roundedAccount = rounded.server.accounts["a"]!
        let beforeHealing = try ImportExportService.exportPayload(from: rounded.context)
        let invalidated = try CloudReplicaCache.state(scope: "11:synthetic-a", in: ModelContext(rounded.container))
        checks["deltaRoundedLegacyClockRetiresOnlyHeadShortcut"] = invalidated == nil
            && rounded.defaults.object(forKey: "assettimemachine.cloud.lastVerifiedBackupID") == nil
            && rounded.defaults.integer(forKey: "assettimemachine.cloud.localOwnerUserID") == 11
            && rounded.defaults.string(forKey: "assettimemachine.cloud.lastUploadedSignature") != nil
            && roundedAccount.legacyReads == 1 && roundedAccount.legacyUploads == 0
        _ = await rounded.cloud.runIsolatedSync(from: rounded.context)
        let healed = try CloudReplicaCache.state(scope: "11:synthetic-a", in: ModelContext(rounded.container))
        checks["deltaRoundedLegacyClockReconcilesBeforeAdoption"] = rounded.cloud.errorMessage == nil
            && healed != nil && roundedAccount.legacyReads == 2
        let healedReads = roundedAccount.legacyReads, healedUploads = roundedAccount.legacyUploads
        let healedPulls = roundedAccount.deltaPulls
        _ = await rounded.cloud.runIsolatedSync(from: rounded.context)
        checks["deltaRoundedLegacyClockUsesIncrementalThirdCycle"] = rounded.cloud.errorMessage == nil
            && roundedAccount.deltaPulls > healedPulls && roundedAccount.legacyReads == healedReads
            && roundedAccount.legacyUploads == healedUploads
        let afterHealing = try ImportExportService.exportPayload(from: rounded.context)
        func userRecords(_ payload: ExportPayload) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: CloudDocumentCodec.encode(payload)) as! [String: Any]
            object.removeValue(forKey: "exportedAt")
            var snapshots = object["snapshots"] as! [[String: Any]]
            for index in snapshots.indices {
                var entries = snapshots[index]["entries"] as! [[String: Any]]
                for entryIndex in entries.indices {
                    entries[entryIndex].removeValue(forKey: "amountEditedAt")
                }
                snapshots[index]["entries"] = entries.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            }
            object["snapshots"] = snapshots.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            for collection in ["categories", "items"] {
                object[collection] = (object[collection] as! [[String: Any]]).sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            }
            return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        }
        checks["deltaRoundedLegacyClockPreservesDomainRecords"] = try userRecords(beforeHealing) == userRecords(afterHealing)

        let lost = try await fixture("lost-ack"), lostAccount = lost.server.accounts["a"]!
        try edit(lost, amount: 30); lost.server.loseNextAcceptedResponse = true
        _ = await lost.cloud.runIsolatedSync(from: lost.context)
        let retained = try CloudReplicaCache.state(scope: "11:synthetic-a", in: ModelContext(lost.container))?.pendingRequest
        checks["deltaLostAcknowledgmentRetainsPendingRequest"] = retained != nil && lostAccount.accepted == 1
        try edit(lost, amount: 31)
        _ = await lost.cloud.runIsolatedSync(from: lost.context)
        checks["deltaLostAcknowledgmentRetriesSameReceiptThenNewerEdit"] = lostAccount.accepted == 2
            && lostAccount.replays == 1 && lostAccount.attempts.count == 3
            && lostAccount.attempts[0].requestID == lostAccount.attempts[1].requestID
            && lostAccount.attempts[2].requestID != lostAccount.attempts[0].requestID
        let remoteAfterRetry = try lostAccount.payload()
        checks["deltaReceiptDoesNotOverwriteNewerLocalSave"] = try amount(lost.context, day: lost.dayIDs[0], item: lost.itemIDs[0]) == 31
            && remoteAfterRetry.snapshots.first { $0.id == lost.dayIDs[0] }?.entries.first { $0.itemID == lost.itemIDs[0] }?.amount == 31

        let conflict = try await fixture("same-day-conflict")
        try edit(conflict, amount: 41, legacyClock: true)
        try conflict.server.remoteAmount(99, dayID: conflict.dayIDs[0], itemID: conflict.itemIDs[0])
        _ = await conflict.cloud.runIsolatedSync(from: conflict.context)
        checks["deltaDivergentDayKeepsFullMergeConflictReview"] = conflict.cloud.entryConflictReview?.conflicts.contains { $0.field == .amount } == true
            && conflict.server.accounts["a"]!.accepted == 0 && conflict.server.accounts["a"]!.legacyUploads == 0
        checks["deltaConflictRetainsLocalValue"] = try amount(conflict.context, day: conflict.dayIDs[0], item: conflict.itemIDs[0]) == 41

        let switched = try await fixture("account-switch")
        let metadata = ModelContext(switched.container); metadata.author = "atm.cloud.replica"
        let old = try CloudReplicaCache.state(scope: "11:synthetic-a", in: metadata)!
        // Reproduce a valid bookmark retained from a previous B session whose
        // records originally matched A; domain ownership is currently still A.
        metadata.insert(CloudReplicaState(scope: "12:synthetic-b", resetID: old.resetID,
                                         cursor: 1, historyToken: old.historyToken))
        let priorDocuments = try CloudReplicaCache.documents(scope: "11:synthetic-a", in: metadata)
        for row in priorDocuments.values {
            metadata.insert(CloudReplicaDocument(scope: "12:synthetic-b", kind: row.kind, recordID: row.recordID,
                                                version: row.version, value: row.value))
        }
        try metadata.save(); try edit(switched, amount: 52)
        switched.cloud.logout(); await switched.cloud.login(username: "b", password: "synthetic")
        _ = await switched.cloud.runIsolatedSync(from: switched.context)
        let other = switched.server.accounts["b"]!
        checks["deltaOldAccountBookmarkCannotBypassOwnership"] = other.attempts.isEmpty && other.legacyUploads == 0
            && switched.cloud.errorMessage?.isEmpty == false
            && switched.defaults.integer(forKey: "assettimemachine.cloud.localOwnerUserID") == 11
        checks["deltaAccountSwitchRetainsLocalRecords"] = try amount(switched.context, day: switched.dayIDs[0], item: switched.itemIDs[0]) == 52

        for categoryDeletion in [false, true] {
            let deletion = try await fixture(categoryDeletion ? "category-delete" : "item-delete")
            let item = try deletion.context.fetch(FetchDescriptor<AssetItem>()).first { $0.id == deletion.itemIDs[0] }!
            let existing = try deletion.context.fetch(FetchDescriptor<AssetSnapshot>()).first { $0.id == deletion.dayIDs[1] }!
            let localDay = AssetSnapshot(date: Calendar.current.date(byAdding: .day, value: 1, to: existing.date)!)
            deletion.context.insert(localDay)
            deletion.context.insert(AssetEntry(amount: 123, snapshot: localDay, item: item)); try deletion.context.save()
            try deletion.server.remoteDelete(itemIDs: categoryDeletion ? Set(deletion.itemIDs) : [deletion.itemIDs[0]],
                                             categoryID: categoryDeletion ? deletion.categoryID : nil)
            _ = await deletion.cloud.runIsolatedSync(from: deletion.context)
            checks[categoryDeletion ? "deltaRemoteCategoryDeleteProtectsUnsyncedDay" : "deltaRemoteItemDeleteProtectsUnsyncedDay"] =
                try amount(deletion.context, day: localDay.id, item: deletion.itemIDs[0]) == 123
                && deletion.cloud.errorMessage != nil && deletion.server.accounts["a"]!.accepted == 0
        }

        let migrationURL = root.appendingPathComponent("upgrade.store")
        let oldPayload: ExportPayload = try autoreleasepool {
            let oldSchema = Schema([AssetCategory.self, AssetItem.self, AssetSnapshot.self, AssetEntry.self,
                                    BacktestRecord.self, SyncDeletionTombstone.self])
            let oldContainer = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, url: migrationURL)])
            let oldContext = ModelContext(oldContainer); oldContext.autosaveEnabled = false
            _ = try seed(oldContext)
            return try ImportExportService.exportPayload(from: oldContext)
        }
        let upgraded = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: migrationURL)])
        let upgradedContext = ModelContext(upgraded)
        let upgradedPayload = try ImportExportService.exportPayload(from: upgradedContext)
        checks["deltaMetadataSchemaUpgradeRetainsDomainData"] = SyncMergeService.isSameContent(oldPayload, upgradedPayload)
            && oldPayload.snapshots.count == upgradedPayload.snapshots.count && oldPayload.items.count == upgradedPayload.items.count
        return checks
    }
}

#if DEBUG && targetEnvironment(simulator)
import SwiftUI

struct CloudDeltaProbeHostView: View {
    @State private var started = false
    var body: some View {
        Color.clear.task {
            guard !started else { return }
            started = true
            let result: [String: Any]
            do {
                let checks = try await CloudDeltaProbe.run()
                result = ["checks": checks, "count": checks.count, "allPassed": checks.values.allSatisfy { $0 }]
            } catch { result = ["allPassed": false, "error": error.localizedDescription] }
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("delta-probe.json")
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
    }
}
#endif
#endif
