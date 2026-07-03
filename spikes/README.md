# AssetTimeMachine Strategy Spikes Index

This directory contains research experiments. Files under `spikes/` are **not** product code and must not be treated as App-verified strategy evidence unless explicitly promoted through the replay pipeline.

## Current product/app status

- Current App default strategy baseline: **pending dump**.
  - Before splitting `BacktestEngine.swift`, replace `tools/expected_backtest_metrics/app/current_app_default_pending.json` with concrete App-engine metrics.
- Current research champion: `345-gold-repair-refine`.
- Current App-equivalent replay target: `345-gold-repair-refine`.
- No new research result is allowed to become a product/default strategy without App-equivalent replay and regression metrics.

## Promotion pipeline

A strategy must move through these states before productization:

1. `ResearchOnly` — spike/prototype only.
2. `PythonVerified` — exact Python replay with fixed parameters.
3. `SwiftReplayVerified` — Swift replay agrees with research result.
4. `AppEquivalentVerified` — App engine/data path reproduces expected metrics.
5. `WalkForwardVerified` — out-of-sample / stability check is acceptable.
6. `ProductCandidate` — eligible for strategy lab / advanced UI.
7. `ProductDefault` — eligible for the simple user-facing default tiers.

Hard rule: **Python research results are not product claims.**

## Active strategy state

### 344-gold-drawdown-repair

- Status: `PythonVerified`, **direction validation only**.
- Role: proved that the old incumbent's largest drawdowns were dominated by the gold sleeve and that gold-sleeve drawdown repair is a valid mechanism family.
- Result snapshot:
  - Full: CAGR `8.44%`, Max DD `-10.93%`, Sharpe `0.9792`
  - 2020+: `12.60% / -10.93%`
  - 10y: `10.59% / -10.93%`
- Superseded by: `345-gold-repair-refine`.
- Expected metrics: `tools/expected_backtest_metrics/research/344_gold_drawdown_repair_python.json`

### 345-gold-repair-refine

- Status: `PythonVerified`, **current research champion**, pending App-equivalent replay.
- Role: current main verification target.
- Result snapshot:
  - Full: CAGR `8.72%`, Max DD `-10.53%`, Sharpe `1.0027`
  - 2020+: `13.82% / -9.71%`
  - 10y: `11.29% / -9.71%`
  - 2022+: `11.94% / -9.19%`
  - Latest target weights: gold `0.22`, nasdaq `0.1365`, sp500 `0.4135`
- Must not become product/default until App-equivalent replay passes.
- Expected metrics: `tools/expected_backtest_metrics/research/345_gold_repair_refine_python.json`
- Parity target: `tools/expected_backtest_metrics/parity/345_gold_repair_refine_parity_target.json`

### 346-stable-gold-regime-logic

- Status: rejected / archived.
- Purpose: test whether better-looking gold-repair variants were stable logic clusters rather than cherry-picked parameter points.
- Verdict: no stable cluster beat 345.
- Important note: an individual outlier looked strong, but the cluster hit rate was weak (`3/140 = 2.1%`), so it was **not promoted**.
- Verdict file: `tools/expected_backtest_metrics/research/346_stable_gold_regime_logic_verdict.json`

### 347-dual-stress-brake

- Status: rejected / archived.
- Purpose: test whether a new dual-stress brake improved results when both gold and equities were under stress.
- Verdict: no promotion as a new logic.
- Reason: top numeric rows had only `1-2` brake days; the new mechanism did not materially drive the result under the stricter gate.
- Verdict file: `tools/expected_backtest_metrics/research/347_dual_stress_brake_verdict.json`

## Research rules from this point forward

Do not add new App strategies directly to `BacktestEngine.swift`.

New research must stay in one of:

- `spikes/`
- `tools/`

Every new spike should state:

- economic hypothesis;
- whether future information/oracle labels are used;
- fixed promotion threshold;
- stability or cluster check if parameters are searched;
- App-equivalent replay plan if it passes;
- final verdict in that spike's `README.md`.

Reject by default:

- future oracle selectors;
- calendar/date-bucket tricks without walk-forward validation;
- single-window winners;
- single-parameter spikes without stability evidence;
- Python-only results that cannot be replayed by the App engine.

## Before Backtest refactor

Before splitting `BacktestEngine.swift`, complete the app-side golden metrics dump:

- current App default strategy;
- current App engine major strategies;
- 345 App-equivalent replay target once implemented.

The placeholder is currently:

- `tools/expected_backtest_metrics/app/current_app_default_pending.json`

Do not remove the placeholder until concrete App-engine metrics replace it.
