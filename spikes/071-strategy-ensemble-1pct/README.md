# Spike 071 - Strategy Ensemble at 1% Fee

Goal: test whether existing app-equivalent strategy curves contain enough
independent behavior to create a higher-Sharpe no-leverage sleeve ensemble under
the current 1% default transaction fee.

Method:
- Use only the current app-equivalent Python engine in `tools/`.
- Run the four supported strategy curves with `fee_rate_pct=1.0` and
  `slippage_rate_pct=0.05`.
- Blend already fee-adjusted strategy NAV curves as a conservative first-pass
  static sleeve screen.
- Also test strategy-level dynamic selectors using trailing return, Sharpe,
  Calmar, and stability scores.
- No leverage, no BTC.

Coverage:
- 2002-03-04 through 2026-06-23.

Best results:

| Candidate | Type | Annualized | Max DD | Vol | Sharpe |
| --- | --- | ---: | ---: | ---: | ---: |
| `coreGoldSatelliteOneWayVolManagedMomentum:0.80` | static | 8.66% | 8.95% | 7.93% | 1.0540 |
| `coreGoldSatelliteOneWayVolManagedMomentum` | single | 10.69% | 11.23% | 9.91% | 1.0423 |
| `calmar_lb252_rb21_top1` | selector | 11.26% | 17.38% | 10.98% | 0.9963 |
| `coreGoldSatelliteEquityBreadthMomentum` | single | 13.08% | 18.85% | 13.10% | 0.9743 |

High-return filter:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `coreGoldSatelliteEquityBreadthMomentum:0.55 + coreGoldSatelliteOneWayVolManagedMomentum:0.45` | 12.03% | 15.05% | 11.50% | 1.0148 |
| `coreGoldSatelliteEquityBreadthMomentum:0.70 + coreGoldSatelliteOneWayVolManagedMomentum:0.30` | 12.39% | 16.33% | 12.01% | 1.0021 |

Conclusion:

Reject.  Strategy-level blending does not create a new high-Sharpe source.  The
best Sharpe is only about 1.05 and requires diluting the one-way strategy with
cash, which cuts annualized return below 9%.  The dynamic selectors are worse.

This says the current app-equivalent strategy family is too correlated; the next
useful path is not more strategy-sleeve mixing, but a new underlying return
source with low turnover under the 1% fee assumption.
