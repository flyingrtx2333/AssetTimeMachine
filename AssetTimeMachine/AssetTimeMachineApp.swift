import SwiftUI
import SwiftData

@main
struct AssetTimeMachineApp: App {
    @AppStorage("app.appearanceMode") private var appearanceModeRawValue: String = AppAppearanceMode.system.rawValue
    @AppStorage("app.language") private var appLanguageRawValue: String = AppLanguage.system.rawValue

    init() {
        AssetTheme.configureSystemAppearance()
    }

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            AssetCategory.self,
            AssetItem.self,
            AssetSnapshot.self,
            AssetEntry.self,
            BacktestRecord.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, appLanguage.locale)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .modelContainer(sharedModelContainer)
    }
}
