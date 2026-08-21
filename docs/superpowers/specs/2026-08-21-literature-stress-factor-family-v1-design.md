# Literature-Motivated Stress Resolution Factor Family V1

**Date:** 2026-08-21  
**Protocol:** ATM-SVP-2  
**Trial:** ATM-SVP2-LIT-STRESS-001  
**Evidence:** R1_RETROSPECTIVE  
**Base strategy:** frozen `nfci-dual-core-v11 / dualcore-v11-2026-08-15`

## Purpose

Open one new, explicitly separate literature-motivated research campaign after the earlier six-family retrospective factor-discovery campaign closed. This family is selected from economic mechanisms before observing any AssetTimeMachine performance for these exact rules. It is not a rescue/retune of F-BREADTH, F-HIGHBETA, F-CREDITCASH, F-VIXTERM, F-VVIX, or any other prior candidate.

The question is narrow: when frozen V11 itself decides to de-risk, can an independent stress-resolution indicator identify cases where V11 is cutting exposure too early, while preserving V11-like risk-adjusted quality?

## Frozen common architecture

- Source strategy remains frozen V11.
- Formal events are unique execution dates where frozen V11 records a trade.
- A de-risk event is an event where at least one positive target weight falls versus the prior V11 event target.
- Candidate factor observations must be available no later than the V11 signal date under the source-specific availability rule below.
- If the factor is risk-on on a de-risk event, retain exactly **50%** of each asset reduction from prior V11 event target to current V11 event target, capped at 100% gross.
- If factor is risk-off or unavailable, use the current V11 target unchanged.
- Each candidate has its own matched availability control that retains 50% on every factor-available V11 de-risk event.
- No factor-driven trades between V11 event dates.
- Research cost remains 1.00% fee + 0.05% slippage.
- No leverage, financing, shorting, negative cash, or gross above 100%.
- Replay rebalance band remains 25%.

## Frozen candidates

### F-BAA — corporate credit stress resolution

Source: FRED `BAA10Y`, Moody's Seasoned Baa Corporate Bond Yield relative to 10-Year Treasury.

Rule:

- Use the latest finite source observation with `observation_date < signal_date`; same-day FRED values are deliberately excluded to avoid publication-time ambiguity.
- Maximum staleness: 7 calendar days.
- Compare with the observation 20 source observations earlier.
- `risk_on = current_BAA10Y <= BAA10Y_20obs_ago`.

Economic interpretation: corporate credit compensation is not widening; the credit channel is not confirming additional stress.

### F-EPU — policy uncertainty resolution

Source: FRED `USEPUINDXD`, daily U.S. Economic Policy Uncertainty Index.

Rule:

- Use the latest finite source observation with `observation_date < signal_date`; same-day observations are excluded because the daily index is published after its observation date.
- Maximum staleness: 7 calendar days.
- Compare with the observation 20 source observations earlier.
- `risk_on = current_EPU <= EPU_20obs_ago`.

Economic interpretation: policy/news uncertainty is not worsening over roughly one source month.

### F-MOVE — Treasury volatility resolution

Source: Yahoo `^MOVE`, ICE BofA MOVE Index close.

Rule:

- Use the latest finite close with `observation_date <= signal_date`.
- Maximum staleness: 7 calendar days.
- Compare with the close 20 source observations earlier.
- `risk_on = current_MOVE <= MOVE_20obs_ago`.

Economic interpretation: Treasury-market option-implied volatility is not worsening, so bond-market fear does not independently confirm the V11 de-risk event.

## Fixed evaluation windows

Use the same seven frozen folds used by V11 research:

1. 2012-07-05..2014-12-31
2. 2015-01-01..2016-12-31
3. 2017-01-01..2018-12-31
4. 2019-01-01..2020-12-31
5. 2021-01-01..2022-12-31
6. 2023-01-01..2024-12-31
7. 2025-01-01..latest

Also report full history, 2020+, and 2022+.

## Admission gates

A candidate is `ADMIT_FOR_ROBUSTNESS` only if all deterministic historical gates pass:

1. full CAGR >= frozen V11 CAGR + 0.50 percentage points;
2. full Sharpe >= frozen V11 Sharpe;
3. full Sharpe > its own matched availability control Sharpe;
4. full MDD <= 10%;
5. at least 5/7 fixed folds have candidate Sharpe >= its matched-control Sharpe;
6. worst fixed-fold Sharpe > 0;
7. gross/no-short/no-negative-weight constraints pass.

Historical admission is not sufficient for certification. All three candidates, whether admitted or not, must then be subjected to the same fixed statistical audit:

- paired circular moving-block bootstrap, block=63 sessions, 20,000 replicates, RNG seed 20260821;
- `P(CAGR_candidate > CAGR_V11) >= 0.90`;
- `P(Sharpe_candidate > Sharpe_matched) >= 0.90`;
- median candidate-minus-V11 CAGR delta > 0;
- median candidate-minus-matched Sharpe delta > 0;
- candidate bootstrap MDD P97.5 <= 15%;
- family CSCV/PBO using 8 equal chronological blocks, PBO <=20%;
- DSR must be reported using all three candidates in this family;
- a second conservative DSR must be reported using all post-protocol formal return-seeking candidates from HR-A/B/C, F-CURVE through F-CREDITCASH, plus all three candidates in this family. No failed trial may be dropped from this inventory.

A candidate may be called `ROBUST_FACTOR_PASS` only if deterministic admission, bootstrap gates, family PBO gate, family DSR >=95%, and global post-protocol DSR >=95% all pass.

## Stop rule

This is the **only** retrospective factor family in this new literature-motivated campaign. After its results are opened:

- no candidate replacement;
- no 10/30/60/120-day lookback search;
- no threshold/percentile/z-score/persistence search;
- no source substitution;
- no 25%/75% retention search;
- no factor combination or voting ensemble;
- no alternative event definition;
- no additional retrospective family under this campaign.

A failed candidate remains failed. A promising but non-robust candidate may only be frozen into a new prospective trial from a new freeze date. A genuinely new externally motivated hypothesis requires a separately declared future campaign and remains subject to cumulative G3 trial accounting.
