# iOS interface polish — 2026-10-24

Scope: refine the existing black/gold and light/gold interface, without changing authentication, persistence, synchronization reconciliation, strategy parameters or calculation algorithms.

## Changes

- Shared `ATMActionButtonStyle`: primary/secondary hierarchy, 48pt minimum height, wrapping labels, disabled/pressed feedback and Reduce Motion support. Applied to cloud recovery/export, backtest actions, recording onboarding, expense entry and trend-video generation.
- Cloud actions are separate from backup history; ownership confirmation identifies the destination account. Empty backup copy no longer promises a sync that may be blocked. Export shows progress.
- Dashboard cloud status is a short, identifiable control with the full status available to accessibility.
- Settings keeps one cloud entry and one strategy selection row. Language selection can expand and has a Done action.
- Expense entry and existing rows adapt to available width and Dynamic Type. Amount inputs retain useful width; frequency labels remain readable. English item-count wording handles one and many items.
- Record editing, date controls, refresh, privacy and share actions have at least 44pt iPhone hit regions inside their labels. Historical backtests use Button semantics instead of a tap gesture.
- Redundant onboarding/empty-state instructions removed. Important overwrite, risk and fee disclosures retained.
- Quant has an explicit no-result state instead of silently showing only its heading.

## Verification

- iOS simulator build passed. Final captures use Debug configuration with `SWIFT_OPTIMIZATION_LEVEL=-O`, including the shared backtest package, while retaining Debug-only screen navigation.
- Localization audit and whitespace checks passed.
- Actual SwiftUI renders inspected on an isolated iPhone 17e simulator, iOS 26.5, 1170 × 2532 pixels (390 × 844 points). Used `demo/time-machine-demo.json`; no personal account or live cloud writes.
- Local captures: `evidence/ui-polish-20261023/`. Includes Chinese dark settings, records, quant, home, language/cloud sheets; light Time Machine; English accessibility-medium settings and expenses. Captures represent individual states, not all possible screen contents.
- Debug-only `-previewSettingsSheet cloud|language|expenses` enables direct navigation for these captures. It neither mocks nor mutates account state.

## Limits and existing findings

- Live signed-in cloud recovery/export and destructive actions were not exercised. Their handlers and reconciliation logic remain unchanged. No TestFlight upload or native macOS installation was performed.
- Unoptimized Debug exposed an existing stack overflow in `advancedRotationConfig(for:)` during strategy-registry initialization: approximately 482 KiB stack frame on a 544 KiB cooperative thread. Optimized build renders Quant successfully; no strategy refactor is included here.
- A first advice calculation can be invalidated when market inputs change; the existing store then returns without a result, and its automatic retry requires an earlier result. The UI now shows the no-result state with the existing refresh control. Recalculation scheduling is unchanged.
- Screenshots verify layout. They do not establish complete VoiceOver traversal, keyboard interaction, press animation quality or live account behavior.

## Release integration

- Merged the latest committed macmini branch through `ffada8e`, including the chart changes shipped in build 214. Fixed the selection overlay so clearing selection dismisses the value popover while the date navigator retains its last-date fallback.
- Imported the completed deterministic V4 calculation fix and its verification helper from macmini. All five files match the existing successful run's SHA256 bindings; see `integrated-calculation-fix.json`. This release therefore includes calculation stability changes as well as interface refinements.
- Existing evidence covers the pair strategy and matched parent, including full and physically truncated inputs. It does not certify every strategy, out-of-sample performance or point-in-time data quality. The research checkout is not modified by this release process.
- Target TestFlight version: `1.14 (215)`. Publication status is recorded separately in the release receipt after Apple processing completes.
