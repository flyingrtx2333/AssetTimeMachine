# Spike 034 - USD Defensive Sleeve

Goal: test whether USD cash can act as a no-leverage low-correlation defensive
asset in the CNY-denominated strategy.

Logic tested:
- Use only the current champion's idle cash budget to hold USD when USD trend or
  cash-yield comparison is favorable.
- In risk-off states, optionally reduce equity exposure and redeploy the freed
  budget to USD.
- USD is converted from `usd_per_cny` using the same app convention.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `unused_trend_lb40_cap100_rs100` | 13.70% | 10.12% | 9.64% | 1.3384 |

Conclusion:

USD cash was almost neutral. It did not materially improve full-history Sharpe
and slightly weakened some recent slices. This is not the missing 1.4 source.
