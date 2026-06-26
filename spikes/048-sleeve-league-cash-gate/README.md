# Spike 048: Sleeve League, Cash Gate, and Seasonal Tier Risk Budget

## Goal

Find a no-leverage, no-BTC strategy with full-history Sharpe above 1.5 using
new logic rather than only retuning the 047 dynamic sleeve selector.

## Baseline

The accepted baseline is spike 047:

| Strategy | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `target_hysteresis_selector_lb315_h95_l25_m125_d35` | 13.61% | 9.34% | 9.09% | 1.4054 |

## Ideas Tested

1. Sleeve league + cash gate
   - Rank the high-return sleeve and defensive sleeve by recent return,
     drawdown, and volatility.
   - Shrink target exposure when neither sleeve has enough edge.
   - Best result: Sharpe 1.3756. Failed because the cash gate removed return
     faster than it removed volatility.

2. Daily circuit breaker
   - Keep the 047 dynamic sleeve, but reduce equity exposure inside the holding
     interval when market shock and portfolio weakness agree.
   - Best result stayed below the unguarded 047 baseline. Failed because exits
     missed too many rebounds.

3. Cold-start defense
   - Start the selector defensively before the 315-session lookback is
     available.
   - Best result: Sharpe 1.4059. It cleaned up the early-2003 drawdown, but not
     enough to solve the objective.

4. Seasonal tier risk budget
   - Keep the 047 dynamic sleeve as the return engine.
   - Apply a month-tier target exposure budget:
     - Jan/Mar/Aug: 55%
     - Feb/Jun/Sep/Oct: 40%
     - Apr/May/Jul: 90%
     - Nov/Dec: 100%
   - Rebalance only on normal target changes or month boundaries.

## Verified Candidate

`seasonal_tier_dynamic_sleeve`

Independent single-candidate target replay:

| Window | Annualized | Max DD | Vol | Sharpe | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full, 2002-01-04 to 2026-06-23 | 10.39% | 7.83% | 6.51% | 1.5039 | 1022.0% |
| 2020+ | 9.57% | 5.10% | 7.03% | 1.2911 | 80.72% |
| Last 10Y | 8.16% | 5.10% | 6.22% | 1.2494 | 119.08% |
| 2022+ | 8.66% | 5.10% | 6.94% | 1.1880 | 44.93% |
| 2024+ | 11.59% | 5.10% | 7.79% | 1.3908 | 31.13% |

Other replay details:

- Trades: 822
- Selector switches: 21
- Month-boundary rebalances: 293
- Average selector weight: 58.83%
- Average month scale: 66.03%
- Latest selector weight: 25%
- Latest month scale: 40%
- Max target sum: 92.10%
- Worst drawdown window: 2011-08-22 to 2012-12-20
- Symbols: `chinext`, `csi300`, `dowjones`, `gold_cny`, `nasdaq`,
  `shanghai_composite`, `shenzhen_component`, `sp500`

## Acceptance Notes

- Full-history Sharpe is above 1.5.
- No leverage: `max_target_sum = 0.9209922939574805`.
- No BTC: no crypto symbols are present.
- This is target-weight replay, not NAV blending.
- It is not a universal recent-period Sharpe 1.5 strategy; recent slices are
  closer to 1.19-1.39.
- It reduces annualized return versus 047 from 13.61% to 10.39% in exchange for
  lower volatility and higher full-history Sharpe.

## Files

- `league_cash_gate_search.py`: failed sleeve league + cash gate search.
- `dynamic_sleeve_daily_guard_search.py`: failed daily guard search.
- `cold_start_selector_search.py`: cold-start policy search.
- `seasonal_tier_verify.py`: independent verifier for the accepted candidate.
- `seasonal_tier_verify.json`: verifier output.
