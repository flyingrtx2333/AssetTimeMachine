# Spike 028 - Calendar-Invariant Sharpe 1.4 Search

Goal: find a no-leverage strategy that beats the corrected app-equivalent
`coreGoldSatelliteOneWayVolManagedMomentum` Sharpe of 1.3388.

Rules:
- Same corrected global rebalance calendar.
- No financing, no shorting, no total notional above 100%.
- Primary metric is full-history Sharpe. Slices are used as sanity checks.

Tested logic families:
- Engine quality routing between the current gold handoff engine and the
  offensive equity breadth engine.
- One-way engine volatility management.
- Selected-basket volatility budgets.
- Portfolio drawdown risk rebuild ladders.
- Faster 20/30/40-session risk review.
- Standalone trend/risk-parity baskets.
- China bubble contagion guards, US breakdown cash guards, and gold blowoff
  cash guards.
- Temporary expanded index universe check with Dow, Nikkei, and Hang Seng
  showed materially worse results and was not promoted.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| `one_way_portfolio_ladder` | 12.69% | 9.24% | 8.83% | 1.3557 | Best full-history Sharpe, but lower return than current champion |
| `one_way_plus_basket_vol9` | 11.49% | 9.87% | 8.04% | 1.3509 | Mostly a cash/volatility haircut |
| `baseline_one_way_vol` | 13.54% | 9.87% | 9.53% | 1.3388 | Current app champion |

Conclusion:

The best clean improvement found in this spike is only a small Sharpe increase
from 1.3388 to 1.3557, and it gives up annualized return. Faster risk review,
standalone trend baskets, and specific contagion guards did not break the 1.4
target. The corrected low-frequency app framework appears to be near a local
ceiling with the current asset set.
