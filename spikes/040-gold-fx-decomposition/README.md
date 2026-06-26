# Spike 040 - Gold FX Decomposition

Goal: test whether CNY gold exposure should be reduced or substituted with USD
cash when CNY gold strength is mostly driven by FX while USD gold is weak.

New logic tested:
- Fetch real `gold_usd` and `usd_per_cny` history.
- Build a USD cash CNY-value proxy.
- Scale or replace `gold_cny` when USD gold is weak under strict, drawdown, or
  FX-only definitions.

Best results:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `baseline_one_way` | 13.53% | 9.87% | 9.53% | 1.3381 |
| `gold_fx_drawdown_scale60_usd0` | 13.52% | 9.87% | 9.53% | 1.3369 |
| `gold_fx_fx_only_scale60_usd0` | 13.52% | 9.87% | 9.53% | 1.3369 |

Conclusion:

The decomposition is economically reasonable, but in this strategy it mostly
removes useful gold exposure and does not improve the 2015 tail. Do not promote
this logic.
