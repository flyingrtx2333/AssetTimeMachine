# Spike 056 - Seasonal Repair Torque

Goal: test whether the 053 high-return repair engine can inherit the high
Sharpe behavior of the earlier seasonal/cash line without using external funds.

Logic tested:

- Start from the 053 repair-overlay engine.
- Apply seasonal risk-budget scales to weak, mid, and good months.
- Test scaling the whole target versus scaling only the base target.
- Test allowing repair overlays in all months, non-weak months, or good months.
- Optionally add the gold phase lock from spike 055.
- Use only app-native market assets; no BTC, no leverage, no external Treasury
  fund assets.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `season_torque_w65_m70_g100_whole_target_all_phase1_repair1` | 11.73% | 9.39% | 7.54% | 1.4622 |
| 053 baseline repair top1 | 13.96% | 9.44% | 9.15% | 1.4297 |

Slices for the best result:

| Slice | Annualized | Sharpe |
| --- | ---: | ---: |
| 2020+ | 11.10% | 1.2840 |
| Last 10Y | 9.25% | 1.2123 |
| 2024+ | 16.98% | 1.7278 |

Conclusion:

Seasonal risk torque improves full-history Sharpe more than the phase-lock
logic, but it pays for that by cutting annualized return from about 14% to
11.73%. It does not solve the requested high-return/high-Sharpe target. The
finding is still useful: the calendar edge is real, but under the no-leverage
constraint it mostly converts return into lower volatility instead of creating
new return.
