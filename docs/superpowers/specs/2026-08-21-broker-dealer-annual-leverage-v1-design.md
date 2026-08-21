# Broker-Dealer Annual Book-Leverage Factor V1

**Date:** 2026-08-21  
**Protocol:** ATM-SVP-2  
**Trial:** ATM-SVP2-BDLEV-001  
**Evidence:** R1_RETROSPECTIVE  
**Base strategy:** frozen `nfci-dual-core-v11 / dualcore-v11-2026-08-15`

## Purpose

Test one literature-driven intermediary-balance-sheet information domain after the strongest prior new-data candidate (FINRA Margin Leverage) remained a statistical near-miss. This is not another market-price, volatility, macro, COT, or customer-margin factor.

Adrian, Moench, and Shin's dynamic intermediary asset-pricing work identifies broker-dealer **book leverage** as a return-forecasting variable and reports that higher leverage / leverage growth forecasts lower future risky-asset returns. Adrian, Etula, and Muir use shocks to securities broker-dealer leverage as an intermediary pricing factor. The present trial therefore fixes the economically favorable state as **negative annual book-leverage growth** before any strategy performance is viewed.

## Frozen point-in-time dataset

Source: Board of Governors of the Federal Reserve System, historical **Financial Accounts of the United States (Z.1)** release archive.

This trial does **not** use today's revised FRED history. For each quarter from 2012Q1 through 2026Q1:

1. discover that quarter's original Z.1 release from the Federal Reserve release-date archive;
2. read the original Security Brokers and Dealers levels table from that release (`L.127/L.128/L.129/L.130`, or the modern `S125s3.s` layout);
3. identify total financial assets using `FL664090005` when the series code exists, with exact-description fallback for old tables;
4. identify total liabilities using `FL664190005`, explicitly excluding “total liabilities and equity”;
5. freeze the complete source HTML locally and record its SHA-256;
6. calculate both the current-quarter and four-quarter-lag leverage from values appearing in the **same release table**.

Using both comparison values from the same historical release is critical: it prevents subsequent methodology revisions/reclassifications of old quarters from becoming a fake leverage-growth signal.

Frozen coverage: **57 quarterly releases, 2012Q1..2026Q1**. Historical release gaps are 69..120 calendar days. The current mutable `/current/` 2026Q1 table is frozen locally with SHA-256 at campaign construction time.

## Frozen factor — F-BDLEV-ANNUAL-US

For release `t`:

- `A_t = Total Financial Assets_t`;
- `L_t = Total Liabilities_t`;
- `BookLev_t = A_t / (A_t - L_t)`;
- `BookLev_t-4` is calculated from the four-quarter-earlier assets and liabilities **inside the same release t table**;
- `AnnualLevGrowth_t = ln(BookLev_t) - ln(BookLev_t-4)`;
- the factor becomes usable one calendar day after the official Z.1 release date;
- `favorable = AnnualLevGrowth_t < 0`.

The one-day lag removes same-day/intraday release-timing ambiguity. The latest released factor state is valid for at most **150 calendar days**. This exceeds the 120-day maximum historical release gap and is only an operational missing-release guard; it does not exclude any historical quarterly release interval in the frozen dataset.

`quarterly_log_change_diagnostic_only` exists only for data-quality diagnostics and is **forbidden** as a return-seeking candidate in this campaign.

## Frozen portfolio action

The factor cannot create independent trades.

- Formal events are unique execution dates on which frozen V11 records a trade.
- Compare the current V11 event target with the previous V11 event target.
- An eligible U.S. de-risk event exists only if V11 reduces `nasdaq` and/or `sp500`.
- If the factor is unavailable or `favorable == false`, use the current V11 target unchanged.
- If `favorable == true`, retain exactly **50%** of each current `nasdaq` / `sp500` reduction relative to the previous V11 event target.
- Gold and China sleeves are never altered.
- Gross remains <=100%; retained U.S. reductions are mechanically scaled if remaining capacity is insufficient.
- No leverage, financing, shorting, negative cash, or negative target weights.
- No factor-driven trades between frozen V11 event dates.
- Research costs remain 1.00% fee + 0.05% slippage.
- Replay rebalance band remains 25%.

### Matched availability control

`C-BDLEV-ALWAYS` applies the identical 50% U.S.-reduction retention on **every** factor-available eligible U.S. de-risk event, irrespective of annual leverage growth.

This distinguishes broker-dealer timing information from the mechanical effect of simply retaining more U.S. equity exposure.

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

`F-BDLEV-ANNUAL-US` is `ADMIT_FOR_ROBUSTNESS` only if all pass:

1. full CAGR > frozen V11 CAGR;
2. full Sharpe >= frozen V11 Sharpe;
3. full Sharpe > `C-BDLEV-ALWAYS` Sharpe;
4. full MDD <=10%;
5. at least 5/7 fixed folds have candidate Sharpe >= matched-control Sharpe;
6. worst fixed-fold Sharpe >0;
7. gross <=100%, minimum target weight >=0, no financing or negative cash.

## Frozen statistical audit

Regardless of deterministic admission:

- paired circular moving-block bootstrap, block=63 sessions, 20,000 replicates, seed=20260821;
- `P(CAGR_candidate > CAGR_V11) >=0.90`;
- `P(Sharpe_candidate > Sharpe_matched) >=0.90`;
- median candidate-minus-V11 CAGR delta >0;
- median candidate-minus-matched Sharpe delta >0;
- candidate bootstrap MDD P97.5 <=15%;
- PBO is not applicable because there is exactly one candidate and no within-family selection;
- cumulative post-protocol DSR includes all **27 prior** formal return-seeking candidates plus this candidate, total **28**; DSR probability must be >=95%.

`ROBUST_FACTOR_PASS` requires deterministic admission, every bootstrap gate, and cumulative 28-trial DSR >=95%.

## Stop rule

This campaign contains exactly one retrospective candidate. After formal performance is viewed, do **not** search:

- quarterly leverage change;
- leverage level thresholds;
- positive annual-growth sign reversal;
- equity-capital ratio / inverse leverage;
- seasonal adjustment variants;
- winsorization or clipping;
- z-scores, percentiles, magnitude thresholds, persistence rules;
- 2-quarter/3-quarter/2-year or any other growth horizon;
- 25%/75%/100% retention fractions;
- alternate 0-day or multi-day release lags;
- alternate stale windows;
- Nasdaq confirmation or other factor ensembles;
- a second retrospective broker-dealer-leverage family.

A historically suggestive but non-robust result may only become a separately preregistered prospective shadow from a new freeze date.
