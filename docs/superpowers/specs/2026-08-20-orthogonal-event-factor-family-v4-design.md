# Orthogonal Event Factor Family V4 Design

## Goal

Test three new, previously unresearched market-internal risk-appetite factors only at frozen V11 de-risk events, using the exact event-retention architecture established before V3 results.

The research question is:

> When frozen V11 is already reducing risk, can high-beta/low-volatility leadership, industrials/utilities leadership, or regional-bank/broad-market leadership identify which de-risk events should retain 50% of the planned reduction, and do so better than an unconditional matched availability control?

## Governance

- Current protocol: `ATM-SVP-2`.
- New lineage: `orthogonal-event-factor-family-v4`.
- Formal candidates are exactly `F-HIGHBETA`, `F-INDUTIL`, `F-BANKS`.
- V11 remains frozen and is never modified.
- Each candidate has its own matched availability control; controls do not count as formal candidates.
- Formal candidate count = 3; formal run budget = 3.
- No rescue grid, factor combination, horizon search, retention-fraction search, stale-tolerance search, or band search is allowed after results are viewed.
- Results from V1/V2/V3 remain in trial accounting; V4 does not replace any earlier factor.

## Frozen event-retention architecture

This family reuses the exact V3 event architecture rather than introducing a new implementation concept:

- Frozen control: `nfci-dual-core-v11 / dualcore-v11-2026-08-15`.
- Fee: 1.00%.
- Slippage: 0.05%.
- Maximum gross: 100%.
- No shorting, financing, leverage, or negative cash.
- Signals: strict T-1.
- Research replay hard band: 25%.
- Candidate logic is evaluated only on unique execution dates on which frozen V11 actually trades.
- A de-risk reduction for symbol `s` is `max(priorBase[s] - currentBase[s], 0)`.
- If retention is enabled, retain exactly 50% of each positive reduction.
- Extra retained weights are proportionally capped only when required to keep gross <=100%.
- Factor changes alone cannot trigger trades between frozen V11 event dates.
- Identity replay without retention must reproduce frozen V11 within the existing replay tolerances before any formal candidate result is accepted.

## Factor state and matched controls

- Use adjusted close.
- Direction lookback: exactly 20 common source observations.
- Stale tolerance: exactly 7 calendar days.
- Candidate risk-on: latest usable ratio >= ratio 20 common observations earlier.
- Candidate path: retain 50% only when factor is risk-on.
- Matched control: retain 50% whenever that factor is available, regardless of direction.
- When the factor is unavailable, candidate and matched control both use the exact current V11 target.

This isolates factor timing value from generic slower de-risking and from differing ETF inception dates.

## Exact factor candidates

### F-HIGHBETA — high-beta / low-volatility risk appetite

Raw market series:

- Yahoo `SPHB`, Invesco S&P 500 High Beta ETF.
- Yahoo `SPLV`, Invesco S&P 500 Low Volatility ETF.

Construct on common dates:

`highbeta_ratio = SPHB_adjclose / SPLV_adjclose`

Risk-on iff the latest usable ratio is >= the ratio 20 common observations earlier.

Economic hypothesis: high-beta stocks outperforming low-volatility stocks indicate broad willingness to hold market-sensitive risk, which is directly relevant when V11 is considering de-risking.

### F-INDUTIL — industrials / utilities cyclical leadership

Raw market series:

- Yahoo `XLI`, Industrial Select Sector SPDR Fund.
- Yahoo `XLU`, Utilities Select Sector SPDR Fund.

Construct:

`indutil_ratio = XLI_adjclose / XLU_adjclose`

Risk-on iff the latest usable ratio is >= the ratio 20 common observations earlier.

Economic hypothesis: industrial-sector leadership over utilities reflects stronger cyclical participation versus a defensive, rate-sensitive sector.

### F-BANKS — regional banks / broad-market financial risk appetite

Raw market series:

- Yahoo `KRE`, SPDR S&P Regional Banking ETF.
- Yahoo `SPY`, SPDR S&P 500 ETF Trust.

Construct:

`banks_ratio = KRE_adjclose / SPY_adjclose`

Risk-on iff the latest usable ratio is >= the ratio 20 common observations earlier.

Economic hypothesis: regional-bank relative strength reflects improving financial intermediation/credit risk appetite and may be informative specifically at de-risk events.

`SPY` appeared previously as a denominator in V3 breadth; `KRE/SPY` is nevertheless a new preregistered factor mechanism and does not alter or retest `RSP/SPY`.

## Pre-result exposure facts

Metadata-only checks performed before freeze:

- SPHB first trade date: 2011-05-05.
- SPLV first trade date: 2011-05-05.
- XLI first trade date: 1998-12-22.
- XLU first trade date: 1998-12-22.
- KRE first trade date: 2006-06-22.
- SPY first trade date: 1993-01-29.

Repository exact-token scan before preregistration found zero prior text hits for `SPHB`, `SPLV`, `XLI`, `XLU`, and `KRE`. `SPY` has prior V3 evidence and is reused only as a denominator in the new KRE/SPY mechanism.

## Formal paths

Formal output contains seven paths:

1. `V11-CONTROL`
2. `C-HIGHBETA-ALWAYS`
3. `F-HIGHBETA`
4. `C-INDUTIL-ALWAYS`
5. `F-INDUTIL`
6. `C-BANKS-ALWAYS`
7. `F-BANKS`

Only the three `F-*` paths count as candidates.

## Evaluation

For every path report full-history CAGR, Sharpe, MDD, volatility, trade count, average cash, target fingerprint, max gross/min target weight, 2020+, 2022+, the same seven frozen V11 folds, source event count, de-risk event count, factor-available de-risk events, and retained events.

## Admission gate

A factor receives `ADMIT_FOR_ROBUSTNESS` only if all are true:

- full-history CAGR > `V11-CONTROL` CAGR;
- full-history Sharpe > its own matched `C-*-ALWAYS` Sharpe;
- full-history MDD <=12%;
- at least 4/7 fixed folds have candidate Sharpe >= matched-control Sharpe in the same fold;
- worst-fold Sharpe >0;
- max gross <=100%;
- minimum target weight >=0;
- no financing or negative cash.

A factor receives `STRONG_INCREMENTAL` only if it is admitted and:

- CAGR >= V11 CAGR +1.0 percentage point;
- Sharpe >= V11 Sharpe.

Passing is permission only for a separately preregistered robustness study, not App integration.

## Failure semantics

- A failed factor stays failed in this family.
- Do not change 20 observations to another horizon after results.
- Do not change 50% retention to another fraction after results.
- Do not change the 7-day stale tolerance or 25% band.
- Do not combine factors in this trial.
- Any new factor transform, retention rule, or combination is a new preregistered family and counts separately under G3.
