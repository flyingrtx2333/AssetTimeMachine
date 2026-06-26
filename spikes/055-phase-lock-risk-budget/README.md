# Spike 055 - Phase Lock Risk Budget

Goal: improve the 053 repair-overlay candidate with a new state-machine layer,
without adding BTC or leverage.

Logic tested:

- Start from the 053 drawdown-repair overlay.
- If an asset had a strong run and then rolled over, temporarily treat that
  asset as its own risk source.
- Clip the asset's target weight and leave freed budget in cash.
- Test gold-only, gold+China, and all-risk-asset lock universes.
- Optional portfolio drawdown budget was also tested.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `phase_gold_middle_scale25_max63_no_pf_repair1` | 14.00% | 9.44% | 9.15% | 1.4338 |
| 053 baseline repair top1 | 13.96% | 9.44% | 9.15% | 1.4297 |
| 053 baseline repair top2 | 14.09% | 10.42% | 9.23% | 1.4293 |

Slices for the best result:

| Slice | Annualized | Sharpe |
| --- | ---: | ---: |
| 2020+ | 13.96% | 1.2932 |
| Last 10Y | 11.38% | 1.1880 |
| 2024+ | 21.02% | 1.7280 |

Conclusion:

Gold phase lock is a real but tiny improvement. It moves full-history Sharpe
from 1.4297 to 1.4338 and keeps annualized return near 14%, but it is nowhere
near the 1.6 target. Do not promote this as the final answer; keep it as a small
component candidate.
