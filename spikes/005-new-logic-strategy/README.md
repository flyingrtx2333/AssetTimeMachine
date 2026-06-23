# 005: New logic strategy spike

## Constraint

No parameter grid search. Each candidate must start from a distinct market hypothesis and use one fixed rule set. Parameters are only rough economic constants (e.g. 200-day trend, 12-month drawdown), not fitted knobs.

## Candidate logics

### A. Lifecycle Trend Engine

**Hypothesis:** Equity returns are mostly earned in healthy trend regimes. Crashes and post-bubble periods should be avoided quickly, not merely down-weighted. Gold is only a defense when gold itself is in a healthy trend.

- Risk-on: Nasdaq + S&P both above long trend and 6-month momentum positive.
- Crisis: Nasdaq loses long trend, 60-day drawdown is severe, or volatility regime spikes.
- Recovery: after crisis, re-enter gradually only after Nasdaq regains medium trend and positive momentum.
- Defense: gold only if above long trend and not in blowoff breakdown; otherwise cash.

### B. Crash Re-entry Ladder

**Hypothesis:** The best risk/reward is not continuous holding, but buying after broad equity damage once falling stops. It deliberately sits in cash/gold during undecided markets.

- Normal: modest broad equity exposure only in healthy trend.
- Crash: stay cash/gold while market is falling.
- Re-entry: when Nasdaq/SP500 are down materially from 1Y high but short momentum turns positive and medium trend recovers, deploy larger equity.
- Exit: if re-entry fails, cut back immediately.

### C. Role Switch Engine

**Hypothesis:** At each point, only one role should dominate: growth engine (Nasdaq/SP500), store-of-value engine (gold), or cash. Mixing many weak assets dilutes signal and increases false comfort.

- Rank Nasdaq, S&P, gold by absolute + relative trend quality.
- Hold only the dominant valid role.
- Reject assets in blowoff breakdown or high-volatility decay.
- Cash is an explicit asset, not leftover.

## Verdict: INVALIDATED for current objective

Ran fixed-rule, non-grid validations with real `units + cash + fee + slippage`, T-1 signal / T execution.

### Tested logic families

1. Lifecycle Trend Engine — structural trend / crisis / recovery states.
2. Crash Re-entry Ladder — buy only after broad damage and short-term repair.
3. Role Switch Engine — one dominant role: growth, gold, or cash.
4. Capital Floor Risk Budget — 90% high-water-mark floor; exposure comes from cushion only.
5. Volatility Budget Role — fixed volatility budget on the dominant valid role.
6. Repair Window Harvester — only participate in equity repair and gold healthy windows.
7. Dual Mandate Drawdown Mode — switch from return mode to capital-preservation mode after portfolio drawdown.
8. Quality Growth with new real assets — QQQ/XLK/SPY via Yahoo adjusted close converted to CNY.
9. Market Permission Growth — QQQ/XLK only when SPY confirms broad risk-on.

### Results summary

No candidate delivered a full-cycle quality jump. Best full-cycle annualized returns were still low and came with 20–39% drawdowns. The only candidate under 10% drawdown was `D_capital_floor_risk_budget`, but it produced ~0% annualized return, so it is not viable.

### What worked

- The spike proved that merely changing signal logic or adding QQQ/XLK does not solve the objective under strict full-cycle drawdown control.
- Capital-floor risk budgeting can mechanically control drawdown, but without a strong low-correlation return source it just converts the strategy into cash.

### What failed

- Trend lifecycle, crash re-entry, role switching, repair-window harvesting, QQQ/XLK quality growth, and SPY market-permission logic all failed the full-cycle objective.
- Main failure episodes repeatedly came from 2004–2009, 2011–2013 gold drawdowns, 2020 shock, and 2022 growth bear market.

### Recommendation for next real research

The current long-only growth/gold/cash universe is likely insufficient for a full-cycle 8–10% annualized strategy with ~9% max drawdown. A genuine next logic should introduce a different payoff source, not more timing rules:

- managed-futures / time-series trend across commodities, rates, FX, equity index futures;
- short-vol/long-vol defensive payoff proxies if data and product design allow;
- cross-asset carry / cash-plus instruments;
- or a fundamentally different allocation objective that accepts higher drawdown.

Do not continue by grid-searching the existing signal thresholds.
