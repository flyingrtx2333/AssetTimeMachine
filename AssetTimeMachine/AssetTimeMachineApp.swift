//
//  AssetTimeMachineApp.swift
//  AssetTimeMachine
//
//  Created by 向钧升 on 4/25/26.
//

import SwiftUI
import SwiftData

@main
struct AssetTimeMachineApp: App {
    @AppStorage("app.appearanceMode") private var appearanceModeRawValue: String = AppAppearanceMode.system.rawValue

    init() {
        AssetTheme.configureSystemAppearance()
    }

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            AssetCategory.self,
            AssetItem.self,
            AssetSnapshot.self,
            AssetEntry.self,
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
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .modelContainer(sharedModelContainer)
    }
}
