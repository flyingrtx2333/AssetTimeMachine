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
