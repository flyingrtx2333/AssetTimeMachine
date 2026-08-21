# TIC Foreign Equity Flow Contrarian Factor V1

**Date:** 2026-08-22  
**Protocol:** ATM-SVP-2  
**Trial:** ATM-SVP2-TIC-001  
**Evidence:** R1_RETROSPECTIVE  
**Base strategy:** frozen `nfci-dual-core-v11 / dualcore-v11-2026-08-15`

## Purpose

Test a new cross-border capital-flow information domain using only first-release U.S. Treasury TIC monthly data. Prior research on international equity flows reports a positive contemporaneous but negative one-month-ahead relation with U.S. stock returns, motivating a preregistered contrarian sign rule rather than a fitted magnitude threshold.

## Frozen first-release data

Source: U.S. Treasury monthly Treasury International Capital release archives.

Coverage is 2011-01 through 2026-05, 185 monthly observations. Every row is extracted from the archive ZIP actually released for that report month and records both the archive SHA-256 and source-member SHA-256. Availability is the actual release date plus one calendar day.

### Explicit February 2023 series break

Treasury identifies February 2023 as a reporting-system break from Form S to expanded Form SLT.

- through 2023-01, use `snetus.txt`, Grand Total / Corp. Stocks / net foreign purchases;
- from 2023-02, use `slt_table1`, Grand Total / U.S. Corporate Equity / net U.S. sales;
- the frozen extraction normalizes both presentations to the same economic sign: **positive means foreign residents are net buyers / increase holdings of U.S. corporate stocks**;
- the trial does **not** treat the measurement levels as statistically seamless across the break;
- therefore no level threshold, percentile, median, z-score, scaling, or cross-regime magnitude comparison is permitted. Only the economic sign is used.

## Frozen factor — F-TIC-FLOW-CONTRARIAN-US

At a strategy signal date:

1. select the latest TIC observation whose `available_date <= signal_date`;
2. if that observation is more than 45 calendar days old, factor state is unavailable;
3. otherwise `risk_on = net_foreign_purchases_us_stocks_millions < 0`;
4. zero would be risk-off (the frozen sample contains no zero months).

The 45-day stale rule is operational, not fitted: normal monthly TIC release cadence is roughly one month; the buffer covers ordinary calendar variation but prevents carrying a stale flow signal indefinitely across delayed releases or shutdown/backlogs.

No magnitude threshold, moving average, percentile, z-score, rolling window, month-over-month change, regime-specific threshold, normalization, or sign reversal is allowed.

## Frozen portfolio action

The factor cannot create independent trades.

- Formal events are unique execution dates where frozen V11 records a trade.
- Compare current V11 event target with the prior V11 event target.
- Eligible U.S. de-risk event: V11 reduces `nasdaq` and/or `sp500` weight.
- If factor is unavailable or risk-off, use current V11 target unchanged.
- If factor is risk-on, retain exactly **50%** of each `nasdaq` / `sp500` reduction.
- Gold and China sleeves are never altered.
- Gross exposure <=100%, no leverage, no financing, no shorting, no negative cash.
- No factor-driven trades between V11 event dates.
- Research costs remain 1.00% fee + 0.05% slippage.
- Replay rebalance band remains 25%.

### Matched availability control

`C-TIC-FLOW-ALWAYS` applies the same 50% U.S.-reduction retention on every factor-available eligible U.S. de-risk event regardless of the sign of the TIC flow.

## Fixed evaluation windows

1. 2012-07-05..2014-12-31
2. 2015-01-01..2016-12-31
3. 2017-01-01..2018-12-31
4. 2019-01-01..2020-12-31
5. 2021-01-01..2022-12-31
6. 2023-01-01..2024-12-31
7. 2025-01-01..latest

Also report full history, 2020+, and 2022+.

## Deterministic admission gates

`F-TIC-FLOW-CONTRARIAN-US` is `ADMIT_FOR_ROBUSTNESS` only if all pass:

1. full CAGR > frozen V11 CAGR;
2. full Sharpe >= frozen V11 Sharpe;
3. full Sharpe > `C-TIC-FLOW-ALWAYS` Sharpe;
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
- PBO not applicable because there is exactly one candidate;
- cumulative post-protocol DSR includes all prior 30 formal return-seeking candidates plus this candidate, total=31; DSR probability >=95%.

`ROBUST_FACTOR_PASS` requires deterministic admission, every bootstrap gate, and cumulative 31-trial DSR >=95%.

## Factor-library rule

If and only if `ROBUST_FACTOR_PASS=true`, immediately export this factor and complete the FlyingrtxFast factor-library validate/import/complete pipeline, then remotely read the stored factor/version back to verify lifecycle and evidence integrity.

## Stop rule

This TIC campaign contains exactly one retrospective candidate. After formal performance is viewed:

- no positive-flow/momentum sign reversal;
- no fixed dollar-flow threshold;
- no percentile, z-score, expanding/rolling median, or regime-specific threshold;
- no 2/3/6/12-month averaging, accumulation, momentum, acceleration, or change rule;
- no GDP, market-cap, equity-market-value, FX, Treasury-flow, bond-flow, or total-TIC normalization;
- no private/official-country decomposition rescue;
- no omission of the February 2023 regime break or re-scaling across it;
- no change to the 45-day stale rule;
- no 25%/75%/100% retention-fraction search;
- no second retrospective TIC equity-flow family.

A promising non-robust result may only become a separately preregistered prospective shadow with this exact rule unchanged.
