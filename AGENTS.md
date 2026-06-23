# Repository Guidelines

This repository is the **AssetTimeMachine** SwiftUI + SwiftData iOS app. It connects to the Flyingrtx backend for public market data and AssetTimeMachine cloud sync.

## Project Structure & Module Organization

- `AssetTimeMachine/` holds app source.
  - `AssetTimeMachineApp.swift`: app entry.
  - `ContentView.swift`: most SwiftUI screens, backtest UI, strategy cards, dashboard, and sheets.
  - `Models.swift`: SwiftData/user data models.
  - `Services.swift`: notification/export/service helpers.
  - `CloudSync.swift`: AssetTimeMachine cloud sync API client.
  - `RemoteMarket.swift`: market-data API client/cache store.
  - `ImportExport.swift`: local import/export.
  - `LogicTests.swift`: lightweight in-app/preview-style logic checks, not a separate XCTest target.
- `AssetTimeMachine/Assets.xcassets/` stores app icons, accent colors, and asset category icons.
- `AssetTimeMachine/Localizable.xcstrings` and related string catalogs hold localized text. Route user-visible strings through `AppLocalization` / localization catalog style already used in the code.
- `demo/` contains sample import/history JSON files.
- `scripts/` contains helper conversion/demo/search scripts.
- `tools/` contains local research/backtest parity utilities. Keep durable comparison scripts here instead of `/tmp`.
- `marketing/` contains App Store copy, screenshots, icon prompts, and backups.
- `build/` contains generated archives/IPAs. Do not hand-edit or commit generated build artifacts unless explicitly asked.

## Connected Backend / Server Context

The app currently uses the Flyingrtx API:

- Base URL in code: `AssetTimeMachine/RemoteMarket.swift`
  - `RemoteMarketClient.baseURL = https://api.flyingrtx.com`
- Cloud sync client: `AssetTimeMachine/CloudSync.swift`
  - `/api/v1/asset-time-machine/cloud/history`
  - `/api/v1/asset-time-machine/cloud/upload`
  - `/api/v1/asset-time-machine/cloud/latest`
- Market data endpoint used by app/tools:
  - `/api/v1/money/public/history`
  - overview/exchange-rate endpoints are also in `RemoteMarket.swift`.

Known local/server project locations:

- iOS app repo: `~/Desktop/AllProjects/AssetTimeMachine`
- Backend/local full-stack project: `~/Desktop/FlyingrtxFast`
- Server IP: `1.14.58.29`
- Server static roots under `/www/wwwroot`, with known dirs:
  - `/www/wwwroot/Flyingrtx`
  - `/www/wwwroot/www.flyingrtx.com`
  - `/www/wwwroot/api.flyingrtx.com`
- Production backend runs in Docker containers named like:
  - `flyingrtx-nginx`
  - `flyingrtx-backend-1`
  - `flyingrtx-backend-2`
  - `flyingrtx-backend-3`
- Local dev backend can be exposed at `http://127.0.0.1:59888` via the FlyingrtxFast dev docker compose setup.
- FRP/launchd setup exists on this Mac for local backend tunneling, but do **not** copy tokens into this repo. Check the private Hermes memory/config or ask the user if credentials are required.

Security rules:

- Do not commit API keys, App Store Connect private keys, SSH secrets, FRP tokens, real user exports, or private financial data.
- If a backend/server operation needs secrets, use existing local env/config files and never paste the secret into source-controlled files.

## Build, Test, and Development Commands

Open in Xcode:

```bash
cd ~/Desktop/AllProjects/AssetTimeMachine
open AssetTimeMachine.xcodeproj
```

List project schemes:

```bash
xcodebuild -list -project AssetTimeMachine.xcodeproj
```

Debug build for simulator:

```bash
xcodebuild \
  -project AssetTimeMachine.xcodeproj \
  -scheme AssetTimeMachine \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  build
```

Release/archive validation uses the same scheme:

```bash
xcodebuild archive \
  -project AssetTimeMachine.xcodeproj \
  -scheme AssetTimeMachine \
  -configuration Release \
  -archivePath "$PWD/build/TestFlight-<version>-<build>/AssetTimeMachine.xcarchive" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates
```

Recommended quick preflight before shipping:

```bash
git diff --check
xcodebuild \
  -project AssetTimeMachine.xcodeproj \
  -scheme AssetTimeMachine \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  build
```

## Running on iOS Simulator

Current commonly used simulator on this Mac:

- `iPhone 17 Pro Max`
- UDID observed during development: `02E004D9-A5F0-401A-9023-0E8315F77C8B`

Boot/open Simulator:

```bash
xcrun simctl boot "iPhone 17 Pro Max" || true
open -a Simulator
```

Build, install, and launch the Debug app:

```bash
cd ~/Desktop/AllProjects/AssetTimeMachine
xcodebuild \
  -project AssetTimeMachine.xcodeproj \
  -scheme AssetTimeMachine \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  build

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData \
  -path '*/Build/Products/Debug-iphonesimulator/AssetTimeMachine.app' \
  ! -path '*/Index.noindex/*' \
  -print -quit)

xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted com.flyingrtx.AssetTimeMachine
```

Take a screenshot:

```bash
xcrun simctl io booted screenshot /tmp/atm-screenshot.png
```

If you need a clean first-run state, uninstall first:

```bash
xcrun simctl uninstall booted com.flyingrtx.AssetTimeMachine || true
```

## TestFlight Release Procedure

Bundle ID: `com.flyingrtx.AssetTimeMachine`

App Store Connect credentials are expected in the local private env file:

```bash
~/.appstoreconnect/assettimemachine.env
```

It should define at least:

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_KEY_PATH` if needed by the local setup

Do not commit this env file or key material.

### 1. Bump build number

Update `CURRENT_PROJECT_VERSION` in:

```text
AssetTimeMachine.xcodeproj/project.pbxproj
```

Use the next integer build number. Keep `MARKETING_VERSION` unless the user asks for a version bump.

Quick check:

```bash
python3 - <<'PY'
from pathlib import Path
import re
text = Path('AssetTimeMachine.xcodeproj/project.pbxproj').read_text()
print(sorted(set(re.findall(r'CURRENT_PROJECT_VERSION = ([^;]+);', text))))
print(sorted(set(re.findall(r'MARKETING_VERSION = ([^;]+);', text))))
PY
```

### 2. Archive

```bash
cd ~/Desktop/AllProjects/AssetTimeMachine
BUILD_DIR="$PWD/build/TestFlight-1.0.5-<build>"
ARCHIVE="$BUILD_DIR/AssetTimeMachine.xcarchive"
LOG="$BUILD_DIR/archive.log"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

git diff --check

xcodebuild archive \
  -project AssetTimeMachine.xcodeproj \
  -scheme AssetTimeMachine \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  > "$LOG" 2>&1 || { tail -n 180 "$LOG"; exit 1; }
```

### 3. Export IPA

Create `ExportOptions.plist` inside the build dir:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>8BPSC5L74V</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

Then export:

```bash
EXPORT="$BUILD_DIR/export"
mkdir -p "$EXPORT"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates
```

Expected IPA:

```text
$BUILD_DIR/export/AssetTimeMachine.ipa
```

### 4. Upload to App Store Connect

```bash
source ~/.appstoreconnect/assettimemachine.env
IPA="$BUILD_DIR/export/AssetTimeMachine.ipa"
LOG="$BUILD_DIR/upload.log"

xcrun altool --upload-app \
  --type ios \
  --file "$IPA" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID" \
  > "$LOG" 2>&1 || { tail -n 180 "$LOG"; exit 1; }

tail -n 80 "$LOG"
```

Capture the `Delivery UUID` from upload output.

### 5. Poll build processing status

Use `--delivery-id` and check for `BUILD-STATUS: VALID`:

```bash
DELIVERY_ID="<delivery-uuid-from-upload>"
STATUS_LOG="$BUILD_DIR/build-status.log"
: > "$STATUS_LOG"

for attempt in $(seq 1 40); do
  echo "--- attempt $attempt $(date) ---" | tee -a "$STATUS_LOG"
  xcrun altool --build-status \
    --delivery-id "$DELIVERY_ID" \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" \
    2>&1 | tee -a "$STATUS_LOG"

  if grep -q "BUILD-STATUS: VALID" "$STATUS_LOG"; then
    echo "ASC_VALID" | tee -a "$STATUS_LOG"
    break
  fi
  if grep -Eq "BUILD-STATUS: (FAILED|INVALID)" "$STATUS_LOG"; then
    echo "ASC_FAILED" | tee -a "$STATUS_LOG"
    exit 2
  fi
  sleep 30
done
```

Important pitfall: this `altool` output uses `BUILD-STATUS: VALID`, not `Status: VALID`.

## Backtest / Strategy Verification Rules

- Do not trust one-off `/tmp` research scripts for app-facing strategy metrics.
- New strategy candidates must be replayed through the current App/backtest engine before being presented as product results.
- For AssetTimeMachine strategy work, keep reusable comparison scripts under `tools/`.
- For multi-asset backtests across gold/US equities/A-shares, use recent valid price forward-fill with enough holiday tolerance; do not accidentally delete dates because one market is closed.
- K-line charts must use real OHLC data. Do not fake OHLC from close-only series.
- User preference: no BTC in main AssetTimeMachine strategy line unless explicitly requested.

## UI / Copy Standards

- Keep iOS UI simple: grouped sections, shallow hierarchy, little repeated text.
- Product-visible copy must not expose implementation/performance excuses. Never show text like “为避免卡顿...” or other internal engineering explanations to users.
- Avoid redundant subtitles. Keep titles concise, ideally one line where practical.
- Do not add images if the asset folder lacks real matching material.
- For visible UI changes, verify with a real simulator/device screenshot, not just a mental mockup.

## Coding Style & Naming Conventions

Use Swift 5 conventions with 4-space indentation. Prefer small SwiftUI views and explicit domain names such as `AssetSnapshot`, `AssetEntry`, `PortfolioCalculator`, and `TrendAnalysisService`. Keep model fields stable and migration-aware because SwiftData persistence is user-facing.

When searching/reading code in this local repo, prefer terminal `rtk grep`, `rtk find`, and `rtk read` when available. Fall back to `python3` snippets for precise line ranges if `rtk read` cannot paginate the needed section.

## Testing Guidelines

The repository currently has `AssetTimeMachine/LogicTests.swift` with lightweight preview-style checks, not a separate XCTest target. For now, validate changes with `xcodebuild ... build` plus manual app flows for record entry, charts, localization, import/export, cloud sync, notifications, backtests, and persistence.

When adding formal tests, create XCTest files named after the unit under test, for example `PortfolioCalculatorTests.swift`, and cover calculations before UI behavior.

## Commit & Pull Request Guidelines

Recent commits use Conventional Commit style, for example `style(ios): polish record grid surfaces` and `chore(code): remove template file headers and inline note`. Follow `type(scope): concise imperative summary`, with scopes such as `ios`, `code`, `marketing`, or `demo`.

Pull requests should describe the user-facing change, list verification commands or devices used, note data-model or localization impacts, and include screenshots for visible UI changes.

## Current Known Operational Notes

- The app base API should return from `https://api.flyingrtx.com`.
- If market-data freshness looks wrong, separate these layers before fixing:
  - app cache / `RemoteMarketStore.historySeries`
  - public history endpoint response
  - backend daily history table
  - latest price cache
  - upstream provider behavior
- Production server access and backend deployment details may use private credentials. Do not infer or expose secrets; use existing local config or ask the user.
