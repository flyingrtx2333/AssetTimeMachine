# Spike 029 - Event Risk State Machine

Goal: test whether a new daily event-driven risk state can push the current
no-leverage strategy above 1.4 Sharpe.

This is not the current app engine. It is a concept probe:
- Base target is the current one-way volatility-managed router.
- Daily risk events can liquidate selected holdings before the next scheduled
  rebalance.
- Cash receives the same app cash yield.
- No leverage, no shorting, no financing.

Tested event modules:
- US equity breakdown exit.
- China bubble contagion exit.
- Gold blowoff invalidation.
- Portfolio drawdown cooldown.
- Held-asset breakdown exits.

Result summary:

| Candidate | Annualized | Max DD | Vol | Sharpe | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| `daily_contagion_exit` | 12.75% | 9.72% | 9.30% | 1.2967 | Best event candidate, worse than current champion |
| `daily_held_equity_breakdown` | 9.51% | 9.72% | 7.99% | 1.1421 | Too much rebound loss |
| `daily_tail_state_machine` | 4.37% | 10.24% | 5.70% | 0.7555 | Over-defensive |

Conclusion:

Daily exits reduced some risk, but they also removed too much participation in
rebounds. This direction did not improve on the current app champion and should
not be promoted without a substantially different event model.
