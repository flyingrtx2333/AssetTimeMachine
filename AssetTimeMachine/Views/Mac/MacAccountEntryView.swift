#if targetEnvironment(macCatalyst)
import AuthenticationServices
import SwiftData
import SwiftUI

struct MacAccountEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var cloudStore: AssetTimeMachineCloudStore
    let onContinueLocally: () -> Void
    let onSignedIn: () -> Void

    @State private var showsPasswordLogin = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AssetTheme.gold)
                        .frame(width: 32, height: 32)
                        .background(AssetTheme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                    Text(AppLocalization.string("欢迎使用资产时光机"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AssetTheme.textPrimary)
                }

                Text(AppLocalization.string("登录后可同步手机端数据，也可以先在本机使用。"))
                    .font(.system(size: 12))
                    .foregroundStyle(AssetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if cloudStore.isSessionPending {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(AppLocalization.string("正在恢复登录"))
                            .font(.system(size: 12))
                            .foregroundStyle(AssetTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42)
                } else if showsPasswordLogin {
                    MacPasswordLoginForm(cloudStore: cloudStore, onSignedIn: onSignedIn) {
                        cloudStore.errorMessage = nil
                        showsPasswordLogin = false
                    }
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        Task {
                            await cloudStore.handleAppleSignIn(result, from: modelContext)
                            if cloudStore.currentUser != nil { onSignedIn() }
                        }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(cloudStore.isWorking || AppPreviewSession.isActive)

                    Button {
                        cloudStore.errorMessage = nil
                        showsPasswordLogin = true
                    } label: {
                        Text(AppLocalization.string("使用已有账号密码登录"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AssetTheme.goldSoft)
                    .padding(.vertical, 5)

                    Divider()

                    Button(action: onContinueLocally) {
                        Text(AppLocalization.string("暂不登录，使用本机"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AssetTheme.textPrimary)
                    .padding(.vertical, 6)
                    .disabled(cloudStore.isWorking)

                    Text(AppLocalization.string("首次通过 Apple 登录会自动创建账户。"))
                        .font(.system(size: 11))
                        .foregroundStyle(AssetTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }

                if !showsPasswordLogin,
                   let errorMessage = cloudStore.errorMessage,
                   !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(AssetTheme.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(width: 380)
            .background(AssetTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AssetTheme.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
    }
}

struct MacPasswordLoginForm: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var cloudStore: AssetTimeMachineCloudStore
    let onSignedIn: () -> Void
    let onBack: () -> Void

    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(AppLocalization.string("用户名"), text: $username)
                .textContentType(.username)
                .textFieldStyle(.roundedBorder)

            SecureField(AppLocalization.string("密码"), text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(signIn)

            if let errorMessage = cloudStore.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(AssetTheme.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(AppLocalization.string("返回"), action: onBack)
                    .buttonStyle(.plain)
                    .foregroundStyle(AssetTheme.textSecondary)

                Spacer()

                Button(action: signIn) {
                    if cloudStore.isWorking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(AppLocalization.string("登录"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AssetTheme.gold)
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || password.isEmpty || cloudStore.isWorking || AppPreviewSession.isActive)
            }
            .font(.system(size: 12))
        }
        .controlSize(.small)
    }

    private func signIn() {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty, !cloudStore.isWorking else { return }
        Task {
            await cloudStore.login(username: username, password: password)
            if cloudStore.currentUser != nil {
                cloudStore.scheduleAutoSync(from: modelContext, quietly: false, delayNanoseconds: 0)
                onSignedIn()
            }
        }
    }
}
#endif
