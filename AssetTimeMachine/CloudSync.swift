import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import SwiftData
import SwiftUI

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

nonisolated struct AssetTimeMachineCloudBackup: Codable, Identifiable, Sendable {
    let id: Int
    let fileName: String?
    let fileSize: Int?
    let uploadedAt: Date
    let lastDownloadedAt: Date?
    let isLatest: Int
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case fileSize = "file_size"
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

enum AssetTimeMachineCloudAPI {
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
    private static var requestSession: URLSession { isolatedSession ?? .shared }

    static let baseURL = RemoteMarketClient.baseURL

    fileprivate static func login(username: String, password: String) async throws -> AssetTimeMachineCloudToken {
        let response: AssetTimeMachineCloudToken = try await request(
            path: "/api/v1/auth/login",
            method: "POST",
            body: AssetTimeMachineCloudLoginRequest(username: username, password: password)
        )
        return response
    }

    fileprivate static func loginWithApple(identityToken: String, authorizationCode: String?, userName: String?, userEmail: String?) async throws -> AssetTimeMachineCloudToken {
        let response: AssetTimeMachineCloudToken = try await request(
            path: "/api/v1/auth/apple/login",
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

    static func fetchHistory(token: String, limit: Int = 10) async throws -> [AssetTimeMachineCloudBackup] {
        try await request(path: "/api/v1/asset-time-machine/cloud/history?limit=\(limit)", token: token)
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
                userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : AppLocalization.string("云同步请求失败")]
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

private enum CloudOperationResult {
    case completed
    case skippedBusy
    case cancelled
    case failed
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
    @Published var currentUser: AssetTimeMachineCloudUser?
    @Published var backups: [AssetTimeMachineCloudBackup] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var lastSyncAt: Date?
    @Published private var hasPendingSync = false
    @Published private(set) var requiresLocalOwnershipConfirmation = false
    @Published private(set) var isApplyingLocalData = false
    @Published private(set) var localDataRevision = 0

    private let tokenKey = "assettimemachine.cloud.accessToken"
    private let refreshTokenKey = "assettimemachine.cloud.refreshToken"
    private let lastUploadedSignatureKey = "assettimemachine.cloud.lastUploadedSignature"
    private let lastSyncAtKey = "assettimemachine.cloud.lastSyncAt"
    private let defaults: UserDefaults
    private let localOwnerKey = "assettimemachine.cloud.localOwnerUserID"
    private let isolatedTest: Bool
    private let tokenStore: CloudTokenStore
    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var hasLoadedInitialState = false
    private var lastAutoSyncAttemptSignature: String?
    private var pendingAutoSyncCoordinatorTask: Task<Void, Never>?
    private var autoSyncCoordinatorTaskID: UUID?
    private var autoSyncGeneration = 0
    private var autoSyncRequestedDelayNanoseconds: UInt64 = 0

    init(tokenStore: CloudTokenStore? = nil, defaults: UserDefaults = .standard, isolatedTest: Bool = false) {
        precondition(!isolatedTest || (AppPreviewSession.isActive && tokenStore != nil
            && defaults !== UserDefaults.standard && AssetTimeMachineCloudAPI.hasIsolatedTransport
            && ProcessInfo.processInfo.arguments.contains("-macCloudSyncProbe")))
        self.defaults = defaults
        self.isolatedTest = isolatedTest
        self.tokenStore = tokenStore ?? KeychainTokenStore.shared
        guard !AppPreviewSession.isActive || isolatedTest else { return }
        lastSyncAt = defaults.object(forKey: lastSyncAtKey) as? Date
        migrateLegacyTokensIfNeeded()
        cachedAccessToken = self.tokenStore.loadAccessToken()
        cachedRefreshToken = self.tokenStore.loadRefreshToken()
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
        if (errorMessage?.isEmpty == false) {
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
        let shouldAttemptRefresh = !hasLoadedInitialState || (hasToken && currentUser == nil && !isWorking)
        guard shouldAttemptRefresh else {
            if currentUser != nil {
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

    func login(username: String, password: String) async {
        guard !AppPreviewSession.isActive || isolatedTest else { return }
        await perform { [self] in
            let token = try await AssetTimeMachineCloudAPI.login(username: username, password: password)
            try self.saveTokens(token)
            try await self.loadSessionData()
            self.statusMessage = AppLocalization.string("登录成功，正在准备云同步")
        }
    }

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
        delayNanoseconds: UInt64 = 6_000_000_000
    ) {
        guard !AppPreviewSession.isActive || isolatedTest,
              !ProcessInfo.processInfo.arguments.contains("-macCloudRecovery"),
              currentUser != nil, hasToken else { return }
        hasPendingSync = true
        autoSyncGeneration &+= 1
        autoSyncRequestedDelayNanoseconds = delayNanoseconds
        guard pendingAutoSyncCoordinatorTask == nil else { return }

        let taskID = UUID()
        autoSyncCoordinatorTaskID = taskID
        pendingAutoSyncCoordinatorTask = Task { [weak self] in
            guard let self else { return }
            var waitingGeneration = self.autoSyncGeneration
            var nextDelayNanoseconds = delayNanoseconds

            while !Task.isCancelled {
                if nextDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: nextDelayNanoseconds)
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled else { break }
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
                    nextDelayNanoseconds = 400_000_000
                    continue
                }

                if processingGeneration == self.autoSyncGeneration {
                    if self.autoSyncCoordinatorTaskID == taskID {
                        self.pendingAutoSyncCoordinatorTask = nil
                        self.autoSyncCoordinatorTaskID = nil
                        self.hasPendingSync = false
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
            }
        }
    }

    @discardableResult
    private func autoSyncIfNeeded(from context: ModelContext, quietly: Bool) async -> Bool {
        guard !AppPreviewSession.isActive || isolatedTest else { return true }
        guard hasToken else { return true }
        guard !context.hasChanges,
              !ModelContextMutationBarrier.shared.hasPendingWrites,
              !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else { return false }

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
                // Unchanged local data says nothing about edits made on another device.
                // Always fetch the cloud head before deciding that synchronization is complete.

                let latestBackup = try await self.fetchLatestBackupIfAvailable()
                let baseBackupID = latestBackup?.id
                try self.validateLocalOwner(local: localPayload, remote: latestBackup?.payload)
                let baseline = try await self.loadSyncBaseline()
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

                if let latestBackup {
                    let reconciliation = try await Self.reconcile(
                        local: localPayload,
                        localCanonicalData: localFingerprint.canonicalData,
                        remote: latestBackup.payload,
                        baseline: baseline
                    )

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
                        try await self.rememberSync(signature: signature, at: latestBackup.uploadedAt, payload: latestBackup.payload)
                        try await self.loadHistory()
                        self.statusMessage = quietly ? AppLocalization.string("已恢复云端最新数据") : AppLocalization.string("已从云端恢复最新资产数据")
                        return

                    case let .merge(mergedPayload, needsLocalImport, matchesRemote, signature):
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
                            completedLocalSignature = signature
                            try await self.rememberSync(signature: signature, at: latestBackup.uploadedAt, payload: latestBackup.payload)
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
                guard shouldUpload else { return }

                let backup: AssetTimeMachineCloudBackup
                do {
                    backup = try await self.withTokenRefresh { token in
                    try await AssetTimeMachineCloudAPI.upload(
                        token: token,
                        payload: payloadToUpload,
                        note: AppLocalization.string("iOS 双向云同步"),
                        baseBackupID: baseBackupID
                    )
                    }
                } catch {
                    if (error as NSError).code == 409, attempt < 2 {
                        cloudConflict = true
                        throw CancellationError()
                    }
                    throw error
                }
                guard !context.hasChanges,
                      !ModelContextMutationBarrier.shared.hasPendingWrites,
                      !ModelContextMutationBarrier.shared.hasBlockingEditorDraft,
                      ModelStoreRevisionClock.shared.currentRevision() == expectedStoreRevision else {
                    wasSupersededByLocalSave = true
                    throw CancellationError()
                }
                try await self.loadHistory()
                try await self.rememberSync(signature: uploadSignature, at: backup.uploadedAt, payload: payloadToUpload)
                completedLocalSignature = uploadSignature
                self.statusMessage = quietly ? AppLocalization.string("双向同步完成") : AppLocalization.format("云端同步完成，时间：%@", backup.uploadedAt.formatted(date: .abbreviated, time: .shortened))
            }

            if syncResult == .completed, let completedLocalSignature {
                lastAutoSyncAttemptSignature = completedLocalSignature
            }
            if syncResult == .skippedBusy {
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
            try await self.loadHistory()
            try await self.rememberSync(signature: fingerprint.signature, at: latest.uploadedAt, payload: latest.payload)
            self.statusMessage = AppLocalization.string("最近一次云端备份已恢复")
        }
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
        clearTokens()
        defaults.removeObject(forKey: lastUploadedSignatureKey)
        defaults.removeObject(forKey: lastSyncAtKey)
        currentUser = nil
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
        currentUser = try await withTokenRefresh { token in
            try await AssetTimeMachineCloudAPI.fetchCurrentUser(token: token)
        }
        if defaults.object(forKey: localOwnerKey) as? Int != currentUser?.id { lastSyncAt = nil }
        try await loadHistory()
    }

    private func loadHistory() async throws {
        backups = try await withTokenRefresh { token in
            try await AssetTimeMachineCloudAPI.fetchHistory(token: token, limit: 8)
        }
        // Listing backups is not proof that this device has applied their contents.
    }

    private func fetchLatestBackupIfAvailable() async throws -> AssetTimeMachineCloudLatestBackup? {
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

    private func validateLocalOwner(local: ExportPayload, remote: ExportPayload?) throws {
        requiresLocalOwnershipConfirmation = false
        guard let userID = currentUser?.id else { throw URLError(.userAuthenticationRequired) }
        if let owner = defaults.object(forKey: localOwnerKey) as? Int {
            guard owner == userID || SyncMergeService.isEmptyUserData(local) || SyncMergeService.looksLikeSeedOnly(local) else {
                throw NSError(domain: "CloudSyncOwner", code: 409,
                    userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("本机记录属于另一个账户，已暂停上传和合并。请先导出本机记录，再选择恢复当前账户的云端数据。")])
            }
        } else if !SyncMergeService.isEmptyUserData(local), !SyncMergeService.looksLikeSeedOnly(local),
                  remote.map({ SyncMergeService.isSameContent(local, $0) }) != true {
            requiresLocalOwnershipConfirmation = remote == nil
            throw NSError(domain: "CloudSyncOwner", code: 409,
                userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("本机记录尚未确认账户归属，已暂停上传。请先核对并恢复当前账户的云端数据，或导出本机记录。")])
        }
    }

    /// Explicit first-account association, offered only when no cloud backup exists.
    func authorizeLocalDataForCurrentAccount(from context: ModelContext) async {
        guard !AppPreviewSession.isActive || isolatedTest,
              requiresLocalOwnershipConfirmation, defaults.object(forKey: localOwnerKey) == nil,
              !context.hasChanges, !ModelContextMutationBarrier.shared.hasBlockingEditorDraft else { return }
        let result = await perform { [self] in
            guard try await self.fetchLatestBackupIfAvailable() == nil else {
                self.requiresLocalOwnershipConfirmation = false
                throw NSError(domain: "CloudSyncOwner", code: 409,
                    userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("云端已出现新记录，请先核对。未上传本机数据。")])
            }
            let payload = try await ImportExportService.exportPayloadCooperatively(from: context)
            try await self.saveLocalSafetyBackup(payload.payload)
            let emptyBase = ExportPayload(exportedAt: .now, categories: [], items: [], snapshots: [], deletions: [])
            try await self.persistSyncBaseline(emptyBase)
            self.requiresLocalOwnershipConfirmation = false
        }
        if result == .completed { scheduleAutoSync(from: context, quietly: false, delayNanoseconds: 0) }
    }

    private func saveLocalSafetyBackup(_ payload: ExportPayload) async throws {
        let owner = defaults.object(forKey: localOwnerKey) as? Int ?? 0
        let parent = try baselineURL(userID: owner).deletingLastPathComponent().appendingPathComponent("SafetyBackups")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = parent.appendingPathComponent("before-restore-" + UUID().uuidString + ".json")
        try await SyncPayloadWork.detached {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(payload).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        defaults.set(file.path, forKey: "assettimemachine.cloud.lastLocalSafetyBackup")
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

    /// Available only to the isolated preview harness; tokens and defaults are supplied by the test.
    func runIsolatedSync(from context: ModelContext) async -> Bool {
        precondition(isolatedTest && AppPreviewSession.isActive)
        return await autoSyncIfNeeded(from: context, quietly: false)
    }

    private func persistSyncBaseline(_ payload: ExportPayload) async throws {
        guard let userID = currentUser?.id else { throw URLError(.userAuthenticationRequired) }
        let file = try baselineURL(userID: userID)
        try await SyncPayloadWork.detached {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(payload).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        defaults.set(userID, forKey: localOwnerKey)
    }

    private func rememberSync(signature: String, at date: Date, payload: ExportPayload) async throws {
        try await persistSyncBaseline(payload)
        defaults.set(signature, forKey: lastUploadedSignatureKey)
        defaults.set(date, forKey: lastSyncAtKey)
        lastSyncAt = date
    }

    private func applyCloudPayload(
        _ payload: ExportPayload,
        into context: ModelContext,
        expectedStoreRevision: UInt64
    ) async throws -> UInt64 {
        let exclusiveID = try ModelContextMutationBarrier.shared.beginExclusiveDrain()
        isApplyingLocalData = true
        defer {
            ModelContextMutationBarrier.shared.finishExclusive(exclusiveID)
            isApplyingLocalData = false
        }

        // Publish the loading barrier first so data-backed feature trees can unmount
        // and register their final draft saves. The mutation begins only after every
        // registered writer has completed; unlike a fixed delay, this stays correct
        // even under a slow scheduler or unusually large record encoding.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        try await ModelContextMutationBarrier.shared.enterExclusive(exclusiveID)

        let committedStoreRevision = try await ImportExportService.importPayloadCooperatively(
            payload,
            into: context,
            replaceExisting: true,
            expectedStoreRevision: expectedStoreRevision
        )

        // Force every feature subtree to release any object that the import deleted.
        // Increment only after the single committed save; cancellation after this point
        // must not report a committed import as failed.
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

    nonisolated private static func reconcile(
        local: ExportPayload,
        localCanonicalData: Data?,
        remote: ExportPayload,
        baseline: ExportPayload?
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
                merged = try SyncMergeService.reconciledPayload(local: local, remote: remote, baseline: baseline)
            } else if SyncMergeService.isSameContent(local, remote) || SyncMergeService.isEmptyUserData(local) {
                merged = SyncMergeService.mergedPayload(local: local, remote: remote)
            } else {
                throw NSError(domain: "CloudSyncBaseline", code: 409,
                    userInfo: [NSLocalizedDescriptionKey: AppLocalization.string("尚无可靠的同步基准，已暂停合并。请先核对并恢复云端数据，或导出本机记录。")])
            }
            try Task.checkCancellation()
            let mergedCanonicalData = try? SyncMergeService.canonicalData(for: merged)
            try Task.checkCancellation()
            let remoteCanonicalData = try? SyncMergeService.canonicalData(for: remote)
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
        errorMessage = nil
        defer { isWorking = false }

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
            errorMessage = error.localizedDescription
            return .failed
        }
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

struct AssetTimeMachineCloudEntryButton: View {
    @ObservedObject var store: AssetTimeMachineCloudStore

    var body: some View {
        Circle()
            .fill(AssetTheme.surfaceRaised.opacity(0.96))
            .overlay(
                Circle()
                    .stroke(AssetTheme.border.opacity(0.9), lineWidth: 1)
            )
            .overlay {
                AssetTimeMachineCloudStatusSymbol(state: store.indicatorState, size: 18)
                    .frame(width: 44, height: 44)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(store.indicatorLabel)
    }
}

struct AssetTimeMachineCloudPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: AssetTimeMachineCloudStore
    @State private var showRestoreConfirm = false
    @State private var showOwnershipConfirm = false
    #if targetEnvironment(macCatalyst)
    @State private var showsMacPasswordLogin = false
    #endif

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: cloudContentSpacing) {
                    statusHero
                    mainCard
                }
                .frame(maxWidth: cloudContentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, cloudHorizontalPadding)
                .padding(.top, cloudTopPadding)
                .padding(.bottom, cloudBottomPadding)
            }
        }
        .navigationTitle(AppLocalization.string("云同步"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(AppLocalization.string("完成")) {
                    dismiss()
                }
            }
        }
        .task {
            await store.refreshIfNeeded(from: modelContext)
        }
        #if targetEnvironment(macCatalyst)
        .sheet(isPresented: $showsMacPasswordLogin) {
            VStack(alignment: .leading, spacing: 16) {
                Text(AppLocalization.string("使用已有账号密码登录"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AssetTheme.textPrimary)
                MacPasswordLoginForm(cloudStore: store) {
                    showsMacPasswordLogin = false
                } onBack: {
                    showsMacPasswordLogin = false
                }
            }
            .padding(20)
            .frame(width: 390, height: 205)
            .background(AssetTheme.background)
            .presentationSizing(.fitted)
        }
        #endif
        .alert(AppLocalization.string("确认关联到当前账户？"), isPresented: $showOwnershipConfirm) {
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("确认并同步")) { Task { await store.authorizeLocalDataForCurrentAccount(from: modelContext) } }
        } message: { Text(AppLocalization.string("本机记录将上传到当前账户的云端备份。请确认这是你的账户。")) }
        .alert(AppLocalization.string("确认恢复云端备份？"), isPresented: $showRestoreConfirm) {
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("覆盖本机"), role: .destructive) {
                Task {
                    await store.restoreLatestBackup(into: modelContext)
                }
            }
        } message: {
            Text(AppLocalization.string("最近一次云端备份将覆盖本机数据，适用于换机或误删后的恢复。"))
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

            #if targetEnvironment(macCatalyst)
            Button(AppLocalization.string("使用已有账号密码登录")) {
                showsMacPasswordLogin = true
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AssetTheme.goldSoft)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            #endif
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(AssetTheme.gold)
                Text(AppLocalization.string("正在恢复云同步状态…"))
                    .font(AppTypography.blockTitle)
                    .foregroundStyle(AssetTheme.textPrimary)
            }

            Text(AppLocalization.string("已检测到登录凭证，正在验证云端连接。"))
                .font(AppTypography.meta)
                .foregroundStyle(AssetTheme.textSecondary)
        }
    }

    private var loggedInSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppLocalization.string("最近备份"))
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AssetTheme.textPrimary)

                Spacer(minLength: 8)

                Button {
                    Task {
                        await store.refreshSession()
                    }
                } label: {
                    Label(AppLocalization.string("刷新"), systemImage: "arrow.clockwise")
                        .font(AppTypography.meta)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(store.isWorking)
            }

            if store.requiresLocalOwnershipConfirmation {
                Button(AppLocalization.string("关联并同步本机记录")) { showOwnershipConfirm = true }
                    .disabled(store.isWorking)
            }
            if store.backups.isEmpty {
                Text(AppLocalization.string("暂无云端备份，正在准备首次同步"))
                    .font(AppTypography.meta)
                    .foregroundStyle(AssetTheme.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.backups.prefix(3).enumerated()), id: \.element.id) { index, backup in
                        cloudBackupRow(backup)

                        if index < min(store.backups.count, 3) - 1 {
                            Rectangle()
                                .fill(AssetTheme.border.opacity(0.32))
                                .frame(height: 1)
                                .padding(.leading, 2)
                        }
                    }
                }

                Button {
                    showRestoreConfirm = true
                } label: {
                    Label(AppLocalization.string("恢复最近一次备份"), systemImage: "arrow.clockwise.icloud")
                        .font(AppTypography.metaStrong)
                        .foregroundStyle(AssetTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(store.isWorking)
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
        }
        .padding(.vertical, 10)
    }

    private func backupFileSizeLabel(for backup: AssetTimeMachineCloudBackup) -> String {
        guard let fileSize = backup.fileSize else {
            return AppLocalization.string("未知大小")
        }
        return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    private var heroTitle: String {
        switch store.indicatorState {
        case .idle:
            return AppLocalization.string("启用云同步")
        case .checking:
            if store.currentUser != nil && !store.hasCompletedInitialSync {
                return store.isWorking ? AppLocalization.string("正在首次云同步") : AppLocalization.string("等待首次云同步")
            }
            return AppLocalization.string("正在连接云同步")
        case .healthy:
            return AppLocalization.string("云同步已启用")
        case .warning:
            if store.currentUser != nil {
                return store.backups.isEmpty ? AppLocalization.string("首次同步需处理") : AppLocalization.string("同步状态需处理")
            }
            return AppLocalization.string("云同步状态需处理")
        }
    }

    private var heroSubtitle: String? {
        switch store.indicatorState {
        case .idle:
            return nil
        case .checking:
            if store.currentUser != nil && !store.hasCompletedInitialSync {
                return store.isWorking
                    ? AppLocalization.string("正在上传或恢复你的资产数据")
                    : AppLocalization.string("账号已登录，稍后会自动完成首次同步")
            }
            return AppLocalization.string("正在验证登录态与最近备份状态")
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
