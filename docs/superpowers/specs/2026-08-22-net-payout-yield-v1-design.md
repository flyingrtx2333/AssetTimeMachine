# First-Release Net Payout Yield Factor V1

**Date:** 2026-08-22  
**Protocol:** ATM-SVP-2  
**Trial:** ATM-SVP2-NPY-001  
**Evidence:** R1_RETROSPECTIVE  
**Base strategy:** frozen `nfci-dual-core-v11 / dualcore-v11-2026-08-15`

## Purpose

Test one slow-moving valuation/corporate-payout information domain that is economically distinct from price momentum, volatility, NFCI, CFTC positioning, customer margin debt, broker-dealer leverage, and SEC insider breadth.

Published evidence finds that payout and net payout yields can contain time-series information about expected aggregate equity returns and that net payout yield can forecast more accurately than dividend yield alone. The literature is not unanimous, so this trial treats the hypothesis as falsifiable and uses one candidate with no rescue search.

## Frozen first-release data

Source: Federal Reserve Financial Accounts of the United States (Z.1), using each quarter's original archived release tables rather than the latest revised history.

For every quarter from 2011Q1 through 2026Q1, the frozen input uses values taken from that quarter's own release:

- `FA106121075`: nonfinancial corporate business; net dividends paid, SAAR;
- `FA103164105`: nonfinancial corporate business; corporate equities; liability transactions, SAAR;
- `LM103164105`: nonfinancial corporate business; corporate equities; liability market value.

Define:

`NetPayoutYield_t = (NetDividends_t - NetEquityIssuance_t) / EquityMarketValue_t`

Because equity liability transactions are negative during net repurchases, subtracting issuance correctly adds repurchases to payout and subtracts net issuance.

Each observation becomes usable only on `release_date + 1 calendar day`. The source HTML for every first-release transaction and level table is frozen locally with SHA-256 evidence. No latest-vintage Z.1 values may replace the frozen first-release inputs.

## Frozen factor — F-NET-PAYOUT-YIELD-US

The literature's hypothesis is about the **level** of payout yield, not merely quarter-to-quarter acceleration. A fixed absolute threshold such as 4% or 5% would invite sample-specific tuning, and a full-sample percentile would leak future information. Therefore the candidate uses a prior-only expanding benchmark:

1. at signal date `t`, select the latest NetPayoutYield observation whose `available_date <= t`;
2. construct the median of **all earlier point-in-time-available NetPayoutYield observations, excluding the latest observation**;
3. factor is available only when at least one prior observation exists;
4. `risk_on = latest NetPayoutYield >= prior-only expanding median`.

There is no fixed yield threshold, z-score, rolling-window length, percentile, quarter-over-quarter sign rule, smoothing, CPI adjustment, market-cap alternative, earnings normalization, or composite factor.

## Frozen portfolio action

The factor cannot create independent trades.

- Formal events are unique execution dates where frozen V11 records a trade.
- Compare current frozen V11 event target with the prior frozen V11 event target.
- An eligible U.S. de-risk event occurs only when V11 reduces `nasdaq` and/or `sp500` weight.
- If factor is unavailable or risk-off, use current V11 target unchanged.
- If factor is risk-on, retain exactly **50%** of each `nasdaq` / `sp500` reduction.
- Gold and China sleeves are never altered by the factor.
- Gross exposure is capped at 100%; retained U.S. reductions are mechanically scaled if capacity is insufficient.
- No shorting, financing, negative cash, or factor-driven trades between V11 event dates.
- Research costs remain 1.00% fee + 0.05% slippage.
- Replay rebalance band remains 25%.

### Matched availability control

`C-NET-PAYOUT-ALWAYS` applies the same 50% U.S.-reduction retention on every factor-available eligible U.S. de-risk event regardless of whether payout yield is above or below its prior-only median.

This distinguishes valuation information from the mechanical effect of retaining more U.S. equity exposure.

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

`F-NET-PAYOUT-YIELD-US` is `ADMIT_FOR_ROBUSTNESS` only if all pass:

1. full CAGR > frozen V11 CAGR;
2. full Sharpe >= frozen V11 Sharpe;
3. full Sharpe > `C-NET-PAYOUT-ALWAYS` Sharpe;
4. full MDD <=10%;
5. at least 5/7 fixed folds have candidate Sharpe >= matched-control Sharpe;
6. worst fixed-fold Sharpe >0;
7. gross <=100%, min target weight >=0, no financing or negative cash.

## Frozen statistical audit

Regardless of deterministic admission:

- paired circular moving-block bootstrap, block=63 sessions, 20,000 replicates, seed=20260822;
- `P(CAGR_candidate > CAGR_V11) >=0.90`;
- `P(Sharpe_candidate > Sharpe_matched) >=0.90`;
- median candidate-minus-V11 CAGR delta >0;
- median candidate-minus-matched Sharpe delta >0;
- candidate bootstrap MDD P97.5 <=15%;
- PBO is not applicable because there is exactly one candidate and no within-family selection;
- cumulative post-protocol DSR includes all prior 29 formal return-seeking candidates plus this candidate, total=30; DSR probability must be >=95%.

`ROBUST_FACTOR_PASS` requires deterministic admission, every bootstrap gate, and cumulative 30-trial DSR >=95%.

## Factor-library rule

If and only if `ROBUST_FACTOR_PASS=true`, immediately export this factor with its complete evidence to the FlyingrtxFast factor-library manifest pipeline, validate/import/complete it, and read the remote factor record back to verify lifecycle and evidence integrity. A FAIL or near-miss is retained in research evidence but is not promoted as validated.

## Stop rule

This Net Payout Yield campaign contains exactly one retrospective candidate. After formal performance is viewed:

- no fixed 2%/3%/4%/5%/6% payout threshold;
- no rolling 4/8/12/20-quarter median or percentile rescue;
- no quarter-over-quarter, year-over-year, z-score, rank, slope, or acceleration rescue;
- no dividend-only, repurchase-only, issuance-only, total-payout, earnings-yield, or alternative denominator rescue;
- no CPI, GDP, market-cap, Fed balance-sheet, or interest-rate normalization;
- no sign reversal;
- no 25%/75%/100% retention-fraction search;
- no second retrospective Net Payout family.

A promising but non-robust result may only be carried forward under a separately preregistered prospective shadow without changing this historical rule.
