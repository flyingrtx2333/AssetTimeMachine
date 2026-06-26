# Spike 072 - Quality Income Gated Basket

Goal: try a different return source under the 1% fee assumption: a low-turnover
quality equity basket, gated by market trend, with income/gold/cash as the
stabilizing sleeve.

Method:
- Use Yahoo adjusted closes converted to CNY through the app's `usd_per_cny`
  history.
- Include quality stocks, sector funds, income funds, gold ETFs, and the current
  app-equivalent `CORE` sleeve as possible offensive assets.
- Rebalance every 63 or 126 sessions.
- Score risk assets by trend, risk efficiency, or stability.
- Deduct 1% fee and 0.05% slippage on every buy and sell.
- No leverage, no shorting, no BTC.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: |
| `trend_rb126_top3_risk55_inc25_gold10_cap35_gate_crash65` | 11.54% | 24.73% | 12.41% | 0.9141 | 0.8976 |
| `trend_rb126_top3_risk65_inc25_gold10_cap35_gate_crash65` | 13.16% | 27.39% | 14.27% | 0.9110 | 0.9088 |
| `efficiency_rb126_top2_risk75_inc15_gold10_cap25_gate_crash65` | 10.29% | 18.99% | 11.18% | 0.9043 | 0.9315 |

Conclusion:

Reject.  The dynamic quality basket raises recent returns but hurts full-cycle
Sharpe.  Even at 126-session turnover, quality/sector rotation still spends too
much time in large equity drawdowns and does not beat the current app-equivalent
core.

The useful finding is that dynamic quality rotation is not the missing edge
under a 1% transaction fee.  The next related test should remove almost all
turnover and inspect static or ultra-low-frequency quality/income baskets.
