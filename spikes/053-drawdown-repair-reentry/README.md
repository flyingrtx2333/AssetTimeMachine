# Spike 053: Drawdown Repair Reentry

## Goal

Find a genuinely different no-leverage, no-BTC return source instead of adding
another protective wrapper around the 047 dynamic sleeve.

## Logic Tested

The new idea is a drawdown-repair reentry engine:

- Wait for an asset to experience a meaningful drawdown from a rolling high.
- Enter only after the asset rebounds from a recent low and confirms above a
  short or medium moving average.
- Optionally require broad equity breadth before equity reentry.
- Use this either as:
  - an overlay that spends only the 047 dynamic sleeve's idle budget, or
  - a standalone repair strategy.

All replays include fees, slippage, cash yield, no leverage, no shorting, and no
BTC.

## Results

Baseline:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `baseline_047_dynamic_sleeve` | 13.61% | 9.34% | 9.09% | 1.4054 |

Initial search best:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `overlay_dd120_12_rb40_55_ma40_mom20_top2_cap25_per12_breadth` | 13.95% | 10.26% | 9.19% | 1.4234 |

Focused refinement best:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `refine_overlay_dd105_10_rb30_55_ma40_top1_cap35_per15_breadth` | 13.96% | 9.44% | 9.15% | 1.4297 |
| `refine_overlay_dd105_10_rb30_55_ma40_top2_cap35_per15_breadth` | 14.09% | 10.42% | 9.23% | 1.4293 |

Best candidate slices:

| Window | Annualized | Sharpe |
| --- | ---: | ---: |
| Full history | 13.96% | 1.4297 |
| 2020+ | 13.88% | 1.2855 |
| Last 10Y | 11.32% | 1.1824 |
| 2024+ | 21.02% | 1.7280 |

## Conclusion

This is a real but modest improvement over 047: it raises both annualized return
and full-history Sharpe. It is not enough for the user's target of roughly 1.6
Sharpe, and it does not fix the recent-slice weakness enough to call it a final
champion.

The useful finding is positive: recovery-after-drawdown can add return without
destroying Sharpe when used only as an idle-budget overlay with breadth
confirmation. This is a better direction than event handbrakes or sleeve
blending, but still needs another independent edge before product promotion.

## Files

- `drawdown_repair_reentry.py`: main repair reentry search.
- `results.json`: main search output.
- `focused_repair_refine.py`: focused refinement around the best overlay.
- `focused_results.json`: focused refinement output.
