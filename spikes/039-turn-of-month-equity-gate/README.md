# Spike 039 - Turn-Of-Month Equity Gate

Goal: test a known equity calendar anomaly: allow higher equity exposure around
month start/end and reduce equity exposure mid-month, while leaving gold
ungated.

Important implementation note:

The first script version accidentally rebalanced every day back to target,
which made the baseline incomparable. The final result only trades when the
strategy target changes or when the normal 60-session rebalance happens.

Best results after correction:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `baseline_one_way` | 13.53% | 9.87% | 9.53% | 1.3381 |
| `turn_f7_l4_off50_gold0_keep` | 12.08% | 9.72% | 8.83% | 1.2948 |
| `turn_f7_l6_off50_gold0_keep` | 12.13% | 9.72% | 8.97% | 1.2819 |

Conclusion:

The turn-of-month effect improves some recent slices but fails the full-history
objective after costs. It reduces exposure more than it adds alpha. Do not
promote this logic.
