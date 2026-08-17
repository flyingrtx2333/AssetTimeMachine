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
  - Final App Store poster exports should also be copied to the local OneDrive delivery folder:
    `/Users/xiangjunsheng/Library/CloudStorage/OneDrive-个人/作品合集/个人-IOSAPP资产时光机-2026`
  - App Store poster screenshots must use an accepted App Store Connect size such as `1242 × 2688px` for portrait uploads.
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
xcrun swiftc \
  -parse-as-library \
  -module-cache-path /private/tmp/atm-swift-module-cache \
  AssetTimeMachine/Backtest/BacktestModels.swift \
  AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift \
  AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift \
  AssetTimeMachine/Backtest/BacktestFXConverter.swift \
  AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift \
  AssetTimeMachine/Backtest/BacktestEngine.swift \
  tools/strategy_metric_dump.swift \
  -o /private/tmp/strategy_metric_dump
ATM_HISTORY_FIXTURE=tools/fixtures/backtest-history/public_history.json \
  /private/tmp/strategy_metric_dump --verify-app-baseline
xcodebuild \
  -project AssetTimeMachine.xcodeproj \
  -scheme AssetTimeMachine \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  build
```

Backtest golden metrics use the pinned fixture at `tools/fixtures/backtest-history/public_history.json` through `ATM_HISTORY_FIXTURE`, so verification remains reproducible after a snapshot is taken. Before formal strategy research or reporting App-comparable metrics, refresh the snapshot and all golden rows from the same `period=all`, 12-symbol, `include_ohlc=true` request used by the App metric dump:

```bash
python3 scripts/refresh_app_backtest_baseline.py
```

Review the fixture and full baseline diff after every refresh. Do not report stale fixture metrics as the App's current online result.

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

### Recommended one-command release

Prefer the maintained release helper for normal TestFlight uploads:

```bash
cd ~/Desktop/AllProjects/AssetTimeMachine
scripts/release_testflight.sh --commit-message "chore(ios): release testflight build"
```

The script automatically:

- reads `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`;
- increments `CURRENT_PROJECT_VERSION` unless `--no-bump` is passed;
- runs `git diff --check`;
- runs the simulator Debug build unless `--skip-debug-build` is passed;
- optionally commits tracked changes plus the build bump when `--commit-message` is passed; untracked research files are intentionally left out;
- archives, exports, uploads the IPA, and polls App Store Connect until `BUILD-STATUS: VALID`.

To bump the user-visible version, pass `--version`:

```bash
scripts/release_testflight.sh --version 1.0.6 --commit-message "chore(ios): release 1.0.6"
```

The script expects App Store Connect credentials from `~/.appstoreconnect/assettimemachine.env` by default. Override with `ASC_ENV=/path/to/env` only for local private setups. Do not print or commit env contents.

Use the manual steps below only when debugging the release helper or when the user explicitly asks for a manual release.

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

The App exposes `AdvancedBacktestStrategyTemplate.productCatalog`; `AdvancedBacktestStrategyTemplate.all` remains the full research/diagnostic inventory. Do not add every parameter variant to the visible library. Keep a small product catalog with materially different risk tiers or signal families.

Current App defaults are initial cash 100,000 CNY, fee 1.00%, and slippage 0.05%. This is both the product assumption and the pinned regression assumption. Do not lower the default fee to improve displayed strategy performance. Environment overrides are allowed only for explicit sensitivity research.

The product Sharpe ratio must remain calculated and visible. The current implementation uses daily returns with a zero risk-free-rate assumption.

Current product results from the pinned fixture, run on 2026-07-13 with data through 2026-07-03:

| Product strategy | Type | Full annualized | Full max drawdown | Last 10Y annualized | Last 10Y max drawdown | Full Sharpe |
|---|---|---:|---:|---:|---:|---:|
| 进取风险预算 | selected | 10.50% | 14.09% | 6.62% | 12.63% | 1.02 |
| 均衡权益状态 | selected / default | 9.60% | 13.02% | 5.67% | 13.02% | 1.01 |
| 稳健锁盈防守 | selected | 8.55% | 11.67% | 5.56% | 11.67% | 0.99 |
| 凸性极速空头组合 | experimental | 11.73% | 13.47% | 11.23% | 13.47% | 1.04 |
| 风险贡献再分配 | experimental | 10.59% | 9.49% | 9.15% | 9.49% | 1.16 |
| 双趋势金纳杠铃 | independent | 10.15% | 16.98% | 13.56% | 16.98% | 0.89 |

The first three visible strategies share the gold/equity meta-strategy trunk and represent aggressive, balanced, and defensive risk tiers. `双趋势金纳杠铃` remains an independent signal family. The two experimental entries serve different goals. `凸性极速空头组合` blends the high-Sharpe, risk-budget, and dual-trend target weights, adds a 3% strict T−1 modeled equity-short crisis sleeve, caps gross exposure at 110%, and charges 5% annual financing on negative cash. The short sleeve is a synthetic inverse-payoff model, not a directly investable product. `风险贡献再分配` replaces the weaker consensus-scaling version. It first blends 40% High-Sharpe State Engine, 25% Aggressive Risk Budget, and 35% Dual-Trend Gold–Nasdaq targets and applies the same 1.00×/1.20×/1.40× exposure-consensus scaling. Every 42 sessions it estimates up to 126 sessions of covariance; when one asset exceeds 65% of portfolio risk contribution, 60% of target weights are reallocated toward lower-volatility and less positively correlated assets. It applies two strict T−1 protections. First, when existing US-equity exposure is at least 10%, a proposed one-step increase is greater than 10% and no more than 20%, and both Nasdaq and S&P 500 five-session momentum are non-positive, only 60% of the incremental exposure is executed. Second, when China-equity targets fall by at least 15%, US-equity targets rise by 5%–10%, and either Nasdaq or S&P 500 five-session momentum has not turned positive, only 50% of the incremental US exposure is executed to avoid immediately transferring regional exit risk into US equities. Normal reductions, ordinary increases, and large regime resets are unchanged. On the current pinned fixture these protections affect a small number of rebalances in 2010, 2012, and 2015, while the last-10-year, 2020+, and 2022+ metrics remain unchanged. Gross exposure is capped at 110%, negative cash is financed at 5% annually, and trades require more than 8% target-weight change. Neither strategy satisfies the requested 8% drawdown threshold, and neither may replace the default `均衡权益状态` without an explicit product decision. All metrics use the required 1% fee and 0.05% slippage assumptions; Sharpe remains calculated and visible.

The backend fixture supplies price-change series; the engine does not inject equity dividend reinvestment. A future total-return-index migration requires a new baseline and must not be compared directly with these values.

If this table disagrees with a non-App script, trust `tools/strategy_metric_dump.swift` and rerun the Swift dump/verifier.


### Required App-engine strategy verification command

Use this command before reporting or updating product-facing strategy metrics:

```bash
cd ~/Desktop/AllProjects/AssetTimeMachine

xcrun swiftc \
  -parse-as-library \
  -module-cache-path /private/tmp/atm-swift-module-cache \
  AssetTimeMachine/Backtest/BacktestModels.swift \
  AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift \
  AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift \
  AssetTimeMachine/Backtest/BacktestFXConverter.swift \
  AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift \
  AssetTimeMachine/Backtest/BacktestEngine.swift \
  tools/strategy_metric_dump.swift \
  -o /private/tmp/strategy_metric_dump

/private/tmp/strategy_metric_dump
```

The dump fetches live history from `https://api.flyingrtx.com`, so it may need network permission. For stable golden verification, run it with `ATM_HISTORY_FIXTURE=tools/fixtures/backtest-history/public_history.json` and `--verify-app-baseline`.

### How to find / research strategies

Use this order when looking for a new strategy candidate:

1. Read the existing App strategy templates first:

   ```bash
   rg -n "AdvancedBacktestStrategyTemplate" AssetTimeMachine/Backtest/BacktestModels.swift
   rg -n "advancedRotationConfig" AssetTimeMachine/Backtest/BacktestEngine.swift
   rg -n 'symbol: ".*rotation' AssetTimeMachine/Backtest
   ```

2. Check the reusable Swift dump/verifier before adding new strategy code:

   ```bash
   ls tools
   sed -n '1,160p' tools/strategy_metric_dump.swift
   ```

3. If a new experiment is needed, implement it as a Swift `StrategyTargetProvider` or Swift CLI search path that calls the same `BacktestDailySimulator`. Do not add Python strategy searchers, app-equivalent simulators, replay scripts, or spike folders.

### Strategy acceptance rules

- Do not trust one-off `/tmp` research scripts for App-facing strategy metrics.
- New strategy candidates must be implemented as Swift target providers and replayed through the current unified App/backtest simulator before being presented as product results. Prefer `tools/strategy_metric_dump.swift` for current product metrics.
- Do not copy high-return/high-Sharpe values from non-App scripts into README, AGENTS, App cards, App subtitles, release notes, or user-facing answers unless a Swift App-engine run produces the same values.
- For AssetTimeMachine strategy work, keep durable Swift comparison/search code under `tools/`.
- For multi-asset backtests across gold/US equities/A-shares, use recent valid price forward-fill with enough holiday tolerance; do not accidentally delete dates because one market is closed.
- K-line charts must use real OHLC data. Do not fake OHLC from close-only series.
- User preference: no BTC in main AssetTimeMachine strategy line unless explicitly requested.
- User preference: use the product default 1.00% fee and 0.05% slippage for strategy research. Do not run multiple transaction-fee sensitivity tests unless the user explicitly requests them.
- User preference: keep all strategy cash strictly as RMB demand deposits using the existing `CashYieldCNY` model. Do not research or propose term deposits, money-market funds, reverse repo, cash ladders, or other cash-yield enhancement unless the user explicitly requests them. Focus strategy research on asset allocation and rebalancing execution logic.
- Hard rule: external fund sleeves/proxies are unavailable and meaningless for this project. Do not use, recommend, rank, compare, or revive strategies that depend on `qmnix`, `qmnrx`, `ostix`, `vmnfx`, `bprrx`, or similar off-App fund/proxy sleeves.
- User explicitly rejected all external fund-sleeve/proxy-asset based strategy lines as unusable/no-value. Treat them as dead ends, not as candidates, benchmarks, fallbacks, or evidence that a Sharpe-2 product strategy exists.
- Treat all prior fund-sleeve/proxy-fund metrics as invalid for current product decisions. Old Sharpe-2 research lines such as `internal_budget_ensemble`, `internal_experience_ensemble`, sparse/internal ensembles, and any descendants of the `qmnrx/ostix` fixture path must not be presented as viable AssetTimeMachine candidates.
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

- Latest TestFlight release: version `1.12` build `182`, Delivery UUID `f8c52358-5c21-4db1-8f79-0ceec6804bbc`, App Store Connect status `BUILD-STATUS: VALID`, artifact directory `build/TestFlight-1.12-182`.
- Build 182 ships the refined NFCI prospective-validation record in Quant: each frozen forward strategy opens its own validation evidence, shows retrospective robustness, factor evidence, preregistered cross-asset results, and server-backed append-only OOS progress. OOS milestones are scoped to the selected frozen strategy, and freeze date is distinguished from the ledger baseline signal date.
- Build 181 commits and packages the finalized NFCI forward-watch workflow, server forward-snapshot execution path, multi-series backtest share poster, and Time Machine selected-point value popover. The changed screens were recaptured on iPhone 17 Pro Max and archived under OneDrive `Changed-Pages-2026-08-15-build181`.
- Build 179 restores accounting clarity to the unified Time Machine chart: total assets, net assets, and liabilities use their actual CNY values on the left axis, while enabled gold and market benchmarks use relative change on the right axis. It also adds explicit scale copy, professional compact amount labels, accurate accessibility values, and preserves independent legend toggles without changing the pinned App-engine strategy baseline.
- Build 178 ships the latest generalized backtest and market-data support changes from `main`, including the expanded remote market parsing path and localization compatibility updates.
- Build 177 adds a polished Quant backtest share poster with strategy curves and key metrics, and consolidates Time Machine portfolio values plus optional gold and market indices into one indexed trend chart. Total assets, net assets, and liabilities are enabled by default; market benchmarks start disabled, every legend item can be toggled independently, and the obsolete standalone comparison charts are removed.
- Build 176 replaces scattered language preferences with one app-wide language store, applies language changes after the Settings selector dismisses, removes double-localization paths, and adds runtime format safeguards plus a mandatory localization audit to prevent future language-switch crashes. It also unifies Quant chart legend/zoom placement and colors, compacts record and Time Machine layouts, restores symmetric comparison controls and year-axis padding, and adds the App Store rating entry without changing the pinned App-engine strategy baseline.
- Build 175 unifies newly completed and saved Quant backtests on one full-screen result page, combines value and per-asset exposure charts behind shared legend and zoom controls, compacts result metrics and Quant entry spacing, and makes the Dashboard Today Strategy action navigate directly to Quant while removing the duplicate strategy sheet and obsolete fallback code. The pinned App-engine strategy baseline remains unchanged.
- Build 174 replaces the aggregate-only exposure timeline with per-asset allocation histories, a high-contrast multi-series chart, and a dashed total-exposure reference. New saved backtests persist bounded extrema-aware asset series while older records retain aggregate fallback compatibility; the pinned App-engine strategy baseline remains unchanged.
- Build 173 professionalizes 196 English localizations across strategies, backtests, DCA, assets, and financial-independence surfaces; standardizes financial terminology such as Sharpe ratio, drawdown, volatility, and cash; and prevents compact paired backtest labels from truncating. English, Simplified Chinese, and Traditional Chinese cold launches, localization audit, simulator visual QA, and Debug/Release builds all pass.
- Build 172 adds an actual daily total-exposure timeline to live and newly saved Quant backtests, preserves exact average exposure alongside an extrema-retaining sampled curve, and keeps the static chart clear of vertical-scroll gestures. It also compacts recent-backtest rows, adds a persistent eye toggle for zero-balance record assets, lets long asset names wrap cleanly, and removes redundant asset-selector subtitles without changing the pinned product-strategy baseline.
- Build 171 replaces the record system's fixed gold/crypto choice with a backend-derived market asset catalog grouped into indices, commodities, precious metals, and crypto. Custom account names such as bank or broker Nasdaq holdings can now bind explicitly to the same symbol used by daily advice; DCA and strategy backtests reuse the same categorized selectors, load newly selected history on demand, and convert USD, HKD, JPY, and USDT series consistently into CNY. It also adds symbol-specific icons and preserves legacy record/import compatibility without changing the pinned product-strategy baseline.
- Build 170 removes English truncation from Quant backtest rows, strategy-library badges, position headers, and the Time Machine period selector by using adaptive multi-line layouts instead of compressed text. It also completes the three-locale catalog audit and live strategy relocalization, hardens App/server backtest parity for strict date parsing, stale FX rejection, USD OHLC conversion, stateful range slicing, and saved curve round-trips, and adds the shared Swift worker package plus nine regression tests without changing the pinned product-strategy baseline.
- Build 169 replaces the indefinite daily-strategy spinner with real staged progress for market-data preparation, strategy target calculation, and current-position matching across the Quant page and dashboard strategy sheet. It also groups rotation executions by rebalance event and uses explicit buy, reduce, and exit action labels so recent-trade rows describe the actual operation instead of repeating a generic rebalance name.
- Build 168 replaces the Quant page's simplified strategy picker with the same searchable, tiered `AdvancedStrategyLibrarySheet` used by advanced backtests, while limiting daily advice to strategies that can produce portfolio target weights. It also removes the redundant market-source and next-trading-day footer blocks from the daily position advice surface, retaining only signal and portfolio-record dates; strategy calculations and the pinned App-engine baseline are unchanged.
- Build 167 makes rebalance actions follow the computed position delta, so an inferred current weight of zero and a positive target now produces `买入` instead of `未记录` when it clears the existing trade threshold; a truly missing portfolio snapshot still remains target-only. It also centralizes the curated product registry and shows a consistent `精选` badge in the Quant strategy selector, strategy library, Settings reminder selector, and Today Strategy surface without changing the pinned App-engine baseline.
- Build 166 reduces the strategy library to `精选` and `基础`, groups product strategies into `稳健` / `均衡` / `进取` tiers and basic strategies into `趋势` / `反转` families, adds mechanism-specific strategy icons, and flattens nested row chrome. It also ships higher-contrast current/target allocation colors, a privacy-safe eye toggle that hides operation amounts by default, concise product strategy names, and migration away from superseded research entries without changing the pinned App-engine baseline.
- Build 165 lets users switch the active daily-advice strategy directly from the Quant page, promotes `无杠杆低噪增强` as the first recommended choice, unifies the product strategy registry, and shares advice computation/cache across Quant, Dashboard, and notification flows.
- Build 164 adds a flat, compact daily position-advice surface to the Quant tab with current/target allocation donuts, aligned action rows, and market-data provenance; removes redundant labels and nested card chrome; restores visible foreground test notifications with precise permission/error feedback; and makes the low-noise strategy's weight aggregation deterministic across processes without changing its pinned product baseline.
- Build 163 adds the independent product strategy `无杠杆低噪增强`. On the 2026-08-10 pinned App-engine fixture it records 14.45% annualized return, 7.93% maximum drawdown, and 1.509 Sharpe after 1% fee and 0.05% slippage; 2020+ annualized return is 16.87% and 2022+ is 20.39%. The strategy uses strict T−1 signals, caps both target and actual gross exposure at 100%, never permits financed exposure or negative cash, and reduces unnecessary same-leader rebalancing with volatility-tiered turnover bands while allowing faster gold reweighting in extreme volatility.
- Build 162 removes the multi-second tab-switch stalls by stabilizing feature-store lifetimes, bounding mounted tab trees, moving dashboard/time-machine projections and backtest preparation off the main actor, and serializing deferred saves with destructive cloud reconciliation so responsiveness no longer trades away edit/import consistency.
- Build 161 further reduces chart and vertical-scroll jank by avoiding per-render date-array allocation, caching sampled points, axes, domains, and summary metrics, lazily mounting detail charts, deferring refresh work during scrolling, and resolving horizontal gesture intent before chart scrubbing begins.
- Build 160 reduces chart interaction jank by deduplicating and sampling rendered points, using nearest-point binary lookup, bounding mounted tabs, and allowing horizontal chart scrubbing only after horizontal intent wins so vertical page scrolling remains responsive.
- Build 156 upgrades the existing `无融资置信度恢复` entry with strict-T−1 online calibration of leadership-transition reliability. After each gold, Nasdaq, S&P 500, or China-equity leadership handoff, the next 10 sessions update a Beta(2,2) posterior; future transitions execute at least 50% and approach full migration as realized reliability improves, while risk reductions and cash exits remain immediate. On the pinned App-engine fixture it records 11.18% annualized return, 7.24% maximum drawdown, and 1.499 Sharpe after 1% fee and 0.05% slippage; since-2020, recent-10Y, and since-2022 Sharpe are 1.494, 1.347, and 1.546, with gross exposure capped at 100% and no negative cash days.
- Build 155 replaces the existing `无融资置信度恢复` implementation under the same strategy ID and catalog entry. On the pinned App-engine fixture it records 11.30% annualized return, 7.25% maximum drawdown, and 1.489 Sharpe after 1% fee and 0.05% slippage; since-2020, recent-10Y, and since-2022 Sharpe are 1.480, 1.333, and 1.532. It also ships the neutral graphite / warm ivory visual-system refinement, calmer SF Pro hierarchy, simplified strategy-library rows, and keyboard-dismiss improvements.
- Build 154 fixes the strategy-library catalog so `无融资置信度恢复` is visible in `策略大全`; strategy logic and pinned metrics are unchanged from build 153.
- Build 153 refines `无融资置信度恢复` with low-confidence A-share pruning, a mature Nasdaq light brake, and low-gross Nasdaq residual cleanup. On the pinned App-engine fixture it records 11.01% annualized return, 7.41% maximum drawdown, and 1.341 Sharpe after 1% fee and 0.05% slippage; since-2020, recent-10Y, and since-2022 Sharpe are 1.347, 1.200, and 1.375 respectively, with executed gross exposure capped at 100% and no negative cash days.
- Build 152 unifies the app palette around neutral graphite / warm ivory surfaces with restrained champagne-gold accents, reduces card shadow weight, and replaces the rounded display type system with a calmer SF Pro hierarchy across shared typography, dashboard charts, snapshot metrics, and time-machine charts.
- The app base API should return from `https://api.flyingrtx.com`.
- If market-data freshness looks wrong, separate these layers before fixing:
  - app cache / `RemoteMarketStore.historySeries`
  - public history endpoint response
  - backend daily history table
  - latest price cache
  - upstream provider behavior
- Production server access and backend deployment details may use private credentials. Do not infer or expose secrets; use existing local config or ask the user.
