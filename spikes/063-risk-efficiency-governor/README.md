# Spike 063 - Risk Efficiency Governor

Goal: push the 062 line closer to 1.6 Sharpe by cutting risk only when the
current target mix has high expected volatility and weak trend/breadth quality.

Logic tested:

- Keep 060 contagion control, 061 currency cash selection, and 062 gold lock.
- Estimate target-mix volatility from current holdings before each rebalance.
- Measure target-weighted momentum and breadth quality.
- Scale risk assets only when expected volatility is high and quality is weak.
- Let the 061 cash selector use freed idle budget.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `governor_weak_momentum_vl20_tr130_tv80_ml40_mt15` | 14.62% | 7.85% | 9.01% | 1.5127 |
| 062 best baseline | 14.61% | 7.85% | 9.04% | 1.5059 |

Slices for the best result:

| Slice | Annualized | Sharpe |
| --- | ---: | ---: |
| 2020+ | 14.18% | 1.3297 |
| Last 10Y | 12.34% | 1.2865 |
| 2024+ | 20.94% | 1.7546 |

Key observations:

- The governor only triggered 4 times in the best candidate.
- It marginally reduces volatility and nudges Sharpe from 1.5059 to 1.5127.
- The effect is too small to be the main path to 1.6.

Conclusion:

The current best no-leverage/no-BTC high-return line is:

1. 060 China/HK contagion control.
2. 061 idle USD cash selector.
3. 062 gold panic-premium lock.
4. 063 sparse risk-efficiency governor.

This reaches 14.62% annualized return and 1.5127 full-history Sharpe, which is
better but still below the 1.6 target. The next useful search should seek a new
return source or a genuinely lower-correlation sleeve, not another defensive
wrapper around the same gold/equity engine.
