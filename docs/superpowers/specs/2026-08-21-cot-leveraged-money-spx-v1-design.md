# COT Leveraged-Money SPX Factor V1

**Date:** 2026-08-21  
**Protocol:** ATM-SVP-2  
**Trial:** ATM-SVP2-COT-001  
**Evidence:** R1_RETROSPECTIVE  
**Base strategy:** frozen `nfci-dual-core-v11 / dualcore-v11-2026-08-15`

## Purpose

Test one new information domain after repeated price/macro/volatility event overlays produced no robust factor. This trial uses official CFTC Traders in Financial Futures positioning data rather than another price-derived indicator.

The literature is mixed by construction and that ambiguity is part of the motivation. Dunbar and Jiang (2020) report out-of-sample aggregate equity-return predictability from changes in financial traders' net-long positions. Chen and Maher (2013) find that trader-position relationships in S&P 500 futures are structurally unstable and that public weekly COT trading signals are not reliably profitable. Therefore this trial does not assume COT is "smart money"; it tests one minimal hypothesis with no parameter search.

## Frozen official data scope

- Source: CFTC Traders in Financial Futures, Futures Only.
- Markets fetched: `S&P 500 Consolidated` (`CFTC_Contract_Market_Code=13874+`) and `NASDAQ-100 Consolidated` (`20974+`).
- Canonical consolidated series start: 2010-06-15.
- Pre-consolidation 2006–2010 standard/E-mini component rows are intentionally excluded; the project will not synthesize its own pseudo-consolidated history.
- Current frozen raw coverage: 2010-06-15 through 2026-08-11.
- Formal factor uses only the S&P 500 Consolidated row. Nasdaq-100 is retained in the raw dataset for pairing/integrity checks but is not a second factor.

## Frozen point-in-time availability

The CFTC historical pages explicitly label dates as **report dates, not release dates**. Normal COT publication is usually Friday 15:30 ET with data from the previous Tuesday; ordinary federal holidays may move release by one or two days.

To avoid look-ahead:

1. ordinary rows are usable only from `report_date + 7 calendar days`;
2. known extraordinary publication disruptions are excluded rather than assigned guessed release dates:
   - report dates 2013-10-01..2013-10-29 (2013 federal shutdown);
   - 2018-12-24..2019-02-26 (2018–2019 lapse in appropriations);
   - 2023-01-31..2023-03-14 (ION cyber incident/reporting backlog);
3. 2025 shutdown/backlog rows use the CFTC's exact official catch-up publication table and become usable **one calendar day after** the stated actual publication date to avoid intraday timing ambiguity;
4. if no new usable COT row has become available for more than 14 calendar days, the factor state is unavailable and V11 is left unchanged.

This availability calendar is frozen before any strategy performance for this candidate is viewed.

## Frozen factor — F-COT-LEV-SPX

For each S&P 500 Consolidated report `t`:

- `OI_t = Open_Interest_All`;
- `LevNetShare_t = (Lev_Money_Long_t - Lev_Money_Short_t) / OI_t`;
- `DeltaLevNetShare_t = LevNetShare_t - LevNetShare_prev` using the immediately previous **point-in-time usable** report; excluded disruption-period reports are never used as the delta baseline;
- once row `t` is point-in-time usable, `risk_on = DeltaLevNetShare_t > 0`.

There is no z-score, percentile, rolling mean, multi-week window, magnitude threshold, Nasdaq confirmation, or trader-category ensemble.

Economic interpretation: Leveraged Money in the CFTC TFF taxonomy is the closest public category to hedge-fund/speculative financial traders. A positive weekly change in net-long share is treated as a directional risk-appetite signal, while explicitly acknowledging prior evidence that the relationship may be unstable and publication lag may destroy much of the information.

## Frozen portfolio action

The factor is **not** allowed to create independent trades.

- Formal events are unique execution dates where frozen V11 records a trade.
- Compare the current V11 event target with the prior V11 event target.
- An eligible U.S. de-risk event occurs only when V11 reduces `nasdaq` and/or `sp500` target weight.
- If factor is unavailable or risk-off, use the current V11 target unchanged.
- If factor is risk-on, retain exactly **50%** of each `nasdaq` / `sp500` reduction from prior-event target to current-event target.
- Gold and China sleeves are never altered by the COT factor.
- Gross is capped at 100%; if simultaneous V11 changes consume capacity, retained U.S. reductions are scaled mechanically to remaining capacity.
- No leverage, financing, shorting, negative cash or negative target weights.
- No factor-driven trades between V11 event dates.
- Research costs remain 1.00% fee + 0.05% slippage.
- Replay rebalance band remains 25%.

### Matched availability control

`C-COT-LEV-ALWAYS` applies the same 50% U.S.-reduction retention on **every** factor-available eligible U.S. de-risk event, regardless of the sign of `DeltaLevNetShare`.

This distinguishes COT timing information from the mechanical effect of simply retaining more U.S. equity exposure.

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

`F-COT-LEV-SPX` is `ADMIT_FOR_ROBUSTNESS` only if all pass:

1. full CAGR > frozen V11 CAGR;
2. full Sharpe >= frozen V11 Sharpe;
3. full Sharpe > `C-COT-LEV-ALWAYS` Sharpe;
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
- family PBO is not applicable because there is exactly one candidate and no within-family selection;
- cumulative post-protocol DSR includes all prior 25 formal return-seeking candidates plus this candidate, total=26; DSR probability must be >=95%.

`ROBUST_FACTOR_PASS` requires deterministic admission, every bootstrap gate, and cumulative 26-trial DSR >=95%.

## Stop rule

This COT campaign contains exactly one retrospective candidate. After formal performance is viewed:

- no Asset Manager / Dealer / Other Reportable / Nonreportable rescue candidate;
- no Nasdaq confirmation or S&P/Nasdaq average;
- no 2/4/8/13/26/52-week positioning window;
- no z-score, percentile, level threshold, magnitude threshold or sign reversal;
- no 25%/75%/100% retention fraction;
- no change to the 14-day stale rule or the conservative availability policy;
- no second retrospective COT family.

If the candidate is historically promising but not robust, it may only become a new prospective shadow from a new freeze date. Any future materially different positioning study requires a new externally justified campaign and remains in cumulative G3 accounting.
