# Spike 047: Dynamic Sleeve Selector

## Goal

Find a no-leverage, no-BTC strategy whose verified app-equivalent target-weight
replay can cross Sharpe 1.4 without collapsing annualized return.

## Idea

Instead of tuning one existing strategy, this spike adds a portfolio construction
layer between two previously verified sleeves:

- High-return sleeve: confirmed acceleration extra-equity satellite from spike
  042.
- Defensive sleeve: profit-lock risk budget from spike 030.

The selector runs every 21 sessions. It compares the two sleeves over a long
lookback and uses hysteresis:

- Stay near the high-return sleeve when its trailing edge over the defensive
  sleeve is large enough.
- Cut back to the defensive sleeve when the satellite sleeve or whole portfolio
  drawdown breaches the guard.
- Use two discrete satellite weights to avoid tiny noisy flips.

## Search Path

1. `dynamic_sleeve_selector.py` screened the idea at NAV level only.
   - Best initial candidate: Sharpe 1.3987.
2. `refine_hysteresis_selector.py` refined the same mechanism at NAV level.
   - Best NAV candidate: Sharpe 1.4010.
   - This was not accepted because NAV blending can overstate product truth.
3. `target_weight_replay.py` replayed the NAV winner through target weights.
   - Replay result fell to Sharpe 1.3849.
4. `target_replay_search.py` searched the selector at target-weight level using
   precomputed sleeve targets.
5. `verify_best_target_selector.py` independently replayed the best single
   candidate.

## Verified Candidate

`target_hysteresis_selector_lb315_h95_l25_m125_d35`

Parameters:

- Mode: `hysteresis_selector`
- Lookback: 315 sessions
- Satellite high weight: 95%
- Satellite low weight: 25%
- Return margin: 1.25%
- Satellite drawdown guard: 3.5%
- Portfolio drawdown guard: 3.0%

Independent single-candidate target replay:

| Window | Annualized | Max DD | Vol | Sharpe | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full, 2002-01-04 to 2026-06-23 | 13.61% | 9.34% | 9.09% | 1.4054 | 2169.82% |
| 2020+ | 12.61% | 7.56% | 10.06% | 1.1908 | 115.74% |
| Last 10Y | 10.44% | 7.56% | 9.04% | 1.1067 | 169.91% |
| 2022+ | 12.59% | 7.56% | 9.92% | 1.2022 | 69.89% |
| 2024+ | 19.68% | 7.05% | 10.92% | 1.6343 | 55.92% |

Other replay details:

- Trades: 348
- Switches: 27
- Average satellite weight: 56.87%
- Latest satellite weight: 25%
- Max target sum: 99.2%
- Worst drawdown window: 2003-02-04 to 2003-04-07
- Symbols: `chinext`, `csi300`, `dowjones`, `gold_cny`, `nasdaq`,
  `shanghai_composite`, `shenzhen_component`, `sp500`

## Acceptance Notes

- No leverage: the independent replay reports `max_target_sum = 0.992`.
- No BTC: the symbol list contains no crypto assets.
- Not a cash-dilution trick: full-history annualized return remains 13.61%.
- Product-truth level: the accepted result comes from target-weight replay with
  fees, slippage, cash, buys, sells, and no shorting.
- Robustness: neighboring target-level candidates also land slightly above 1.4,
  so the result is not a single isolated point.

## Files

- `target_search_results.json`: full target-level search output.
- `best_target_verify.json`: independent single-candidate verification.
- `verify_best_target_selector.py`: reproducible verifier for the accepted
  candidate.

## Caveat

The full-history Sharpe crosses 1.4, but the 2020+ and last-10-year Sharpe
ratios are closer to 1.1-1.2. This is a real improvement over the prior
full-history champion, but it should be presented as a full-history Sharpe 1.4
candidate, not as a uniformly 1.4+ recent-period strategy.
