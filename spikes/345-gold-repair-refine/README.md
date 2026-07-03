# Spike 345 - Gold repair refine

## Verdict

A stronger research-level candidate was found and fixed-parameter replay verified.

This replaces spike 344 as the current research champion, but still needs App-equivalent engine replay before product claims or integration.

## Baselines

Old incumbent (`refine_buy_permission_only`):

- Full: 8.30% / -12.76%, Sharpe 0.94
- 2020+: 11.88% / -12.76%
- 10y: 9.98% / -12.76%

Spike 344 gold repair:

- Full: 8.44% / -10.93%, Sharpe 0.9792
- 2020+: 12.60% / -10.93%
- 10y: 10.59% / -10.93%
- 2022+: 10.92% / -10.93%

## Spike 345 best hit

Fixed replay from `verify_best.py`:

- Full: 8.72% / -10.53%, Sharpe 1.0027
- 2020+: 13.82% / -9.71%, Sharpe 1.2662
- 10y: 11.29% / -9.71%, Sharpe 1.1783
- 2022+: 11.94% / -9.19%, Sharpe 1.1663
- Avg exposure: 0.6014
- Turnover: 109.46
- Repair days: 176

Latest target weights:

- gold: 0.22
- nasdaq: 0.1365
- sp500: 0.4135

## Parameters

```json
{
  "dd_fast_n": 63,
  "dd_slow_n": 126,
  "dd_fast_cut": -0.08,
  "dd_slow_cut": -0.16,
  "deep_dd_cut": -0.24,
  "mom_fast_n": 30,
  "mom_slow_n": 150,
  "mom_fast_cut": -0.02,
  "mom_slow_cut": -0.05,
  "ma_fast": 80,
  "ma_slow": 220,
  "gold_stress_cap": 0.22,
  "gold_deep_cap": 0.20,
  "eq_ma": 120,
  "eq_mom_n": 150,
  "nas_min_mom": 0.04,
  "sp_min_mom": 0.0,
  "vol_n": 63,
  "score_mom_n": 120,
  "eq_dd_n": 90,
  "eq_dd_floor": -0.12,
  "handoff_ratio": 0.95,
  "second_ratio": 0.30
}
```

## Drawdown attribution after refine

Top fixed-replay drawdowns:

- 2008: -10.53%
- 2006: -10.23%
- 2014: -10.16%
- 2011: -9.99%
- 2020: -9.71%
- 2022: -9.19%
- 2010: -8.82%
- 2005: -8.31%

The candidate improved both return and drawdown against spike 344 in the research harness. Next step: implement the same overlay in App-equivalent Swift/backtest replay and compare against the same data path.
