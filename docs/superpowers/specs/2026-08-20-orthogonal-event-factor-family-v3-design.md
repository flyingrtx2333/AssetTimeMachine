# Orthogonal Event Factor Family V3 Design

## Goal

Test three new, previously unresearched market-price factors only at frozen V11 de-risk events, so factor quality is measured without allowing the factor to create independent daily trading.

The research question is:

> When frozen V11 is already reducing risk, can market-based credit, cyclical/defensive, or equal-weight breadth information identify which de-risk events should be partially retained, and do so better than an unconditional matched retention control?

## Governance

- Current protocol: `ATM-SVP-2`.
- New lineage: `orthogonal-event-factor-family-v3`.
- Formal candidates are exactly `F-CREDIT`, `F-CYCLICAL`, `F-BREADTH`.
- V11 remains frozen and is never modified.
- Each candidate has a matched availability control; controls do not count as formal candidates.
- Formal candidate count = 3; formal run budget = 3.
- No rescue grid, factor combination, horizon search, retention-fraction search, stale-tolerance search, or band search is allowed after results are viewed.

## Frozen event-retention architecture

- Frozen V11 control: `nfci-dual-core-v11 / dualcore-v11-2026-08-15`.
- Fee: 1.00%.
- Slippage: 0.05%.
- Maximum gross: 100%.
- No shorting, financing, leverage, or negative cash.
- Signals: strict T-1.
- Research replay hard band: 25%.
- Candidate logic is evaluated only on unique execution dates on which frozen V11 actually trades.
- Let `priorBase` be the prior V11 event target and `currentBase` the current V11 event target.
- A de-risk reduction for a symbol is `max(priorBase[symbol] - currentBase[symbol], 0)`.
- If retention is enabled, retain exactly 50% of each reduction. The 50% fraction is fixed before the formal run and matches the existing single-signal retention semantics already used in the frozen V11 research lineage; it is not searched.
- Extra retained weights are scaled down proportionally only when required to keep total gross <=100%.
- No new unrelated asset is introduced: retention can only restore part of a symbol that was positive in the previous frozen V11 event target and is now being reduced.
- Between V11 event dates, the replay target remains unchanged; factor state changes alone cannot trigger a trade.

## Factor state and matched controls

For every factor candidate, state is computed only from observations available on or before the T-1 signal date. If the latest usable observation is more than 7 calendar days stale, the factor is unavailable.

At each V11 de-risk event:

- candidate path: retain 50% only when factor state is `risk-on`;
- matched control: retain 50% whenever that factor is available, regardless of risk-on/risk-off direction;
- when factor is unavailable, candidate and matched control both use the exact current V11 target.

This matched control isolates timing value from data start date and from the generic benefit/cost of slower de-risking.

## Exact factor candidates

### F-CREDIT — high-yield / investment-grade credit risk appetite

Raw market series:

- Yahoo `HYG`, iShares iBoxx $ High Yield Corporate Bond ETF.
- Yahoo `LQD`, iShares iBoxx $ Investment Grade Corporate Bond ETF.

Use adjusted close. On common source dates compute:

`credit_ratio = HYG_adjclose / LQD_adjclose`

Risk-on at T-1 iff the latest usable ratio is greater than or equal to the ratio 20 common observations earlier.

Economic hypothesis: relative high-yield strength versus investment-grade credit indicates improving corporate credit risk appetite and is relevant precisely when a base allocation model considers cutting risk.

### F-CYCLICAL — consumer discretionary / staples relative strength

Raw market series:

- Yahoo `XLY`, Consumer Discretionary Select Sector SPDR Fund.
- Yahoo `XLP`, Consumer Staples Select Sector SPDR Fund.

Use adjusted close. On common source dates compute:

`cyclical_ratio = XLY_adjclose / XLP_adjclose`

Risk-on iff the latest usable ratio is greater than or equal to the ratio 20 common observations earlier.

Economic hypothesis: discretionary outperformance versus staples reflects stronger cyclical growth/risk appetite relative to defensive consumption.

### F-BREADTH — equal-weight / cap-weight S&P 500 breadth

Raw market series:

- Yahoo `RSP`, Invesco S&P 500 Equal Weight ETF.
- Yahoo `SPY`, SPDR S&P 500 ETF Trust.

Use adjusted close. On common source dates compute:

`breadth_ratio = RSP_adjclose / SPY_adjclose`

Risk-on iff the latest usable ratio is greater than or equal to the ratio 20 common observations earlier.

Economic hypothesis: equal-weight outperformance indicates broader market participation rather than narrow mega-cap leadership.

## Fixed source rules

- Direction lookback: exactly 20 common source observations.
- Stale tolerance: exactly 7 calendar days.
- No percentile, z-score, moving average, level threshold, persistence count, or alternative horizon is tested in this family.
- Full source histories must not be fetched until design, preregistration, pure logic, fetcher, and executable Swift runner are committed.
- Fetcher may report only metadata, row counts, first/last date, provenance, and SHA; it may not calculate factor-conditioned returns or strategy metrics.

## Formal paths

Formal output contains seven paths:

1. `V11-CONTROL`
2. `C-CREDIT-ALWAYS`
3. `F-CREDIT`
4. `C-CYCLICAL-ALWAYS`
5. `F-CYCLICAL`
6. `C-BREADTH-ALWAYS`
7. `F-BREADTH`

Only the three `F-*` paths count as candidates.

## Evaluation

For every path report:

- full-history CAGR, Sharpe, MDD, volatility;
- trade count and average cash;
- target fingerprint;
- max gross / min target weight;
- 2020+ and 2022+ metrics;
- the same seven frozen V11 folds;
- number of V11 source event dates;
- number of de-risk events;
- factor-available de-risk events;
- factor-risk-on retained events.

## Admission gate

A factor receives `ADMIT_FOR_ROBUSTNESS` only if all are true:

- full-history CAGR > `V11-CONTROL` CAGR;
- full-history Sharpe > its own matched `C-*-ALWAYS` Sharpe;
- full-history MDD <=12%;
- at least 4/7 fixed folds have candidate Sharpe >= its matched control Sharpe;
- worst-fold Sharpe >0;
- max gross <=100%;
- minimum target weight >=0;
- no financing or negative cash.

A factor receives `STRONG_INCREMENTAL` only if it is admitted and:

- CAGR >= V11 CAGR +1.0 percentage point;
- Sharpe >= V11 Sharpe.

Passing is only permission for a separately preregistered robustness study, not product integration.

## Failure semantics

- A failed factor stays failed in this family.
- Do not change 20 observations to another horizon after results.
- Do not change 50% retention to 25/75/100% after results.
- Do not change the 7-day stale tolerance or 25% band.
- Do not combine factors in this trial.
- Any new factor transform, retention rule, or combination is a new preregistered family and counts separately under G3.
