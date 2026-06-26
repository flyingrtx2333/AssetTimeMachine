# Spike 060 - Contagion Controlled Global Repair

Goal: improve the 059 high-return global repair line by controlling the 2015
China/HK equity contagion window without adding leverage, shorting, or BTC.

Logic tested:

- Start from `global_eq_cap8_per6_top1_oil4_phase1_repair1`.
- Detect China/HK bubble rollover and weak global equity breadth.
- Temporarily scale equity/global-repair exposure during contagion windows.
- Release the control after US or global breadth repairs.
- Keep total target weight capped at 100%.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `contagion_cluster_cd63_eq35_glob0_gold0_us_repair` | 14.16% | 9.44% | 9.04% | 1.4642 |
| 059 best baseline | 14.35% | 9.68% | 9.27% | 1.4478 |

Slices for the best result:

| Slice | Annualized | Sharpe |
| --- | ---: | ---: |
| 2020+ | 13.87% | 1.3038 |
| Last 10Y | 11.53% | 1.2122 |
| 2024+ | 22.57% | 1.8455 |

Key observations:

- The control did improve Sharpe and moved the 2015 drawdown regression out of
  the worst slot.
- The new worst drawdown moved back to 2003-02-04 to 2003-04-07.
- This is useful, but it did not open a path to 1.6 Sharpe by itself.

Conclusion:

Keep the contagion control idea as a valid building block. The next bottleneck
is not China/HK equity contagion; it is the early-2003 gold drawdown and then
overall risk efficiency.
