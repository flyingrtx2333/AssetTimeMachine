# Repository Guidelines

## Project Structure & Module Organization

This is a SwiftUI + SwiftData multi-platform app for local-first personal asset tracking.

- `AssetTimeMachine/` holds app source. Key files include `AssetTimeMachineApp.swift`, `ContentView.swift`, `Models.swift`, `Services.swift`, `CloudSync.swift`, and `ImportExport.swift`.
- `AssetTimeMachine/Assets.xcassets/` stores app icons, accent colors, and asset category icons.
- `AssetTimeMachine/Localizable.xcstrings` and related string catalogs hold localized text.
- `demo/` contains sample import/history JSON files.
- `scripts/` contains helper conversion and demo generation scripts.
- `marketing/` contains App Store copy, screenshots, icon prompts, and backups.

## Build, Test, and Development Commands

- `open AssetTimeMachine.xcodeproj` opens the project in Xcode for interactive development.
- `xcodebuild -list -project AssetTimeMachine.xcodeproj` lists available targets and schemes.
- `xcodebuild -project AssetTimeMachine.xcodeproj -scheme AssetTimeMachine -configuration Debug build` builds the app from the command line.
- `xcodebuild -project AssetTimeMachine.xcodeproj -scheme AssetTimeMachine -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build` validates an iOS simulator build; adjust the simulator name as needed.
- `python3 scripts/generate_demo_import_json.py` regenerates demo import data when editing sample flows.

## Coding Style & Naming Conventions

Use Swift 5 conventions with 4-space indentation. Prefer small SwiftUI views and explicit domain names such as `AssetSnapshot`, `AssetEntry`, `PortfolioCalculator`, and `TrendAnalysisService`. Keep model fields stable and migration-aware because SwiftData persistence is user-facing. Route user-visible strings through the existing localization path.

## Testing Guidelines

The repository currently has `AssetTimeMachine/LogicTests.swift` with lightweight preview-style checks, not a separate XCTest target. For now, validate changes with `xcodebuild ... build` plus manual app flows for record entry, charts, localization, import/export, and persistence. When adding formal tests, create XCTest files named after the unit under test, for example `PortfolioCalculatorTests.swift`, and cover calculations before UI behavior.

## Commit & Pull Request Guidelines

Recent commits use Conventional Commit style, for example `style(ios): polish record grid surfaces` and `chore(code): remove template file headers and inline note`. Follow `type(scope): concise imperative summary`, with scopes such as `ios`, `code`, `marketing`, or `demo`.

Pull requests should describe the user-facing change, list verification commands or devices used, note data-model or localization impacts, and include screenshots for visible UI changes.

## Security & Configuration Tips

Keep private backups, real user data, signing settings, and generated App Store assets out of unrelated changes. Treat JSON exports as sensitive financial data and avoid committing new private samples unless explicitly intended.
