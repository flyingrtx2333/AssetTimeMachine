# Spike 344 - Gold drawdown repair

## Verdict

Research-level promotion hit found. Do not integrate blindly yet; next step is App-equivalent implementation/replay.

## Why this mechanism

A corrected attribution pass showed the incumbent (`refine_buy_permission_only`) is not mainly limited by Nasdaq. The largest drawdowns are dominated by the gold sleeve:

- 2022 drawdown: gold contribution about -12.23%
- 2008 drawdown: gold contribution about -12.17%
- 2006 drawdown: gold contribution about -9.55%
- 2011 / 2026 drawdowns also show large gold drag

So the new mechanism keeps the incumbent return engine but adds a local gold-sleeve repair:

- if gold is in a drawdown / trend-break regime, cap gold from 0.45/0.30 down to a stress cap;
- freed weight goes only to healthy Nasdaq/S&P sleeves; otherwise it remains cash;
- no cash-yield advantage;
- no OHLC forced-sell rule;
- no full strategy rewrite.

## Current incumbent

`refine_buy_permission_only`

- Full: CAGR 8.30%, Max DD -12.76%, Sharpe 0.94
- 2020+: 11.88% / -12.76%
- 10y: 9.98% / -12.76%

## Best hit

`incumbent_gold_drawdown_repair`

Exact replay from `verify_exact.py`:

- Full: CAGR 8.44%, Max DD -10.93%, Sharpe 0.9792
- 2020+: 12.60% / -10.93%, Sharpe 1.1735
- 10y: 10.59% / -10.93%, Sharpe 1.1194
- 2022+: 10.92% / -10.93%, Sharpe 1.0725
- Avg exposure: 0.604
- Turnover: 95.73
- Repair days: 150

Latest target weights from the exact hit:

- gold 0.24
- nasdaq 0.1305
- sp500 0.3885

## Drawdown verification

Exact replay top drawdowns:

- 2022: -10.93% vs incumbent -12.76%
- 2008: -10.61% vs incumbent -11.95%
- 2014: -10.20% vs incumbent -10.29%
- 2020: -9.73% vs incumbent -10.00%
- 2006: -9.51% vs incumbent -11.81%
- 2011: -8.67% vs incumbent -9.98%
- 2026: -7.90% vs incumbent -9.80%

## Best overlay parameters

```json
{
  "dd_fast_n": 63,
  "dd_slow_n": 126,
  "dd_fast_cut": -0.09,
  "dd_slow_cut": -0.18,
  "deep_dd_cut": -0.24,
  "mom_fast_n": 20,
  "mom_slow_n": 120,
  "mom_fast_cut": -0.03,
  "mom_slow_cut": -0.05,
  "ma_fast": 100,
  "ma_slow": 200,
  "gold_stress_cap": 0.24,
  "gold_deep_cap": 0.22,
  "eq_ma": 120,
  "eq_mom_n": 120,
  "nas_min_mom": 0.02,
  "sp_min_mom": 0.0,
  "vol_n": 63,
  "score_mom_n": 120,
  "eq_dd_n": 126,
  "eq_dd_floor": -0.12,
  "handoff_ratio": 0.85,
  "second_ratio": 0.3
}
```

## Decision

This is the first recent mechanism that beats the incumbent across full-cycle return, full-cycle drawdown, Sharpe, 2020+ slice, and 10y slice in the research harness.

Next required step before product claims: port the overlay into the App-equivalent backtest engine and replay with the same market data path.
