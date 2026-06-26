# Spike 026 - Network Speed Logic

Goal: find a higher-Sharpe, no-financing strategy by changing signal logic, not by tuning existing parameters.

Inputs:
- App-equivalent Python backtest path via `tools/atm_app_equivalent_backtest.py`.
- Prior engine definitions from `spikes/022-engine-selection-logic/engine_selection_logic.py`.
- Market data through the same public-history path as the app-equivalent tools.

Ideas tested:
- Dynamic-speed momentum: learn whether 20/60/120/240-session momentum has recently predicted the next rebalance month for each asset.
- Network confirmation: let positively correlated assets reinforce or veto an asset's own dynamic-speed signal.
- Engine routing: use the network signal as a standalone engine, a sleeve, or a veto on the prior engine router.

References used as structural inspiration:
- Network momentum across asset classes: https://arxiv.org/abs/2308.11294
- Dynamic momentum learning: https://arxiv.org/abs/2106.08420

Result summary:

| Candidate | Annualized | Max DD | Sharpe | Notes |
| --- | ---: | ---: | ---: | --- |
| `network_confirmed_return_lead` | 15.08% | 13.68% | 1.2777 | Best network-veto variant, below prior best |
| `network_strong_offense` | 16.08% | 17.35% | 1.2637 | Better return, weaker risk quality |
| `network_speed_engine` | 12.11% | 32.45% | 0.8189 | Standalone network signal failed badly around 2007-2008 |

Conclusion:

Network/dynamic-speed logic is not a new champion in this asset universe. It is too unstable as a standalone engine and too restrictive as an offensive veto. Keep the code as a documented failure mode, but do not promote it into the app.
