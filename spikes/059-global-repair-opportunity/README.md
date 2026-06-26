# Spike 059 - Global Repair Opportunity

Goal: find a more independent return source than repeatedly wrapping the 053
repair engine with risk controls.

Logic tested:

- Start from the 053 drawdown-repair overlay.
- Add a separate global repair sleeve using Hang Seng and Nikkei.
- Optionally add WTI as a tiny commodity repair sleeve.
- Extra assets are not ranked into the main engine; they can only use idle risk
  budget after a drawdown has started to repair.
- No leverage, no shorting, no BTC.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `global_eq_cap8_per6_top1_oil4_phase1_repair1` | 14.35% | 9.68% | 9.27% | 1.4478 |
| 053 baseline repair top1 | 13.96% | 9.44% | 9.15% | 1.4297 |
| 055 phase-lock best | 14.00% | 9.44% | 9.15% | 1.4338 |

Slices for the best result:

| Slice | Annualized | Sharpe |
| --- | ---: | ---: |
| 2020+ | 13.75% | 1.2516 |
| Last 10Y | 11.46% | 1.1734 |
| 2024+ | 21.21% | 1.7134 |

Key observations:

- The global equity repair sleeve fired only 8 times, but it lifted both
  annualized return and full-history Sharpe.
- The best high-return result shifted the worst drawdown back to the 2015
  China/global-equity window: 2015-05-27 to 2015-09-28.
- WTI-only repair remained weak and reopened 2008 drawdown, so WTI should not be
  used as the core independent sleeve.

Conclusion:

This is the best new high-return lead in the latest round. It does not reach
1.6 Sharpe, but it moves the frontier from about 13.96% / 1.4297 to
14.35% / 1.4478 without BTC or leverage.

The next useful step is not more global-asset expansion. It is a targeted 2015
equity-contagion control that preserves the global repair return while avoiding
the 2015 drawdown regression.
