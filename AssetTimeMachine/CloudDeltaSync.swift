import Foundation
import SwiftData

nonisolated enum CloudJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([CloudJSON]), object([String: CloudJSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([CloudJSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: CloudJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }
}

nonisolated struct CloudDocumentKey: Hashable, Sendable {
    let kind: String
    let id: String
    var wireKey: String { kind + ":" + id }
    init(kind: String, id: String) { self.kind = kind; self.id = id }
    init(wireKey: String) throws {
        guard let split = wireKey.firstIndex(of: ":") else { throw CocoaError(.coderReadCorrupt) }
        kind = String(wireKey[..<split]); id = String(wireKey[wireKey.index(after: split)...])
    }
}

nonisolated struct CloudDeltaDocument: Codable, Sendable {
    let kind: String
    let id: String
    let version: Int64
    let value: CloudJSON
    var key: CloudDocumentKey { .init(kind: kind, id: id) }
}

nonisolated struct CloudDeltaChange: Codable, Sendable {
    let kind: String
    let id: String
    let baseVersion: Int64
    let value: CloudJSON
    var key: CloudDocumentKey { .init(kind: kind, id: id) }
    enum CodingKeys: String, CodingKey { case kind, id, value; case baseVersion = "base_version" }
}

nonisolated struct CloudDeltaRequest: Codable, Sendable {
    let `protocol`: Int
    let accountID: String
    let cursor: Int64
    let requestID: String
    let changes: [CloudDeltaChange]
    let deviceName: String?
    let appVersion: String?
    enum CodingKeys: String, CodingKey {
        case `protocol`, cursor, changes
        case accountID = "account_id", requestID = "request_id", deviceName = "device_name", appVersion = "app_version"
    }
}

nonisolated struct CloudDeltaPending: Codable, Sendable {
    let request: CloudDeltaRequest
    let historyToken: Data?
}

nonisolated struct CloudDeltaBootstrap: Decodable, Sendable {
    let `protocol`: Int
    let accountID: String
    let cursor: Int64
    let backup: AssetTimeMachineCloudBackup?
    let payload: ExportPayload
    let versions: [String: Int64]
    enum CodingKeys: String, CodingKey { case `protocol`, cursor, backup, payload, versions; case accountID = "account_id" }
}

nonisolated struct CloudDeltaPull: Decodable, Sendable {
    struct Batch: Decodable, Sendable { let revision: Int64; let documents: [CloudDeltaDocument] }
    let `protocol`: Int
    let accountID: String
    let cursor: Int64
    let revision: Int64
    let hasMore: Bool
    let batches: [Batch]
    let backup: AssetTimeMachineCloudBackup?
    enum CodingKeys: String, CodingKey {
        case `protocol`, cursor, revision, batches, backup
        case accountID = "account_id", hasMore = "has_more"
    }
}

nonisolated struct CloudDeltaAck: Decodable, Sendable {
    let `protocol`: Int
    let accountID: String
    let cursor: Int64
    let backup: AssetTimeMachineCloudBackup
    let documents: [CloudDeltaDocument]
    enum CodingKeys: String, CodingKey { case `protocol`, cursor, backup, documents; case accountID = "account_id" }
}

nonisolated enum CloudDocumentCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        let parser = FlexibleAPIDateParser()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = parser.date(from: value) else { throw CocoaError(.coderReadCorrupt) }
            return date
        }
        return try decoder.decode(type, from: data)
    }
    static func json<T: Encodable>(_ value: T) throws -> CloudJSON { try decode(CloudJSON.self, from: encode(value)) }

    static func partition(_ payload: ExportPayload) throws -> [CloudDocumentKey: CloudJSON] {
        var result: [CloudDocumentKey: CloudJSON] = [.init(kind: "header", id: "root"): .object([:])]
        for value in payload.categories { result[.init(kind: "category", id: value.id.uuidString)] = try json(value) }
        for value in payload.items { result[.init(kind: "item", id: value.id.uuidString)] = try json(value) }
        for value in payload.snapshots { result[.init(kind: "snapshot", id: value.id.uuidString)] = try json(value) }
        for value in payload.deletionRecords {
            result[.init(kind: "deletion", id: value.entityKind + ":" + value.entityID.uuidString)] = try json(value)
        }
        return result
    }

    static func payload(_ documents: [CloudDocumentKey: CloudJSON]) throws -> ExportPayload {
        func records<T: Decodable>(_ kind: String, _ type: T.Type) throws -> [T] {
            try documents.filter { $0.key.kind == kind && $0.value != .null }
                .sorted { $0.key.id < $1.key.id }.map { try decode(type, from: encode($0.value)) }
        }
        return try .init(exportedAt: Date(timeIntervalSince1970: 0),
                         categories: records("category", ExportPayload.CategoryPayload.self),
                         items: records("item", ExportPayload.ItemPayload.self),
                         snapshots: records("snapshot", ExportPayload.SnapshotPayload.self),
                         deletions: records("deletion", ExportPayload.DeletionPayload.self))
    }

    static func userContent(_ value: CloudJSON, key: CloudDocumentKey,
                            catalog: [CloudDocumentKey: CloudJSON]) throws -> Data {
        if value == .null { return Data("null".utf8) }
        var selected = catalog.filter { ["category", "item"].contains($0.key.kind) }
        selected[key] = value
        return try SyncMergeService.userContentData(for: payload(selected))
    }
}

nonisolated struct CloudDeltaHistoryScan: Sendable {
    let token: Data?
    let snapshotIDs: Set<UUID>
    let catalogChanged: Bool
    let requiresFullExport: Bool
    let hasLocalChanges: Bool
}

nonisolated struct CloudReplicaBookmark: Sendable {
    let cursor: Int64
    let historyToken: Data?
    let pendingRequest: Data?
}

nonisolated enum CloudDeltaControl: Error { case legacy, deferred }

@ModelActor
actor CloudDeltaHistoryReader {
    func scan(after tokenData: Data?, collectChanges: Bool = true) throws -> CloudDeltaHistoryScan {
        let descriptor: HistoryDescriptor<DefaultHistoryTransaction>
        if let tokenData {
            let token = try JSONDecoder().decode(DefaultHistoryToken.self, from: tokenData)
            descriptor = HistoryDescriptor(predicate: #Predicate { $0.token > token })
        } else { descriptor = HistoryDescriptor() }
        let transactions = try modelContext.fetchHistory(descriptor)
        var snapshots: Set<UUID> = [], catalog = false, full = false, changed = false
        if collectChanges {
            for transaction in transactions {
                try Task.checkCancellation()
                if transaction.author?.hasPrefix("atm.cloud.") == true { continue }
                for change in transaction.changes {
                    switch change {
                    case .delete(let deletion):
                        if deletion is DefaultHistoryDelete<CloudReplicaState>
                            || deletion is DefaultHistoryDelete<CloudReplicaDocument> { continue }
                        if deletion is DefaultHistoryDelete<AssetCategory> || deletion is DefaultHistoryDelete<AssetItem>
                            || deletion is DefaultHistoryDelete<AssetSnapshot> || deletion is DefaultHistoryDelete<AssetEntry>
                            || deletion is DefaultHistoryDelete<SyncDeletionTombstone> {
                            full = true; changed = true
                        }
                    case .insert, .update:
                        let model = modelContext.model(for: change.changedPersistentIdentifier)
                        if let entry = model as? AssetEntry {
                            if let id = entry.snapshot?.id { snapshots.insert(id) } else { full = true }
                            changed = true
                        } else if let snapshot = model as? AssetSnapshot { snapshots.insert(snapshot.id); changed = true }
                        else if model is AssetCategory || model is AssetItem { catalog = true; changed = true }
                        else if model is SyncDeletionTombstone { full = true; changed = true }
                    @unknown default: full = true; changed = true
                    }
                }
            }
        }
        // Remote domain imports are processed too. Exclude replica-only saves so
        // advancing this bookmark does not create a new bookmark on every poll.
        let checkpoint = transactions.last { $0.author != "atm.cloud.replica" }
        return CloudDeltaHistoryScan(token: try checkpoint.map { try JSONEncoder().encode($0.token) } ?? tokenData,
                                     snapshotIDs: snapshots, catalogChanged: catalog, requiresFullExport: full,
                                     hasLocalChanges: changed)
    }
}

@MainActor
enum CloudReplicaCache {
    static func state(scope: String, in context: ModelContext) throws -> CloudReplicaState? {
        var request = FetchDescriptor<CloudReplicaState>(predicate: #Predicate { $0.scope == scope })
        request.fetchLimit = 2
        let values = try context.fetch(request)
        guard values.count < 2 else { throw CocoaError(.coderReadCorrupt) }
        return values.first
    }
    static func documents(scope: String, kinds: Set<String>? = nil,
                          in context: ModelContext) throws -> [CloudDocumentKey: CloudReplicaDocument] {
        let request: FetchDescriptor<CloudReplicaDocument>
        if let kinds {
            let selected = Array(kinds)
            request = FetchDescriptor(predicate: #Predicate { $0.scope == scope && selected.contains($0.kind) })
        } else { request = FetchDescriptor(predicate: #Predicate { $0.scope == scope }) }
        let rows = try context.fetch(request)
        var result: [CloudDocumentKey: CloudReplicaDocument] = [:]
        for row in rows {
            let key = CloudDocumentKey(kind: row.kind, id: row.recordID)
            guard result[key] == nil else { throw CocoaError(.coderReadCorrupt) }
            result[key] = row
        }
        return result
    }
    static func document(scope: String, key: CloudDocumentKey, in context: ModelContext) throws -> CloudReplicaDocument? {
        let kind = key.kind, id = key.id
        var request = FetchDescriptor<CloudReplicaDocument>(predicate: #Predicate {
            $0.scope == scope && $0.kind == kind && $0.recordID == id
        })
        request.fetchLimit = 2
        let rows = try context.fetch(request)
        guard rows.count < 2 else { throw CocoaError(.coderReadCorrupt) }
        return rows.first
    }
    static func value(_ row: CloudReplicaDocument?) throws -> CloudJSON {
        guard let data = row?.value else { return .null }
        return try CloudDocumentCodec.decode(CloudJSON.self, from: data)
    }
    static func values(_ rows: [CloudDocumentKey: CloudReplicaDocument]) throws -> [CloudDocumentKey: CloudJSON] {
        try rows.mapValues { try value($0) }
    }
    static func update(_ documents: [CloudDeltaDocument], scope: String, in context: ModelContext) throws {
        for document in documents {
            let data = document.value == .null ? nil : try CloudDocumentCodec.encode(document.value)
            if let row = try self.document(scope: scope, key: document.key, in: context) {
                row.value = data; row.version = document.version
            } else {
                context.insert(CloudReplicaDocument(scope: scope, kind: document.kind, recordID: document.id,
                                                    version: document.version, value: data))
            }
        }
    }
}
