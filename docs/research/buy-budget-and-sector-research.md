# Explicit research allocation and monthstart screen

Production `BacktestDailySimulator` retains `symbolOrder` by default. `proportionalGap` is an explicit research counterfactual: compute eligible positive buy shortfalls after sales, allocate settled pre-sale cash proportionally, retain fees/slippage and pending settlement, and reject financing. No public strategy or server request enables this automatically.

Research CLI:

```text
industry-trend-screen --etfs INPUT --history HISTORY --output FRESH_DIRECTORY --source-commit COMMIT --buy-budget-policy proportional-gap-v1
sector-monthstart-screen --sectors INPUT --history HISTORY --output FRESH_DIRECTORY --source-commit COMMIT
```

Both reject existing output directories and retain daily states, fills, inputs/binary hashes and evidence. The industry command has exactly one fixed candidate and three controls; only its two industry rows use the allocation experiment.

The sector screen has exactly one fixed long-only post-monthstart candidate, opposite-ranking falsification, same-window all-sector calendar control and initial equal-capital sector buyhold. Its frozen nine-sector price ranks use 252 previous observed sessions at the last close before the new month. After observing D1, enter D2 open; after observing D3, exit D4 open. No future holiday calendar or signal-day close execution. Cash is CashYieldCNY; fees0.025% perfill, no leverage. FX is strictly earlier calendar-date, max14days, and shared by open/close marks. Missing data throws.

Outputs are D0 price-only adaptations, not full shareholder total returns or formal validation. No cash dividends, broker lot/minimum order or FX wallet acceptance. Full metrics include initial NAV; slices retain a preceding real state. No parameter search or published-strategy promotion.

Tests cover unchanged default path, equal-budget rename symmetry, settlement, fees/accounting, prefix/future disturbances, prior-month rank, fixed holding window, invalid inputs and past-only FX. The initial Release package run was observed passing153core+3worker; its temporary logfile is no longer available. The retained repeat is qualified below. Saved prior/new industry replay has one extra rounding-sized dust fill, despite NAV error below5.24e-10CNY and material trade agreement. Strict complete-list parity remains unaccepted; retain the default and old evidence. Do not suppress small orders post-hoc to claim migration acceptance.

Evidence is in FlyingrtxFast research workspace studies `industry-allocation-counterfactual-2026-10-06` and `sector-monthstart-reversal-2026-10-06`. Quote/unit/cash audits only inspect saved Swift outputs.

Evidence recovery recheck:153core pass; worker timeout test once failed to observe startup PID within2s, unchanged-source isolated recheck passed. Preserve failed/full and recheck receipts; all-package repeat was not clean. No worker source fix or rollout claimed.
