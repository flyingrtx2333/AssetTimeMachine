# SEC Insider Buy Breadth Factor V1

**Date:** 2026-08-21  
**Protocol:** ATM-SVP-2  
**Trial:** ATM-SVP2-INSIDER-001  
**Evidence:** R1_RETROSPECTIVE  
**Base strategy:** frozen `nfci-dual-core-v11 / dualcore-v11-2026-08-15`

## Purpose

Test one genuinely new information domain after price/macro/volatility, COT, customer-margin and broker-dealer leverage candidates failed or remained non-robust. This trial uses corporate insiders' SEC Section 16 Form 4 open-market purchases.

The economic prior is intentionally narrow. Classic evidence finds aggregate insider trading predicts aggregate future stock returns, and separate evidence finds insider purchases are materially more informative than insider sales. The candidate therefore uses purchase breadth only and does not search sale definitions, dollar weighting, transaction-size thresholds or combined buy/sell ratios.

## Frozen official data scope

- Source: SEC Insider Transactions Data Sets, quarterly Form 3/4/5 flattened XML data.
- Frozen source quarters: 2012 Q1 through 2026 Q2, 58 quarters.
- Required tables: `SUBMISSION.tsv` and `NONDERIV_TRANS.tsv` only.
- Evidence universe: all issuers appearing in the official Section 16 data; no survivorship-filtered index membership is imposed.
- Frozen evidence: 233,821 initial Form 4 filings containing at least one qualifying non-derivative open-market purchase.
- Amendments (`DOCUMENT_TYPE=4/A`) are excluded. This intentionally preserves the initial as-filed information set rather than using a later amendment to rewrite the historical signal.
- A qualifying purchase requires all of:
  - `DOCUMENT_TYPE = 4`;
  - `TRANS_CODE = P`;
  - `TRANS_ACQUIRED_DISP_CD = A`;
  - transaction is from `NONDERIV_TRANS`.
- Derivative transactions, exercises (`M`), grants, gifts, sales and all other transaction codes are excluded.

The frozen evidence artifact retains accession number, filing date, issuer CIK and issuer trading symbol for every qualifying filing. Each source quarterly ZIP has its SHA-256 recorded before strategy performance is viewed.

## Frozen point-in-time availability

The SEC bulk data provide `FILING_DATE` but not historical acceptance timestamps. EDGAR filing timestamps were observable in real time, but this trial does not reconstruct them one filing at a time.

To avoid intraday or late-filing look-ahead:

1. group initial Form 4 filings by Monday-Friday **filing week** using `FILING_DATE`;
2. count each issuer CIK at most once per week regardless of the number of insiders, filings or purchase rows;
3. a completed filing week becomes usable only on the **following Tuesday**;
4. the latest weekly observation is usable for at most **10 calendar days** after that Tuesday;
5. the final partial week in a quarterly data boundary is not emitted until all Monday-Friday filing days are present.

The frozen bulk archive currently ends at 2026-06-30, so the final complete filing week ends 2026-06-26. The factor is allowed to become unavailable later rather than filling July/August with guessed data.

## Frozen factor — F-SEC-INSIDER-BUY-BREADTH-US

For completed filing week `t`:

- `BuyBreadth_t = number of distinct ISSUERCIK values with >=1 qualifying P filing during week t`;
- `DeltaBuyBreadth_t = BuyBreadth_t - BuyBreadth_(t-1)`;
- once week `t` is point-in-time usable, `risk_on = DeltaBuyBreadth_t > 0`.

There is no rolling average, percentile, z-score, absolute count threshold, dollar weighting, market-cap weighting, sale denominator, sale confirmation, transaction-value threshold or issuer-size filter.

Economic interpretation: a week-over-week broadening in the number of companies whose insiders deploy personal capital into open-market purchases is treated as a market-level confirmation that frozen V11 may be de-risking U.S. equities too aggressively.

## Frozen portfolio action

The factor cannot create independent trades.

- Formal events are unique execution dates where frozen V11 records a trade.
- Compare current V11 event target with the prior V11 event target.
- An eligible U.S. de-risk event occurs only when V11 reduces `nasdaq` and/or `sp500` target weight.
- If the factor is unavailable or risk-off, use current V11 target unchanged.
- If the factor is risk-on, retain exactly **50%** of each `nasdaq` / `sp500` reduction.
- Gold and China sleeves are never altered by this factor.
- Gross <=100%; retained U.S. reductions are mechanically scaled if remaining capacity is insufficient.
- No leverage, financing, shorting, negative cash or negative target weights.
- No factor-driven trades between frozen V11 event dates.
- Research cost remains 1.00% fee + 0.05% slippage.
- Replay rebalance band remains 25%.

### Matched availability control

`C-SEC-INSIDER-ALWAYS` retains the same 50% of U.S.-equity reductions on **every** factor-available eligible U.S. de-risk event, regardless of `DeltaBuyBreadth` sign.

This distinguishes insider-buy timing information from the mechanical effect of retaining more U.S. equity exposure.

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

`F-SEC-INSIDER-BUY-BREADTH-US` is `ADMIT_FOR_ROBUSTNESS` only if all pass:

1. full CAGR > frozen V11 CAGR;
2. full Sharpe >= frozen V11 Sharpe;
3. full Sharpe > `C-SEC-INSIDER-ALWAYS` Sharpe;
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
- PBO is not applicable because this trial contains exactly one candidate;
- cumulative post-protocol DSR includes the prior **28** formal return-seeking candidates plus this candidate, total=29; DSR probability >=95%.

`ROBUST_FACTOR_PASS` requires deterministic admission, every bootstrap gate, and cumulative 29-trial DSR >=95%.

## Stop rule

This SEC-insider campaign contains exactly one retrospective candidate. After performance is viewed:

- no sales-based rescue candidate;
- no buy/sell ratio, net purchases, dollar value, shares, market-cap weighting or issuer-size filter;
- no director/officer/10%-owner subgroup selection;
- no 2/4/8/13/26/52-week window;
- no z-score, percentile, absolute breadth threshold, magnitude threshold or sign reversal;
- no same-day/next-day/following-Monday availability rescue;
- no 25%/75%/100% retention fraction;
- no Form 4/A amendment incorporation to improve historical results;
- no second retrospective SEC insider family.

If historically suggestive but not robust-certified, the only allowed continuation is a separately preregistered prospective shadow using newly disseminated EDGAR Form 4 filings after a new freeze date.
