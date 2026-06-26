# Spike 052: Sleeve Correlation and Seasonal Router

## Goal

After the event-driven handbrake failed, test whether there is a cleaner way to
combine the high-return 047 dynamic sleeve with the higher-Sharpe 049
seasonal/carry sleeve, or route between the satellite and defensive sleeves by
month without cutting total exposure to cash.

## Ideas Tested

1. NAV-level 047/049 blend screen:
   - 047: 13.61% annualized, 1.4054 Sharpe.
   - 049: 10.64% annualized, 1.5191 Sharpe.
   - Check whether low correlation creates a better frontier.

2. Target-weight seasonal sleeve router:
   - Keep 047 target generation intact.
   - Tilt or replace the selector weight between satellite and defensive sleeves
     based on strong/weak month groups.
   - This keeps the portfolio invested instead of applying a cash risk-budget
     scale.

## Results

Daily return correlation between 047 and 049: `0.9280`.

Best NAV blend screen:

| 047 Weight | Annualized | Max DD | Vol | Sharpe |
| ---: | ---: | ---: | ---: | ---: |
| 0% | 10.64% | 8.05% | 6.59% | 1.5191 |
| 25% | 11.39% | 7.75% | 7.10% | 1.5069 |
| 50% | 12.14% | 7.47% | 7.70% | 1.4794 |
| 100% | 13.61% | 9.34% | 9.09% | 1.4054 |

Best target-weight seasonal router:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `seasonal_sleeve_tilt_s101112_w1268910_h15_m0_l20` | 13.64% | 9.04% | 9.11% | 1.4058 |
| `baseline_047_dynamic_sleeve` | 13.61% | 9.34% | 9.09% | 1.4054 |

## Conclusion

This route does not solve the objective. The 049 seasonal/carry sleeve is too
correlated with 047 to provide a meaningful blend benefit. Month-aware routing
inside the sleeve selector barely changes full-history Sharpe and does not move
toward 1.6.

The useful negative finding: the remaining gap is unlikely to be closed by
mixing the existing two sleeves or by applying month labels to the selector
weight. We need a genuinely different return source or a materially different
entry/exit model.

## Files

- `sleeve_correlation_season_router.py`: durable screen and target-weight
  seasonal router replay.
- `results.json`: generated output.
