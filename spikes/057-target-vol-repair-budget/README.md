# Spike 057 - Target Vol Repair Budget

Goal: test whether an ex-ante target-volatility budget can improve the 053
repair-overlay engine more cleanly than seasonal risk scaling.

Logic tested:

- Build the 053 repair-overlay target portfolio first.
- Estimate the target portfolio's recent realized volatility.
- Clip total exposure only when the estimated target volatility is above a
  budget.
- Add an optional short-term shock clip.
- Optionally add the gold phase lock from spike 055.
- No BTC, no leverage, no shorting.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `target_vol_lb42_tv105_floor65_shock70_phase1_repair1` | 13.03% | 9.12% | 8.46% | 1.4450 |
| 053 baseline repair top1 | 13.96% | 9.44% | 9.15% | 1.4297 |
| 056 seasonal torque best | 11.73% | 9.39% | 7.54% | 1.4622 |

Slices for the best result:

| Slice | Annualized | Sharpe |
| --- | ---: | ---: |
| 2020+ | 12.65% | 1.2655 |
| Last 10Y | 10.57% | 1.1765 |
| 2024+ | 18.91% | 1.6745 |

Conclusion:

Target-volatility clipping is cleaner to explain, but the evidence is weaker
than seasonal torque. It improves full-history Sharpe modestly to 1.4450 while
cutting annualized return to 13.03%. This should not be promoted over the 053 or
056 candidates.
