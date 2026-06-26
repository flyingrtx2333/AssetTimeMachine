# Spike 082 - Defensive Income Source Path

Goal: continue the Sharpe > 1.2 strategy search after App-only assets failed in
spike 081.

Core finding:

The current App-only universe does not have a strong enough defensive return
source. Once a real defensive income sleeve is added, a no-leverage strategy can
clear Sharpe 1.2 under the current 1% fee assumption.

Verified candidate:

`max_sharpe:r63_cdd8_qdd15_cc10_qc60_g25`

Base basket:

- 50% `OSTIX`
- 30% `CORE`
- 5% `IAU`
- 5% `AAPL`
- 5% `LLY`
- 5% `ORLY`

Where:

- `CORE` is the current app-equivalent
  `coreGoldSatelliteOneWayVolManagedMomentum` strategy curve.
- `OSTIX` is the defensive income sleeve.
- `IAU` is a gold ETF sleeve.
- `AAPL`, `LLY`, `ORLY` are a low-turnover quality satellite sleeve.

Stress overlay:

- Review every 63 sessions.
- If `CORE` has 126-session drawdown worse than 8% and 63-session return below
  0, cut 10% from `CORE`.
- If the quality sleeve has 126-session drawdown worse than 15% and
  63-session return below 0, cut 60% from the quality sleeve.
- Redeploy 25% of any cut exposure into `IAU`.
- Redeploy the remaining 75% into `OSTIX`.
- Gross exposure remains capped at 100%; no leverage, no shorting, no BTC.

Latest verification:

Command:

```bash
cd ~/Desktop/AllProjects/AssetTimeMachine
python3 -B spikes/078-stress-tilted-quality-basket/stress_tilted_quality_basket.py
```

Result from the latest rerun:

| Candidate | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe | Last-10Y Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `max_sharpe:r63_cdd8_qdd15_cc10_qc60_g25` | 9.91% | 13.06% | 5.69% | 1.6377 | 1.4944 | 1.5543 | 209 |

Higher-return balance:

`middle:r126_cdd8_qdd15_cc5_qc35_g50`

Base basket:

- 45% `OSTIX`
- 30% `CORE`
- 5% `IAU`
- 10% `AAPL`
- 5% `LLY`
- 5% `ORLY`

Latest rerun:

| Candidate | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe | Last-10Y Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `middle:r126_cdd8_qdd15_cc5_qc35_g50` | 11.43% | 15.44% | 6.65% | 1.6096 | 1.4224 | 1.5302 | 143 |

Research basis:

- Dual momentum and absolute momentum explain the `CORE` trend engine.
- Defensive Asset Allocation / Protective Asset Allocation motivate canary and
  breadth-style risk gating.
- Volatility-managed portfolio research motivates cutting exposure during poor
  risk-quality states, but without using leverage.
- The practical unlock is not another App-only risk switch; it is the defensive
  income sleeve.

Product caveat:

This is not yet an App strategy candidate because the App/backend do not
currently provide `OSTIX`, `IAU`, or the individual quality stocks as official
assets. Product promotion requires:

1. Add durable market-data support for the external assets, including adjusted
   total-return history.
2. Replay through Swift `BacktestEngine` or a proven equivalent path.
3. Decide whether individual-stock satellites are acceptable in the product, or
   replace them with fund/ETF proxies.

Conclusion:

Sharpe > 1.2 has been found, but not inside the current App-only universe. The
strongest verified path is adding a real defensive income asset, then building a
low-turnover stress-tilted allocation around it.
