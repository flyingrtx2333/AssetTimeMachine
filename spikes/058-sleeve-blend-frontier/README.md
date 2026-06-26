# Spike 058 - Sleeve Blend Frontier

Goal: test whether the existing best sleeves are complementary enough to reach
the user's target of higher annualized return and ideally 1.6 Sharpe.

This is a NAV-level screen, not product truth. Each sleeve is first replayed
with its own fees/slippage, then sleeve daily NAV returns are blended. A passing
result would still need target-weight-level replay before app use.

Sleeves tested:

- `repair_053`: current high-return repair-overlay candidate.
- `seasonal_056`: app-native seasonal risk torque candidate.
- `carry_049`: high-Sharpe seasonal carry candidate, using external Treasury
  fund data.

Return correlations:

| Pair | Daily return correlation |
| --- | ---: |
| `repair_053` / `seasonal_056` | 0.9797 |
| `repair_053` / `carry_049` | 0.9213 |
| `seasonal_056` / `carry_049` | 0.9421 |

Best static NAV blend:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| 15% `seasonal_056` / 85% `carry_049` | 10.81% | 8.15% | 6.68% | 1.5219 |
| 100% `carry_049` | 10.64% | 8.05% | 6.59% | 1.5191 |

Best dynamic router:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `router_sharpe_lb63_rb21` | 12.11% | 7.85% | 7.80% | 1.4593 |

Conclusion:

The old sleeves are too correlated to blend into a new high-Sharpe/high-return
candidate. Static blending barely improves on the low-return 049 carry sleeve,
and dynamic routing is weaker than the simple static high-Sharpe sleeve.

This rules out "just mix 053, 056, and 049" as a path to 1.6 Sharpe. The next
promising direction needs a truly independent return source rather than another
combination of the same gold/equity/cash timing signals.
