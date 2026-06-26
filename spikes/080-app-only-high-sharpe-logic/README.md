# Spike 080 - App-only High Sharpe Logic

Goal: answer whether a higher-Sharpe strategy can be found using only assets
already supported by AssetTimeMachine, with no financing, no BTC, no external
tickers, and the current 1% default fee.

Allowed asset universe:

- `gold_cny`
- `nasdaq`
- `sp500`
- `dowjones`
- `hsi`
- `nikkei`
- `csi300`
- `shanghai_composite`
- `shenzhen_component`
- `chinext` only as a later-history optional asset
- cash via the App cash-yield model

Scripts:

- `search_app_only_logic.py`: mechanism-first dynamic strategy search using
  App-only assets.
- `static_frontier.py`: deterministic low-turnover permanent portfolio frontier.

Reference app-equivalent baseline, 1% fee:

| Strategy | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `coreGoldSatelliteOneWayVolManagedMomentum` | 10.66% | 11.23% | 9.91% | 1.039 |
| `coreGoldSatelliteEquityBreadthMomentum` | 13.01% | 18.85% | 13.10% | 0.970 |
| `coreGoldSatelliteHeatCappedMomentum` | 9.50% | 12.04% | 9.98% | 0.931 |
| `coreGoldSatelliteGoldHandoffMomentum` | 9.45% | 11.38% | 9.98% | 0.926 |

Dynamic App-only mechanism results:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| Best existing app-equivalent baseline | 10.66% | 11.23% | 9.91% | 1.039 |
| `cash_barbell_reb120_band5` | 5.46% | 14.34% | 7.35% | 0.737 |
| `low_turnover_persistence_reb120_band5` | 7.81% | 22.30% | 11.41% | 0.696 |
| `gold_us_handoff_plus_cash_reb120_band2` | 5.27% | 17.43% | 8.04% | 0.659 |
| `canary_global_momentum_reb120_band2` | 5.33% | 20.67% | 9.79% | 0.563 |

Low-turnover static frontier, best results:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| 30% gold / 20% Nasdaq / 5% CSI300 / 5% SH Comp / 2.5% HSI / 2.5% Nikkei, yearly rebalance, 10% band | 7.42% | 25.98% | 7.88% | 0.920 |
| 30% gold / 20% Nasdaq / 5% CSI300 / 5% SH Comp, yearly rebalance, 10% band | 7.17% | 23.10% | 7.62% | 0.919 |
| 40% gold / 20% Nasdaq / 5% CSI300 / 5% SH Comp / 2.5% HSI / 2.5% Nikkei, yearly rebalance, 10% band | 8.59% | 27.50% | 9.32% | 0.903 |

Existing App-equivalent overlay exploration also failed to beat the current
baseline. The best overlay candidate was:

| Candidate | Annualized | Max DD | Sharpe |
| --- | ---: | ---: | ---: |
| `cluster_rotation_veto` | 9.51% | 11.38% | 0.948 |

Conclusion:

No stronger App-only high-Sharpe candidate was found in this round. Under the
current app universe and 1% fee, `coreGoldSatelliteOneWayVolManagedMomentum`
remains the strongest app-equivalent strategy found so far.

The external-asset research achieved higher Sharpe because it added a stable
income/bond-like asset such as `OSTIX`. The current App-only universe does not
have a comparable stabilizer. Cash reduces volatility but also cuts return too
much to improve Sharpe beyond the current dynamic gold/equity strategy.

Product decision:

- Do not add the dynamic candidates from this spike.
- Do not add the static frontier candidates as "high Sharpe" strategies.
- If the target remains Sharpe above 1.6 or 2.0 without leverage, the more
  promising product path is adding a real bond/income/cash-plus data asset to
  the backend and App, then re-running app-equivalent validation.
