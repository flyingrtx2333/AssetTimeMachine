# Variance Risk Premium Proxy V1

**Date:** 2026-08-21  
**Protocol:** ATM-SVP-2  
**Trial:** ATM-SVP2-VRP-001  
**Evidence:** R1_RETROSPECTIVE  
**Base strategy:** frozen `nfci-dual-core-v11 / dualcore-v11-2026-08-15`

## Purpose

Test one deliberately narrow, literature-motivated return-premium hypothesis after the stress-resolution family failed. This is a new mechanism, not a threshold/source/lookback rescue of any prior event factor. There is exactly one candidate and no parameter grid.

The economic premise is that the variance risk premium — option-implied variance minus subsequent/realized variance — contains information about expected equity returns. The canonical academic measure uses model-free option-implied variance and high-frequency realized variation. AssetTimeMachine does not currently have the required intraday option/realized-variance archive, so this trial explicitly tests a **daily-data proxy**, not the canonical VRP measure.

## Frozen candidate — F-VRP-PROXY

### Factor definition

Inputs available by frozen V11 signal date:

- FRED `VIXCLS`, using the latest finite close with `observation_date <= signal_date` and at most 7 calendar days stale;
- frozen S&P 500 sleeve price series from `generalization_public_history.json`.

For market session `t`:

1. daily log return: `r_t = ln(P_t / P_{t-1})`;
2. 21-session annualized realized variance: `RV21_t = (252 / 21) * sum(r_i^2, i=t-20..t)`;
3. implied variance proxy: `IV_t = (VIX_t / 100)^2`;
4. daily VRP proxy: `VRP_t = IV_t - RV21_t`;
5. compute the median of the **previous 252 valid market-session VRP proxy observations**, excluding `t`;
6. `risk_on = VRP_t > trailing_252_median`.

No alternative 10/20/30/63-day realized window, no mean/z-score/quantile other than the frozen previous-252 median, and no threshold optimization are permitted.

### Portfolio action

- Only frozen V11 trade execution dates are eligible.
- Candidate is eligible only when current frozen V11 positive gross is strictly between 0 and 100%.
- If factor is unavailable or `risk_on == false`, use frozen V11 target unchanged.
- If `risk_on == true`, fill exactly **50% of the currently unused gross budget**, allocated pro rata across the current positive frozen V11 holdings.
- Gross remains <=100%; no leverage, financing, shorting or negative weights.
- No factor-driven trades between frozen V11 events.
- Research costs remain 1.00% fee + 0.05% slippage.
- Replay rebalance band remains 25%.

### Matched control

`C-VRP-ALWAYS`: whenever the VRP proxy is available at an eligible underinvested V11 event, fill exactly 50% of unused gross regardless of VRP state. This isolates timing information from the mechanical effect of using more risk budget.

## Fixed evaluation windows

Use the same seven frozen folds:

1. 2012-07-05..2014-12-31
2. 2015-01-01..2016-12-31
3. 2017-01-01..2018-12-31
4. 2019-01-01..2020-12-31
5. 2021-01-01..2022-12-31
6. 2023-01-01..2024-12-31
7. 2025-01-01..latest

Also report full history, 2020+, and 2022+.

## Deterministic admission gates

F-VRP-PROXY is `ADMIT_FOR_ROBUSTNESS` only if all pass:

1. full CAGR >= frozen V11 CAGR + 0.50 percentage points;
2. full Sharpe >= frozen V11 Sharpe;
3. full Sharpe > C-VRP-ALWAYS Sharpe;
4. full MDD <=10%;
5. at least 5/7 fixed folds have candidate Sharpe >= matched-control Sharpe;
6. worst fixed-fold Sharpe >0;
7. gross/no-short/no-negative-weight constraints pass.

## Frozen statistical audit

Regardless of deterministic admission, run:

- paired circular moving-block bootstrap, block=63 sessions, 20,000 replicates, seed 20260821;
- `P(CAGR_candidate > CAGR_V11) >= 0.90`;
- `P(Sharpe_candidate > Sharpe_matched) >= 0.90`;
- median candidate-minus-V11 CAGR delta >0;
- median candidate-minus-matched Sharpe delta >0;
- candidate bootstrap MDD P97.5 <=15%;
- no family PBO is reported because this trial has exactly one candidate and no within-family selection;
- global post-protocol DSR must include the prior 24 formal return-seeking candidates plus F-VRP-PROXY, for a total of 25 trials; DSR probability >=95% is required.

`ROBUST_FACTOR_PASS` requires deterministic admission, every bootstrap gate, and global 25-trial DSR >=95%.

## Stop rule

This campaign contains exactly one candidate. After formal results are viewed:

- no alternative realized-volatility window;
- no alternate VRP threshold or percentile;
- no 25%/75%/100% completion fraction;
- no VIX/VIX3M substitution or ensemble;
- no candidate replacement;
- no second retrospective VRP-proxy family.

A promising but non-robust result may only be frozen as a prospective shadow from a new date. A future canonical VRP study using model-free implied variance plus intraday realized variance would be a materially new dataset/methodology and must be preregistered separately.
