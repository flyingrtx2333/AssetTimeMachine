# Spike 065 - Sparse Seasonal Risk Budget

## Goal

Rework the spike 048 seasonal-tier strategy for the App's new 1% default fee.
The original 048 logic had attractive full-history Sharpe at low cost, but it
traded on month boundaries. This spike tests whether a sparse execution policy
can preserve the low-volatility edge while avoiding expensive monthly churn.

## Logic Tested

- Original monthly seasonal tier, rerun at 1% fee.
- Scheduled-only seasonal scaling:
  - apply month scale only when the strategy already has a normal target update;
  - no month-boundary trades.
- Sell-only month boundary:
  - if a new month requires lower exposure, sell down immediately;
  - if a new month allows higher exposure, wait for normal strategy rebalance.
- Weak-month-only sell boundary:
  - only February, June, September, and October cut exposure.
- Fixed selector weights:
  - remove dynamic selector churn while keeping sparse seasonal risk control.

All variants use:

- 1% fee.
- 0.05% slippage.
- No leverage.
- No shorting.
- No BTC/ETH.

## Best Results

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| `sell_only_boundary_048_band100` | 5.50% | 7.54% | 5.00% | 1.0623 | 558 |
| `sell_only_boundary_048_band50` | 5.50% | 7.54% | 5.00% | 1.0622 | 560 |
| `fixed_selector_25_sell_boundary_048` | 5.07% | 7.22% | 4.75% | 1.0322 | 560 |
| `scheduled_only_048_band50` | 6.85% | 9.23% | 6.49% | 1.0220 | 342 |
| `weak_only_sell_boundary_band100` | 6.58% | 10.20% | 6.28% | 1.0144 | 501 |
| `original_full_monthly_048_band50` | 6.86% | 11.02% | 6.57% | 1.0104 | 809 |

Slice check for the best candidate:

| Slice | Annualized | Sharpe |
| --- | ---: | ---: |
| 2020+ | 4.04% | 0.7607 |
| Last 10Y | 3.12% | 0.6674 |
| 2024+ | 6.08% | 1.0262 |

## Additional Probe

A walk-forward same-month seasonality selector was tested outside the durable
script:

- It used only prior years of the same month.
- It selected top assets by historical same-month score.
- It excluded all future data for the decision month.

After filtering out near-all-cash candidates, no candidate had enough annualized
return and trading activity to be useful. The apparent highest Sharpe results
were cash artifacts, not investable strategies.

## Conclusion

Sparse seasonal execution is directionally useful but not enough. Sell-only
month boundaries improve full-history Sharpe from about 1.01 to about 1.06 under
1% fee, but annualized return falls to 5.50% and recent slices are weak.

Do not promote this to the App as a new strategy. The finding is still useful:

- high-fee execution should be slow-in, fast-out;
- monthly buy-up trades are too expensive;
- seasonal risk budgeting can lower volatility, but it is not the missing 1.6
  Sharpe source.

The remaining path likely requires either a new low-correlation tradable asset
source or a stronger state machine that keeps more of the 063 return engine
without full reallocations.

## Files

- `sparse_seasonal_fee_search.py`: durable sparse seasonal execution search.
- `results.json`: generated full-history and slice metrics.
