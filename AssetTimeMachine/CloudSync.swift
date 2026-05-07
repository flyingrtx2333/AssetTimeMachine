import AuthenticationServices
import Combine
import Foundation
import SwiftData
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct AssetTimeMachineCloudUser: Codable {
    let id: Int
    let userName: String?
    let userEmail: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userName = "user_name"
        case userEmail = "user_email"
    }

    var displayName: String {
        if let userName, !userName.isEmpty {
            return userName
        }
        if let userEmail, !userEmail.isEmpty {
            return userEmail
        }
        return "用户 #\(id)"
    }
}

struct AssetTimeMachineCloudBackup: Codable, Identifiable {
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

struct AssetTimeMachineCloudLatestBackup: Codable {
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

private struct AssetTimeMachineCloudToken: Codable {
    let accessToken: String
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }
}

private struct AssetTimeMachineCloudLoginRequest: Encodable {
    let username: String
    let password: String
}

private struct AssetTimeMachineAppleLoginRequest: Encodable {
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

private struct AssetTimeMachineCloudUploadRequest: Encodable {
    let payload: ExportPayload
    let fileName: String
    let dataKind: String
    let deviceName: String?
    let appVersion: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case payload
        case fileName = "file_name"
        case dataKind = "data_kind"
        case deviceName = "device_name"
        case appVersion = "app_version"
        case note
    }
}

private struct AssetTimeMachineCloudErrorResponse: Codable {
    let detail: String?
}

enum AssetTimeMachineCloudAPI {
    static let baseURL = RemoteMarketClient.baseURL

    static func login(username: String, password: String) async throws -> String {
        let response: AssetTimeMachineCloudToken = try await request(
            path: "/api/v1/auth/login",
            method: "POST",
            body: AssetTimeMachineCloudLoginRequest(username: username, password: password)
        )
        return response.accessToken
    }

    static func loginWithApple(identityToken: String, authorizationCode: String?, userName: String?, userEmail: String?) async throws -> String {
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
        return response.accessToken
    }

    static func fetchCurrentUser(token: String) async throws -> AssetTimeMachineCloudUser {
        try await request(path: "/api/v1/users/me", token: token)
    }

    static func fetchHistory(token: String, limit: Int = 10) async throws -> [AssetTimeMachineCloudBackup] {
        try await request(path: "/api/v1/asset-time-machine/cloud/history?limit=\(limit)", token: token)
    }

    static func upload(token: String, payload: ExportPayload, note: String?) async throws -> AssetTimeMachineCloudBackup {
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
                note: note
            )
        )
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

    private static func request<T: Decodable>(path: String, method: String = "GET", token: String? = nil) async throws -> T {
        try await request(path: path, method: method, token: token, bodyData: nil)
    }

    private static func request<T: Decodable, Body: Encodable>(path: String, method: String, token: String? = nil, body: Body) async throws -> T {
        let bodyData = try encoder().encode(body)
        return try await request(path: path, method: method, token: token, bodyData: bodyData)
    }

    private static func request<T: Decodable>(path: String, method: String, token: String?, bodyData: Data?) async throws -> T {
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

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decoder().decode(T.self, from: data)
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
                userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "云同步请求失败"]
            )
        }
    }

    private static func url(for path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = fractionalISO8601DateFormatter.date(from: value) ?? iso8601DateFormatter.date(from: value) ?? localDateFormatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date format: \(value)")
        }
        return decoder
    }

    private static let fractionalISO8601DateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601DateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}

enum AssetTimeMachineCloudIndicatorState {
    case idle
    case healthy
    case warning

    var cloudSymbolName: String {
        switch self {
        case .idle:
            return "icloud"
        case .healthy, .warning:
            return "icloud.fill"
        }
    }
}

@MainActor
final class AssetTimeMachineCloudStore: ObservableObject {
    @Published var currentUser: AssetTimeMachineCloudUser?
    @Published var backups: [AssetTimeMachineCloudBackup] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var lastSyncAt: Date?

    private let tokenKey = "assettimemachine.cloud.accessToken"
    private let lastUploadedSignatureKey = "assettimemachine.cloud.lastUploadedSignature"
    private let lastSyncAtKey = "assettimemachine.cloud.lastSyncAt"
    private let defaults = UserDefaults.standard
    private var hasLoadedInitialState = false

    init() {
        lastSyncAt = defaults.object(forKey: lastSyncAtKey) as? Date
    }

    var hasToken: Bool {
        !(accessToken?.isEmpty ?? true)
    }

    var indicatorState: AssetTimeMachineCloudIndicatorState {
        if currentUser != nil {
            return backups.isEmpty || (errorMessage?.isEmpty == false) ? .warning : .healthy
        }
        return errorMessage?.isEmpty == false ? .warning : .idle
    }

    var indicatorLabel: String {
        switch indicatorState {
        case .idle:
            return "云备份未开启"
        case .healthy:
            return "云备份正常"
        case .warning:
            return currentUser == nil ? "云备份需要注意" : "云备份已开启，但还需要处理"
        }
    }

    private var accessToken: String? {
        defaults.string(forKey: tokenKey)
    }

    func refreshIfNeeded(from context: ModelContext? = nil) async {
        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true
        guard hasToken else { return }
        await refreshSession()
        if let context {
            await autoSyncIfNeeded(from: context, quietly: true)
        }
    }

    func login(username: String, password: String) async {
        await perform { [self] in
            let token = try await AssetTimeMachineCloudAPI.login(username: username, password: password)
            self.saveToken(token)
            try await self.loadSessionData()
            self.statusMessage = "登录成功，自动同步已开启"
        }
    }

    func handleAppleSignIn(_ result: Result<ASAuthorization, any Error>, from context: ModelContext) async {
        switch result {
        case let .failure(error):
            errorMessage = friendlyAppleSignInMessage(for: error)
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "没有拿到 Apple 登录凭证"
                return
            }

            guard let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8),
                  !identityToken.isEmpty else {
                errorMessage = "Apple 没有返回 identity token"
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
                self.saveToken(token)
                try await self.loadSessionData()
                self.statusMessage = "Apple 登录成功，自动同步已开启"
            }

            if currentUser != nil {
                await autoSyncIfNeeded(from: context, quietly: false)
            }
        }
    }

    func refreshSession() async {
        await perform { [self] in
            try await self.loadSessionData()
        }
    }

    func autoSyncIfNeeded(from context: ModelContext, quietly: Bool) async {
        guard let token = accessToken else { return }

        let payload: ExportPayload
        do {
            payload = try ImportExportService.exportPayload(from: context)
        } catch {
            if !quietly {
                errorMessage = "本机数据导出失败，无法自动同步"
            }
            return
        }

        let signature = Self.syncSignature(for: payload)
        if defaults.string(forKey: lastUploadedSignatureKey) == signature {
            return
        }

        await perform { [self] in
            let backup = try await AssetTimeMachineCloudAPI.upload(
                token: token,
                payload: payload,
                note: "iOS 自动云同步"
            )
            try await self.loadHistory(using: token)
            self.rememberSync(signature: signature, at: backup.uploadedAt)
            self.statusMessage = quietly ? "自动同步已完成" : "已自动同步到云端，时间：\(backup.uploadedAt.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    func restoreLatestBackup(into context: ModelContext) async {
        guard let token = accessToken else {
            errorMessage = "请先登录，再从云端恢复"
            return
        }

        await perform { [self] in
            let latest = try await AssetTimeMachineCloudAPI.downloadLatest(token: token)
            try ImportExportService.importPayload(latest.payload, into: context, replaceExisting: true)
            try await self.loadHistory(using: token)
            self.rememberSync(signature: Self.syncSignature(for: latest.payload), at: latest.uploadedAt)
            self.statusMessage = "已恢复最近一次云端备份"
        }
    }

    func logout() {
        defaults.removeObject(forKey: tokenKey)
        defaults.removeObject(forKey: lastUploadedSignatureKey)
        currentUser = nil
        backups = []
        lastSyncAt = nil
        statusMessage = "已退出云同步账号"
        errorMessage = nil
    }

    private func saveToken(_ token: String) {
        defaults.set(token, forKey: tokenKey)
    }

    private func loadSessionData() async throws {
        guard let token = accessToken else {
            throw NSError(domain: "AssetTimeMachineCloudStore", code: 401, userInfo: [NSLocalizedDescriptionKey: "缺少登录 token"])
        }
        currentUser = try await AssetTimeMachineCloudAPI.fetchCurrentUser(token: token)
        try await loadHistory(using: token)
    }

    private func loadHistory(using token: String) async throws {
        backups = try await AssetTimeMachineCloudAPI.fetchHistory(token: token, limit: 8)
        if let latestUploadedAt = backups.first?.uploadedAt {
            lastSyncAt = latestUploadedAt
            defaults.set(latestUploadedAt, forKey: lastSyncAtKey)
        }
    }

    private func rememberSync(signature: String, at date: Date) {
        defaults.set(signature, forKey: lastUploadedSignatureKey)
        defaults.set(date, forKey: lastSyncAtKey)
        lastSyncAt = date
    }

    private static func syncSignature(for payload: ExportPayload) -> String {
        let latestItemUpdate = payload.items.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let latestSnapshotUpdate = payload.snapshots.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let latestEntryUpdate = payload.snapshots
            .flatMap(\.entries)
            .map(\.updatedAt)
            .max()?
            .timeIntervalSince1970 ?? 0
        return [
            String(payload.categories.count),
            String(payload.items.count),
            String(payload.snapshots.count),
            String(Int(latestItemUpdate)),
            String(Int(latestSnapshotUpdate)),
            String(Int(latestEntryUpdate))
        ].joined(separator: ":")
    }

    private func perform(_ task: @escaping () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await task()
        } catch {
            if (error as NSError).code == 401 {
                defaults.removeObject(forKey: tokenKey)
                currentUser = nil
                backups = []
            }
            errorMessage = error.localizedDescription
        }
    }

    private func friendlyAppleSignInMessage(for error: any Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == ASAuthorizationError.errorDomain,
              let code = ASAuthorizationError.Code(rawValue: nsError.code) else {
            return error.localizedDescription
        }

        switch code {
        case .canceled:
            return "已取消 Apple 登录"
        case .failed:
            return "Apple 登录失败，请稍后再试"
        case .invalidResponse:
            return "Apple 登录返回的数据无效"
        case .notHandled:
            return "系统未处理此次 Apple 登录请求"
        case .unknown:
            return "Apple 一键登录当前不可用"
        @unknown default:
            return error.localizedDescription
        }
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
                Image(systemName: store.indicatorState.cloudSymbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AssetTheme.gold)
                    .frame(width: 44, height: 44)
            }
            .overlay(alignment: .bottomTrailing) {
                statusBadge
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(store.indicatorLabel)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch store.indicatorState {
        case .healthy:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AssetTheme.positive)
                .background(Circle().fill(AssetTheme.background))
                .offset(x: 4, y: 4)
        case .idle, .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AssetTheme.accentOrange)
                .padding(1)
                .background(Circle().fill(AssetTheme.background))
                .offset(x: 4, y: 4)
        }
    }
}

struct AssetTimeMachineCloudPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: AssetTimeMachineCloudStore
    @State private var showRestoreConfirm = false

    var body: some View {
        ZStack {
            AssetTheme.pageGradient.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    statusHero
                    mainCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("云同步")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.refreshIfNeeded(from: modelContext)
        }
        .alert("确认恢复云端备份？", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("覆盖本机", role: .destructive) {
                Task {
                    await store.restoreLatestBackup(into: modelContext)
                }
            }
        } message: {
            Text("会用最近的云端备份覆盖本机数据，适合换机或误删后恢复。")
        }
    }

    private var statusHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AssetTheme.surfaceRaised.opacity(0.96))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .stroke(AssetTheme.border.opacity(0.9), lineWidth: 1)
                        )

                    Image(systemName: store.indicatorState.cloudSymbolName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AssetTheme.gold)
                        .frame(width: 24, height: 24)
                }
                .overlay(alignment: .bottomTrailing) {
                    statusBadge
                        .offset(x: 4, y: 4)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(heroTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)

                    if let heroSubtitle, !heroSubtitle.isEmpty {
                        Text(heroSubtitle)
                            .font(.footnote)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }

                Spacer(minLength: 10)
            }

            if let statusNotice {
                Label(statusNotice.text, systemImage: statusNotice.systemImage)
                    .font(.footnote)
                    .foregroundStyle(statusNotice.color)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch store.indicatorState {
        case .healthy:
            ZStack {
                Circle()
                    .fill(AssetTheme.background)
                    .frame(width: 18, height: 18)

                Circle()
                    .fill(AssetTheme.positive)
                    .frame(width: 14, height: 14)

                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.white)
            }
        case .idle, .warning:
            ZStack {
                Circle()
                    .fill(AssetTheme.background)
                    .frame(width: 20, height: 20)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AssetTheme.accentOrange)
                    .frame(width: 16, height: 16)
            }
        }
    }

    private var statusNotice: (text: String, systemImage: String, color: Color)? {
        if let errorMessage = store.errorMessage, !errorMessage.isEmpty {
            return (errorMessage, "exclamationmark.triangle.fill", AssetTheme.negative)
        }
        if let statusMessage = store.statusMessage,
           !statusMessage.isEmpty,
           !statusMessage.contains("同步"),
           !statusMessage.contains("登录成功") {
            return (statusMessage, "checkmark.circle.fill", AssetTheme.positive)
        }
        return nil
    }

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let currentUser = store.currentUser {
                loggedInSection(currentUser)
            } else {
                appleLoginSection
            }
        }
    }

    private var appleLoginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("使用 Apple 登录开启云同步")
                .font(.headline)
                .foregroundStyle(AssetTheme.textPrimary)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task {
                    await store.handleAppleSignIn(result, from: modelContext)
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(store.isWorking)
        }
    }

    private func loggedInSection(_ currentUser: AssetTimeMachineCloudUser) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(AssetTheme.surfaceRaised.opacity(0.92))
                        .frame(width: 36, height: 36)

                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AssetTheme.gold)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(currentUser.displayName)
                        .font(.headline)
                        .foregroundStyle(AssetTheme.textPrimary)
                    Text(currentUser.userEmail ?? "已连接 Flyingrtx 云同步")
                        .font(.footnote)
                        .foregroundStyle(AssetTheme.textSecondary)
                }

                Spacer(minLength: 8)

                Button("退出") {
                    store.logout()
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary)
            }

            Label(
                store.lastSyncAt.map { "上次同步 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "等待首次自动同步",
                systemImage: "arrow.triangle.2.circlepath.circle.fill"
            )
            .font(.footnote.weight(.medium))
            .foregroundStyle(AssetTheme.textSecondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近备份")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)

                    Spacer(minLength: 8)

                    Button {
                        Task {
                            await store.refreshSession()
                        }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isWorking)
                }

                if store.backups.isEmpty {
                    Text("等待首次自动同步")
                        .font(.footnote)
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
                        Label("恢复最近备份", systemImage: "arrow.clockwise.icloud")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isWorking)
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(backup.isLatest == 1 ? AssetTheme.gold : AssetTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(backup.fileName ?? "未命名备份")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AssetTheme.textPrimary)

                HStack(spacing: 8) {
                    Text(backup.uploadedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(AssetTheme.textSecondary)

                    if let fileSize = backup.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                }
            }

            Spacer(minLength: 8)

            if backup.isLatest == 1 {
                Text("最新")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AssetTheme.goldSoft)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AssetTheme.gold.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 10)
    }

    private var heroTitle: String {
        switch store.indicatorState {
        case .idle:
            return "开启云同步"
        case .healthy:
            return "自动同步已开启"
        case .warning:
            if store.currentUser != nil {
                return store.backups.isEmpty ? "自动同步已开启" : "同步需要处理"
            }
            return "云同步需要处理"
        }
    }

    private var heroSubtitle: String? {
        switch store.indicatorState {
        case .idle:
            return nil
        case .healthy:
            return store.lastSyncAt.map { "最近同步 \($0.formatted(date: .abbreviated, time: .shortened))" }
        case .warning:
            if store.currentUser != nil && store.backups.isEmpty {
                return "等待首次自动同步"
            }
            return nil
        }
    }
}
