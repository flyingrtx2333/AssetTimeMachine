# Orthogonal Event Budget Family V5 Design

## Goal

Test whether three new risk-asset/safe-asset market ratios can use the unused V11 cash budget more selectively than an unconditional event-level fill control, without leverage and without allowing factor state changes to create independent trades.

The research question is:

> On frozen V11 trade events where the current V11 risky target is below 100% gross, can growth-vs-duration, speculative-biotech-vs-healthcare, or transports-vs-Treasuries identify the subset of events on which scaling the existing positive V11 holdings to 100% gross improves both return and risk-adjusted performance relative to a matched unconditional fill control?

## Governance

- Current protocol: `ATM-SVP-2`.
- New lineage: `orthogonal-event-budget-family-v5`.
- Formal candidates: `F-GROWTHBOND`, `F-BIOTECH`, `F-TRANSPORT` only.
- Matched controls: `C-GROWTHBOND-ALWAYS`, `C-BIOTECH-ALWAYS`, `C-TRANSPORT-ALWAYS`.
- Formal candidate count = 3; formal run budget = 3.
- V11 is frozen and unchanged.
- V1/V2/V3/V4 evidence remains permanent and is not replaced by this family.
- No factor combination, horizon search, threshold search, stale-tolerance search, band search, or alternative gross target is allowed after results.

## Frozen event budget-completion architecture

- Fee: 1.00%.
- Slippage: 0.05%.
- Max gross: 100%.
- No shorting, financing, leverage, or negative cash.
- Strict T-1.
- Replay band: 25%.
- Logic is evaluated only on unique execution dates on which frozen V11 actually trades.
- Let `currentBase` be the frozen V11 target on that event date.
- If current positive-risk gross is in `(0,1)` and completion is enabled, scale only the already-positive `currentBase` holdings proportionally until gross reaches exactly 100%.
- Never introduce a symbol whose current V11 target is zero.
- If currentBase gross is already 100%, zero, factor-unavailable, or factor-risk-off, preserve currentBase unchanged.
- Between frozen V11 trade dates, no factor state change can trigger a trade.
- Identity replay with completion disabled must reproduce frozen V11 within the established replay tolerances before formal results are accepted.

This is a new architecture hypothesis, not a change to V3/V4's frozen 50% retention fraction. V3/V4 remain unchanged in their ledgers.

## Factor state and matched controls

- Use adjusted close.
- Ratio direction lookback: exactly 20 common source observations.
- Stale tolerance: exactly 7 calendar days.
- Candidate risk-on iff latest usable ratio >= ratio 20 common observations earlier.
- Candidate path: complete current V11 positive holdings to 100% gross only when risk-on.
- Matched control: complete to 100% whenever the factor is available, regardless of direction.
- When unavailable, candidate and matched control both preserve V11.

## Exact candidates

### F-GROWTHBOND — growth equities / long-duration Treasuries

- Yahoo `QQQ`, Invesco QQQ Trust.
- Yahoo `TLT`, iShares 20+ Year Treasury Bond ETF.
- `growthbond_ratio = QQQ_adjclose / TLT_adjclose`.
- Risk-on iff ratio is nondecreasing over 20 common observations.

Hypothesis: growth-equity leadership over long-duration Treasuries indicates stronger willingness to own equity duration/risk versus a major safety asset.

### F-BIOTECH — speculative biotech / broad healthcare

- Yahoo `XBI`, SPDR S&P Biotech ETF.
- Yahoo `XLV`, Health Care Select Sector SPDR Fund.
- `biotech_ratio = XBI_adjclose / XLV_adjclose`.
- Risk-on iff ratio is nondecreasing over 20 common observations.

Hypothesis: equal-weight speculative biotech leadership versus broad healthcare is a targeted risk-appetite indicator rather than a generic market trend.

### F-TRANSPORT — transports / intermediate Treasuries

- Yahoo `IYT`, iShares U.S. Transportation ETF.
- Yahoo `IEF`, iShares 7-10 Year Treasury Bond ETF.
- `transport_ratio = IYT_adjclose / IEF_adjclose`.
- Risk-on iff ratio is nondecreasing over 20 common observations.

Hypothesis: transport-sector leadership over intermediate Treasuries is a cross-asset proxy for stronger real-economy/cyclical risk appetite.

## Pre-result metadata facts

Metadata-only checks before preregistration:

- QQQ first trade: 1999-03-10.
- TLT first trade: 2002-07-30.
- XBI first trade: 2006-02-06.
- XLV first trade: 1998-12-22.
- IYT first trade: 2004-01-02.
- IEF first trade: 2002-07-30.
- Exact-token repository scan found zero prior text hits for all six tickers before this family was created.

## Formal paths

1. `V11-CONTROL`
2. `C-GROWTHBOND-ALWAYS`
3. `F-GROWTHBOND`
4. `C-BIOTECH-ALWAYS`
5. `F-BIOTECH`
6. `C-TRANSPORT-ALWAYS`
7. `F-TRANSPORT`

Only the three `F-*` paths count as candidates.

## Evaluation

Report full-history CAGR, Sharpe, MDD, volatility, trades, average cash, target fingerprint, max gross/min weight, 2020+, 2022+, same seven V11 folds, source event count, underinvested event count, factor-available underinvested events, and completed events.

## Admission gate

`ADMIT_FOR_ROBUSTNESS` requires all:

- CAGR > V11-CONTROL CAGR;
- Sharpe > own matched control Sharpe;
- MDD <=12%;
- at least 4/7 folds candidate Sharpe >= matched control Sharpe;
- worst-fold Sharpe >0;
- max gross <=100%;
- min target weight >=0;
- no financing/negative cash.

`STRONG_INCREMENTAL` additionally requires:

- CAGR >= V11 CAGR +1.0 percentage point;
- Sharpe >= V11 Sharpe.

Passing only authorizes a separately preregistered robustness family.

## Failure semantics

- Do not change 20 observations, 7-day stale tolerance, 25% band, or gross target after results.
- Do not replace 100% gross completion with 75/90/95% after results.
- Do not combine the three factors inside this trial.
- Any new factor, factor transform, or architecture is a new preregistered family and counts separately under G3.
