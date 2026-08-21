# FINRA Margin Leverage Factor V1

**Date:** 2026-08-21  
**Protocol:** ATM-SVP-2  
**Trial:** ATM-SVP2-MARGIN-001  
**Evidence:** R1_RETROSPECTIVE  
**Base strategy:** frozen `nfci-dual-core-v11 / dualcore-v11-2026-08-15`

## Purpose

Test one new public leverage/sentiment information domain after COT positioning failed. FINRA margin statistics directly measure aggregate customer margin debit and free credit balances rather than deriving another signal from market prices.

Prior research generally finds margin borrowing is strongly related to past stock returns and investor sentiment; evidence from other margin-trading markets also suggests margin activity can contain predictive information, although the sign and horizon are not structurally guaranteed. This trial therefore fixes one simple risk-appetite interpretation before performance is viewed and does not search alternate signs or transforms.

## Frozen data scope

Source: FINRA Margin Statistics official rolling XLSX.

Use only the unified FINRA Rule 4521-era rows from **2010-02 onward**. Earlier rows are intentionally excluded because through January 2010 NYSE and FINRA collected similar data separately and combined free-credit fields differently. The trial will not synthesize a pseudo-unified pre-2010 history.

Frozen current coverage: 2010-02 through 2026-07.

## Frozen point-in-time availability

FINRA states that Margin Statistics are generally published in the **third week of the month following the reference month**. Exact historical publication timestamps are not provided.

To avoid look-ahead, each reference month `YYYY-MM` becomes usable only on the **first calendar day of the second following month**:

- January data -> March 1;
- February data -> April 1;
- ...

This is deliberately later than FINRA's stated normal publication window.

A factor observation is valid for at most **35 calendar days after its conservative available date**. Because valid observations are scheduled on the first day of each month, 35 days covers the normal 28–31 day cadence but causes the factor to become unavailable if a monthly update is missing.

## Frozen factor — F-MARGIN-LEV-US

For each unified reference month `t`:

- `Debit_t = Debit Balances in Customers' Securities Margin Accounts`;
- `Free_t = Free Credit Balances in Customers' Cash Accounts + Free Credit Balances in Customers' Securities Margin Accounts`;
- `MarginLeverage_t = Debit_t / Free_t`;
- `DeltaMarginLeverage_t = MarginLeverage_t - MarginLeverage_(t-1)`;
- once month `t` is conservatively available, `risk_on = DeltaMarginLeverage_t > 0`.

There is no z-score, percentile, market-cap normalization, real/inflation adjustment, multi-month window, absolute debt threshold or sign reversal.

Economic interpretation: increasing customer debit relative to immediately available free credits is a direct rise in aggregate securities-account risk-taking/leverage. The fixed hypothesis is that this confirms continued U.S.-equity risk appetite when frozen V11 begins to de-risk.

## Frozen portfolio action

The factor cannot create independent trades.

- Formal events are unique execution dates where frozen V11 records a trade.
- Compare the current V11 event target with the prior V11 event target.
- An eligible U.S. de-risk event occurs only when V11 reduces `nasdaq` and/or `sp500` target weight.
- If factor is unavailable or risk-off, use current V11 target unchanged.
- If factor is risk-on, retain exactly **50%** of each `nasdaq` / `sp500` reduction.
- Gold and China sleeves are never altered by the margin factor.
- Gross <=100%; retained U.S. reductions are mechanically scaled if remaining capacity is insufficient.
- No leverage, financing, shorting, negative cash or negative target weights.
- No factor-driven trades between V11 event dates.
- Research cost remains 1.00% fee + 0.05% slippage.
- Replay rebalance band remains 25%.

### Matched availability control

`C-MARGIN-LEV-ALWAYS` retains the same 50% of U.S.-equity reductions on **every** factor-available eligible U.S. de-risk event, regardless of the sign of `DeltaMarginLeverage`.

## Fixed evaluation windows

Use the same seven folds:

1. 2012-07-05..2014-12-31
2. 2015-01-01..2016-12-31
3. 2017-01-01..2018-12-31
4. 2019-01-01..2020-12-31
5. 2021-01-01..2022-12-31
6. 2023-01-01..2024-12-31
7. 2025-01-01..latest

Also report full history, 2020+, and 2022+.

## Deterministic admission gates

`F-MARGIN-LEV-US` is `ADMIT_FOR_ROBUSTNESS` only if all pass:

1. full CAGR > frozen V11 CAGR;
2. full Sharpe >= frozen V11 Sharpe;
3. full Sharpe > `C-MARGIN-LEV-ALWAYS` Sharpe;
4. full MDD <=10%;
5. at least 5/7 fixed folds have candidate Sharpe >= matched-control Sharpe;
6. worst fixed-fold Sharpe >0;
7. gross <=100%, min target weight >=0, no financing or negative cash.

## Frozen statistical audit

Regardless of deterministic admission:

- paired circular moving-block bootstrap, block=63 sessions, 20,000 replicates, seed=20260821;
- `P(CAGR_candidate > CAGR_V11) >=0.90`;
- `P(Sharpe_candidate > Sharpe_matched) >=0.90`;
- median candidate-minus-V11 CAGR delta >0;
- median candidate-minus-matched Sharpe delta >0;
- candidate bootstrap MDD P97.5 <=15%;
- PBO not applicable because there is exactly one candidate;
- cumulative post-protocol DSR includes the prior 26 formal return-seeking candidates plus this candidate, total=27; DSR probability >=95%.

`ROBUST_FACTOR_PASS` requires deterministic admission, every bootstrap gate, and cumulative 27-trial DSR >=95%.

## Stop rule

This FINRA-margin campaign contains exactly one retrospective candidate. After performance is viewed:

- no debit-only rescue candidate;
- no free-credit-only or debit/free-credit alternative denominator;
- no market-cap, CPI, GDP or price normalization;
- no 2/3/6/12-month change or moving average;
- no z-score, percentile, level threshold, magnitude threshold or sign reversal;
- no 25%/75%/100% retention fraction;
- no change to 35-day stale rule or conservative publication lag;
- no second retrospective margin-debt family.

A promising non-robust result may only become a new prospective shadow from a new freeze date.
