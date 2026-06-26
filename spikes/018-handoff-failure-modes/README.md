# Handoff Failure Modes

This spike diagnoses the remaining failure modes after the current strongest
gold handoff protection, then tests logic-first overlays on the App-equivalent
Python backtest.

Run:

```sh
/opt/miniconda3/bin/python3.13 -B spikes/018-handoff-failure-modes/handoff_failure_modes.py
```

Data cutoff: 2026-06-19.

## Current Champion

`current_gold_handoff`

- Full: 12.44% annualized / 9.76% max drawdown / Sharpe 1.2026
- Post-2020: 13.67% / 9.08%
- Last 10y: 11.52% / 9.08%
- Post-2024: 22.57% / 7.36%

The main remaining drawdown window is 2007-01-24 to 2007-08-16. The strategy
entered the window with roughly 61% Shanghai Composite plus 20% gold, then later
rotated into roughly 64% Nasdaq. This is not primarily a gold handoff issue; it
is an extreme regional-equity heat and cross-market handoff issue.

After equity heat is capped, the next exposed drawdown is 2003-02-04 to
2003-04-07, when the strategy held roughly 87% gold. The preceding 2002-12-09
rebalance bought a large gold sleeve with gold near its one-year high but with
only moderate 90-day momentum, so a pure rollover guard triggers too late.

## Best New Candidate

`dual_position_caps_eq50_gold75`

Logic:

- Keep current gold-to-confirmed-US handoff.
- If any equity cluster is in extreme long-term heat, cap total equity exposure
  at 50%.
- If gold is near its one-year high and has moderate 90-day momentum, cap gold
  at 75%.

Result:

- Full: 12.26% annualized / 9.14% max drawdown / Sharpe 1.2139
- Post-2020: 13.50% / 9.08%
- Last 10y: 11.41% / 9.08%
- Post-2024: 22.08% / 6.58%

This is not stronger on raw annualized return, but it is the strongest risk
quality candidate found in this spike: max drawdown improves by about 0.63pp and
Sharpe improves while annualized return gives up about 0.18pp.

## Rejected Directions

- Fixed shorter rebalance cadence is worse. 20/30/45-session rebalancing
  increases drawdown or materially lowers return.
- Heat-triggered adaptive rebalance is also worse in this implementation. It
  introduces new drawdown windows in 2026 or 2011-2012.
- Handoff target tweaks such as S&P-only, both-US-confirmed, and extra
  replacement-asset quality filters do not beat the current handoff.
- Gold-only crowded caps reduce recent drawdown but give up too much return
  unless paired with the equity heat cap.

## Product Takeaway

Current "黄金交接保护" remains the strongest return-first strategy. The best
next candidate is a "dual crowded-position guard": protect against both A-share
style equity heat and gold safe-haven crowding while preserving the existing
gold handoff.
