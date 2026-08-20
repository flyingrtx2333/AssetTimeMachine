# Orthogonal Factor Family V2 Design

## Goal

Test three new, previously unresearched factor mechanisms as standardized V11 risk-budget deployment gates, without tuning any earlier factor, V11 parameter, execution band, or overlay rule after results are viewed.

The research question is:

> Can publicly reproducible funding-stress, cross-asset cyclical, or options-tail-risk information identify the subset of V11 cash-reserve periods in which deploying more of the existing 100% risk budget improves risk-adjusted performance relative to an ungated ALWAYS-FILL control?

## Governance

- Current protocol: `ATM-SVP-2`.
- New trial family: `orthogonal-factor-family-v2`.
- Formal candidates are exactly `F-FUNDING`, `F-COPGOLD`, and `F-SKEW`.
- `V11-CONTROL` and `ALWAYS-FILL` are controls and do not count as formal candidates.
- Formal run budget is exactly 3 candidate runs.
- No candidate may be replaced, transformed, or reparameterized after results are viewed.
- All failed candidates remain in G3 trial accounting.

## Frozen control and overlay semantics

- Frozen control: `nfci-dual-core-v11 / dualcore-v11-2026-08-15`.
- Fee: 1.00%.
- Slippage: 0.05%.
- Maximum gross exposure: 100%.
- Shorting: forbidden.
- Financing/leverage: forbidden.
- Negative cash: forbidden.
- Signals: strict T-1.
- Hard rebalance band: 25%, identical across ALWAYS-FILL and all three factors.

For every candidate:

1. Start from the exact frozen V11 positive target weights for the execution date.
2. Evaluate the factor only from observations available on or before the T-1 signal date.
3. If the factor is risk-on and V11 gross is in `(0,1)`, scale only the already-positive V11 holdings proportionally until gross reaches 100%.
4. Never open an asset whose V11 target is zero.
5. If the factor is risk-off or unavailable, preserve the V11 target unchanged.

`ALWAYS-FILL` applies step 3 whenever V11 gross is in `(0,1)` without a factor gate. It is the mandatory control for separating genuine factor timing from the mechanical effect of taking more risk.

## Factor candidates

### F-FUNDING — short-term funding stress compression

Raw sources:

- FRED `DCPF3M`: 90-Day AA Financial Commercial Paper Interest Rate, daily, Board of Governors of the Federal Reserve System.
- FRED `DFF`: Effective Federal Funds Rate, daily.

Construct on common observation dates:

`funding_spread = DCPF3M - DFF`

Risk-on at T-1 iff the latest usable funding spread is less than or equal to the funding spread 20 common observations earlier.

Interpretation: a falling commercial-paper premium relative to the policy/funding rate indicates easing short-term private funding stress.

The 20-observation horizon is fixed as a natural roughly one-month market horizon and is not searched.

### F-COPGOLD — copper/gold cyclical relative strength

Raw sources:

- Yahoo market series `HG=F`, COMEX copper futures continuous/front-market history.
- Yahoo market series `GC=F`, COMEX gold futures continuous/front-market history.

On common source dates compute:

`copper_gold_ratio = HG_close / GC_close`

Risk-on at T-1 iff the latest usable ratio is greater than or equal to the ratio 20 common observations earlier.

Interpretation: copper is an industrial/cyclical metal while gold has a stronger safe-haven/monetary role; relative copper strength is treated as a cross-asset signal of stronger cyclical risk appetite.

Only ratio direction is used. No ratio level, percentile, z-score, moving average, or roll adjustment is selected after results.

### F-SKEW — equity tail-risk pricing direction

Raw source:

- Yahoo market series `^SKEW`, representing the Cboe SKEW Index.

Risk-on at T-1 iff the latest usable SKEW close is less than or equal to the close 20 source observations earlier.

Cboe defines higher SKEW as more negative implied skew / greater priced tail risk. Therefore a falling SKEW is the preregistered risk-on direction.

The 20-observation horizon is fixed before the formal run and is not searched.

## Data discipline

- Before the design, preregistration, pure factor logic, fetcher, and Swift runner are committed, full factor histories must not be fetched.
- Metadata-only checks are allowed before freeze.
- Market-price data are treated as contemporaneous observations.
- FRED source observations use only dates at or before T-1; no future backfill is allowed.
- If the latest usable observation for a factor is more than 7 calendar days older than the signal date, the factor is unavailable and the candidate remains identical to V11 for that decision.
- The 7-calendar-day stale tolerance is fixed before the first formal run and is not searched.
- Full factor input range is `2001-01-01` through the exact end date of the frozen base history fixture used by the run.
- Data fetching code must not calculate candidate returns, Sharpe, MDD, factor-conditioned returns, or any performance diagnostic.

## Controls

Formal output must contain all five paths:

1. `V11-CONTROL`
2. `ALWAYS-FILL`
3. `F-FUNDING`
4. `F-COPGOLD`
5. `F-SKEW`

Only the final three count toward the formal candidate count.

## Evaluation

Report for all controls/candidates:

- full-history CAGR;
- Sharpe;
- maximum drawdown;
- annualized volatility;
- trade count;
- average cash ratio;
- target fingerprint;
- max gross and minimum target weight;
- 2020+ metrics;
- 2022+ metrics;
- the same seven V11 fixed folds:
  - `2012-07-05..2014-12-31`
  - `2015-01-01..2016-12-31`
  - `2017-01-01..2018-12-31`
  - `2019-01-01..2020-12-31`
  - `2021-01-01..2022-12-31`
  - `2023-01-01..2024-12-31`
  - `2025-01-01..latest`

## Admission gate

A factor receives `ADMIT_FOR_ROBUSTNESS` only if all are true:

- full-history CAGR > `V11-CONTROL` CAGR;
- full-history Sharpe > `ALWAYS-FILL` Sharpe;
- full-history MDD <= 12%;
- at least 4/7 fixed folds have candidate Sharpe >= `ALWAYS-FILL` Sharpe in the same fold;
- worst-fold Sharpe > 0;
- max gross <=100%;
- minimum target weight >=0;
- no financing or negative cash.

A factor receives `STRONG_INCREMENTAL` only if it is admitted and:

- full-history CAGR >= V11 CAGR + 1.0 percentage point;
- full-history Sharpe >= V11 Sharpe.

These are factor-screening gates only. Passing does not authorize App integration or a product claim.

## Failure semantics

- A FAIL is a useful negative result.
- Do not change 20 observations to 5/10/40/60 after viewing results.
- Do not add level thresholds, z-scores, moving averages, percentiles, persistence requirements, or combinations to rescue a failed factor.
- Do not change the 7-day stale tolerance or 25% band after results.
- Do not combine the three factors in this trial.
- Any new transform, factor, or combination is a new preregistered family with its own trial count.
