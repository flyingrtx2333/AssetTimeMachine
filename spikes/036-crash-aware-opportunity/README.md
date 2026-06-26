# Spike 036 - Crash-Aware Opportunity

Goal: test whether a crash-aware overlay plus a broader no-BTC opportunity
satellite can improve the current champion without leverage.

New logic tested:
- China equity bubble-rollover lock.
- Cross-asset opportunity satellite from Dow, Shenzhen Component, ChiNext,
  Hang Seng, Nikkei, and WTI.
- Optional correlation cap and smooth risk budget.

Best results:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `risk_clean_skip_weak_months_cap10_per10_top2` | 14.18% | 13.14% | 9.93% | 1.3427 |
| `cn_lock_redeploy_gold_risk_clean_smooth_after_cap10_per10_top2` | 12.46% | 9.98% | 8.78% | 1.3392 |
| `baseline_one_way` | 13.53% | 9.87% | 9.53% | 1.3381 |

Conclusion:

The broader opportunity satellite can raise annualized return, but it also
reopens 2015/2020 tail risk. The China lock reduces risk only by giving up too
much return. Do not promote this logic.
