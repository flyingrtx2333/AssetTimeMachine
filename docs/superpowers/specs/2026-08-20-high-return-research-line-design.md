# High-Return Research Line Design

## Purpose

Create a new research lineage that targets a long-run net CAGR in the 18–22% region without modifying frozen `nfci-dual-core-v11` / `dualcore-v11-2026-08-15`.

The research question is not “how do we force CAGR to 20%?” It is:

> Can a low-complexity, preregistered combination of multi-timescale trend information and more complete use of the existing 100% risk budget materially raise net CAGR while preserving strong Sharpe, controlled drawdown, no leverage, no shorting, and realistic 1.00% fee + 0.05% slippage?

Increased trading frequency is treated as a mechanism to test, not an optimization target.

## Governance

- Current research governance: `ATM-SVP-2`.
- V11 is a frozen control only. No V11 parameter, target-path rule, NFCI threshold, 1.22 scale, 25% band, or 50/50 core weight may change.
- This is a new lineage: `high-return-architecture-v1`.
- First formal family contains exactly three candidates. V11 control metrics are reported but do not count as a candidate.
- No parameter grid is allowed in round 1.
- No candidate may be replaced after results are viewed.
- Failed candidates remain in the trial ledger and count toward future DSR / multiple-testing accounting.
- Any round-2 research must be a new preregistered trial family and may not be justified merely by “round 1 almost passed.”

## Fixed Execution Assumptions

- Assets: current five V11 economic roles only: `gold_cny`, `nasdaq`, `sp500`, `csi300`, `shanghai_composite`.
- Cash: existing RMB demand-deposit `CashYieldCNY` model.
- Fee: 1.00%.
- Slippage: 0.05%.
- Maximum gross exposure: 100%.
- Negative cash: forbidden.
- Shorting: forbidden.
- Financing/leverage: forbidden.
- Signals: strict T-1.
- Point-in-time NFCI: only through the frozen V11 control/target path where applicable.

## Candidate Family

### HR-A — Multi-timescale trend allocator

Goal: test whether modestly faster information capture adds net alpha after costs without relying on V11’s full target path.

For each of the five role assets, at T-1 compute four simple total-return signs:

- 20 sessions
- 60 sessions
- 120 sessions
- 252 sessions

Trend score is the fraction of those four horizons with positive return, so the score is one of `0, 0.25, 0.50, 0.75, 1.00`.

Eligibility requires score >= 0.75. Eligible assets are ranked by:

`trend_score / max(60-session annualized volatility, 8%)`

Keep at most the top two eligible assets. Allocate among them in proportion to the same score/volatility quantity, normalized to at most 100% gross. If fewer than two are eligible, unused capital remains RMB cash.

Execution review cadence is every 10 common simulator sessions. A 15% absolute target-weight band is required before trading. These two natural values are fixed before formal execution and are not searched.

Interpretation: this is the only round-1 candidate whose entire return engine is faster/more active. It is the direct test of “does more frequent trend updating create useful net alpha?”

### HR-B — V11 state-conditioned risk-budget completion

Goal: test whether V11 leaves too much cash unused during unusually broad, persistent risk-on states.

Start from the exact frozen V11 T-1 target weights.

At T-1 compute a breadth vote across the five role assets. An asset votes risk-on when both its 60-session and 120-session returns are positive. Let `breadth` be the number of risk-on assets.

If `breadth >= 4` and V11 gross exposure is below 100%, scale all positive V11 risky-asset target weights proportionally so total gross reaches 100%. Do not create a position in an asset that V11 currently targets at zero. Gold participates exactly like any other positive V11 holding.

Otherwise, use the frozen V11 target unchanged.

No additional defensive rule is added; V11 remains responsible for de-risking. Review every 10 common simulator sessions and use the existing frozen 25% hard band for execution.

Interpretation: this tests whether higher CAGR can come from fuller use of the existing risk budget in high-confidence states, rather than simply trading more often.

### HR-C — 50/50 architecture blend

Goal: test whether an independent faster trend allocator and V11’s macro-aware target path provide complementary return sources.

At each T-1 decision point:

- 50% of target weight comes from HR-A.
- 50% comes from HR-B.
- Combine by role symbol.
- Normalize only if gross would exceed 100%.
- Negative weights are forbidden.

Review every 10 common simulator sessions. Use a 20% absolute target-weight execution band, fixed before the formal run.

Interpretation: this is not a searched ensemble weight. `50/50` is the single preregistered neutral blend.

## Why No Faster Grid

Round 1 deliberately does **not** test 5/10/15/20-day review intervals, many trend windows, or many rebalance bands. Doing so would answer “which parameter looked best historically,” not whether the underlying architecture adds robust alpha.

If HR-A fails, “try every faster cadence until one works” is forbidden.

## Evaluation

All three candidates and the V11 control must be produced by Swift research code and the shared `BacktestDailySimulator` path.

Report:

- CAGR
- maximum drawdown
- annualized volatility
- Sharpe
- trade count
- average cash ratio
- target fingerprint
- seven fixed time folds
- 2020+ and 2022+ slices
- target gross/negative-weight constraint checks

The seven folds are frozen before any candidate execution and reuse the V11 validation ranges exactly:

1. `2012-07-05..2014-12-31`
2. `2015-01-01..2016-12-31`
3. `2017-01-01..2018-12-31`
4. `2019-01-01..2020-12-31`
5. `2021-01-01..2022-12-31`
6. `2023-01-01..2024-12-31`
7. `2025-01-01..latest`

### Round-1 admission gate

A candidate is `ADMIT_FOR_ROBUSTNESS` only if all are true:

- full-history CAGR >= 16.0%
- full-history Sharpe >= 1.40
- full-history MDD <= 12.0%
- CAGR exceeds frozen V11 by at least 1.5 percentage points
- at least 5/7 time folds have Sharpe > 1.0
- worst-fold Sharpe > 0
- no leverage / negative cash / negative target weights
- all results are net of 1.00% fee + 0.05% slippage

This is intentionally weaker than the aspirational 18–22% target. It is only permission to run a separate robustness protocol; it is not product acceptance.

### High-return target flag

A candidate receives `TARGET_REGION` only if:

- CAGR >= 18.0%
- Sharpe >= 1.45
- MDD <= 12.0%
- and it also passes every admission gate above.

A 20% CAGR is **not** a hard threshold and must not be optimized to exactly.

## Next Stage If Admitted

Any admitted candidate must enter a separate preregistered robustness family before App consideration:

- parameter/structure perturbation without winner selection
- moving-block bootstrap
- PBO/DSR with complete post-protocol candidate accounting
- execution-stress test
- role-preserving G4-style holdout where applicable
- new strategy version and prospective OOS clock if productized

## Failure Semantics

- If none of HR-A/B/C is admitted, round 1 is a valid negative result.
- No candidate can be renamed or quietly altered after results are seen.
- A new idea is allowed only as a separately preregistered family with its own hypothesis and candidate budget.
- “Higher frequency failed” is a useful result; it must not trigger a cadence sweep on the same family.
