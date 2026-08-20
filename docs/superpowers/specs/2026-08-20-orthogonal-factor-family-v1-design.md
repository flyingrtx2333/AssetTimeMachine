# Orthogonal Factor Family V1 Design

## Goal

Test three new, economically distinct factors as standardized risk-budget completion gates on top of frozen `nfci-dual-core-v11 / dualcore-v11-2026-08-15`, without tuning V11 or any factor parameter after results are viewed.

## Frozen control and overlay semantics

- Frozen control: `nfci-dual-core-v11 / dualcore-v11-2026-08-15`.
- Execution: 1.00% fee + 0.05% slippage, no leverage, no shorting, no negative cash.
- Strict T-1.
- Overlay rule is identical for all three factor candidates: start from the exact frozen V11 positive target weights. If the factor is risk-on and V11 gross is in `(0,1)`, scale only existing positive V11 holdings proportionally to 100% gross. Do not open a position that V11 targets at zero. If factor is not risk-on or unavailable, leave V11 unchanged.
- `ALWAYS-FILL` is a non-candidate control that applies the same scaling whenever V11 gross is in `(0,1)` regardless of factor. This separates factor timing value from the effect of simply taking more risk.
- Use the same 25% hard rebalance band as frozen V11 for all overlays and controls.

## Exact factor candidates

### F-CURVE — Treasury term spread state

Source series: FRED `T10Y3M`, daily 10-year Treasury constant maturity minus 3-month Treasury constant maturity.

Risk-on at T-1 iff the latest observation available on or before the signal date is strictly greater than 0. No moving average, percentile, or threshold search is allowed.

Economic hypothesis: a normally sloped curve is a coarse indicator of less restrictive macro/credit-cycle conditions; inversion is treated as a reason not to spend V11 cash reserves.

### F-USD — Dollar-liquidity direction

Source series: Yahoo market index `DX-Y.NYB`.

Risk-on at T-1 iff the latest close is less than or equal to the close 20 source observations earlier. The 20-observation horizon is fixed as a natural one-month market horizon and is not searched.

Economic hypothesis: dollar weakening is consistent with less global dollar funding pressure; a strengthening dollar can tighten financial conditions outside the U.S.

### F-SIZE — Small-cap / large-cap breadth

Source series: Yahoo `^RUT` Russell 2000 and `^RUI` Russell 1000.

On common source dates compute `^RUT / ^RUI`. Risk-on at T-1 iff the latest ratio is greater than or equal to the ratio 20 common observations earlier. The 20-observation horizon is fixed and not searched.

Economic hypothesis: relative small-cap strength is a market-based proxy for broader cyclical/risk participation beyond large-cap leadership.

## Data discipline

- Full candidate histories must not be fetched until this design and the ATM-SVP-2 preregistration are committed.
- Market-price factor histories are treated as contemporaneous observations; no future data may be used.
- For each signal date use only the latest factor observation on or before T-1.
- If the latest usable factor observation is more than 7 calendar days stale, the factor is unavailable and the overlay stays identical to V11. This stale-data rule is frozen before the first formal run.
- Candidate factor histories must cover the V11 research period sufficiently to allow the same full-history V11 evaluation range after warmup.

## Controls

Formal output must contain:

1. `V11-CONTROL` — direct frozen V11.
2. `ALWAYS-FILL` — standardized risk-budget completion with no factor gate.
3. `F-CURVE`.
4. `F-USD`.
5. `F-SIZE`.

Only the final three count as tested factor candidates for G3 trial accounting.

## Evaluation

Report full-history CAGR, Sharpe, MDD, volatility, trade count, average cash, target fingerprint, max gross/min weight, 2020+, 2022+, and the same seven fixed V11 folds.

A factor receives `ADMIT_FOR_ROBUSTNESS` only if all are true:

- full-history CAGR > V11-CONTROL CAGR;
- full-history Sharpe > ALWAYS-FILL Sharpe;
- full-history MDD <= 12%;
- at least 4/7 folds have candidate Sharpe >= ALWAYS-FILL Sharpe in the same fold;
- worst-fold Sharpe > 0;
- no leverage, negative cash, or negative target weights.

A factor receives `STRONG_INCREMENTAL` only if it is admitted and full-history CAGR >= V11 CAGR + 1.0 percentage point and Sharpe >= V11 Sharpe.

These are factor-screening gates only, not product acceptance. An admitted factor must enter a separate preregistered robustness family before integration into any new strategy version.

## Failure rule

If a factor fails, do not change its 20-day horizon, sign rule, curve threshold, stale tolerance, band, or overlay semantics inside this family. No rescue grid is allowed. Any different factor or transform is a new preregistered family.
