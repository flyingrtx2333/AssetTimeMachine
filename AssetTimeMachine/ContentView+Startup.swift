import SwiftUI
import SwiftData
import UniformTypeIdentifiers

extension ContentView {
    @MainActor
    func runStartupIfNeeded() async {
        guard !didRunStartup else { return }
        didRunStartup = true

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-openSnapshotsTab") {
            selectTab(.snapshots)
        }

        if ProcessInfo.processInfo.arguments.contains("-openTimeMachineTab") {
            selectTab(.timeMachine)
        }

        if let importPath = launchArgumentValue(after: "-importJSONPath") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: importPath))
                try ImportExportService.importJSON(
                    data,
                    into: modelContext,
                    replaceExisting: ProcessInfo.processInfo.arguments.contains("-replaceExistingImport")
                )
                try? "success".write(
                    to: URL(fileURLWithPath: "/tmp/assettimemachine-import-status.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                let message = "[AssetTimeMachine] import failed: \(error)"
                print(message)
                try? message.write(
                    to: URL(fileURLWithPath: "/tmp/assettimemachine-import-status.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        } else {
            try? SeedDataService.seedDefaultCategoriesIfNeeded(in: modelContext)
        }
        #else
        try? SeedDataService.seedDefaultCategoriesIfNeeded(in: modelContext)
        #endif

        await Task.yield()
        try? SeedDataService.ensureDefaultFinancialItems(in: modelContext)
        try? AssetItemService.migrateLegacyAutoPricedItemsIfNeeded(in: modelContext)

        if !hasCompletedOnboarding {
            presentOnboarding()
        }
    }

    @MainActor
    func presentOnboarding() {
        onboardingReturnTab = selectedTab
        showsOnboarding = true
    }

    @MainActor
    func finishOnboarding() {
        hasCompletedOnboarding = true
        showsOnboarding = false
        activeOnboardingAnchorID = nil
        selectTab(onboardingReturnTab)
    }

    #if DEBUG
    @MainActor
    func scheduleDebugTabSwitchLoopIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-profileTabSwitchLoop"),
              debugTabSwitchTask == nil else { return }

        func debugName(for tab: AppTab) -> String {
            switch tab {
            case .dashboard: return "dashboard"
            case .snapshots: return "snapshots"
            case .timeMachine: return "timeMachine"
            case .backtest: return "backtest"
            case .settings: return "settings"
            }
        }

        print("[tab-profile] scheduling auto tab switch loop")
        let sequence: [AppTab] = [
            .snapshots, .timeMachine, .backtest, .settings, .dashboard,
            .snapshots, .timeMachine, .backtest, .settings, .dashboard
        ]

        debugTabSwitchTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            for tab in sequence {
                guard !Task.isCancelled else { return }
                print("[tab-profile] switching to \(debugName(for: tab))")
                await MainActor.run {
                    selectTab(tab)
                }
                try? await Task.sleep(for: .milliseconds(520))
            }
            await MainActor.run {
                debugTabSwitchTask = nil
            }
        }
    }

    func launchArgumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
    #endif
}
