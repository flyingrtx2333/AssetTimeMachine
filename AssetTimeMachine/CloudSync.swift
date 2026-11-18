import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

nonisolated struct AssetTimeMachineCloudUser: Codable, Sendable {
    let id: Int
    let userName: String?
    let userEmail: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userName = "user_name"
        case userEmail = "user_email"
    }

    @MainActor
    var displayName: String {
        if let userName, !userName.isEmpty {
            return userName
        }
        if let userEmail, !userEmail.isEmpty {
            return userEmail
        }
        return AppLocalization.format("用户 #%d", id)
    }
}

nonisolated struct AssetTimeMachineCloudBackup: Codable, Identifiable, Sendable, Equatable {
    let id: Int
    let fileName: String?
    let fileSize: Int?
    let storageURL: URL?
    let uploadedAt: Date
    let lastDownloadedAt: Date?
    let isLatest: Int
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case fileSize = "file_size"
        case storageURL = "storage_url"
        case uploadedAt = "uploaded_at"
        case lastDownloadedAt = "last_downloaded_at"
        case isLatest = "is_latest"
        case note
    }
}

nonisolated struct AssetTimeMachineCloudLatestBackup: Codable, Sendable {
    let id: Int
    let uploadedAt: Date
    let payload: ExportPayload
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case uploadedAt = "uploaded_at"
        case payload
        case note
    }
}

nonisolated private struct AssetTimeMachineCloudToken: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
    }
}

nonisolated private struct AssetTimeMachineCloudLoginRequest: Encodable, Sendable {
    let username: String
    let password: String
}

nonisolated private struct AssetTimeMachineCloudRefreshRequest: Encodable, Sendable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

nonisolated private struct AssetTimeMachineAppleLoginRequest: Encodable, Sendable {
    let identityToken: String
    let authorizationCode: String?
    let userName: String?
    let userEmail: String?

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
        case userName = "user_name"
        case userEmail = "user_email"
    }
}

nonisolated private struct AssetTimeMachineCloudUploadRequest: Encodable, Sendable {
    let payload: ExportPayload
    let fileName: String
    let dataKind: String
    let deviceName: String?
    let appVersion: String?
    let note: String?
    let baseBackupID: Int?

    enum CodingKeys: String, CodingKey {
        case payload
        case fileName = "file_name"
        case dataKind = "data_kind"
        case deviceName = "device_name"
        case appVersion = "app_version"
        case note
        case baseBackupID = "base_backup_id"
    }
}

nonisolated private struct AssetTimeMachineCloudErrorResponse: Codable, Sendable {
    let detail: String?
}

nonisolated struct CloudAccountDeletionInfo: Decodable, Sendable {
    let requiresAppleAuthorization: Bool
    let accountID: String
    let hasDeletionHistory: Bool
    enum CodingKeys: String, CodingKey {
        case requiresAppleAuthorization = "requires_apple_authorization"
        case accountID = "account_id"
        case hasDeletionHistory = "has_deletion_history"
    }
}

nonisolated private struct CloudAccountDeletionRequest: Encodable, Sendable {
    let confirmation = "DELETE_ASSET_TIME_MACHINE_ACCOUNT"
    let identityToken: String?
    let authorizationCode: String?
    enum CodingKeys: String, CodingKey {
        case confirmation
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
    }
}

nonisolated struct CloudAccountDeletionResult: Decodable, Sendable { let deleted: Bool }

enum AssetTimeMachineCloudAPI {
    private static let productionSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()
    nonisolated(unsafe) private static var isolatedSession: URLSession?
    static var hasIsolatedTransport: Bool { isolatedSession != nil }
    static func installIsolatedTransport(_ protocolClass: URLProtocol.Type) {
        precondition(AppPreviewSession.isActive && ProcessInfo.processInfo.arguments.contains("-macCloudSyncProbe"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        config.urlCache = nil
        config.timeoutIntervalForRequest = 5
        isolatedSession = URLSession(configuration: config)
    }
    static func removeIsolatedTransport() {
        isolatedSession?.invalidateAndCancel()
        isolatedSession = nil
    }
    private static var requestSession: URLSession { isolatedSession ?? productionSession }

    static let baseURL = RemoteMarketClient.baseURL

    fileprivate static func login(username: String, password: String) async throws -> AssetTimeMachineCloudToken {
        let response: AssetTimeMachineCloudToken = try await request(
            path: "/api/v1/asset-time-machine/account/login",
            method: "POST",
            body: AssetTimeMachineCloudLoginRequest(username: username, password: password)
        )
        return response
    }

    fileprivate static func loginWithApple(identityToken: String, authorizationCode: String?, userName: String?, userEmail: String?) async throws -> AssetTimeMachineCloudToken {
        let response: AssetTimeMachineCloudToken = try await request(
            path: "/api/v1/asset-time-machine/account/apple/login",
            method: "POST",
            body: AssetTimeMachineAppleLoginRequest(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                userName: userName,
                userEmail: userEmail
            )
        )
        return response
    }

    fileprivate static func refresh(refreshToken: String) async throws -> AssetTimeMachineCloudToken {
        try await request(
            path: "/api/v1/auth/refresh",
            method: "POST",
            body: AssetTimeMachineCloudRefreshRequest(refreshToken: refreshToken)
        )
    }

    static func fetchCurrentUser(token: String) async throws -> AssetTimeMachineCloudUser {
        try await request(path: "/api/v1/users/me", token: token)
    }

    static func accountInfo(token: String) async throws -> CloudAccountDeletionInfo {
        try await request(path: "/api/v1/asset-time-machine/account", token: token)
    }

    static func deleteAccount(token: String, identityToken: String?, authorizationCode: String?) async throws -> CloudAccountDeletionResult {
        try await request(path: "/api/v1/asset-time-machine/account", method: "DELETE", token: token,
                          body: CloudAccountDeletionRequest(identityToken: identityToken, authorizationCode: authorizationCode))
    }

    static func fetchHistory(token: String, limit: Int = 10, materialize: Bool = false) async throws -> [AssetTimeMachineCloudBackup] {
        try await request(path: "/api/v1/asset-time-machine/cloud/history?limit=\(limit)&materialize=\(materialize ? "true" : "false")", token: token)
    }

    static func deltaBootstrap(token: String) async throws -> CloudDeltaBootstrap {
        try await request(path: "/api/v1/asset-time-machine/cloud/sync/bootstrap", token: token)
    }

    static func deltaPull(token: String, accountID: String, since: Int64, through: Int64? = nil) async throws -> CloudDeltaPull {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "account_id", value: accountID), URLQueryItem(name: "since", value: String(since))]
        if let through { components.queryItems?.append(URLQueryItem(name: "through", value: String(through))) }
        return try await request(path: "/api/v1/asset-time-machine/cloud/sync/changes?" + (components.percentEncodedQuery ?? ""), token: token)
    }

    static func deltaCommit(token: String, body: CloudDeltaRequest) async throws -> CloudDeltaAck {
        try await request(path: "/api/v1/asset-time-machine/cloud/sync/commit", method: "POST", token: token, body: body)
    }

    static func deltaRequest(accountID: String, cursor: Int64, changes: [CloudDeltaChange]) -> CloudDeltaRequest {
        .init(protocol: 2, accountID: accountID, cursor: cursor, requestID: UUID().uuidString,
              changes: changes, deviceName: deviceName, appVersion: appVersion)
    }

    static func backupPayload(token: String, id: Int) async throws -> ExportPayload {
        try await request(path: "/api/v1/asset-time-machine/cloud/sync/backups/\(id)", token: token)
    }

    static func downloadBackupPayload(at url: URL) async throws -> ExportPayload {
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw URLError(.badURL) }
        // URLs come from this account's authenticated history. Never forward its token to storage.
        return try await request(url: url)
    }

    static func upload(token: String, payload: ExportPayload, note: String?, baseBackupID: Int? = nil) async throws -> AssetTimeMachineCloudBackup {
        try await request(
            path: "/api/v1/asset-time-machine/cloud/upload",
            method: "POST",
            token: token,
            body: AssetTimeMachineCloudUploadRequest(
                payload: payload,
                fileName: backupFileName,
                dataKind: "snapshot_bundle",
                deviceName: deviceName,
                appVersion: appVersion,
                note: note,
                baseBackupID: baseBackupID
            )
        )
    }

    static func recoveryArchive(token: String) async throws -> [(String, Data)] {
        func get(_ url: URL, authenticated: Bool) async throws -> Data {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            if authenticated { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            let (data, response) = try await requestSession.data(for: request)
            try validate(response: response, data: data)
            return data
        }
        let base = RemoteMarketClient.baseURL
        let history = try await get(base.appendingPathComponent("api/v1/asset-time-machine/cloud/history")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "100")]), authenticated: true)
        var result = [("history.json", history)]
        let latest = try await get(base.appendingPathComponent("api/v1/asset-time-machine/cloud/latest"), authenticated: true)
        result.append(("latest.json", latest))
        if let records = try JSONSerialization.jsonObject(with: history) as? [[String: Any]] {
            for record in records {
                guard let id = record["id"] as? Int,
                      let address = record["storage_url"] as? String,
                      let url = URL(string: address), url.scheme == "https" else { continue }
                do {
                    let data = try await get(url, authenticated: false)
                    result.append(("backup-\(id).json", data))
                } catch {
                    result.append(("backup-\(id)-unavailable.txt", Data("Download unavailable".utf8)))
                }
            }
        }
        return result
    }

    static func downloadLatest(token: String) async throws -> AssetTimeMachineCloudLatestBackup {
        try await request(path: "/api/v1/asset-time-machine/cloud/latest", token: token)
    }

    private static var backupFileName: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "asset-time-machine-\(formatter.string(from: .now)).json"
    }

    private static var appVersion: String? {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)) where !version.isEmpty && !build.isEmpty:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        default:
            return nil
        }
    }

    private static var deviceName: String? {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName
        #endif
    }

    private static func request<T: Decodable & Sendable>(path: String, method: String = "GET", token: String? = nil) async throws -> T {
        try await request(path: path, method: method, token: token, bodyData: nil)
    }

    private static func request<T: Decodable & Sendable>(url: URL, token: String? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await requestSession.data(for: request)
        try validate(response: response, data: data)
        return try await SyncPayloadWork.detached {
            try decoder().decode(T.self, from: data)
        }
    }

    private static func request<T: Decodable & Sendable, Body: Encodable & Sendable>(path: String, method: String, token: String? = nil, body: Body) async throws -> T {
        let bodyData = try await SyncPayloadWork.detached {
            try encoder().encode(body)
        }
        return try await request(path: path, method: method, token: token, bodyData: bodyData)
    }

    private static func request<T: Decodable & Sendable>(path: String, method: String, token: String?, bodyData: Data?) async throws -> T {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if bodyData != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await requestSession.data(for: request)
        try validate(response: response, data: data)
        return try await SyncPayloadWork.detached {
            try decoder().decode(T.self, from: data)
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let detail = (try? decoder().decode(AssetTimeMachineCloudErrorResponse.self, from: data).detail) ?? String(data: data, encoding: .utf8)
            throw NSError(
                domain: "AssetTimeMachineCloudAPI",
                code: httpResponse.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: detail?.isEmpty == false ? AppLocalization.string(detail!) : AppLocalization.string("云同步请求失败"),
                    "cloudRawDetail": detail ?? ""
                ]
            )
        }
    }

    private static func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    nonisolated private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let dateParser = FlexibleAPIDateParser()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = dateParser.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date format: \(value)")
        }
        return decoder
    }
}

enum AssetTimeMachineCloudIndicatorState {
    case idle
    case checking
    case healthy
    case warning

    var cloudSymbolName: String {
        switch self {
        case .idle:
            return "exclamationmark.icloud"
        case .checking:
            return "arrow.triangle.2.circlepath.icloud"
        case .healthy:
            return "checkmark.icloud.fill"
        case .warning:
            return "exclamationmark.icloud.fill"
        }
    }

    var symbolColor: Color {
        switch self {
        case .healthy:
            return AssetTheme.positive
        case .warning:
            return AssetTheme.negative
        case .idle, .checking:
            return AssetTheme.gold
        }
    }
}

enum CloudSyncPhase: Hashable {
    case idle, queued, waitingForEdits, checking, downloading, applying, uploading, retrying
}

struct CloudBackupRecovery: Identifiable {
    let id = UUID()
    let backup: AssetTimeMachineCloudBackup
    let payload: ExportPayload
    let userID: Int
    let accountID: String
}

private enum CloudOperationResult {
    case completed
    case skippedBusy
    case cancelled
    case failed
    case retryableFailure
}

nonisolated private struct PendingCloudUpload: Codable, Sendable {
    let userID: Int
    let baseBackupID: Int?
    let baselineSignature: String?
    let signature: String
    let payload: ExportPayload
    let confirmation: PendingEntryConfirmation?
}

nonisolated private struct PendingEntryConfirmation: Codable, Sendable {
    let originalLocalUserSignature: String
    let candidateUserSignature: String
    let remoteSignature: String
    let choices: [String: SyncMergeService.EntryChoice]
}

nonisolated struct CloudSyncEntryReview: Identifiable, Sendable {
    var id = UUID()
    let userID: Int
    let backupID: Int
    let localUserSignature: String
    let remoteSignature: String
    let baselineSignature: String?
    let conflicts: [SyncMergeService.EntryConflict]
    let itemNames: [UUID: String]
}

nonisolated private struct EntryConfirmationRequest: Sendable {
    let review: CloudSyncEntryReview
    let choices: [String: SyncMergeService.EntryChoice]
}

nonisolated private struct CloudPayloadFingerprint: Sendable {
    let signature: String
    let canonicalData: Data?
}

nonisolated private enum CloudPayloadReconciliation: Sendable {
    case restoreRemote(payload: ExportPayload, signature: String)
    case merge(
        payload: ExportPayload,
        needsLocalImport: Bool,
        matchesRemote: Bool,
        signature: String
    )
}

@MainActor
final class AssetTimeMachineCloudStore: ObservableObject {
    static let foregroundCheckInterval: TimeInterval = 5
    @Published var currentUser: AssetTimeMachineCloudUser? {
        didSet { if oldValue?.id != currentUser?.id { entryConflictReview = nil } }
    }
    @Published var backups: [AssetTimeMachineCloudBackup] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var lastSyncAt: Date?
    @Published private var hasPendingSync = false
    @Published private(set) var requiresLocalOwnershipConfirmation = false
    @Published private(set) var isApplyingLocalData = false
    @Published private(set) var localDataRevision = 0
    @Published private(set) var entryConflictReview: CloudSyncEntryReview?
    @Published private(set) var localRestoreNeedsCloudConfirmation = false
    @Published private(set) var syncPhase: CloudSyncPhase = .idle

    private let tokenKey = "assettimemachine.cloud.accessToken"
    private let refreshTokenKey = "assettimemachine.cloud.refreshToken"
    private let lastUploadedSignatureKey = "assettimemachine.cloud.lastUploadedSignature"
    private let lastSyncAtKey = "assettimemachine.cloud.lastSyncAt"
    private let lastVerifiedBackupIDKey = "assettimemachine.cloud.lastVerifiedBackupID"
    private let localRestorePendingKey = "assettimemachine.cloud.localRestorePending"
    private let beforeJSONImportKey = "assettimemachine.local.beforeJSONImport"
    private let defaults: UserDefaults
    private let localOwnerKey = "assettimemachine.cloud.localOwnerUserID"
    private let localOwnerAccountKey = "assettimemachine.cloud.localOwnerAccountID"
    private let accountResetRequiredKey = "assettimemachine.cloud.accountResetRequired"
    private var currentAccountID: String?
    private let isolatedTest: Bool
    private let tokenStore: CloudTokenStore
    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var hasLoadedInitialState = false
    private var lastVerifiedBackupID: Int?
    private var lastAutoSyncAttemptSignature: String?
    private var pendingAutoSyncCoordinatorTask: Task<Void, Never>?
    private var autoSyncCoordinatorTaskID: UUID?
    private var autoSyncGeneration = 0
    private var autoSyncRequestedDelayNanoseconds: UInt64 = 0
    private var automaticSyncIsActive = true
    private var autoSyncEncounteredTransientFailure = false
    private var deltaUnsupported = false
    private let deltaResetKey = "assettimemachine.cloud.deltaResetID"
    private let inheritedRebaseKeyPrefix = "assettimemachine.cloud.inheritedRebase.v1."

    init(tokenStore: CloudTokenStore? = nil, defaults: UserDefaults = .standard, isolatedTest: Bool = false) {
        precondition(!isolatedTest || (AppPreviewSession.isActive && tokenStore != nil
            && defaults !== UserDefaults.standard && AssetTimeMachineCloudAPI.hasIsolatedTransport
            && ProcessInfo.processInfo.arguments.contains("-macCloudSyncProbe")))
        self.defaults = defaults
        self.isolatedTest = isolatedTest
        self.tokenStore = tokenStore ?? KeychainTokenStore.shared
        guard !AppPreviewSession.isActive || isolatedTest else { return }
        localRestoreNeedsCloudConfirmation = defaults.bool(forKey: localRestorePendingKey)
        requiresLocalOwnershipConfirmation = localRestoreNeedsCloudConfirmation
        lastSyncAt = defaults.object(forKey: lastSyncAtKey) as? Date
        migrateLegacyTokensIfNeeded()
        cachedAccessToken = self.tokenStore.loadAccessToken()
        cachedRefreshToken = self.tokenStore.loadRefreshToken()
        if defaults.object(forKey: localOwnerKey) != nil,
           defaults.string(forKey: localOwnerAccountKey) != nil {
            lastVerifiedBackupID = defaults.object(forKey: lastVerifiedBackupIDKey) as? Int
        }
    }

    var hasToken: Bool {
        !(accessToken?.isEmpty ?? true)
    }

    var isSessionPending: Bool {
        hasToken && currentUser == nil && (isWorking || !hasLoadedInitialState) && (errorMessage?.isEmpty ?? true)
    }

    var hasCompletedInitialSync: Bool {
        lastSyncAt != nil
    }

    var indicatorState: AssetTimeMachineCloudIndicatorState {
        if (errorMessage?.isEmpty == false) || entryConflictReview != nil
            || (requiresLocalOwnershipConfirmation && hasToken) || syncPhase == .waitingForEdits {
            return .warning
        }
        if isWorking || hasPendingSync || isSessionPending {
            return .checking
        }
        if currentUser != nil {
            return hasCompletedInitialSync ? .healthy : .checking
        }
        return .idle
    }

    var indicatorLabel: String {
        if requiresLocalOwnershipConfirmation && hasToken { return AppLocalization.string("请确认本机记录的账户") }
        if entryConflictReview != nil { return AppLocalization.string("有记录需要确认") }
        if errorMessage?.isEmpty == false { return AppLocalization.string("云同步需要重试") }
        switch syncPhase {
        case .queued: return AppLocalization.string("已存本机，等待云同步")
        case .waitingForEdits: return AppLocalization.string("请先保存或放弃当前编辑")
        case .checking: return AppLocalization.string("正在检查云端更新")
        case .downloading: return AppLocalization.string("正在下载云端记录")
        case .applying: return AppLocalization.string("正在更新本机记录")
        case .uploading: return AppLocalization.string("已存本机，正在上传")
        case .retrying: return AppLocalization.string("已存本机，等待网络重试")
        case .idle: break
        }
        switch indicatorState {
        case .idle:
            return AppLocalization.string("云备份未开启")
        case .checking:
            if currentUser != nil && !hasCompletedInitialSync {
                return AppLocalization.string("等待首次云同步")
            }
            return AppLocalization.string("正在检查云备份")
        case .healthy:
            return AppLocalization.string("云备份正常")
        case .warning:
            return currentUser == nil ? AppLocalization.string("云备份需要注意") : AppLocalization.string("云备份已开启，但还需要处理")
        }
    }

    private var accessToken: String? {
        cachedAccessToken
    }

    private var refreshToken: String? {
        cachedRefreshToken
    }

    func refreshIfNeeded(from context: ModelContext) async {
        guard !AppPreviewSession.isActive || isolatedTest else { return }
        if currentUser != nil, ModelContextMutationBarrier.shared.hasBlockingEditorDraft {
            syncPhase = .waitingForEdits
            return
        }
        let shouldAttemptRefresh = !hasLoadedInitialState || (hasToken && currentUser == nil && !isWorking)
        guard shouldAttemptRefresh else {
            if currentUser != nil, !isWorking, pendingAutoSyncCoordinatorTask == nil {
                scheduleAutoSync(from: context, quietly: true, delayNanoseconds: 0)
            }
            return
        }

        hasLoadedInitialState = true
        guard hasToken else { return }
        await refreshSession()
        if currentUser != nil {
            scheduleAutoSync(from: context, quietly: true, delayNanoseconds: 0)
        }
    }

    /// The local store and pending-upload journal survive suspension; timers do not
    /// need to keep a hidden or background application awake.
    func setAutomaticSyncActive(_ active: Bool) {
        automaticSyncIsActive = active
        guard !active else { return }
        pendingAutoSyncCoordinatorTask?.cancel()
        pendingAutoSyncCoordinatorTask = nil
        autoSyncCoordinatorTaskID = nil
        if !isWorking { syncPhase = .idle }
    }

    func login(username: String, password: String) async {
        guard !AppPreviewSession.isActive || isolatedTest else { return }
        await perform { [self] in
            let token = try await AssetTimeMachineCloudAPI.login(username: username, password: password)
            try self.saveTokens(token)
            try await self.loadSessionData()
            self.statusMessage = AppLocalization.string("登录成功，正在准备云同步")
        }
    }

    #if os(macOS) && ATM_DIRECT_DISTRIBUTION
    func handleWebLogin(_ data: Data, from context: ModelContext) async {
        guard !AppPreviewSession.isActive || isolatedTest else { return }
        await perform { [self] in
            let token = try JSONDecoder().decode(AssetTimeMachineCloudToken.self, from: data)
            guard !token.accessToken.isEmpty else { throw URLError(.userAuthenticationRequired) }
            try self.saveTokens(token)
            try await self.loadSessionData()
            self.statusMessage = AppLocalization.string("登录成功，正在准备云同步")
        }
        if currentUser != nil {
            scheduleAutoSync(from: context, quietly: false, delayNanoseconds: 0)
        }
    }
    #endif

    func handleAppleSignIn(_ result: Result<ASAuthorization, any Error>, from context: ModelContext) async {
        guard !AppPreviewSession.isActive || isolatedTest else { return }
        switch result {
        case let .failure(error):
            errorMessage = friendlyAppleSignInMessage(for: error)
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = AppLocalization.string("未获取到 Apple 登录凭证")
                return
            }

            guard let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8),
                  !identityToken.isEmpty else {
                errorMessage = AppLocalization.string("Apple 未返回 identity token")
                return
            }

            let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            let fullName = [credential.fullName?.familyName, credential.fullName?.givenName]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined()
            let userName = fullName.isEmpty ? nil : fullName
            let userEmail = credential.email

            await perform { [self] in
                let token = try await AssetTimeMachineCloudAPI.loginWithApple(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    userName: userName,
                    userEmail: userEmail
                )
                try self.saveTokens(token)
                try await self.loadSessionData()
                self.statusMessage = AppLocalization.string("Apple 登录成功，正在准备云同步")
            }

            if currentUser != nil {
                scheduleAutoSync(from: context, quietly: false, delayNanoseconds: 0)
            }
        }
    }

    /// Read-only incident archive: never imports, merges, or uploads user data.
    @discardableResult
    func archiveRecovery() async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetTimeMachine-Recovery-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let archive = try await withTokenRefresh { token in
                try await AssetTimeMachineCloudAPI.recoveryArchive(token: token)
            }
            for (name, data) in archive {
                let file = directory.appendingPathComponent(name)
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            statusMessage = AppLocalization.string("同步诊断备份已保存；尚未恢复或上传数据")
            defaults.set(directory.path, forKey: "nativeMac.recoveryArchivePath")
            NSLog("[CloudRecovery] archive: %@", directory.path)
            return true
        } catch {
            errorMessage = error.localizedDescription
            NSLog("[CloudRecovery] failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Incident recovery only: cloud remains unchanged; verified local backup precedes this call.
    @discardableResult
    func recoverArchivedLatest(into context: ModelContext) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            guard ProcessInfo.processInfo.arguments.contains("-macCloudRecovery"),
                  ProcessInfo.processInfo.arguments.contains("-macRecoverFromCloud"),
                  let path = defaults.string(forKey: "nativeMac.recoveryArchivePath") else {
                throw URLError(.noPermissionsToReadFile)
            }
            let archive = URL(fileURLWithPath: path)
            let decoder = JSONDecoder()
            let parser = FlexibleAPIDateParser()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                guard let date = parser.date(from: value) else { throw URLError(.cannotParseResponse) }
                return date
            }
            let archived = try decoder.decode(AssetTimeMachineCloudLatestBackup.self,
                from: Data(contentsOf: archive.appendingPathComponent("latest.json")))
            guard let remote = try await fetchLatestBackupIfAvailable(), remote.id == archived.id,
                  SyncMergeService.isSameContent(remote.payload, archived.payload) else {
                throw NSError(domain: "CloudRecovery", code: 409,
                              userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("云端版本已变化，请重新核对备份")])
            }
            let local = try await ImportExportService.exportPayloadCooperatively(from: context)
            let remoteIDs = Set(remote.payload.snapshots.map(\.id))
            guard !remote.payload.snapshots.isEmpty,
                  Set(local.payload.snapshots.map(\.id)).isSubset(of: remoteIDs) else {
                throw NSError(domain: "CloudRecovery", code: 409,
                              userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("存在本机独有记录，已停止自动恢复")])
            }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let localFile = archive.appendingPathComponent("local-before-recovery.json")
            try encoder.encode(local.payload).write(to: localFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localFile.path)
            _ = try await applyCloudPayload(remote.payload, into: context, expectedStoreRevision: local.storeRevision)
            let restored = try await ImportExportService.exportPayloadCooperatively(from: context)
            guard SyncMergeService.isSameContent(restored.payload, remote.payload) else {
                throw NSError(domain: "CloudRecovery", code: 422,
                              userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("恢复后校验不一致，未启用自动同步")])
            }
            let fingerprint = try await Self.payloadFingerprint(for: remote.payload)
            if currentUser == nil {
                currentUser = try await withTokenRefresh { try await AssetTimeMachineCloudAPI.fetchCurrentUser(token: $0) }
            }
            lastVerifiedBackupID = remote.id
            try await rememberSync(signature: fingerprint.signature, at: remote.uploadedAt, payload: remote.payload)
            statusMessage = AppLocalization.string("已恢复手机云端数据并完成校验；未上传资产数据")
            errorMessage = nil
            NSLog("[CloudRecovery] restored backup %d; snapshots %d; verified same content; no upload", remote.id, restored.payload.snapshots.count)
            return true
        } catch {
            errorMessage = error.localizedDescription
            NSLog("[CloudRecovery] restore stopped: %@", error.localizedDescription)
            return false
        }
    }

    func refreshSession() async {
        guard !AppPreviewSession.isActive || isolatedTest else { return }
        await perform { [self] in
            try await self.loadSessionData()
        }
    }

    /// Owns both the debounce and the in-flight operation above feature-view lifetime.
    /// A cloud apply temporarily unmounts the TabView, so Dashboard must only submit
    /// intents and must never own or cancel the operation that performs that apply.
    func scheduleAutoSync(
        from context: ModelContext,
        quietly: Bool = true,
        delayNanoseconds: UInt64 = 120_000_000
    ) {
        guard !AppPreviewSession.isActive || isolatedTest,
              !ProcessInfo.processInfo.arguments.contains("-macCloudRecovery"),
              !localRestoreNeedsCloudConfirmation,
              currentUser != nil, hasToken else { return }
        hasPendingSync = true
        if !isWorking { syncPhase = .queued }
        guard automaticSyncIsActive else { return }
        autoSyncGeneration &+= 1
        autoSyncRequestedDelayNanoseconds = delayNanoseconds
        guard pendingAutoSyncCoordinatorTask == nil else { return }

        let taskID = UUID()
        autoSyncCoordinatorTaskID = taskID
        pendingAutoSyncCoordinatorTask = Task { [weak self] in
            guard let self else { return }
            var waitingGeneration = self.autoSyncGeneration
            var nextDelayNanoseconds = delayNanoseconds
            var transientFailures = 0

            while !Task.isCancelled {
                if nextDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: nextDelayNanoseconds)
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled, self.automaticSyncIsActive else { break }
                if waitingGeneration != self.autoSyncGeneration {
                    waitingGeneration = self.autoSyncGeneration
                    nextDelayNanoseconds = self.autoSyncRequestedDelayNanoseconds
                    continue
                }

                // A manual cloud operation or an unsaved editor owns the store for now.
                // Keep the intent queued instead of treating a busy/dirty store as a
                // completed sync and silently dropping the local save.
                while self.isWorking
                    || context.hasChanges
                    || ModelContextMutationBarrier.shared.hasPendingWrites
                    || ModelContextMutationBarrier.shared.hasBlockingEditorDraft {
                    if !self.isWorking {
                        self.syncPhase = ModelContextMutationBarrier.shared.hasBlockingEditorDraft
                            ? .waitingForEdits : .queued
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled,
                          self.currentUser != nil,
                          self.hasToken else { break }
                }
                guard !Task.isCancelled,
                      self.currentUser != nil,
                      self.hasToken else { break }
                if waitingGeneration != self.autoSyncGeneration {
                    waitingGeneration = self.autoSyncGeneration
                    nextDelayNanoseconds = self.autoSyncRequestedDelayNanoseconds
                    continue
                }

                let processingGeneration = self.autoSyncGeneration
                let didFinish = await self.autoSyncIfNeeded(from: context, quietly: quietly)
                guard !Task.isCancelled else { break }

                if !didFinish {
                    if self.autoSyncEncounteredTransientFailure {
                        self.syncPhase = .retrying
                        transientFailures = min(transientFailures + 1, 6)
                        nextDelayNanoseconds = UInt64(min(60, 1 << transientFailures)) * 1_000_000_000
                    } else {
                        transientFailures = 0
                        nextDelayNanoseconds = 400_000_000
                    }
                    continue
                }

                if processingGeneration == self.autoSyncGeneration {
                    if self.autoSyncCoordinatorTaskID == taskID {
                        self.pendingAutoSyncCoordinatorTask = nil
                        self.autoSyncCoordinatorTaskID = nil
                        self.hasPendingSync = false
                        self.syncPhase = .idle
                    }
                    return
                }
                waitingGeneration = self.autoSyncGeneration
                nextDelayNanoseconds = 0
            }

            if self.autoSyncCoordinatorTaskID == taskID {
                self.pendingAutoSyncCoordinatorTask = nil
                self.autoSyncCoordinatorTaskID = nil
                self.hasPendingSync = false
                if !self.isWorking { self.syncPhase = .idle }
            }
        }
    }

    private var replicaScope: String? {
        guard let userID = currentUser?.id, let account = currentAccountID else { return nil }
        return String(userID) + ":" + account
    }

    private func replicaBookmark(_ scope: String, container: ModelContainer) throws -> CloudReplicaBookmark? {
        let context = ModelContext(container)
        guard let state = try CloudReplicaCache.state(scope: scope, in: context),
              state.resetID == (defaults.string(forKey: deltaResetKey) ?? "0") else { return nil }
        return .init(cursor: state.cursor, historyToken: state.historyToken, pendingRequest: state.pendingRequest)
    }

    private func historyScan(_ container: ModelContainer, after token: Data?, collect: Bool = true) async throws -> CloudDeltaHistoryScan {
        try await BackgroundTaskWork.run {
            try await CloudDeltaHistoryReader(modelContainer: container).scan(after: token, collectChanges: collect)
        }
    }

    private func enableDeltaIfSupported(from context: ModelContext, historyToken: Data?) async {
        guard !deltaUnsupported, let historyToken, let scope = replicaScope, let account = currentAccountID,
              !requiresLocalOwnershipConfirmation, !localRestoreNeedsCloudConfirmation,
              !context.hasChanges, !ModelContextMutationBarrier.shared.hasPendingWrites,
              !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else { return }
        do {
            let revision = ModelStoreRevisionClock.shared.currentRevision()
            let bootstrap = try await withTokenRefresh { try await AssetTimeMachineCloudAPI.deltaBootstrap(token: $0) }
            guard let baseline = try await loadSyncBaseline() else { return }
            let baselineFingerprint = try await Self.payloadFingerprint(for: baseline)
            let bootstrapFingerprint = try await Self.payloadFingerprint(for: bootstrap.payload)
            guard bootstrap.protocol == 2, bootstrap.accountID == account,
                  bootstrap.backup?.id == lastVerifiedBackupID, replicaScope == scope,
                  !requiresLocalOwnershipConfirmation, !localRestoreNeedsCloudConfirmation, !context.hasChanges,
                  !ModelContextMutationBarrier.shared.hasPendingWrites,
                  !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
                  ModelStoreRevisionClock.shared.currentRevision() == revision else { return }
            if baselineFingerprint.signature != bootstrapFingerprint.signature {
                // An old JSON storage representation may differ from the accepted
                // local baseline without changing its backup ID. Retire only the
                // head shortcut so the existing complete three-way review heals it.
                lastVerifiedBackupID = nil
                defaults.removeObject(forKey: lastVerifiedBackupIDKey)
                scheduleAutoSync(from: context, quietly: true, delayNanoseconds: 0)
                return
            }
            let values = try await SyncPayloadWork.detached { try CloudDocumentCodec.partition(bootstrap.payload) }
            guard replicaScope == scope, bootstrap.backup?.id == lastVerifiedBackupID,
                  !requiresLocalOwnershipConfirmation, !localRestoreNeedsCloudConfirmation, !context.hasChanges,
                  !ModelContextMutationBarrier.shared.hasPendingWrites,
                  !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
                  ModelStoreRevisionClock.shared.currentRevision() == revision else { return }
            let metadata = ModelContext(context.container); metadata.author = "atm.cloud.replica"
            if let old = try CloudReplicaCache.state(scope: scope, in: metadata) { metadata.delete(old) }
            for old in try CloudReplicaCache.documents(scope: scope, in: metadata).values { metadata.delete(old) }
            metadata.insert(CloudReplicaState(scope: scope, resetID: defaults.string(forKey: deltaResetKey) ?? "0",
                                             cursor: bootstrap.cursor, historyToken: historyToken))
            for (wireKey, version) in bootstrap.versions {
                let key = try CloudDocumentKey(wireKey: wireKey)
                let value = values[key] ?? .null
                let data = value == .null ? nil : try CloudDocumentCodec.encode(value)
                metadata.insert(CloudReplicaDocument(scope: scope, kind: key.kind, recordID: key.id,
                                                     version: version, value: data))
            }
            try metadata.save()
        } catch {
            // Capability adoption is optional; a successful legacy sync remains successful.
            if [404, 405, URLError.unsupportedURL.rawValue].contains((error as NSError).code) { deltaUnsupported = true }
        }
    }

    private func prepareLegacyFromReplica(scope: String, container: ModelContainer) async throws {
        let metadata = ModelContext(container); metadata.author = "atm.cloud.replica"
        guard let state = try CloudReplicaCache.state(scope: scope, in: metadata), state.pendingRequest == nil else {
            throw CloudDeltaControl.deferred
        }
        let values = try CloudReplicaCache.values(CloudReplicaCache.documents(scope: scope, in: metadata))
        let payload = try await SyncPayloadWork.detached { try CloudDocumentCodec.payload(values) }
        try await persistSyncBaseline(payload)
        lastVerifiedBackupID = nil
        let fingerprint = try await Self.payloadFingerprint(for: payload)
        recordSyncMetadata(signature: fingerprint.signature, at: lastSyncAt ?? .now)
        state.resetID = "retired"
        try metadata.save()
    }

    private func updateDeltaSyncMetadata(_ backup: AssetTimeMachineCloudBackup?) {
        guard let backup else { return }
        if lastVerifiedBackupID != backup.id {
            lastVerifiedBackupID = backup.id
            defaults.set(backup.id, forKey: lastVerifiedBackupIDKey)
        }
        if lastSyncAt != backup.uploadedAt {
            lastSyncAt = backup.uploadedAt
            defaults.set(backup.uploadedAt, forKey: lastSyncAtKey)
        }
        if backups.first != backup {
            backups = [backup] + backups.filter { $0.id != backup.id && $0.isLatest != 1 }
        }
        let message = AppLocalization.string("双向同步完成")
        if statusMessage != message { statusMessage = message }
    }

    private func finishDeltaPending(_ pending: CloudDeltaPending, encoded: Data, scope: String,
                                    container: ModelContainer) async throws {
        guard currentAccountID == pending.request.accountID else { throw CloudDeltaControl.deferred }
        syncPhase = .uploading
        let ack: CloudDeltaAck
        do {
            ack = try await withTokenRefresh { try await AssetTimeMachineCloudAPI.deltaCommit(token: $0, body: pending.request) }
        } catch {
            let apiError = error as NSError
            let rawDetail = apiError.userInfo["cloudRawDetail"] as? String ?? apiError.localizedDescription
            if apiError.code == 409 && !rawDetail.contains("重复请求") {
                // A definitive CAS rejection precedes any write. Keep the history
                // bookmark so the same local changes can be rebased, with a new ID.
                let metadata = ModelContext(container); metadata.author = "atm.cloud.replica"
                if let state = try CloudReplicaCache.state(scope: scope, in: metadata), state.pendingRequest == encoded {
                    state.pendingRequest = nil; try metadata.save()
                }
                throw CloudDeltaControl.deferred
            }
            throw error
        }
        let expected = Dictionary(uniqueKeysWithValues: pending.request.changes.map { ($0.key, $0.value) })
        guard ack.protocol == 2, ack.accountID == pending.request.accountID,
              ack.cursor == pending.request.cursor + 1, ack.documents.count == expected.count,
              Set(ack.documents.map(\.key)).count == expected.count,
              ack.documents.allSatisfy({ $0.version == ack.cursor && expected[$0.key] == $0.value }),
              replicaScope == scope else { throw CocoaError(.coderReadCorrupt) }
        let metadata = ModelContext(container); metadata.author = "atm.cloud.replica"
        guard let state = try CloudReplicaCache.state(scope: scope, in: metadata), state.pendingRequest == encoded else {
            throw CloudDeltaControl.deferred
        }
        try CloudReplicaCache.update(ack.documents, scope: scope, in: metadata)
        state.cursor = ack.cursor; state.historyToken = pending.historyToken; state.pendingRequest = nil
        try metadata.save()
        // User models are untouched: an edit saved while the upload was in flight
        // remains in native history after the captured request's bookmark.
        updateDeltaSyncMetadata(ack.backup)
    }

    private func applyDeltaDocuments(_ documents: [CloudDeltaDocument], cursor: Int64,
                                     scope: String, into context: ModelContext,
                                     expectedRevision: UInt64) async throws {
        // Deletions can affect unsent records outside a day chunk through model
        // cascade rules or logical aliases. Reuse the complete three-way review.
        if documents.contains(where: { $0.kind == "deletion" || $0.value == .null }) {
            throw CloudDeltaControl.legacy
        }
        let metadata = ModelContext(context.container)
        let baseCatalog = try CloudReplicaCache.values(CloudReplicaCache.documents(scope: scope, kinds: ["category", "item"], in: metadata))
        let incomingIDs = Set(documents.filter { $0.kind == "snapshot" }.compactMap { UUID(uuidString: $0.id) })
        let incomingLocal = try ImportExportService.exportDays(incomingIDs, from: context)
        var sourceIDs = Set(incomingLocal.snapshots.flatMap(\.entries).map(\.id))
        for document in documents where document.kind == "snapshot" {
            let snapshot = try CloudDocumentCodec.decode(ExportPayload.SnapshotPayload.self, from: CloudDocumentCodec.encode(document.value))
            sourceIDs.formUnion(snapshot.entries.map(\.id))
        }
        let descendantIDs = try SnapshotService.inheritedSnapshotIDs(dependingOn: sourceIDs, in: context)
        let ids = incomingIDs.union(descendantIDs)
        let local = descendantIDs.isSubset(of: incomingIDs) ? incomingLocal : try ImportExportService.exportDays(ids, from: context)
        var desired = try CloudDocumentCodec.partition(local)
        let localCatalog = desired.filter { ["category", "item"].contains($0.key.kind) }
        for document in documents {
            let base = try CloudReplicaCache.value(CloudReplicaCache.document(scope: scope, key: document.key, in: metadata))
            let here = desired[document.key] ?? .null
            if document.kind != "header" {
                let oldUser = try CloudDocumentCodec.userContent(base, key: document.key, catalog: baseCatalog)
                let localUser = try CloudDocumentCodec.userContent(here, key: document.key, catalog: localCatalog)
                let remoteUser = try CloudDocumentCodec.userContent(document.value, key: document.key, catalog: baseCatalog)
                if oldUser != localUser && localUser != remoteUser { throw CloudDeltaControl.legacy }
                if document.kind == "snapshot", base == .null, document.value != .null {
                    let incoming = try CloudDocumentCodec.decode(ExportPayload.SnapshotPayload.self, from: CloudDocumentCodec.encode(document.value))
                    let day = Calendar.current.startOfDay(for: incoming.date)
                    let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                    let sameDay = try context.fetch(FetchDescriptor<AssetSnapshot>(predicate: #Predicate { $0.date >= day && $0.date < end }))
                    if sameDay.contains(where: { $0.id != incoming.id }) { throw CloudDeltaControl.legacy }
                }
                desired[document.key] = document.value
            }
        }
        let incomingPayload = try CloudDocumentCodec.payload(desired)
        let rebase = try await SyncPayloadWork.detached {
            SyncMergeService.rebasedInheritance(in: incomingPayload, provenBy: [local])
        }
        let payload = rebase.payload
        let exclusiveID = try ModelContextMutationBarrier.shared.beginExclusiveDrain()
        isApplyingLocalData = true; syncPhase = .applying
        defer {
            ModelContextMutationBarrier.shared.finishExclusive(exclusiveID)
            isApplyingLocalData = false
        }
        try await ModelContextMutationBarrier.shared.enterExclusive(exclusiveID)
        guard replicaScope == scope, !context.hasChanges,
              ModelStoreRevisionClock.shared.currentRevision() == expectedRevision else {
            throw CloudDeltaControl.deferred
        }
        let previousAuthor = context.author
        // Repaired days are new local work. Keep them in native history so the
        // following delta export sends them; received source days compare equal.
        context.author = rebase.changedSnapshotIDs.isEmpty ? "atm.cloud.delta" : "atm.inheritance.rebase"
        defer { context.author = previousAuthor }
        do {
            _ = try await ImportExportService.importPayloadCooperatively(payload, into: context, replaceExisting: true,
                expectedStoreRevision: expectedRevision, replacingSnapshotIDs: ids, saveChanges: false)
            guard replicaScope == scope,
                  let state = try CloudReplicaCache.state(scope: scope, in: context), state.pendingRequest == nil else {
                throw CloudDeltaControl.deferred
            }
            try CloudReplicaCache.update(documents, scope: scope, in: context)
            state.cursor = cursor
            try context.save()
            localDataRevision &+= 1
        } catch { context.rollback(); throw error }
    }

    /// Repair a stale copy left by an earlier app only when its old acknowledged
    /// source proves the copy. Run once per replica reset, never on every poll.
    private func repairInheritedCopiesOnce(scope: String, context: ModelContext) async throws {
        let resetID = defaults.string(forKey: deltaResetKey) ?? "0"
        let key = inheritedRebaseKeyPrefix + scope
        guard defaults.string(forKey: key) != resetID else { return }
        guard replicaScope == scope, !requiresLocalOwnershipConfirmation, !localRestoreNeedsCloudConfirmation,
              defaults.object(forKey: localOwnerKey) as? Int == currentUser?.id,
              defaults.string(forKey: localOwnerAccountKey) == currentAccountID,
              !defaults.bool(forKey: accountResetRequiredKey), !context.hasChanges,
              !ModelContextMutationBarrier.shared.hasPendingWrites,
              !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else { throw CloudDeltaControl.deferred }
        var inherited = FetchDescriptor<AssetEntry>(predicate: #Predicate { $0.inheritedFromEntryID != nil })
        inherited.fetchLimit = 1
        guard try !context.fetch(inherited).isEmpty else { defaults.set(resetID, forKey: key); return }
        let exported = try await ImportExportService.exportPayloadCooperatively(from: context)
        let baseline = try? await loadSyncBaseline()
        let repaired = try await SyncPayloadWork.detached {
            SyncMergeService.rebasedInheritance(in: exported.payload, provenBy: baseline.map { [$0] } ?? [])
        }
        guard replicaScope == scope, (defaults.string(forKey: deltaResetKey) ?? "0") == resetID,
              !context.hasChanges, !ModelContextMutationBarrier.shared.hasPendingWrites,
              !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
              ModelStoreRevisionClock.shared.currentRevision() == exported.storeRevision else { throw CloudDeltaControl.deferred }
        guard !repaired.changedSnapshotIDs.isEmpty else { defaults.set(resetID, forKey: key); return }
        let payload = ExportPayload(exportedAt: repaired.payload.exportedAt,
            categories: repaired.payload.categories, items: repaired.payload.items,
            snapshots: repaired.payload.snapshots.filter { repaired.changedSnapshotIDs.contains($0.id) },
            deletions: repaired.payload.deletionRecords)
        let exclusiveID = try ModelContextMutationBarrier.shared.beginExclusiveDrain()
        isApplyingLocalData = true; syncPhase = .applying
        defer { ModelContextMutationBarrier.shared.finishExclusive(exclusiveID); isApplyingLocalData = false }
        try await ModelContextMutationBarrier.shared.enterExclusive(exclusiveID)
        guard replicaScope == scope, !context.hasChanges,
              ModelStoreRevisionClock.shared.currentRevision() == exported.storeRevision else { throw CloudDeltaControl.deferred }
        let previousAuthor = context.author; context.author = "atm.inheritance.rebase"
        defer { context.author = previousAuthor }
        do {
            _ = try await ImportExportService.importPayloadCooperatively(payload, into: context, replaceExisting: true,
                expectedStoreRevision: exported.storeRevision, replacingSnapshotIDs: repaired.changedSnapshotIDs,
                saveChanges: false)
            guard replicaScope == scope else { throw CloudDeltaControl.deferred }
            try context.save()
            localDataRevision &+= 1
            defaults.set(resetID, forKey: key)
        } catch { context.rollback(); throw error }
    }

    private func runDeltaCycle(scope: String, context: ModelContext) async throws {
        guard let accountID = currentAccountID,
              var bookmark = try replicaBookmark(scope, container: context.container) else { throw CloudDeltaControl.legacy }
        if let encoded = bookmark.pendingRequest {
            let pending = try CloudDocumentCodec.decode(CloudDeltaPending.self, from: encoded)
            try await finishDeltaPending(pending, encoded: encoded, scope: scope, container: context.container)
            guard let next = try replicaBookmark(scope, container: context.container) else { throw CloudDeltaControl.deferred }
            bookmark = next
        }
        try await repairInheritedCopiesOnce(scope: scope, context: context)
        let revisionBeforePull = ModelStoreRevisionClock.shared.currentRevision()
        var cursor = bookmark.cursor, through: Int64?, incoming: [CloudDocumentKey: CloudDeltaDocument] = [:]
        var latestBackup: AssetTimeMachineCloudBackup?
        var pages = 0
        repeat {
            syncPhase = .checking
            let page: CloudDeltaPull
            do {
                page = try await withTokenRefresh { try await AssetTimeMachineCloudAPI.deltaPull(
                    token: $0, accountID: accountID, since: cursor, through: through) }
            } catch {
                if [404, 405, 409].contains((error as NSError).code) { throw CloudDeltaControl.legacy }
                throw error
            }
            guard page.protocol == 2, page.accountID == accountID, page.revision >= cursor,
                  through == nil || through == page.revision else { throw CocoaError(.coderReadCorrupt) }
            through = page.revision
            for batch in page.batches {
                guard batch.revision == cursor + 1,
                      Set(batch.documents.map(\.key)).count == batch.documents.count,
                      batch.documents.allSatisfy({ $0.version == batch.revision }) else { throw CocoaError(.coderReadCorrupt) }
                for document in batch.documents { incoming[document.key] = document }
                cursor = batch.revision
            }
            guard page.cursor == cursor, page.hasMore == (cursor < page.revision) else { throw CocoaError(.coderReadCorrupt) }
            latestBackup = page.backup
            pages += 1
            guard pages <= 4096, !(page.hasMore && page.batches.isEmpty) else { throw CocoaError(.coderReadCorrupt) }
            if !page.hasMore { break }
        } while true
        guard replicaScope == scope, !context.hasChanges,
              !ModelContextMutationBarrier.shared.hasPendingWrites,
              !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
              ModelStoreRevisionClock.shared.currentRevision() == revisionBeforePull else { throw CloudDeltaControl.deferred }
        if !incoming.isEmpty {
            try await applyDeltaDocuments(Array(incoming.values), cursor: cursor, scope: scope,
                                          into: context, expectedRevision: revisionBeforePull)
        } else if cursor != bookmark.cursor {
            let metadata = ModelContext(context.container); metadata.author = "atm.cloud.replica"
            guard let state = try CloudReplicaCache.state(scope: scope, in: metadata) else { throw CloudDeltaControl.deferred }
            state.cursor = cursor; try metadata.save()
        }
        updateDeltaSyncMetadata(latestBackup)
        guard let current = try replicaBookmark(scope, container: context.container) else { throw CloudDeltaControl.deferred }
        let revisionBeforeExport = ModelStoreRevisionClock.shared.currentRevision()
        let scan: CloudDeltaHistoryScan
        do { scan = try await historyScan(context.container, after: current.historyToken) }
        catch { throw CloudDeltaControl.legacy }
        guard !context.hasChanges, !ModelContextMutationBarrier.shared.hasPendingWrites,
              !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
              ModelStoreRevisionClock.shared.currentRevision() == revisionBeforeExport else { throw CloudDeltaControl.deferred }
        guard scan.hasLocalChanges else {
            if scan.token != current.historyToken {
                let metadata = ModelContext(context.container); metadata.author = "atm.cloud.replica"
                guard let state = try CloudReplicaCache.state(scope: scope, in: metadata),
                      state.cursor == cursor, state.pendingRequest == nil else { throw CloudDeltaControl.deferred }
                state.historyToken = scan.token
                try metadata.save()
            }
            return
        }
        let local: ExportPayload
        if scan.requiresFullExport { local = try await ImportExportService.exportPayloadCooperatively(from: context).payload }
        else { local = try ImportExportService.exportDays(scan.snapshotIDs, from: context) }
        guard !context.hasChanges, ModelStoreRevisionClock.shared.currentRevision() == revisionBeforeExport else { throw CloudDeltaControl.deferred }
        let candidates = try CloudDocumentCodec.partition(local)
        let metadata = ModelContext(context.container); metadata.author = "atm.cloud.replica"
        let catalog = candidates.filter { ["category", "item"].contains($0.key.kind) }
        let baseRows = try CloudReplicaCache.documents(scope: scope,
            kinds: scan.requiresFullExport ? nil : ["category", "item", "deletion"], in: metadata)
        var keys = Set(candidates.keys).union(baseRows.keys).filter { $0.kind != "header" }
        if !scan.requiresFullExport {
            keys = keys.filter { $0.kind != "snapshot" || UUID(uuidString: $0.id).map { scan.snapshotIDs.contains($0) } == true }
        }
        var changes: [CloudDeltaChange] = []
        for key in keys.sorted(by: { $0.wireKey < $1.wireKey }) {
            let row = try baseRows[key] ?? CloudReplicaCache.document(scope: scope, key: key, in: metadata)
            let prior = try CloudReplicaCache.value(row), value = candidates[key] ?? .null
            guard prior != value else { continue }
            if try CloudDocumentCodec.userContent(prior, key: key, catalog: catalog)
                != CloudDocumentCodec.userContent(value, key: key, catalog: catalog) {
                changes.append(.init(kind: key.kind, id: key.id, baseVersion: row?.version ?? 0, value: value))
            }
        }
        guard let state = try CloudReplicaCache.state(scope: scope, in: metadata), state.cursor == cursor,
              state.pendingRequest == nil else { throw CloudDeltaControl.deferred }
        if changes.isEmpty {
            state.historyToken = scan.token; try metadata.save()
            return
        }
        let request = AssetTimeMachineCloudAPI.deltaRequest(accountID: accountID, cursor: cursor, changes: changes)
        let pending = CloudDeltaPending(request: request, historyToken: scan.token)
        let encoded = try CloudDocumentCodec.encode(pending)
        state.pendingRequest = encoded; try metadata.save()
        try await finishDeltaPending(pending, encoded: encoded, scope: scope, container: context.container)
    }

    /// nil means a verified legacy reconciliation is required. Transient failures
    /// keep the same durable request so an uncertain acceptance cannot be replayed.
    private func incrementalSyncIfAvailable(from context: ModelContext) async -> Bool? {
        guard let scope = replicaScope, !requiresLocalOwnershipConfirmation,
              defaults.object(forKey: localOwnerKey) as? Int == currentUser?.id,
              defaults.string(forKey: localOwnerAccountKey) == currentAccountID,
              !defaults.bool(forKey: accountResetRequiredKey),
              (try? replicaBookmark(scope, container: context.container)) != nil else { return nil }
        var fallback = false, deferred = false
        let result = await perform { [self] in
            do { try await runDeltaCycle(scope: scope, context: context) }
            catch CloudDeltaControl.legacy {
                try await prepareLegacyFromReplica(scope: scope, container: context.container)
                fallback = true
            } catch CloudDeltaControl.deferred { deferred = true }
        }
        if fallback { return nil }
        if deferred || result == .skippedBusy || result == .cancelled { return false }
        if result == .retryableFailure { autoSyncEncounteredTransientFailure = true; return false }
        return true
    }

    @discardableResult
    private func autoSyncIfNeeded(from context: ModelContext, quietly: Bool,
        confirmation: EntryConfirmationRequest? = nil) async -> Bool {
        autoSyncEncounteredTransientFailure = false
        guard !AppPreviewSession.isActive || isolatedTest else { return true }
        guard !localRestoreNeedsCloudConfirmation else { return true }
        guard hasToken else { return true }
        guard !context.hasChanges,
              !ModelContextMutationBarrier.shared.hasPendingWrites,
              !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else { return false }

        if confirmation == nil, let result = await incrementalSyncIfAvailable(from: context) { return result }
        let usesHistory = !deltaUnsupported && !context.container.configurations.contains(where: { $0.isStoredInMemoryOnly })
        let initialHistory = usesHistory ? try? await historyScan(context.container, after: nil, collect: false) : nil

        for attempt in 0..<3 {
            guard !context.hasChanges,
                  !ModelContextMutationBarrier.shared.hasPendingWrites,
                  !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else { return false }
            var completedLocalSignature: String?
            var wasSupersededByLocalSave = false
            var cloudConflict = false
            let syncResult = await perform { [self] in
                let localExport: VersionedExportPayload
                do {
                    localExport = try await ImportExportService.exportPayloadCooperatively(from: context)
                } catch {
                    guard !Self.isCancellation(error) else { throw error }
                    throw NSError(
                        domain: "AssetTimeMachineCloudStore",
                        code: -30,
                        userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("本机数据导出失败，无法自动同步")]
                    )
                }

                let localPayload = localExport.payload
                var expectedStoreRevision = localExport.storeRevision
                let localFingerprint = try await Self.payloadFingerprint(for: localPayload)
                let localSignature = localFingerprint.signature
                guard !context.hasChanges,
                      !ModelContextMutationBarrier.shared.hasPendingWrites,
                      !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
                      ModelStoreRevisionClock.shared.currentRevision() == expectedStoreRevision else {
                    wasSupersededByLocalSave = true
                    throw CancellationError()
                }
                // Quotes can advance locally without changing user intent. Check the
                // authenticated head before downloading or uploading another full backup.
                if let headID = self.lastVerifiedBackupID,
                   let acknowledgedSignature = self.defaults.string(forKey: self.lastUploadedSignatureKey),
                   let userID = self.currentUser?.id,
                   !FileManager.default.fileExists(atPath: try self.pendingUploadURL(userID: userID).path),
                   let baseline = try await self.loadSyncBaseline(),
                   try await Self.payloadFingerprint(for: baseline).signature == acknowledgedSignature {
                    let unchangedUserContent: Bool
                    if localSignature == acknowledgedSignature {
                        unchangedUserContent = true
                    } else {
                        let localUserSignature = try await Self.userSignature(for: localPayload)
                        unchangedUserContent = localUserSignature == (try await Self.userSignature(for: baseline))
                    }
                    if unchangedUserContent {
                        let heads = try await self.withTokenRefresh { token in
                            try await AssetTimeMachineCloudAPI.fetchHistory(token: token, limit: 1)
                        }
                        if let head = heads.first, head.isLatest == 1, head.id == headID {
                            try self.validateLocalOwner(local: localPayload, remote: baseline)
                            guard !context.hasChanges, !ModelContextMutationBarrier.shared.hasPendingWrites,
                                  !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
                                  ModelStoreRevisionClock.shared.currentRevision() == expectedStoreRevision else {
                                wasSupersededByLocalSave = true
                                throw CancellationError()
                            }
                            // Leave the acknowledged signature/baseline untouched:
                            // the newer derived quotes have not been uploaded.
                            completedLocalSignature = localSignature
                            return
                        }
                    }
                }
                // A different head still requires the full payload and three-way merge.

                var latestBackup = try await self.fetchLatestBackupIfAvailable()
                let baseBackupID = latestBackup?.id
                try await self.recoverSharedHistoryIfNeeded(local: localPayload, latest: latestBackup)
                try self.validateLocalOwner(local: localPayload, remote: latestBackup?.payload)
                try await self.recoverPendingUpload(latest: latestBackup)
                let baseline = try await self.loadSyncBaseline()
                let rawRemoteFingerprint: CloudPayloadFingerprint?
                if let latestBackup { rawRemoteFingerprint = try await Self.payloadFingerprint(for: latestBackup.payload) }
                else { rawRemoteFingerprint = nil }
                latestBackup = try await self.resolveDeletionHistory(latestBackup, local: localPayload, baseline: baseline)
                if latestBackup == nil,
                   SyncMergeService.isEmptyUserData(localPayload) || SyncMergeService.looksLikeSeedOnly(localPayload) {
                    try await self.persistSyncBaseline(localPayload)
                    self.lastSyncAt = nil
                    self.defaults.removeObject(forKey: self.lastSyncAtKey)
                    self.statusMessage = AppLocalization.string("云端暂无记录，可先在本机添加资产。不会上传空记录。")
                    return
                }
                var payloadToUpload = localPayload
                var uploadSignature = localSignature
                var shouldUpload = true
                var confirmedUpload: PendingEntryConfirmation?

                if let latestBackup {
                    guard let userID = self.currentUser?.id, let remoteFingerprint = rawRemoteFingerprint else {
                        throw URLError(.userAuthenticationRequired)
                    }
                    let pending = try await self.loadPendingUpload()
                    var choices: [String: SyncMergeService.EntryChoice] = [:]
                    var resumed: CloudPayloadReconciliation?
                    var baselineSignature: String?
                    if let baseline { baselineSignature = try await Self.payloadFingerprint(for: baseline).signature }
                    if let confirmation {
                        let review = confirmation.review
                        guard review.userID == self.currentUser?.id, review.backupID == latestBackup.id,
                              review.remoteSignature == rawRemoteFingerprint?.signature,
                              review.baselineSignature == baselineSignature,
                              review.localUserSignature == (try await Self.userSignature(for: localPayload)) else {
                            self.entryConflictReview = nil
                            throw NSError(domain: "CloudSyncReview", code: 409,
                                userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("记录已变化，请重新查看差异")])
                        }
                        choices = confirmation.choices
                    } else if let pending, let saved = pending.confirmation,
                              pending.baseBackupID == latestBackup.id,
                              saved.remoteSignature == rawRemoteFingerprint?.signature,
                              pending.baselineSignature == baselineSignature {
                        let userSignature = try await Self.userSignature(for: localPayload)
                        if userSignature == saved.candidateUserSignature {
                            // Only derived quotes/metadata may have changed since the
                            // confirmed candidate was applied. The server head is exact.
                            resumed = .merge(payload: localPayload, needsLocalImport: false,
                                matchesRemote: false, signature: localSignature)
                            confirmedUpload = saved
                        } else if userSignature == saved.originalLocalUserSignature {
                            choices = saved.choices
                            confirmedUpload = saved
                        }
                    }
                    let reconciliation: CloudPayloadReconciliation
                    do {
                        if let resumed { reconciliation = resumed }
                        else {
                            reconciliation = try await Self.reconcile(local: localPayload,
                                localCanonicalData: localFingerprint.canonicalData, remote: latestBackup.payload,
                                baseline: baseline, serverCanonicalData: rawRemoteFingerprint?.canonicalData,
                                choices: choices)
                        }
                    } catch let conflict as SyncMergeService.EntryConflicts {
                        let review = CloudSyncEntryReview(userID: userID, backupID: latestBackup.id,
                            localUserSignature: try await Self.userSignature(for: localPayload),
                            remoteSignature: remoteFingerprint.signature, baselineSignature: baselineSignature,
                            conflicts: conflict.conflicts,
                            itemNames: Dictionary((localPayload.items + latestBackup.payload.items).map { ($0.id, $0.name) },
                                uniquingKeysWith: { first, _ in first }))
                        if let old = self.entryConflictReview,
                           old.userID == review.userID, old.backupID == review.backupID,
                           old.localUserSignature == review.localUserSignature,
                           old.remoteSignature == review.remoteSignature, old.baselineSignature == review.baselineSignature {
                            // Keep in-progress choices stable during periodic checks.
                        } else { self.entryConflictReview = review }
                        throw conflict
                    }

                    switch reconciliation {
                    case let .restoreRemote(remotePayload, signature):
                        do {
                            _ = try await self.applyCloudPayload(
                                remotePayload,
                                into: context,
                                expectedStoreRevision: expectedStoreRevision
                            )
                        } catch is ImportExportConsistencyError {
                            wasSupersededByLocalSave = true
                            throw CancellationError()
                        }
                        completedLocalSignature = signature
                        self.lastVerifiedBackupID = signature == rawRemoteFingerprint?.signature ? latestBackup.id : nil
                        try await self.rememberSync(signature: signature, at: latestBackup.uploadedAt, payload: latestBackup.payload)
                        self.entryConflictReview = nil
                        if signature != rawRemoteFingerprint?.signature {
                            self.scheduleAutoSync(from: context, delayNanoseconds: 0)
                        }
                        try await self.loadHistoryAfterSync()
                        self.statusMessage = quietly ? AppLocalization.string("已恢复云端最新数据") : AppLocalization.string("已从云端恢复最新资产数据")
                        return

                    case let .merge(mergedPayload, needsLocalImport, matchesRemote, signature):
                        if confirmation != nil || confirmedUpload != nil {
                            let originalSignature: String
                            if let saved = confirmedUpload { originalSignature = saved.originalLocalUserSignature }
                            else { originalSignature = try await Self.userSignature(for: localPayload) }
                            let confirmedChoices = confirmation?.choices ?? confirmedUpload?.choices ?? [:]
                            confirmedUpload = PendingEntryConfirmation(
                                originalLocalUserSignature: originalSignature,
                                candidateUserSignature: try await Self.userSignature(for: mergedPayload),
                                remoteSignature: remoteFingerprint.signature, choices: confirmedChoices)
                            if let confirmation {
                                try await self.saveReviewSafetyBackups(local: localPayload, remote: latestBackup.payload,
                                    id: confirmation.review.id)
                            }
                            // The decision survives a crash before local import or an
                            // uncertain upload. Never persist a partial review candidate.
                            try await self.persistPendingUpload(mergedPayload, signature: signature,
                                baseBackupID: baseBackupID, baseline: baseline, confirmation: confirmedUpload)
                        }
                        if needsLocalImport {
                            do {
                                expectedStoreRevision = try await self.applyCloudPayload(
                                    mergedPayload,
                                    into: context,
                                    expectedStoreRevision: expectedStoreRevision
                                )
                            } catch is ImportExportConsistencyError {
                                wasSupersededByLocalSave = true
                                throw CancellationError()
                            }
                        } else if context.hasChanges
                                    || ModelContextMutationBarrier.shared.hasPendingWrites
                                    || ModelContextMutationBarrier.shared.hasBlockingEditorDraft
                                    || ModelStoreRevisionClock.shared.currentRevision() != expectedStoreRevision {
                            wasSupersededByLocalSave = true
                            throw CancellationError()
                        }
                        payloadToUpload = mergedPayload
                        uploadSignature = signature
                        if matchesRemote {
                            self.lastVerifiedBackupID = latestBackup.id
                            completedLocalSignature = signature
                            try await self.rememberSync(signature: signature, at: latestBackup.uploadedAt, payload: latestBackup.payload)
                            self.entryConflictReview = nil
                            try self.clearPendingUpload()
                            shouldUpload = false
                        }
                    }
                }

                guard !context.hasChanges,
                      !ModelContextMutationBarrier.shared.hasPendingWrites,
                      !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
                      ModelStoreRevisionClock.shared.currentRevision() == expectedStoreRevision else {
                    wasSupersededByLocalSave = true
                    throw CancellationError()
                }
                guard shouldUpload else {
                    try await self.loadHistoryAfterSync()
                    return
                }

                try await self.persistPendingUpload(payloadToUpload, signature: uploadSignature,
                    baseBackupID: baseBackupID, baseline: baseline, confirmation: confirmedUpload)
                let backup: AssetTimeMachineCloudBackup
                do {
                    self.syncPhase = .uploading
                    backup = try await self.withTokenRefresh { token in
                    try await AssetTimeMachineCloudAPI.upload(
                        token: token,
                        payload: payloadToUpload,
                        note: AppLocalization.string("iOS 双向云同步"),
                        baseBackupID: baseBackupID
                    )
                    }
                } catch {
                    if (error as NSError).code == 409 {
                        try self.clearPendingUpload()
                        if attempt < 2 {
                            cloudConflict = true
                            throw CancellationError()
                        }
                    }
                    throw error
                }
                // Acknowledgment belongs to the uploaded revision, even if another
                // local save arrived during the request. Never lose this ancestor.
                try await self.persistSyncBaseline(payloadToUpload)
                self.lastVerifiedBackupID = backup.id
                try self.clearPendingUpload()
                self.entryConflictReview = nil
                guard !context.hasChanges,
                      !ModelContextMutationBarrier.shared.hasPendingWrites,
                      !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
                      ModelStoreRevisionClock.shared.currentRevision() == expectedStoreRevision else {
                    wasSupersededByLocalSave = true
                    throw CancellationError()
                }
                self.recordSyncMetadata(signature: uploadSignature, at: backup.uploadedAt)
                completedLocalSignature = uploadSignature
                try await self.loadHistoryAfterSync()
                self.statusMessage = quietly ? AppLocalization.string("双向同步完成") : AppLocalization.format("云端同步完成，时间：%@", backup.uploadedAt.formatted(date: .abbreviated, time: .shortened))
            }

            if syncResult == .completed, let completedLocalSignature {
                lastAutoSyncAttemptSignature = completedLocalSignature
                entryConflictReview = nil
                await enableDeltaIfSupported(from: context, historyToken: initialHistory?.token)
            }
            if syncResult == .skippedBusy {
                return false
            }
            if syncResult == .retryableFailure {
                autoSyncEncounteredTransientFailure = true
                return false
            }
            guard (wasSupersededByLocalSave || cloudConflict), !Task.isCancelled else {
                return true
            }
            guard attempt < 2 else { return false }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return false
    }

    func restoreLatestBackup(into context: ModelContext) async {
        guard !AppPreviewSession.isActive || isolatedTest else { return }
        guard hasToken else {
            errorMessage = AppLocalization.string("登录后方可恢复云端备份")
            return
        }

        guard !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else {
            errorMessage = AppLocalization.string("请先完成当前编辑，再恢复云端备份")
            return
        }
        do {
            try await ModelContextMutationBarrier.shared.waitForPendingWrites()
        } catch {
            return
        }
        guard !context.hasChanges else {
            errorMessage = AppLocalization.string("请先完成当前编辑，再恢复云端备份")
            return
        }
        let requestedStoreRevision = ModelStoreRevisionClock.shared.currentRevision()
        await perform { [self] in
            let before = try await ImportExportService.exportPayloadCooperatively(from: context)
            guard before.storeRevision == requestedStoreRevision else { throw CancellationError() }
            try await self.saveLocalSafetyBackup(before.payload)
            let latest = try await self.withTokenRefresh { token in
                try await AssetTimeMachineCloudAPI.downloadLatest(token: token)
            }
            let fingerprint = try await Self.payloadFingerprint(for: latest.payload)
            do {
                _ = try await self.applyCloudPayload(
                    latest.payload,
                    into: context,
                    expectedStoreRevision: requestedStoreRevision
                )
            } catch is ImportExportConsistencyError {
                throw NSError(
                    domain: "AssetTimeMachineCloudStore",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("请稍后再试")]
                )
            }
            self.lastVerifiedBackupID = latest.id
            try await self.rememberSync(signature: fingerprint.signature, at: latest.uploadedAt, payload: latest.payload)
            try self.clearPendingUpload()
            self.requiresLocalOwnershipConfirmation = false
            self.entryConflictReview = nil
            self.localRestoreNeedsCloudConfirmation = false
            self.defaults.removeObject(forKey: self.localRestorePendingKey)
            try await self.loadHistoryAfterSync()
            self.statusMessage = AppLocalization.string("最近一次云端备份已恢复")
        }
    }

    func refreshBackupHistory() async {
        guard !AppPreviewSession.isActive || isolatedTest, hasToken else { return }
        await perform { [self] in
            self.backups = try await self.withTokenRefresh {
                try await AssetTimeMachineCloudAPI.fetchHistory(token: $0, limit: 100, materialize: true)
            }
        }
    }

    func retrySync(from context: ModelContext) async {
        guard !isWorking, hasToken else { return }
        pendingAutoSyncCoordinatorTask?.cancel()
        pendingAutoSyncCoordinatorTask = nil
        autoSyncCoordinatorTaskID = nil
        hasPendingSync = false
        syncPhase = .idle
        errorMessage = nil
        await refreshIfNeeded(from: context)
    }

    func prepareBackupRecovery(_ backup: AssetTimeMachineCloudBackup) async throws -> CloudBackupRecovery {
        guard !AppPreviewSession.isActive || isolatedTest, !isWorking, hasToken,
              let userID = currentUser?.id, let accountID = currentAccountID else {
            throw URLError(.userAuthenticationRequired)
        }
        isWorking = true; syncPhase = .downloading
        defer { isWorking = false; syncPhase = .idle }
        // Only use a storage URL obtained from this account's fresh authenticated list.
        let history = try await withTokenRefresh { try await AssetTimeMachineCloudAPI.fetchHistory(token: $0, limit: 100, materialize: true) }
        guard let selected = history.first(where: { $0.id == backup.id }) else {
            throw NSError(domain: "CloudBackupRecovery", code: 404,
                userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("此备份已不可用，请刷新列表")])
        }
        let payload: ExportPayload
        if let url = selected.storageURL {
            payload = try await AssetTimeMachineCloudAPI.downloadBackupPayload(at: url)
        } else if selected.isLatest == 1 {
            let latest = try await withTokenRefresh { try await AssetTimeMachineCloudAPI.downloadLatest(token: $0) }
            guard latest.id == selected.id else { throw URLError(.resourceUnavailable) }
            payload = latest.payload
        } else {
            payload = try await withTokenRefresh { try await AssetTimeMachineCloudAPI.backupPayload(token: $0, id: selected.id) }
        }
        let prepared = try await ImportExportService.prepareLocalImportPayload(payload)
        guard currentUser?.id == userID, currentAccountID == accountID, hasToken else {
            throw URLError(.userAuthenticationRequired)
        }
        backups = history
        return CloudBackupRecovery(backup: selected, payload: prepared, userID: userID, accountID: accountID)
    }

    func restoreBackup(_ recovery: CloudBackupRecovery, into context: ModelContext) async throws {
        guard currentUser?.id == recovery.userID, currentAccountID == recovery.accountID, hasToken else {
            throw URLError(.userAuthenticationRequired)
        }
        // A historical version is an explicit local recovery, never a new cloud head.
        try await restoreLocalRecords(recovery.payload, into: context)
        statusMessage = AppLocalization.string("所选备份已恢复，云同步已暂停")
    }

    func accountDeletionInfo() async throws -> CloudAccountDeletionInfo {
        guard !AppPreviewSession.isActive || isolatedTest else { throw URLError(.userAuthenticationRequired) }
        return try await withTokenRefresh { try await AssetTimeMachineCloudAPI.accountInfo(token: $0) }
    }

    func deleteAccount(identityToken: String? = nil, authorizationCode: String? = nil) async -> Bool {
        guard !AppPreviewSession.isActive || isolatedTest, !isWorking else { return false }
        autoSyncGeneration &+= 1
        pendingAutoSyncCoordinatorTask?.cancel()
        pendingAutoSyncCoordinatorTask = nil
        autoSyncCoordinatorTaskID = nil
        hasPendingSync = false
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await withTokenRefresh { token in
                try await AssetTimeMachineCloudAPI.deleteAccount(token: token, identityToken: identityToken,
                                                                 authorizationCode: authorizationCode)
            }
            guard result.deleted else { throw URLError(.badServerResponse) }
            // Keep offline records, but never reuse the deleted account's baseline/outbox.
            defaults.set(true, forKey: accountResetRequiredKey)
            try? resetAccountSyncMetadata()
            clearTokens()
            currentUser = nil
            currentAccountID = nil
            backups = []
            lastSyncAt = nil
            requiresLocalOwnershipConfirmation = false
            entryConflictReview = nil
            statusMessage = AppLocalization.string("资产时光机账户已删除")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func resetAccountSyncMetadata() throws {
        defaults.set(UUID().uuidString, forKey: deltaResetKey)
        defaults.set(true, forKey: accountResetRequiredKey)
        if let userID = currentUser?.id {
            for file in [try baselineURL(userID: userID), try pendingUploadURL(userID: userID)] {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
        }
        defaults.removeObject(forKey: localOwnerKey)
        defaults.removeObject(forKey: localOwnerAccountKey)
        defaults.removeObject(forKey: lastUploadedSignatureKey)
        defaults.removeObject(forKey: lastSyncAtKey)
        defaults.removeObject(forKey: lastVerifiedBackupIDKey)
        lastVerifiedBackupID = nil
        defaults.removeObject(forKey: accountResetRequiredKey)
        lastSyncAt = nil
    }

    func logout() {
        guard !AppPreviewSession.isActive || isolatedTest else { return }
        guard !isWorking else { return }
        autoSyncGeneration &+= 1
        pendingAutoSyncCoordinatorTask?.cancel()
        pendingAutoSyncCoordinatorTask = nil
        autoSyncCoordinatorTaskID = nil
        hasPendingSync = false
        requiresLocalOwnershipConfirmation = false
        entryConflictReview = nil
        clearTokens()
        // Keep the acknowledged fingerprint so a legacy install can recover its
        // baseline from this account's authenticated history after signing in again.
        // Account deletion clears it through resetAccountSyncMetadata().
        defaults.removeObject(forKey: lastSyncAtKey)
        currentUser = nil
        currentAccountID = nil
        backups = []
        lastSyncAt = nil
        statusMessage = AppLocalization.string("已退出云同步")
        errorMessage = nil
    }

    private func saveTokens(_ token: AssetTimeMachineCloudToken, fallbackRefreshToken: String? = nil) throws {
        let refreshTokenToSave: String?
        if let refreshToken = token.refreshToken, !refreshToken.isEmpty {
            refreshTokenToSave = refreshToken
        } else if let fallbackRefreshToken, !fallbackRefreshToken.isEmpty {
            refreshTokenToSave = fallbackRefreshToken
        } else {
            refreshTokenToSave = nil
        }
        try tokenStore.save(accessToken: token.accessToken, refreshToken: refreshTokenToSave)
        let verifiedAccessToken = tokenStore.loadAccessToken()
        guard verifiedAccessToken == token.accessToken else {
            throw NSError(
                domain: "AssetTimeMachineCloudStore",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("登录凭证保存后校验失败")]
            )
        }
        cachedAccessToken = verifiedAccessToken
        cachedRefreshToken = tokenStore.loadRefreshToken()
        clearLegacyUserDefaultsTokens()
    }

    private func clearTokens() {
        currentAccountID = nil
        lastVerifiedBackupID = nil
        defaults.removeObject(forKey: lastVerifiedBackupIDKey)
        try? tokenStore.clear()
        cachedAccessToken = nil
        cachedRefreshToken = nil
        clearLegacyUserDefaultsTokens()
    }

    private func migrateLegacyTokensIfNeeded() {
        guard tokenStore.loadAccessToken()?.isEmpty ?? true else {
            clearLegacyUserDefaultsTokens()
            return
        }
        guard let legacyAccessToken = defaults.string(forKey: tokenKey), !legacyAccessToken.isEmpty else {
            clearLegacyUserDefaultsTokens()
            return
        }
        let legacyRefreshToken = defaults.string(forKey: refreshTokenKey)
        do {
            try tokenStore.save(accessToken: legacyAccessToken, refreshToken: legacyRefreshToken)
            guard tokenStore.loadAccessToken() == legacyAccessToken else { return }
            clearLegacyUserDefaultsTokens()
        } catch {
            // Keep legacy UserDefaults tokens if Keychain migration fails, so upgraded users stay signed in.
        }
    }

    private func clearLegacyUserDefaultsTokens() {
        defaults.removeObject(forKey: tokenKey)
        defaults.removeObject(forKey: refreshTokenKey)
    }

    private func loadSessionData() async throws {
        // Retry the batch under one token refresh, rather than racing three refreshes.
        let (user, account, history) = try await withTokenRefresh { token in
            async let user = AssetTimeMachineCloudAPI.fetchCurrentUser(token: token)
            async let account = AssetTimeMachineCloudAPI.accountInfo(token: token)
            async let history = AssetTimeMachineCloudAPI.fetchHistory(token: token, limit: 100)
            return try await (user, account, history)
        }
        currentUser = user
        let owner = defaults.object(forKey: localOwnerKey) as? Int
        let knownAccount = defaults.string(forKey: localOwnerAccountKey)
        let accountChanged = knownAccount.map { $0 != account.accountID } ?? account.hasDeletionHistory
        if defaults.bool(forKey: accountResetRequiredKey), let owner, owner != currentUser?.id {
            throw NSError(domain: "CloudSyncOwner", code: 409,
                          userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("请重新登录后确认本机记录")])
        }
        if defaults.bool(forKey: accountResetRequiredKey)
            || (owner != nil && owner == currentUser?.id
                && accountChanged) {
            try resetAccountSyncMetadata()
        }
        currentAccountID = account.accountID
        if defaults.object(forKey: localOwnerKey) as? Int != currentUser?.id {
            lastSyncAt = nil
            lastVerifiedBackupID = nil
        }
        backups = history
        if localRestoreNeedsCloudConfirmation { requiresLocalOwnershipConfirmation = true }
    }

    private func loadHistory() async throws {
        backups = try await withTokenRefresh { token in
            try await AssetTimeMachineCloudAPI.fetchHistory(token: token, limit: 100)
        }
        // Listing backups is not proof that this device has applied their contents.
    }

    private func loadHistoryAfterSync() async throws {
        do { try await loadHistory() }
        catch {
            // The data revision is already committed. A temporary list failure is
            // retried by the next active check, not an undo of that acknowledgment.
            guard Self.isTransientFailure(error) else { throw error }
        }
    }

    private func fetchLatestBackupIfAvailable() async throws -> AssetTimeMachineCloudLatestBackup? {
        syncPhase = .downloading
        do {
            return try await withTokenRefresh { token in
                try await AssetTimeMachineCloudAPI.downloadLatest(token: token)
            }
        } catch {
            if (error as NSError).code == 404 {
                return nil
            }
            throw error
        }
    }

    private func withTokenRefresh<T>(_ operation: (String) async throws -> T) async throws -> T {
        guard let token = accessToken, !token.isEmpty else {
            throw NSError(domain: "AssetTimeMachineCloudStore", code: 401, userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("缺少登录 token")])
        }

        do {
            return try await operation(token)
        } catch {
            guard (error as NSError).code == 401 else {
                throw error
            }
            guard let refreshToken, !refreshToken.isEmpty else {
                throw error
            }

            do {
                let refreshedToken = try await AssetTimeMachineCloudAPI.refresh(refreshToken: refreshToken)
                try saveTokens(refreshedToken, fallbackRefreshToken: refreshToken)
                return try await operation(refreshedToken.accessToken)
            } catch {
                if (error as NSError).code == 401 {
                    clearTokens()
                    currentUser = nil
                    backups = []
                }
                throw error
            }
        }
    }

    private func recoverSharedHistoryIfNeeded(local: ExportPayload, latest: AssetTimeMachineCloudLatestBackup?) async throws {
        let owner = defaults.object(forKey: localOwnerKey) as? Int
        guard let userID = currentUser?.id, owner.map({ $0 == userID }) ?? true,
              let accountID = currentAccountID, !defaults.bool(forKey: accountResetRequiredKey),
              defaults.string(forKey: localOwnerAccountKey).map({ $0 == accountID }) ?? true,
              let latest else { return }
        if owner != nil, FileManager.default.fileExists(atPath: try baselineURL(userID: userID).path) { return }
        let recovered = try await recoverLegacySyncBaseline(latest: latest, includeLocalBaseline: false)
        let remote = latest.payload
        let baseline = try await SyncPayloadWork.detached {
            guard let base = recovered ?? SyncMergeService.sharedHistoryBaseline(local: local, remote: remote) else { return nil as ExportPayload? }
            // Prove that the recovered ancestor permits a safe merge before binding
            // ownership. An unrelated account or a genuine unproven edit still stops.
            _ = try SyncMergeService.reconciledPayload(local: local, remote: remote, baseline: base)
            return base
        }
        guard let baseline else { return }
        try await saveLocalSafetyBackup(local)
        try await persistSyncBaseline(baseline)
        requiresLocalOwnershipConfirmation = false
    }

    private func validateLocalOwner(local: ExportPayload, remote: ExportPayload?) throws {
        guard currentAccountID != nil, !defaults.bool(forKey: accountResetRequiredKey) else {
            throw NSError(domain: "CloudSyncOwner", code: 409,
                          userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("请重新登录后确认本机记录")])
        }
        requiresLocalOwnershipConfirmation = false
        guard let userID = currentUser?.id else { throw URLError(.userAuthenticationRequired) }
        if let owner = defaults.object(forKey: localOwnerKey) as? Int {
            guard owner == userID || SyncMergeService.isEmptyUserData(local) || SyncMergeService.looksLikeSeedOnly(local) else {
                throw NSError(domain: "CloudSyncOwner", code: 409,
                    userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("本机记录属于另一个账户，已暂停上传和合并。请先导出本机记录，再选择恢复当前账户的云端数据。")])
            }
        } else if !SyncMergeService.isEmptyUserData(local), !SyncMergeService.looksLikeSeedOnly(local),
                  remote.map({ SyncMergeService.isSameContent(local, $0) }) != true {
            requiresLocalOwnershipConfirmation = true
            throw NSError(domain: "CloudSyncOwner", code: 409,
                userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("本机记录尚未关联当前账户，已暂停同步。请确认账户后合并。")])
        }
    }

    /// Explicit association also repairs legacy installs without an owner or merge baseline.
    /// Recover only an exact fingerprint match from this account's history; otherwise
    /// an empty baseline permits additions and identical records, never divergent edits.
    func authorizeLocalDataForCurrentAccount(from context: ModelContext) async {
        guard !AppPreviewSession.isActive || isolatedTest,
              requiresLocalOwnershipConfirmation, defaults.object(forKey: localOwnerKey) == nil,
              !context.hasChanges, !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else { return }
        let result = await perform { [self] in
            let latest = try await self.fetchLatestBackupIfAvailable()
            let payload = try await ImportExportService.exportPayloadCooperatively(from: context)
            let recovered = try await self.recoverLegacySyncBaseline(latest: latest)
            let base = recovered ?? ExportPayload(exportedAt: .now, categories: [], items: [], snapshots: [], deletions: [])
            // Check before binding the account or changing either copy. The normal sync
            // fetches the head again and retains its revision checks and upload CAS.
            if let latest {
                do {
                    _ = try await SyncPayloadWork.detached {
                        try SyncMergeService.reconciledPayload(local: payload.payload, remote: latest.payload, baseline: base)
                    }
                } catch SyncMergeService.Conflict.divergentEdits {
                    if case .none = recovered {
                        throw NSError(domain: "CloudSyncBaseline", code: 409,
                            userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("未找到匹配的历史版本，无法自动合并。请导出本机记录以核对差异。")])
                    }
                    throw SyncMergeService.Conflict.divergentEdits
                }
            }
            guard !context.hasChanges, !ModelContextMutationBarrier.shared.hasPendingWrites,
                  !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
                  ModelStoreRevisionClock.shared.currentRevision() == payload.storeRevision else { throw CancellationError() }
            try await self.saveLocalSafetyBackup(payload.payload)
            try await self.persistSyncBaseline(base)
            self.requiresLocalOwnershipConfirmation = false
            self.localRestoreNeedsCloudConfirmation = false
            self.defaults.removeObject(forKey: self.localRestorePendingKey)
        }
        if result == .completed { scheduleAutoSync(from: context, quietly: false, delayNanoseconds: 0) }
    }

    private func recoverLegacySyncBaseline(latest: AssetTimeMachineCloudLatestBackup?, includeLocalBaseline: Bool = true) async throws -> ExportPayload? {
        if includeLocalBaseline, let existing = try await loadSyncBaseline() { return existing }
        guard let signature = defaults.string(forKey: lastUploadedSignatureKey), signature.count == 64,
              signature.allSatisfy({ $0.isHexDigit }) else { return nil }
        if let latest, try await Self.payloadFingerprint(for: latest.payload).signature == signature { return latest.payload }
        let history = try await withTokenRefresh { token in
            try await AssetTimeMachineCloudAPI.fetchHistory(token: token, limit: 20)
        }
        let deadline = Date.now.addingTimeInterval(45)
        for backup in history where backup.id != latest?.id {
            guard Date.now < deadline else { break }
            guard let url = backup.storageURL else { continue }
            do {
                let payload = try await AssetTimeMachineCloudAPI.downloadBackupPayload(at: url)
                if try await Self.payloadFingerprint(for: payload).signature == signature { return payload }
            } catch {
                // Missing historical objects do not justify guessing a merge base.
                guard (error as NSError).code == 404 || (error as NSError).code == 403 else { throw error }
            }
        }
        return nil
    }

    func exportLocalRecords(from context: ModelContext) async throws -> Data {
        guard !context.hasChanges, !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else {
            throw NSError(domain: "CloudExport", code: 409,
                userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("请先完成当前编辑")])
        }
        let payload = try await ImportExportService.exportPayloadCooperatively(from: context).payload
        return try await SyncPayloadWork.detached {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(payload)
        }
    }

    var hasBeforeJSONImportBackup: Bool {
        defaults.string(forKey: beforeJSONImportKey).map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    func exportBeforeJSONImportBackup() async throws -> Data {
        guard let path = defaults.string(forKey: beforeJSONImportKey) else { throw CocoaError(.fileNoSuchFile) }
        return try await SyncPayloadWork.detached { try Data(contentsOf: URL(fileURLWithPath: path)) }
    }

    /// This explicit local recovery never uploads the imported file or silently
    /// reconciles it with a different cloud version. Association is a later user choice.
    func restoreLocalRecords(_ payload: ExportPayload, into context: ModelContext) async throws {
        guard !AppPreviewSession.isActive || isolatedTest,
              !isWorking, !context.hasChanges,
              !ModelContextMutationBarrier.shared.hasPendingWrites,
              !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else {
            throw NSError(domain: "LocalJSONImport", code: 409,
                userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("请先完成当前编辑，再恢复记录")])
        }
        isWorking = true
        syncPhase = .applying
        defer { isWorking = false; syncPhase = .idle }
        let payload = try await ImportExportService.prepareLocalImportPayload(payload)
        autoSyncGeneration &+= 1
        pendingAutoSyncCoordinatorTask?.cancel()
        pendingAutoSyncCoordinatorTask = nil
        autoSyncCoordinatorTaskID = nil
        hasPendingSync = false

        let before = try await ImportExportService.exportPayloadCooperatively(from: context)
        let backup = try await saveLocalSafetyBackup(before.payload)
        defaults.set(backup.path, forKey: beforeJSONImportKey)
        let owner = defaults.object(forKey: localOwnerKey) as? Int
        let needsConfirmation = hasToken || owner != nil || localRestoreNeedsCloudConfirmation
        if needsConfirmation {
            // Persist before the replacement, so suspension/restart cannot upload an
            // imported historical version before the user has checked the account.
            defaults.set(true, forKey: localRestorePendingKey)
            localRestoreNeedsCloudConfirmation = true
        }
        let owners = Set([owner, currentUser?.id].compactMap { $0 })
        for owner in owners {
            for file in [try baselineURL(userID: owner), try pendingUploadURL(userID: owner)]
                where FileManager.default.fileExists(atPath: file.path) {
                let archived = backup.deletingPathExtension().appendingPathExtension(file.lastPathComponent)
                try FileManager.default.copyItem(at: file, to: archived)
                try FileManager.default.removeItem(at: file)
            }
        }
        try resetAccountSyncMetadata()
        requiresLocalOwnershipConfirmation = needsConfirmation
        entryConflictReview = nil
        _ = try await applyCloudPayload(payload, into: context, expectedStoreRevision: before.storeRevision)
        errorMessage = nil
        statusMessage = AppLocalization.string("JSON 记录已恢复")
    }

    @discardableResult
    private func saveLocalSafetyBackup(_ payload: ExportPayload) async throws -> URL {
        let owner = defaults.object(forKey: localOwnerKey) as? Int ?? 0
        let parent = try baselineURL(userID: owner).deletingLastPathComponent().appendingPathComponent("SafetyBackups")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = parent.appendingPathComponent("before-restore-" + UUID().uuidString + ".json")
        try await SyncPayloadWork.detached {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            guard try Data(contentsOf: file) == data else { throw CocoaError(.fileReadCorruptFile) }
        }
        defaults.set(file.path, forKey: "assettimemachine.cloud.lastLocalSafetyBackup")
        return file
    }

    private func baselineURL(userID: Int) throws -> URL {
        let parent: URL
        if isolatedTest {
            parent = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncProbe-" + String(ObjectIdentifier(defaults).hashValue))
        } else {
            parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CloudSyncBaselines")
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return parent.appendingPathComponent("account-\(userID).json")
    }

    private func loadSyncBaseline() async throws -> ExportPayload? {
        guard let userID = currentUser?.id else { return nil }
        let file = try baselineURL(userID: userID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try await SyncPayloadWork.detached {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ExportPayload.self, from: Data(contentsOf: file))
        }
    }

    /// Old clients sent only deletion UUIDs. Recover their logical identity from
    /// this account's authenticated history instead of resurrecting an offline alias.
    private func resolveDeletionHistory(_ latest: AssetTimeMachineCloudLatestBackup?,
        local: ExportPayload, baseline: ExportPayload?) async throws -> AssetTimeMachineCloudLatestBackup? {
        guard let latest else { return nil }
        var contexts = [local] + (baseline.map { [$0] } ?? [])
        var resolved = SyncMergeService.enrichingDeletionIdentities(in: latest.payload, using: contexts)
        var unresolved = SyncMergeService.unresolvedDeletionIdentities(in: resolved, knownBy: baseline.map { [$0] } ?? [])
        if !unresolved.isEmpty {
            let history = try await withTokenRefresh { token in
                try await AssetTimeMachineCloudAPI.fetchHistory(token: token, limit: 20)
            }
            for backup in history where backup.id != latest.id {
                guard let url = backup.storageURL else { continue }
                do {
                    contexts.append(try await AssetTimeMachineCloudAPI.downloadBackupPayload(at: url))
                    resolved = SyncMergeService.enrichingDeletionIdentities(in: resolved, using: contexts)
                    unresolved = SyncMergeService.unresolvedDeletionIdentities(in: resolved, knownBy: baseline.map { [$0] } ?? [])
                    if unresolved.isEmpty { break }
                } catch {
                    guard (error as NSError).code == 403 || (error as NSError).code == 404 else { throw error }
                }
            }
        }
        guard unresolved.isEmpty else {
            throw NSError(domain: "CloudSyncDeletionHistory", code: 409,
                userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("暂时无法核对删除记录，已保留本机数据")])
        }
        return .init(id: latest.id, uploadedAt: latest.uploadedAt, payload: resolved, note: latest.note)
    }

    private func pendingUploadURL(userID: Int) throws -> URL {
        try baselineURL(userID: userID).deletingLastPathComponent()
            .appendingPathComponent("account-\(userID)-pending-upload.json")
    }

    private func persistPendingUpload(_ payload: ExportPayload, signature: String,
        baseBackupID: Int?, baseline: ExportPayload?, confirmation: PendingEntryConfirmation? = nil) async throws {
        guard let userID = currentUser?.id else { throw URLError(.userAuthenticationRequired) }
        let file = try pendingUploadURL(userID: userID)
        let baselineSignature: String?
        if let baseline { baselineSignature = try await Self.payloadFingerprint(for: baseline).signature }
        else { baselineSignature = nil }
        let pending = PendingCloudUpload(userID: userID, baseBackupID: baseBackupID,
            baselineSignature: baselineSignature, signature: signature, payload: payload, confirmation: confirmation)
        try await SyncPayloadWork.detached {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(pending).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func clearPendingUpload() throws {
        guard let userID = currentUser?.id else { return }
        let file = try pendingUploadURL(userID: userID)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    /// Recover only a proven accepted candidate. A timeout does not say whether
    /// the server committed it; timestamps or the latest device clock cannot decide.
    private func recoverPendingUpload(latest: AssetTimeMachineCloudLatestBackup?) async throws {
        guard let pending = try await loadPendingUpload() else { return }
        let baseline = try await loadSyncBaseline()
        let currentSignature: String?
        if let baseline { currentSignature = try await Self.payloadFingerprint(for: baseline).signature }
        else { currentSignature = nil }
        if currentSignature == pending.signature || currentSignature != pending.baselineSignature {
            try clearPendingUpload()
            return
        }
        if let latest, try await Self.payloadFingerprint(for: latest.payload).signature == pending.signature {
            try await persistSyncBaseline(latest.payload)
            try clearPendingUpload()
            return
        }
        if latest?.id == pending.baseBackupID {
            if pending.confirmation == nil { try clearPendingUpload() }
            return
        }
        let history = try await withTokenRefresh { token in
            try await AssetTimeMachineCloudAPI.fetchHistory(token: token, limit: 20)
        }
        for backup in history where backup.id != latest?.id && backup.id > (pending.baseBackupID ?? 0) {
            guard let url = backup.storageURL else { continue }
            do {
                let payload = try await AssetTimeMachineCloudAPI.downloadBackupPayload(at: url)
                if try await Self.payloadFingerprint(for: payload).signature == pending.signature {
                    try await persistSyncBaseline(payload)
                    try clearPendingUpload()
                    return
                }
            } catch {
                guard (error as NSError).code == 403 || (error as NSError).code == 404 else { throw error }
            }
        }
    }

    private func loadPendingUpload() async throws -> PendingCloudUpload? {
        guard let userID = currentUser?.id else { return nil }
        let file = try pendingUploadURL(userID: userID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let pending = try await SyncPayloadWork.detached {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PendingCloudUpload.self, from: Data(contentsOf: file))
        }
        guard pending.userID == userID,
              try await Self.payloadFingerprint(for: pending.payload).signature == pending.signature else {
            throw URLError(.cannotDecodeContentData)
        }
        return pending
    }

    /// Available only to the isolated preview harness; tokens and defaults are supplied by the test.
    func runIsolatedSync(from context: ModelContext) async -> Bool {
        precondition(isolatedTest && AppPreviewSession.isActive)
        if currentAccountID == nil, currentUser != nil {
            do { currentAccountID = try await accountDeletionInfo().accountID }
            catch { errorMessage = error.localizedDescription; return true }
        }
        return await autoSyncIfNeeded(from: context, quietly: false)
    }

    @discardableResult
    func confirmEntryConflicts(reviewID: UUID, choices: [String: SyncMergeService.EntryChoice],
        from context: ModelContext) async -> Bool {
        guard !AppPreviewSession.isActive || isolatedTest,
              !isWorking, let review = entryConflictReview, review.id == reviewID,
              currentUser?.id == review.userID, hasToken,
              !context.hasChanges, !ModelContextMutationBarrier.shared.hasPendingWrites,
              !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else { return false }
        guard Set(choices.keys) == Set(review.conflicts.map(\.id)) else { return false }
        _ = await autoSyncIfNeeded(from: context, quietly: false,
            confirmation: EntryConfirmationRequest(review: review, choices: choices))
        if let pending = try? await loadPendingUpload(), let saved = pending.confirmation,
           pending.baseBackupID == review.backupID, pending.baselineSignature == review.baselineSignature,
           saved.originalLocalUserSignature == review.localUserSignature,
           saved.remoteSignature == review.remoteSignature, saved.choices == choices {
            // A transient upload failure must not ask for the same decision again.
            // The private journal binds retry to this exact server head and intent.
            entryConflictReview = nil
            statusMessage = AppLocalization.string("选择已保存，等待同步")
            scheduleAutoSync(from: context, quietly: false, delayNanoseconds: 2_000_000_000)
            return true
        }
        if entryConflictReview == nil, errorMessage != nil {
            scheduleAutoSync(from: context, quietly: false, delayNanoseconds: 0)
        }
        return entryConflictReview == nil && errorMessage == nil
    }

    private func saveReviewSafetyBackups(local: ExportPayload, remote: ExportPayload, id: UUID) async throws {
        guard let owner = currentUser?.id else { throw URLError(.userAuthenticationRequired) }
        let directory = try baselineURL(userID: owner).deletingLastPathComponent()
            .appendingPathComponent("SafetyBackups/review-" + id.uuidString)
        try await SyncPayloadWork.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            for (name, payload) in [("local.json", local), ("cloud.json", remote)] {
                let file = directory.appendingPathComponent(name)
                try encoder.encode(payload).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        defaults.set(directory.appendingPathComponent("local.json").path, forKey: "assettimemachine.cloud.lastLocalSafetyBackup")
    }

    private func persistSyncBaseline(_ payload: ExportPayload) async throws {
        // Any explicit full restore/reconciliation supersedes a previous delta cursor.
        defaults.set(UUID().uuidString, forKey: deltaResetKey)
        guard let userID = currentUser?.id else { throw URLError(.userAuthenticationRequired) }
        let file = try baselineURL(userID: userID)
        try await SyncPayloadWork.detached {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(payload).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        defaults.set(userID, forKey: localOwnerKey)
        if let currentAccountID { defaults.set(currentAccountID, forKey: localOwnerAccountKey) }
    }

    private func rememberSync(signature: String, at date: Date, payload: ExportPayload) async throws {
        try await persistSyncBaseline(payload)
        recordSyncMetadata(signature: signature, at: date)
    }

    private func recordSyncMetadata(signature: String, at date: Date) {
        defaults.set(signature, forKey: lastUploadedSignatureKey)
        defaults.set(date, forKey: lastSyncAtKey)
        // Only persist an acknowledged head; a normalized/unsent revision keeps nil.
        defaults.set(lastVerifiedBackupID, forKey: lastVerifiedBackupIDKey)
        lastSyncAt = date
    }

    private func applyCloudPayload(
        _ payload: ExportPayload,
        into context: ModelContext,
        expectedStoreRevision: UInt64
    ) async throws -> UInt64 {
        syncPhase = .applying
        let exclusiveID = try ModelContextMutationBarrier.shared.beginExclusiveDrain()
        isApplyingLocalData = true
        defer {
            ModelContextMutationBarrier.shared.finishExclusive(exclusiveID)
            isApplyingLocalData = false
        }

        // Publish the editing barrier without unmounting feature views. The mutation
        // begins only after every registered writer has completed; active editor drafts
        // already prevent beginExclusiveDrain from acquiring the store.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        try await ModelContextMutationBarrier.shared.enterExclusive(exclusiveID)

        let previousAuthor = context.author
        context.author = "atm.cloud.legacy"
        defer { context.author = previousAuthor }
        let committedStoreRevision = try await ImportExportService.importPayloadCooperatively(
            payload,
            into: context,
            replaceExisting: true,
            expectedStoreRevision: expectedStoreRevision
        )

        // Refresh value caches after the committed save. The importer retains models
        // with matching IDs; this revision must not become a root-view identity.
        localDataRevision &+= 1
        await Task.yield()
        return committedStoreRevision
    }

    nonisolated private static func payloadFingerprint(for payload: ExportPayload) async throws -> CloudPayloadFingerprint {
        try await SyncPayloadWork.detached {
            let canonicalData = try? SyncMergeService.canonicalData(for: payload)
            return CloudPayloadFingerprint(
                signature: signatureValue(for: payload, canonicalData: canonicalData),
                canonicalData: canonicalData
            )
        }
    }

    nonisolated private static func userSignature(for payload: ExportPayload) async throws -> String {
        try await SyncPayloadWork.detached {
            SHA256.hash(data: try SyncMergeService.userContentData(for: payload)).map { String(format: "%02x", $0) }.joined()
        }
    }

    nonisolated private static func reconcile(
        local: ExportPayload,
        localCanonicalData: Data?,
        remote: ExportPayload,
        baseline: ExportPayload?,
        serverCanonicalData: Data? = nil,
        choices: [String: SyncMergeService.EntryChoice] = [:]
    ) async throws -> CloudPayloadReconciliation {
        try await SyncPayloadWork.detached {
            if SyncMergeService.looksLikeSeedOnly(local), !SyncMergeService.isEmptyUserData(remote) {
                let remoteCanonicalData = try? SyncMergeService.canonicalData(for: remote)
                return .restoreRemote(
                    payload: remote,
                    signature: signatureValue(for: remote, canonicalData: remoteCanonicalData)
                )
            }

            let merged: ExportPayload
            if let baseline {
                let review = try SyncMergeService.reviewedPayload(local: local, remote: remote, baseline: baseline, choices: choices)
                guard let resolved = review.payload else { throw SyncMergeService.EntryConflicts(conflicts: review.conflicts) }
                merged = resolved
            } else if SyncMergeService.isSameContent(local, remote) || SyncMergeService.isEmptyUserData(local) {
                merged = SyncMergeService.mergedPayload(local: local, remote: remote)
            } else {
                throw NSError(domain: "CloudSyncBaseline", code: 409,
                    userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("尚无可靠的同步基准，已暂停合并。请先核对并恢复云端数据，或导出本机记录。")])
            }
            try Task.checkCancellation()
            let mergedCanonicalData = try? SyncMergeService.canonicalData(for: merged)
            try Task.checkCancellation()
            let remoteCanonicalData = serverCanonicalData ?? (try? SyncMergeService.canonicalData(for: remote))
            try Task.checkCancellation()

            return .merge(
                payload: merged,
                needsLocalImport: mergedCanonicalData != localCanonicalData,
                matchesRemote: mergedCanonicalData == remoteCanonicalData,
                signature: signatureValue(for: merged, canonicalData: mergedCanonicalData)
            )
        }
    }

    nonisolated private static func signatureValue(for payload: ExportPayload, canonicalData: Data?) -> String {
        if let canonicalData {
            let digest = SHA256.hash(data: canonicalData)
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        var latestItemUpdate = 0.0
        for item in payload.items {
            latestItemUpdate = max(latestItemUpdate, item.updatedAt.timeIntervalSince1970)
        }

        var latestSnapshotUpdate = 0.0
        var latestEntryUpdate = 0.0
        for snapshot in payload.snapshots {
            latestSnapshotUpdate = max(latestSnapshotUpdate, snapshot.updatedAt.timeIntervalSince1970)
            for entry in snapshot.entries {
                latestEntryUpdate = max(latestEntryUpdate, entry.updatedAt.timeIntervalSince1970)
            }
        }

        return [
            String(payload.categories.count),
            String(payload.items.count),
            String(payload.snapshots.count),
            String(latestItemUpdate),
            String(latestSnapshotUpdate),
            String(latestEntryUpdate)
        ].joined(separator: ":")
    }

    @discardableResult
    private func perform(_ task: @escaping () async throws -> Void) async -> CloudOperationResult {
        guard !isWorking else { return .skippedBusy }
        isWorking = true
        syncPhase = .checking
        errorMessage = nil
        defer { isWorking = false; syncPhase = .idle }

        do {
            try await task()
            return .completed
        } catch {
            guard !Self.isCancellation(error) else {
                return .cancelled
            }
            if (error as NSError).code == 401 {
                clearTokens()
                currentUser = nil
                backups = []
                errorMessage = AppLocalization.string("登录状态已过期，请重新登录")
                statusMessage = nil
                return .failed
            }
            errorMessage = error is SyncMergeService.EntryConflicts
                ? AppLocalization.string("有记录需要确认") : error.localizedDescription
            return Self.isTransientFailure(error) ? .retryableFailure : .failed
        }
    }

    nonisolated private static func isTransientFailure(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                    .callIsActive, .dataNotAllowed, .resourceUnavailable].contains { $0.rawValue == error.code }
        }
        return error.domain == "AssetTimeMachineCloudAPI"
            && (error.code == 408 || error.code == 429 || (500...599).contains(error.code))
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue
    }

    private func friendlyAppleSignInMessage(for error: any Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == ASAuthorizationError.errorDomain,
              let code = ASAuthorizationError.Code(rawValue: nsError.code) else {
            return error.localizedDescription
        }

        if code == .canceled {
            return AppLocalization.string("已取消 Apple 登录")
        }
        if code == .failed {
            return AppLocalization.string("Apple 登录失败，请稍后再试")
        }
        if code == .invalidResponse {
            return AppLocalization.string("Apple 登录返回的数据无效")
        }
        if code == .notHandled {
            return AppLocalization.string("系统未处理此次 Apple 登录请求")
        }
        if code == .unknown {
            return AppLocalization.string("Apple 一键登录当前不可用")
        }
        return error.localizedDescription
    }
}

struct CloudSyncEntryReviewView: View {
    let review: CloudSyncEntryReview
    let busy: Bool
    let cancel: () -> Void
    let confirm: ([String: SyncMergeService.EntryChoice]) async -> Void
    @State private var choices: [String: SyncMergeService.EntryChoice] = [:]

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(review.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(conflict.itemID.flatMap { review.itemNames[$0] } ?? AppLocalization.string("资产"))
                                    .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                Spacer(minLength: 8)
                                Text(conflict.date.formatted(date: .numeric, time: .omitted))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Text(fieldTitle(conflict.field)).font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: 8) {
                                option(.local, conflict: conflict, data: conflict.localValue)
                                option(.remote, conflict: conflict, data: conflict.remoteValue)
                            }
                            Divider()
                        }
                    }
                }
            }
            HStack {
                Button(AppLocalization.string("返回"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(AppLocalization.string("确认并同步")) { Task { await confirm(choices) } }
                    .buttonStyle(.borderedProminent).tint(AssetTheme.gold)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || choices.count != review.conflicts.count)
            }.disabled(busy)
        }
    }

    private func option(_ side: SyncMergeService.EntryChoice, conflict: SyncMergeService.EntryConflict, data: Data) -> some View {
        let selected = choices[conflict.id] == side
        return Button { choices[conflict.id] = side } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(AppLocalization.string(side == .local ? "本机" : "云端"))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                }.font(.system(size: 12))
                Text(displayValue(data, conflict: conflict)).font(.system(size: 14, weight: .medium))
                    .monospacedDigit().lineLimit(conflict.field == .note ? nil : 1).minimumScaleFactor(0.65)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(selected ? AssetTheme.gold.opacity(0.12) : Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? AssetTheme.gold : Color.secondary.opacity(0.2)))
        }.buttonStyle(.plain).disabled(busy)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func fieldTitle(_ field: SyncMergeService.EntryField) -> String {
        switch field {
        case .amount: AppLocalization.string("金额")
        case .quantity: AppLocalization.string("数量")
        case .unitPrice: AppLocalization.string("单价")
        case .note: AppLocalization.string("备注")
        }
    }

    private func displayValue(_ data: Data, conflict: SyncMergeService.EntryConflict) -> String {
        // Formatting must never hide the very difference the user is reviewing.
        let exact = display(conflict.localValue, field: conflict.field) == display(conflict.remoteValue, field: conflict.field)
        return display(data, field: conflict.field, exact: exact)
    }

    private func display(_ data: Data, field: SyncMergeService.EntryField, exact: Bool = false) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), !(value is NSNull) else {
            return AppLocalization.string("未填写")
        }
        if let number = value as? NSNumber {
            if exact {
                return (field == .amount || field == .unitPrice ? "CNY " : "") + number.stringValue
            }
            if field == .amount || field == .unitPrice {
                return number.doubleValue.formatted(.currency(code: "CNY").precision(.fractionLength(2...8)))
            }
            return number.doubleValue.formatted(.number.precision(.fractionLength(0...8)))
        }
        let string = value as? String ?? ""
        return string.isEmpty ? AppLocalization.string("未填写") : string
    }
}

struct CloudAccountDeletionView: View {
    @ObservedObject var store: AssetTimeMachineCloudStore
    let close: () -> Void
    @State private var requirements: CloudAccountDeletionInfo?
    @State private var errorMessage: String?
    @State private var confirmsDeletion = false
    @State private var isDeleting = false
    @State private var identityToken: String?
    @State private var authorizationCode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(AppLocalization.string("账户和云端备份将永久删除。本机记录、网站账户及其他产品数据保留。"))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(AssetTheme.textSecondary)
                    if let error = errorMessage ?? store.errorMessage, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(AssetTheme.negative)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    controls
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .foregroundStyle(AssetTheme.textPrimary)
        #if os(macOS)
        .background(NativePalette.canvas)
        #else
        .background(AssetTheme.background)
        #endif
        .interactiveDismissDisabled(isDeleting)
        .task { await loadRequirements() }
        .alert(AppLocalization.string("永久删除资产时光机账户？"), isPresented: $confirmsDeletion) {
            Button(AppLocalization.string("取消"), role: .cancel) { clearAuthorization() }
            Button(AppLocalization.string("永久删除"), role: .destructive) { Task { await delete() } }
        } message: {
            Text(AppLocalization.string("此操作不可撤销。"))
        }
    }

    private var header: some View {
        HStack {
            Text(AppLocalization.string("删除资产时光机账户")).font(.title2.weight(.semibold))
            Spacer()
            Button(AppLocalization.string("取消"), action: close).disabled(isDeleting)
        }
    }

    @ViewBuilder private var controls: some View {
        if isDeleting {
            ProgressView(AppLocalization.string("正在删除账户")).frame(maxWidth: .infinity)
        } else if let requirements {
            if requirements.requiresAppleAuthorization {
                Text(AppLocalization.string("使用 Apple ID 确认身份后删除")).font(.callout)
                appleConfirmationButton
            } else {
                Button(AppLocalization.string("删除账户"), role: .destructive) { confirmsDeletion = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(AssetTheme.negative)
                    .disabled(store.isWorking)
            }
        } else if errorMessage != nil {
            Button(AppLocalization.string("重试")) { Task { await loadRequirements() } }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private var appleConfirmationButton: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = []
        } onCompletion: { result in
            handleAppleAuthorization(result)
        }
        .frame(height: 44)
        .disabled(store.isWorking)
    }

    private func handleAppleAuthorization(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken,
                  let code = credential.authorizationCode,
                  let tokenString = String(data: token, encoding: .utf8),
                  let codeString = String(data: code, encoding: .utf8) else {
                errorMessage = AppLocalization.string("未获取到 Apple 登录凭证")
                return
            }
            identityToken = tokenString
            authorizationCode = codeString
            errorMessage = nil
            confirmsDeletion = true
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code != .canceled { errorMessage = error.localizedDescription }
        }
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        let deleted = await store.deleteAccount(identityToken: identityToken, authorizationCode: authorizationCode)
        clearAuthorization()
        if deleted { close() }
    }

    private func clearAuthorization() {
        identityToken = nil
        authorizationCode = nil
    }

    private func loadRequirements() async {
        errorMessage = nil
        store.errorMessage = nil
        do { requirements = try await store.accountDeletionInfo() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct CloudBackupRecoveryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @ObservedObject var store: AssetTimeMachineCloudStore
    let recovery: CloudBackupRecovery
    @State private var isRestoring = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(AppLocalization.string("确认恢复")).font(.headline)
                Spacer()
                Button(AppLocalization.string("取消")) { dismiss() }.disabled(isRestoring)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(recovery.backup.uploadedAt.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))
                        .font(.headline)
                    LabeledContent(AppLocalization.string("资产项目"), value: String(recovery.payload.items.count))
                    LabeledContent(AppLocalization.string("历史记录"), value: String(recovery.payload.snapshots.count))
                    if let first = recovery.payload.snapshots.map(\.date).min(),
                       let last = recovery.payload.snapshots.map(\.date).max() {
                        Text(first.formatted(.dateTime.year().month().day().locale(locale)) + " – "
                            + last.formatted(.dateTime.year().month().day().locale(locale)))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(AppLocalization.string("将替换本机资产记录，并保留恢复前的 JSON 备份。"))
                    Text(AppLocalization.string("云端记录不会被替换；自动同步将暂停，待你核对后重新关联。"))
                    if let error { Text(error).foregroundStyle(AssetTheme.negative) }
                    Button(role: .destructive) {
                        isRestoring = true; error = nil
                        Task {
                            defer { isRestoring = false }
                            do {
                                try await store.restoreBackup(recovery, into: context)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            if isRestoring { ProgressView() }
                            Text(AppLocalization.string("恢复这些记录"))
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRestoring || store.isWorking)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .interactiveDismissDisabled(isRestoring)
        #if os(macOS)
        .frame(width: 448, height: 440)
        #endif
    }
}

#if !os(macOS)
private struct AssetTimeMachineCloudStatusSymbol: View {
    let state: AssetTimeMachineCloudIndicatorState
    let size: CGFloat

    var body: some View {
        ZStack {
            Image(systemName: state == .checking ? "icloud" : state.cloudSymbolName)
                .font(.system(size: size, weight: .semibold))

            if state == .checking {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(state.symbolColor.opacity(0.85))
                    .symbolEffect(.rotate, options: .repeat(.continuous))
            }
        }
        .foregroundStyle(state.symbolColor)
    }
}

struct CloudRecordsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct AssetTimeMachineCloudPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: AssetTimeMachineCloudStore
    @State private var exportDocument: CloudRecordsDocument?
    @State private var showsExport = false
    @State private var isExporting = false
    @State private var recovery: CloudBackupRecovery?
    @State private var showOwnershipConfirm = false
    @State private var showsEntryReview = false
    @State private var showsPasswordLogin = false

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            if showsEntryReview, let review = store.entryConflictReview {
                CloudSyncEntryReviewView(review: review, busy: store.isWorking,
                    cancel: { showsEntryReview = false }) { choices in
                    if await store.confirmEntryConflicts(reviewID: review.id, choices: choices, from: modelContext) {
                        showsEntryReview = false
                    }
                }.id(review.id).padding(20)
            } else { ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: cloudContentSpacing) {
                    statusHero
                    mainCard
                }
                .frame(maxWidth: cloudContentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, cloudHorizontalPadding)
                .padding(.top, cloudTopPadding)
                .padding(.bottom, cloudBottomPadding)
            } }
        }
        .navigationTitle(AppLocalization.string(showsEntryReview ? "同步差异" : "云同步"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(AppLocalization.string("完成")) {
                    if showsEntryReview { showsEntryReview = false } else { dismiss() }
                }
            }
        }
        .task {
            await store.refreshIfNeeded(from: modelContext)
        }
        .onChange(of: store.entryConflictReview?.id) { _, id in
            if id == nil { showsEntryReview = false }
        }
        .sheet(isPresented: $showsPasswordLogin) {
            VStack(alignment: .leading, spacing: 16) {
                Text(AppLocalization.string("使用已有账号密码登录"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                CloudPasswordLoginForm(cloudStore: store) {
                    showsPasswordLogin = false
                } onBack: {
                    showsPasswordLogin = false
                }
            }
            .padding(20)
            #if targetEnvironment(macCatalyst)
            .frame(width: 390, height: 205)
            .background(AssetTheme.background)
            .presentationSizing(.fitted)
            #else
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
            #endif
        }
        .fileExporter(isPresented: $showsExport, document: exportDocument, contentType: .json,
                      defaultFilename: "AssetTimeMachine-Local") { result in
            if case let .failure(error) = result, (error as NSError).code != NSUserCancelledError {
                store.errorMessage = error.localizedDescription
            }
        }
        .alert(AppLocalization.format("确认关联至 %@？", store.currentUser?.displayName ?? "—"), isPresented: $showOwnershipConfirm) {
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确认并同步")) { Task { await store.authorizeLocalDataForCurrentAccount(from: modelContext) } }
        } message: { Text(AppLocalization.string("确认本机记录属于当前账户？合并前会保留备份；冲突时暂停，不覆盖两端记录。")) }
        .sheet(item: $recovery) { candidate in
            CloudBackupRecoveryView(store: store, recovery: candidate)
        }
    }

    private var cloudContentSpacing: CGFloat {
        #if targetEnvironment(macCatalyst)
        16
        #else
        20
        #endif
    }

    private var cloudContentWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        430
        #else
        .infinity
        #endif
    }

    private var cloudHorizontalPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        18
        #else
        20
        #endif
    }

    private var cloudTopPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        14
        #else
        20
        #endif
    }

    private var cloudBottomPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        14
        #else
        TabScrollLayout.sheetBottomPadding
        #endif
    }

    private var statusHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(AssetTheme.surfaceRaised.opacity(0.96))
                        .frame(width: cloudHeroSize, height: cloudHeroSize)
                        .overlay(
                            Circle()
                                .stroke(AssetTheme.border.opacity(0.9), lineWidth: 1)
                        )

                    AssetTimeMachineCloudStatusSymbol(state: store.indicatorState, size: 18)
                        .frame(width: 24, height: 24)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(heroTitle)
                        .font(AppTypography.blockTitle)
                        .foregroundStyle(AssetTheme.textPrimary)

                    if let heroSubtitle, !heroSubtitle.isEmpty {
                        Text(heroSubtitle)
                            .font(AppTypography.meta)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }

                Spacer(minLength: 10)
            }

            if let statusNotice {
                Label(statusNotice.text, systemImage: statusNotice.systemImage)
                    .font(AppTypography.meta)
                    .foregroundStyle(statusNotice.color)
            }
            if store.errorMessage?.isEmpty == false, store.hasToken {
                Button(AppLocalization.string("重试同步")) { Task { await store.retrySync(from: modelContext) } }
                    .disabled(store.isWorking)
            }
        }
    }

    private var cloudHeroSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        38
        #else
        48
        #endif
    }

    private var statusNotice: (text: String, systemImage: String, color: Color)? {
        if let errorMessage = store.errorMessage, !errorMessage.isEmpty {
            return (errorMessage, "exclamationmark.triangle.fill", AssetTheme.negative)
        }
        if let statusMessage = store.statusMessage,
           !statusMessage.isEmpty,
           !statusMessage.contains(AppLocalization.string("同步")),
           !statusMessage.contains(AppLocalization.string("登录成功")) {
            return (statusMessage, "checkmark.circle.fill", AssetTheme.positive)
        }
        return nil
    }

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            if store.currentUser != nil {
                loggedInSection
            } else if store.isSessionPending {
                sessionLoadingSection
            } else {
                appleLoginSection
            }
        }
    }

    private var appleLoginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS) && ATM_DIRECT_DISTRIBUTION
            NativeWebLoginButton(cloud: store)
                .frame(height: cloudLoginButtonHeight)
            #else
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task {
                    await store.handleAppleSignIn(result, from: modelContext)
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: cloudLoginButtonHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .disabled(store.isWorking || AppPreviewSession.isActive)
            #endif

            Button(AppLocalization.string("使用已有账号密码登录")) {
                store.errorMessage = nil
                showsPasswordLogin = true
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AssetTheme.goldSoft)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    private var cloudLoginButtonHeight: CGFloat {
        #if targetEnvironment(macCatalyst)
        42
        #else
        52
        #endif
    }

    private var sessionLoadingSection: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(AssetTheme.gold)
            Text(AppLocalization.string("正在恢复云同步状态…"))
                .font(AppTypography.body)
                .foregroundStyle(AssetTheme.textSecondary)
        }
    }

    private var loggedInSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.entryConflictReview != nil {
                Button(AppLocalization.string("查看差异")) { showsEntryReview = true }
                    .buttonStyle(ATMActionButtonStyle())
                    .disabled(store.isWorking || isExporting)
            }
            if store.requiresLocalOwnershipConfirmation {
                Button(AppLocalization.string("关联并同步本机记录")) {
                    showOwnershipConfirm = true
                }
                .buttonStyle(ATMActionButtonStyle())
                .disabled(store.isWorking || isExporting)
            }

            HStack {
                Text(AppLocalization.string("最近备份"))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 8)

                Button {
                    Task {
                        await store.refreshBackupHistory()
                    }
                } label: {
                    Label(AppLocalization.string("刷新"), systemImage: "arrow.clockwise")
                        .font(AppTypography.meta)
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.isWorking || isExporting)
            }

            if store.backups.isEmpty {
                Text(AppLocalization.string("暂无云端备份"))
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.backups.enumerated()), id: \.element.id) { index, backup in
                        Button { previewBackup(backup) } label: { cloudBackupRow(backup) }
                            .buttonStyle(.plain)
                            .disabled(store.isWorking || isExporting)

                        if index < store.backups.count - 1 {
                            Rectangle()
                                .fill(AssetTheme.border.opacity(0.32))
                                .frame(height: 1)
                                .padding(.leading, 2)
                        }
                    }
                }

            }

            VStack(spacing: 10) {
                Button {
                    isExporting = true
                    Task {
                        defer { isExporting = false }
                        do {
                            exportDocument = CloudRecordsDocument(data: try await store.exportLocalRecords(from: modelContext))
                            showsExport = true
                        } catch { store.errorMessage = error.localizedDescription }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isExporting { ProgressView().tint(AssetTheme.textPrimary) }
                        Label(AppLocalization.string("导出本机记录"), systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(ATMActionButtonStyle(prominence: .secondary))
                .disabled(store.isWorking || isExporting)

                if !store.backups.isEmpty {
                    Button { if let latest = store.backups.first(where: { $0.isLatest == 1 }) { previewBackup(latest) } } label: {
                        Label(AppLocalization.string("恢复最近一次备份"), systemImage: "arrow.clockwise.icloud")
                    }
                    .buttonStyle(ATMActionButtonStyle(prominence: .secondary))
                    .disabled(store.isWorking || isExporting)
                }
            }
        }
    }

    private func cloudBackupRow(_ backup: AssetTimeMachineCloudBackup) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(AssetTheme.surfaceRaised.opacity(0.85))
                    .frame(width: 30, height: 30)

                Image(systemName: backup.isLatest == 1 ? "icloud.fill" : "clock.arrow.circlepath")
                    .font(AppTypography.microValue)
                    .foregroundStyle(backup.isLatest == 1 ? AssetTheme.gold : AssetTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(backup.uploadedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textPrimary)

                Text(backupFileSizeLabel(for: backup))
                    .font(AppTypography.caption)
                    .foregroundStyle(AssetTheme.textSecondary)
            }

            Spacer(minLength: 8)

            if backup.isLatest == 1 {
                Text(AppLocalization.string("最新"))
                    .font(AppTypography.chartCaptionStrong)
                    .foregroundStyle(AssetTheme.goldSoft)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AssetTheme.gold.opacity(0.12), in: Capsule())
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func backupFileSizeLabel(for backup: AssetTimeMachineCloudBackup) -> String {
        guard let fileSize = backup.fileSize else {
            return AppLocalization.string("未知大小")
        }
        return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    private var heroTitle: String {
        store.indicatorState == .idle ? AppLocalization.string("启用云同步") : store.indicatorLabel
    }

    private func previewBackup(_ backup: AssetTimeMachineCloudBackup) {
        Task {
            do { recovery = try await store.prepareBackupRecovery(backup) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    private var heroSubtitle: String? {
        switch store.indicatorState {
        case .idle:
            return nil
        case .checking:
            return nil
        case .healthy:
            return store.lastSyncAt.map { AppLocalization.format("最近同步 %@", $0.formatted(date: .abbreviated, time: .shortened)) }
        case .warning:
            if store.currentUser != nil && store.backups.isEmpty {
                return AppLocalization.string("首次同步尚未完成")
            }
            return nil
        }
    }
}

#endif
