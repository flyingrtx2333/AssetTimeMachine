# Repository Guidelines

This repository is the **AssetTimeMachine** SwiftUI + SwiftData iOS app. It connects to the Flyingrtx backend for public market data and AssetTimeMachine cloud sync.

## Project Structure & Module Organization

- `AssetTimeMachine/` holds app source.
  - `AssetTimeMachineApp.swift`: app entry.
  - `ContentView.swift`: app shell and top-level routing.
  - `Models.swift`: SwiftData/user data models.
  - `Services.swift`: notification/export/service helpers.
  - `CloudSync.swift`: AssetTimeMachine cloud sync API client.
  - `RemoteMarket.swift`: market-data API client/cache store.
  - `ImportExport.swift`: local import/export.
  - `LogicTests.swift`: lightweight in-app/preview-style logic checks, not a separate XCTest target.
  - `Backtest/`: backtest UI, strategy templates, strategy cards, result views, and App-facing backtest engine.
  - `Views/`: dashboard, settings, snapshots, time machine, and shared SwiftUI surfaces.
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

### Where the App backtest engine lives

The production App backtest engine currently lives in `AssetTimeMachine/Backtest/`:

- `AssetTimeMachine/Backtest/BacktestEngine.swift`: source of truth for App-facing metrics.
- `AssetTimeMachine/Backtest/BacktestModels.swift`: `AdvancedBacktestStrategyTemplate.all`, `AdvancedBacktestStrategyMode`, strategy notification defaults, result payload models.
- `BacktestEngine.runAdvancedStrategy(...)` handles single-asset rule based advanced backtests.
- `BacktestEngine.runAdvancedStrategies(...)` handles multi-asset advanced backtests.
- `BacktestEngine.runAdvancedRotationStrategy(...)` / `runAdvancedRotation(...)` handles rotation strategies.
- `BacktestEngine.advancedRotationRebalanceAdvice(...)` powers “今日调仓 / 提醒策略” target-weight advice.
- `BacktestRecordCodec` serializes/deserializes saved backtest records and detail payloads.

Do not present strategy performance from a separate research script as product truth unless it has been replayed through these App paths or a parity script proven equivalent to them.

### Current App-engine strategy metrics

These are the current App-engine truth values from `tools/strategy_metric_dump.swift`, run against the production market history endpoint on 2026-06-26. Assumptions: full available history, initial cash 100,000 CNY, fee 1%, slippage 0.05%.

| Strategy | Annualized | Max drawdown | Sharpe | Range |
|---|---:|---:|---:|---|
| 权益曲线状态机 | 11.00% | 10.24% | 1.10 | 2002-01-04..2026-06-26 |
| 单向控波元策略 | 10.61% | 11.23% | 1.04 | 2002-01-04..2026-06-26 |
| 动态袖套夏普策略 | 10.05% | 11.65% | 1.03 | 2002-01-04..2026-06-26 |
| 增强热度上限元 | 9.65% | 12.04% | 0.93 | 2002-01-04..2026-06-26 |
| 热度上限元策略 | 9.44% | 12.04% | 0.93 | 2002-01-04..2026-06-26 |
| 黄金交接保护 | 9.39% | 11.38% | 0.92 | 2002-01-04..2026-06-26 |
| 月度热度上限元 | 8.82% | 16.57% | 0.85 | 2002-01-04..2026-06-26 |
| 全球修复传染控制 | 3.45% | 23.43% | 0.43 | 2002-01-04..2026-06-26 |
| 双金丝雀动量防守 | 1.86% | 31.89% | 0.28 | 2002-01-04..2026-06-26 |
| 美元现金修复策略 | 1.24% | 24.44% | 0.20 | 2002-01-04..2026-06-26 |
| 黄金恐慌锁盈策略 | 1.14% | 25.29% | 0.19 | 2002-01-04..2026-06-26 |
| 风险效率增强策略 | 1.01% | 25.76% | 0.17 | 2002-01-04..2026-06-26 |
| MA金叉死叉 | 0.75% | 43.40% | 0.12 | 2000-01-13..2026-06-26 |
| BOLL下轨反弹 | -5.89% | 80.30% | -0.76 | 2000-01-13..2026-06-26 |
| MA60趋势 | -6.41% | 87.05% | -0.46 | 2000-01-13..2026-06-26 |
| MA20趋势 | -18.78% | 99.60% | -1.48 | 2000-01-13..2026-06-26 |

If this table disagrees with a research script, trust this table only until `tools/strategy_metric_dump.swift` is rerun.

### Required App-engine strategy verification command

Use this command before reporting or updating product-facing strategy metrics:

```bash
cd ~/Desktop/AllProjects/AssetTimeMachine

xcrun swiftc \
  -parse-as-library \
  -module-cache-path /private/tmp/atm-swift-module-cache \
  AssetTimeMachine/Backtest/BacktestModels.swift \
  AssetTimeMachine/Backtest/BacktestEngine.swift \
  tools/strategy_metric_dump.swift \
  -o /private/tmp/strategy_metric_dump

/private/tmp/strategy_metric_dump
```

The dump fetches live history from `https://api.flyingrtx.com`, so it may need network permission. Do not substitute `tools/batch_strategy_summary.py` for this command when the question is “what does the App currently show/calculate?”; that batch script may include spike runners that are not App-equivalent.

### How to find / research strategies

Use this order when looking for a new strategy candidate:

1. Read the existing App strategy templates first:

   ```bash
   rg -n "AdvancedBacktestStrategyTemplate" AssetTimeMachine/Backtest/BacktestModels.swift
   rg -n "advancedRotationConfig" AssetTimeMachine/Backtest/BacktestEngine.swift
   rg -n 'symbol: ".*rotation' AssetTimeMachine/Backtest
   ```

2. Check reusable parity/search tools before creating new scripts:

   ```bash
   ls tools
   sed -n '1,160p' tools/strategy_metric_dump.swift
   sed -n '1,120p' tools/atm_app_equivalent_backtest.py
   sed -n '1,120p' tools/atm_strategy_explorer.py
   sed -n '1,120p' tools/search_no_btc_2002_strategies.py
   ```

3. Check previous spike writeups before repeating work:

   ```bash
   find spikes -maxdepth 2 -name README.md | sort
   ```

4. If a new experiment is needed, create a numbered folder under `spikes/NNN-short-topic/` with:
   - `README.md`: hypothesis, data range, assets, result table, why it passed/failed.
   - one or more `.py` scripts: deterministic, no hardcoded secrets, no `/tmp`-only dependencies.

5. Promote only durable, reusable comparison/search code into `tools/`. Keep temporary dead-end probes in `spikes/`.

### Strategy acceptance rules

- Do not trust one-off `/tmp` research scripts for App-facing strategy metrics.
- New strategy candidates must be replayed through the current App/backtest engine before being presented as product results. Prefer `tools/strategy_metric_dump.swift` for current product metrics.
- Do not copy high-return/high-Sharpe values from spike scripts into README, AGENTS, App cards, App subtitles, release notes, or user-facing answers unless a Swift App-engine run produces the same values.
- For AssetTimeMachine strategy work, keep reusable comparison scripts under `tools/`.
- For multi-asset backtests across gold/US equities/A-shares, use recent valid price forward-fill with enough holiday tolerance; do not accidentally delete dates because one market is closed.
- K-line charts must use real OHLC data. Do not fake OHLC from close-only series.
- User preference: no BTC in main AssetTimeMachine strategy line unless explicitly requested.
- Main product candidates should be checked on full history plus slices such as 2020+, recent 10Y, and stress periods; do not optimize only one pretty interval.
- Preferred direction is gold/Nasdaq-centered strategies with controlled drawdown. Avoid unrelated asset stories unless the user explicitly asks.

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
