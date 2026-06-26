# Spike 044 - High-Return / Defensive Ensemble

Goal: screen whether the best high-return satellite and the best defensive
profit-lock engine are complementary enough to exceed 1.4 Sharpe.

Method:
- Static NAV sleeve blend only.
- Underlying sleeves already include fees and slippage.
- Any passing result would require target-weight replay before app use.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `blend_satellite_80` | 14.08% | 10.16% | 9.60% | 1.3777 |
| `confirmed_satellite_best` | 14.44% | 10.56% | 9.84% | 1.3771 |
| `profit_lock_best` | 12.28% | 7.96% | 8.53% | 1.3577 |

Conclusion:

The engines are not complementary enough. Static blending slightly smooths the
curve but still stalls around 1.378. No target-weight replay is warranted.
