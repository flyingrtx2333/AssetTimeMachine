import SwiftUI
import SwiftData
import UIKit
import UserNotifications

final class AssetTimeMachineAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

@main
struct AssetTimeMachineApp: App {
    @UIApplicationDelegateAdaptor(AssetTimeMachineAppDelegate.self) private var appDelegate
    @AppStorage("app.appearanceMode") private var appearanceModeRawValue: String = AppAppearanceMode.system.rawValue
    @AppStorage("app.language") private var appLanguageRawValue: String = AppLanguage.system.rawValue
    private let modelBootstrap: AppModelContainerBootstrap

    init() {
        AssetTheme.configureSystemAppearance()
        modelBootstrap = AppModelContainerBootstrap()
    }

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if modelBootstrap.persistentStoreError == nil {
                    ContentView()
                } else {
                    PersistentStoreUnavailableView()
                }
            }
                .environment(\.locale, appLanguage.locale)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .modelContainer(modelBootstrap.container)
    }
}

private struct AppModelContainerBootstrap {
    let container: ModelContainer
    let persistentStoreError: Error?

    init() {
        let schema = Schema([
            AssetCategory.self,
            AssetItem.self,
            AssetSnapshot.self,
            AssetEntry.self,
            BacktestRecord.self,
            SyncDeletionTombstone.self,
        ])

        do {
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
            )
            persistentStoreError = nil
        } catch {
            persistentStoreError = error
            do {
                container = try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                )
            } catch {
                fatalError("Could not create fallback ModelContainer: \(error)")
            }
        }
    }
}

private struct PersistentStoreUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label(
                AppLocalization.string("本机数据无法打开"),
                systemImage: "externaldrive.badge.exclamationmark"
            )
        } description: {
            Text(AppLocalization.string("应用未修改现有数据。请重新启动；若问题持续，请更新应用或联系支持。"))
        }
        .tint(AssetTheme.gold)
    }
}
