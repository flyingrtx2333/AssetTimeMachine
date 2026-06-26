# Spike 038 - Energy Inflation Sleeve

Goal: test WTI as a separate inflation/commodity sleeve on top of the current
champion. WTI uses real `oil_wti_cny` public history from 2000 onward.

New logic tested:
- WTI is not ranked with equities.
- It can only use idle cash.
- It requires positive trend, moving-average confirmation, drawdown guard, and
  optional gold/equity confirmation.

Best results:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `baseline_one_way` | 13.53% | 9.87% | 9.53% | 1.3381 |
| `energy_dual_confirmed_cap8_cv60` | 13.35% | 10.03% | 9.67% | 1.3043 |
| `energy_risk_clean_cap8_cv60` | 13.45% | 11.05% | 9.74% | 1.3043 |

Conclusion:

WTI has enough history, but its volatility and crash behavior hurt the current
strategy more than the inflation upside helps. Do not promote this logic.
