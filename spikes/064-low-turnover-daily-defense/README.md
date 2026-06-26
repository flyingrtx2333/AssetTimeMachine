# Spike 064 - 1% Fee Low-Turnover Defense

## Goal

Re-check the current best no-leverage/no-BTC strategy line after the App default
fee was changed to 1%, then look for a better high-Sharpe direction without
simple parameter tuning.

## What Changed Versus Prior Spikes

Prior 060-063 results were generated around a much lower trading cost. This
spike uses:

- 1% execution fee.
- 0.05% slippage.
- No leverage.
- No shorting.
- No BTC/ETH.
- Re-entry after daily risk exits only on scheduled rebalance.

## Tests

1. Replay the 063 champion stack with 1% fee.
2. Add sell-only daily defenses:
   - equity shock exit;
   - portfolio airbag exit;
   - gold crack exit.
3. Add transaction-cost-aware no-trade zones.
4. Remove or slow high-turnover overlays from the 063 stack.
5. Coarsen target execution:
   - drop sub-5% sleeves;
   - quantize target weights to 5%-10% buckets;
   - keep only the top 2-4 sleeves.
6. Preserve same-group holdings:
   - avoid switching within the same equity region when the current holding is
     still trend-healthy.
7. Test low-frequency return-source alternatives:
   - quarterly gold/Nasdaq trend barbell;
   - volatility-balanced gold/Nasdaq trend core;
   - global top-two risk-efficiency rotation;
   - crisis gold router;
   - semiannual single macro winner.

## Results: 063 Stack Under 1% Fee

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| `base_targets_no_repair_global` | 9.29% | 12.23% | 9.04% | 0.9968 | 549 |
| `no_repair_keep_global` | 9.27% | 11.82% | 9.05% | 0.9944 | 569 |
| `coarse_drop_lt5_quant5` | 9.33% | 11.39% | 9.13% | 0.9928 | 569 |
| `no_global_overlay_keep_repair` | 9.36% | 11.46% | 9.20% | 0.9879 | 706 |
| `baseline_063_1pct_band` | 9.34% | 11.06% | 9.21% | 0.9850 | 721 |
| `baseline_063_1pct_no_band` | 9.31% | 11.07% | 9.20% | 0.9836 | 871 |
| `coarse_top3_quant10` | 8.98% | 10.27% | 9.07% | 0.9640 | 555 |
| `daily_gold_crack_sell_only` | 8.77% | 11.03% | 9.00% | 0.9495 | 748 |
| `sticky_same_group_quant5` | 8.73% | 13.04% | 9.06% | 0.9402 | 604 |
| `sticky_same_group_drop_lt5` | 8.59% | 12.35% | 9.00% | 0.9319 | 545 |
| `daily_portfolio_airbag_sell_only` | 6.97% | 14.77% | 8.88% | 0.7794 | 861 |
| `daily_equity_airbag_sell_only` | 4.00% | 22.16% | 8.55% | 0.4872 | 975 |

No-trade zone check:

| No-Trade Band | Annualized | Sharpe | Trades |
| ---: | ---: | ---: | ---: |
| 0.0% | 9.31% | 0.9836 | 871 |
| 2.5% | 9.34% | 0.9850 | 721 |
| 10.0% | 9.37% | 0.9860 | 621 |
| 20.0% | 9.35% | 0.9885 | 581 |
| 30.0% | 9.21% | 0.9887 | 561 |

Observation: a larger no-trade zone cuts trades, but Sharpe remains near 0.99.
The main issue is not tiny weight drift; the previous high-return stack needs
meaningful reallocations, and 1% fee consumes too much of that edge.

Coarse target execution did not solve the problem either. Dropping sub-5%
sleeves and trading in 5% buckets reduced trades from 721 to 569 but only moved
Sharpe from 0.9850 to 0.9928.

Same-group holding preservation reduced some switching, but it also dulled the
return engine. The best sticky variant fell to 0.9402 Sharpe.

## Results: Low-Frequency Return Sources

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| `quarterly_global_top2_efficiency` | 9.12% | 45.30% | 17.31% | 0.5758 | 255 |
| `quarterly_gold_nasdaq_trend_barbell` | 5.33% | 21.10% | 10.44% | 0.5346 | 117 |
| `quarterly_vol_balanced_gold_nasdaq` | 5.34% | 23.51% | 11.99% | 0.4802 | 155 |
| `quarterly_crisis_gold_router` | 4.16% | 25.51% | 11.06% | 0.4121 | 151 |
| `semiannual_global_top2_efficiency` | 4.71% | 57.37% | 18.85% | 0.3316 | 158 |
| `semiannual_single_best_macro` | -1.87% | 58.87% | 17.75% | -0.0131 | 81 |

Observation: lower turnover alone is not enough. The low-frequency strategies
avoid some cost, but they also lose the return source that made 063 useful.

## Asset-Pool Check

Backend public history currently provides the main App assets:

- `gold_cny`
- `nasdaq`
- `sp500`
- `csi300`
- `shanghai_composite`
- `usd_per_cny`

Extra endpoint probes confirmed availability for:

- `gold_usd`
- `oil_wti_cny`
- `oil_wti`
- `dow_jones`
- `nikkei225`
- `hang_seng`

Rejected or unavailable in the current endpoint:

- silver variants;
- TLT/IEF/SHY/AGG-style bond proxies;
- US 10Y / dollar index style symbols.

BTC/ETH are available but intentionally excluded.

## Conclusion

No candidate in this round is good enough to promote into the App. Under a 1%
fee assumption, the current 063-style line falls from about 1.51 Sharpe to about
0.99 Sharpe. Daily stop/airbag logic makes results worse because it sells the
return source and pays extra cost before scheduled re-entry.

The next genuinely useful direction is probably not another wrapper around the
same gold/equity engine. To approach 1.6 Sharpe with 1% fee and no leverage, the
App likely needs either:

1. a new low-correlation, low-turnover tradable asset class with durable history
   in the backend, or
2. a state machine that captures the 063 return source while reducing full
   reallocations by more than the tested no-trade bands can.

## Files

- `low_turnover_daily_defense.py`: 063 stack replay, daily sell-only defenses,
  no-trade bands, and overlay-removal tests.
- `low_frequency_return_sources.py`: independent low-frequency return-source
  probes.
- `results.json`: generated output for the 063-stack tests.
- `low_frequency_results.json`: generated output for low-frequency probes.
