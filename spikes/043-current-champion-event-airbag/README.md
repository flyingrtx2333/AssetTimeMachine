# Spike 043 - Current Champion Event Airbag

Goal: test whether a daily equity airbag on the current one-way champion can
reduce the remaining 2015/2022 drawdown without giving up too much return.

Tested:
- Partial equity scale-down after broad US equity shock.
- Held-asset breakdown exits.
- Gold redeployment when gold trend is healthy.
- No leverage, no shorting, no BTC.

Best result remained the baseline:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `baseline_one_way` | 13.53% | 9.87% | 9.53% | 1.3381 |
| `partial_us_airbag_40` | 9.62% | 12.06% | 8.72% | 1.0638 |

Conclusion:

Daily airbag exits remove too much rebound participation and sharply reduce
Sharpe. This is not the right mechanism.
