# Spike 050: Seasonal Carry Alpha Quarantine

## Goal

Find a no-leverage, no-BTC improvement over the 049 seasonal/carry line, ideally
moving full-history Sharpe toward 1.6 without cutting annualized return further.

## Ideas Tested

1. Guarded seasonal alpha:
   - Keep the 047 dynamic sleeve as the core.
   - Use fixed or adaptive same-month seasonal confidence to decide core risk
     tier.
   - Fill idle risk budget with Treasury carry.
   - Add month-specific alpha only when trend and breadth confirm.
   - Suppress China alpha during bubble-rollover states.

2. Gold blowoff rollover protection:
   - Diagnose the 049 drawdown window, which is dominated by 2011-2012 gold
     rollover exposure.
   - When gold is hot over medium/long lookbacks and then cracks, cap or cut
     gold and let idle budget move into short Treasury carry.

3. Meta selector between high-return and high-Sharpe sleeves:
   - NAV-level test between the verified 047 dynamic sleeve and the 049
     seasonal/carry sleeve.
   - Switch into the high-return sleeve only when it beats the low-risk sleeve
     over a trailing lookback and its drawdown is acceptable.

4. Expanded data-source probe:
   - Treat QQQ/SPY adjusted-close proxies and Treasury funds as formal tradable
     assets.
   - This is not product-ready because the App does not currently source those
     histories as first-class strategy assets.

## Results

Durable 050 script:

| Candidate | Annualized | Max DD | Vol | Sharpe | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| `fixed_ws40_ms65_gs100_wa10_ma10_ga0_breadth_short_only` | 11.46% | 8.46% | 7.19% | 1.4976 | Best guarded alpha result |
| `fixed_ws50_ms70_gs100_wa20_ma20_ga5_breadth_short_only` | 12.11% | 8.38% | 7.70% | 1.4773 | Higher return, lower Sharpe |

Focused short-only carry seasonal search, using formal replay:

| Candidate Shape | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| Weak 40%, mid 55%, Apr/May/Jul 85%, Nov/Dec 90% | 10.06% | 7.34% | 6.23% | 1.5226 |
| Weak 50%, mid 65%, Apr/May/Jul 95%, Nov/Dec 100% | 11.41% | 8.10% | 7.06% | 1.5182 |

Gold blowoff rollover protection did not help:

| Best Narrow Guard | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| Keep 50%, cap 35%, hot 120d/240d + crack filter | 10.88% | 7.81% | 6.75% | 1.5169 |

NAV-level meta selector between 047 and 049 did not help enough:

| Best NAV Selector | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| 378-session lookback, 4% edge margin | 12.23% | 8.91% | 7.67% | 1.4950 |

Expanded ETF/Treasury formal rotation was much weaker:

| Probe | Best Approx. Annualized | Best Approx. Sharpe |
| --- | ---: | ---: |
| QQQ/SPY/gold/Treasury adjusted-close rotation | < 9% | < 0.75 |

## Conclusion

This path does not beat the current 049 focused seasonal/carry frontier. The
best durable result remains around Sharpe 1.52, and attempts to raise annualized
return above 11-12% pull Sharpe back toward 1.48-1.50.

The useful finding is negative but concrete: the remaining gap to 1.6 is not
solved by adding guarded seasonal alpha, gold rollover caps, traditional
canary/dual-momentum rotation, or treating Treasury assets as formal rotation
assets. A better candidate likely needs a different source of edge rather than
another protective wrapper around 047.

## Files

- `seasonal_carry_alpha_quarantine.py`: durable target-weight replay search for
  guarded seasonal alpha plus carry.
- `results.json`: generated output from the durable 050 search.
