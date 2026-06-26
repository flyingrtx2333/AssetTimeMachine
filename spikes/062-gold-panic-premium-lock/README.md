# Spike 062 - Gold Panic Premium Lock

Goal: address the 061 line's remaining worst drawdown, which is driven by early
2003 gold exposure after a fast panic-premium run-up and rollover.

Logic tested:

- Keep 060 contagion control and 061 currency cash selection.
- Arm a gold lock after short-term gold overheating.
- When gold cracks after the hot state, temporarily scale gold exposure.
- Release after gold reclaims the moving average or after a cooldown.
- Keep freed budget as CNY cash or USD cash via the 061 selector.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `gold_panic_hot30_100_cr20_45_ma20_s25_cd21_ma_reclaim` | 14.61% | 7.85% | 9.04% | 1.5059 |
| 061 best baseline | 14.67% | 9.44% | 9.14% | 1.4961 |

Slices for the best result:

| Slice | Annualized | Sharpe |
| --- | ---: | ---: |
| 2020+ | 14.19% | 1.3285 |
| Last 10Y | 12.31% | 1.2745 |
| 2024+ | 20.94% | 1.7546 |

Key observations:

- The gold lock successfully cuts the 2003 drawdown from about 9.44% to 7.85%.
- It costs a small amount of annualized return and recent upside.
- The best state machine fired 10 times and was active on 17 rebalance checks.

Conclusion:

The panic-premium lock is a valid risk repair, but it is not the missing return
source. After this step, the remaining gap to 1.6 is mostly a return/volatility
efficiency problem rather than a single drawdown-window problem.
