# Spike 045 - Contagion Quarantine

Goal: test a specific 2015 hypothesis: after an A-share bubble rollover, avoid
immediately handing risk to other equities until US equities repair.

Tested:
- Full and partial equity quarantine.
- 120/180 session quarantine windows.
- Optional early release after US repair.
- Gold redeployment when gold trend is healthy.

Best result remained the baseline:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `baseline_one_way` | 13.53% | 9.87% | 9.53% | 1.3381 |
| `quarantine_120_soft55_repair` | 13.43% | 9.72% | 9.46% | 1.3376 |

Conclusion:

The quarantine changes the drawdown shape but does not improve Sharpe. It gives
up return faster than it removes risk.
