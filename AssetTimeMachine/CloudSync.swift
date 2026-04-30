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

@MainActor
final class AssetTimeMachineCloudStore: ObservableObject {
    @Published var currentUser: AssetTimeMachineCloudUser?
    @Published var backups: [AssetTimeMachineCloudBackup] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let tokenKey = "assettimemachine.cloud.accessToken"
    private let defaults = UserDefaults.standard
    private var hasLoadedInitialState = false

    var hasToken: Bool {
        !(accessToken?.isEmpty ?? true)
    }

    private var accessToken: String? {
        defaults.string(forKey: tokenKey)
    }

    func refreshIfNeeded() async {
        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true
        guard hasToken else { return }
        await refreshSession()
    }

    func login(username: String, password: String) async {
        await perform { [self] in
            let token = try await AssetTimeMachineCloudAPI.login(username: username, password: password)
            self.saveToken(token)
            try await self.loadSessionData()
            self.statusMessage = "登录成功，现在可以把数据丢到云端啦"
        }
    }

    func handleAppleSignIn(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case let .failure(error):
            errorMessage = error.localizedDescription
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
                self.statusMessage = "Apple 登录成功，云同步已解锁"
            }
        }
    }

    func refreshSession() async {
        await perform { [self] in
            try await self.loadSessionData()
        }
    }

    func uploadCurrentData(from context: ModelContext) async {
        guard let token = accessToken else {
            errorMessage = "请先登录，再上传云备份"
            return
        }

        await perform { [self] in
            let payload = try ImportExportService.exportPayload(from: context)
            let backup = try await AssetTimeMachineCloudAPI.upload(
                token: token,
                payload: payload,
                note: "iOS 手动云备份"
            )
            try await self.loadHistory(using: token)
            self.statusMessage = "已上传到云端，时间：\(backup.uploadedAt.formatted(date: .abbreviated, time: .shortened))"
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
            self.statusMessage = "已用云端最新备份覆盖本机数据"
        }
    }

    func logout() {
        defaults.removeObject(forKey: tokenKey)
        currentUser = nil
        backups = []
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
}

struct AssetTimeMachineCloudCard: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var store = AssetTimeMachineCloudStore()
    @State private var username = ""
    @State private var password = ""
    @State private var showRestoreConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("云同步")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)

                    Text("登录后可把当前资产数据备份到 Flyingrtx 云端，也能把最新云备份拉回本机。")
                        .font(.subheadline)
                        .foregroundStyle(AssetTheme.textSecondary)
                }

                Spacer(minLength: 12)

                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(AssetTheme.gold)
            }

            if let currentUser = store.currentUser {
                loggedInSection(currentUser)
            } else {
                loginSection
            }

            if let statusMessage = store.statusMessage, !statusMessage.isEmpty {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(AssetTheme.positive)
            }

            if let errorMessage = store.errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(AssetTheme.negative)
            }
        }
        .atmCardStyle()
        .task {
            await store.refreshIfNeeded()
        }
        .alert("确认恢复云端备份？", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("覆盖本机", role: .destructive) {
                Task {
                    await store.restoreLatestBackup(into: modelContext)
                }
            }
        } message: {
            Text("会用云端最新备份替换当前本机数据。建议先点一次“上传到云端”留个保险。")
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("用户名", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AssetTheme.background.opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AssetTheme.border.opacity(0.6), lineWidth: 1)
                )
                .foregroundStyle(AssetTheme.textPrimary)

            SecureField("密码", text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AssetTheme.background.opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AssetTheme.border.opacity(0.6), lineWidth: 1)
                )
                .foregroundStyle(AssetTheme.textPrimary)

            Button {
                Task {
                    await store.login(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                }
            } label: {
                HStack {
                    if store.isWorking {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(AssetTheme.background)
                    }
                    Text(store.isWorking ? "登录中..." : "账号登录")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSubmitPasswordLogin ? AssetTheme.gold : AssetTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(canSubmitPasswordLogin ? AssetTheme.background : AssetTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitPasswordLogin || store.isWorking)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task {
                    await store.handleAppleSignIn(result)
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(store.isWorking)
        }
    }

    private func loggedInSection(_ currentUser: AssetTimeMachineCloudUser) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentUser.displayName)
                        .font(.headline)
                        .foregroundStyle(AssetTheme.textPrimary)
                    Text(currentUser.userEmail ?? "已登录 Flyingrtx 云同步")
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

            HStack(spacing: 10) {
                syncActionButton(
                    title: store.isWorking ? "上传中..." : "上传到云端",
                    systemImage: "arrow.up.circle.fill",
                    fill: AssetTheme.gold,
                    foreground: AssetTheme.background,
                    disabled: store.isWorking
                ) {
                    Task {
                        await store.uploadCurrentData(from: modelContext)
                    }
                }

                syncActionButton(
                    title: store.isWorking ? "处理中..." : "下载并覆盖",
                    systemImage: "arrow.down.circle.fill",
                    fill: AssetTheme.surfaceRaised,
                    foreground: AssetTheme.textPrimary,
                    disabled: store.isWorking
                ) {
                    showRestoreConfirm = true
                }
            }

            Button {
                Task {
                    await store.refreshSession()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("刷新云端记录")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(AssetTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(store.isWorking)

            if store.backups.isEmpty {
                Text("云端还没有备份记录，先上传一次试试。")
                    .font(.footnote)
                    .foregroundStyle(AssetTheme.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("最近云备份")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AssetTheme.textPrimary)

                    ForEach(store.backups.prefix(3)) { backup in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(backup.isLatest == 1 ? AssetTheme.gold : AssetTheme.border)
                                .frame(width: 8, height: 8)
                                .padding(.top, 6)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(backup.fileName ?? "未命名备份")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(AssetTheme.textPrimary)
                                Text(backup.uploadedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(AssetTheme.textSecondary)
                                if let fileSize = backup.fileSize {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(AssetTheme.textSecondary)
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
                    }
                }
            }
        }
    }

    private var canSubmitPasswordLogin: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func syncActionButton(title: String, systemImage: String, fill: Color, foreground: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(fill.opacity(disabled ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(foreground.opacity(disabled ? 0.78 : 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
