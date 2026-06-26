# Spike 081 - Paper-inspired High Sharpe Search

Goal: look for a no-leverage, no-BTC, App-only strategy with Sharpe above 1.2
under the current 1% transaction fee assumption.

Paper ideas translated into testable mechanisms:

- Dual momentum: combine relative momentum ranking with absolute momentum
  filters.
- PAA/DAA-style breadth canary: reduce risky exposure when many canary assets
  have weak momentum.
- Volatility-managed portfolios: use less exposure when recent volatility is
  high, without using leverage.
- Faber-style TAA: only hold assets above a long moving average; otherwise hold
  cash.
- USD-cash defensive sleeve: use App-style `usd_cash` synthesized from
  `usd_per_cny` only when USD trend clears a cash hurdle.

References checked:

- Gary Antonacci, "Risk Premia Harvesting Through Dual Momentum", SSRN 2042750.
- Wouter Keller and Jan Willem Keuning, "Protective Asset Allocation", SSRN
  2759734.
- Wouter Keller and Jan Willem Keuning, "Breadth Momentum and the Canary
  Universe: Defensive Asset Allocation", SSRN 3212862.
- Alan Moreira and Tyler Muir, "Volatility-Managed Portfolios", SSRN 2659431.
- Meb Faber, "A Quantitative Approach to Tactical Asset Allocation", SSRN
  962461.

Constraints:

- Assets: current AssetTimeMachine public universe only, no `OSTIX`, `IAU`, or
  external fund/stock tickers.
- No leverage or shorting; gross target exposure is capped at 100%.
- Fee: 1%.
- Slippage: 0.05%.
- Cash: same CNY cash-yield model used by the existing App-equivalent Python
  backtest helper.

Run:

```bash
cd ~/Desktop/AllProjects/AssetTimeMachine
python3 -B spikes/081-paper-inspired-high-sharpe/paper_inspired_high_sharpe.py
python3 -B spikes/081-paper-inspired-high-sharpe/currency_defense_probe.py
```

Results:

Main paper-inspired search:

- Coverage: 2002-01-04 through 2026-06-26.
- Candidates evaluated: 4,788.
- Sharpe >= 1.2 candidates: 0.

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| Existing App baseline: `coreGoldSatelliteOneWayVolManagedMomentum` | 10.65% | 11.23% | 9.91% | 1.038 |
| Best new paper-inspired candidate: `faber_cluster_gold50_us30_china10_global10_tv75_reb120_band10` | 4.09% | 12.56% | 6.11% | 0.666 |

USD-cash defensive probe:

- Coverage: 2002-01-04 through 2026-06-26.
- Candidates evaluated: 1,152.
- Sharpe >= 1.2 candidates: 0.

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| Existing App baseline: `coreGoldSatelliteOneWayVolManagedMomentum` | 10.65% | 11.23% | 9.91% | 1.038 |
| Best USD defensive candidate: `usd_def_can2_weak1_top2_off60_gold25_def98_uidle60_tv110_reb120_band10` | 4.99% | 28.75% | 10.50% | 0.502 |

Conclusion:

Rejected for product use. The tested paper logic did not find an App-only
Sharpe 1.2 strategy. Under the current asset universe and 1% fee, the existing
`coreGoldSatelliteOneWayVolManagedMomentum` remains the strongest verified
candidate.

Important finding:

The earlier 061/062 USD-cash and gold-panic spike line reported Sharpe around
1.5, but the current Swift `BacktestEngine` replay shows the corresponding App
strategies around 0.17-0.20 Sharpe. This spike deliberately rebuilt `usd_cash`
from `usd_per_cny` in the App style and still failed, so the old 061/062 numbers
must not be treated as product evidence.

Next research direction:

The papers that clear much higher Sharpe usually rely on a real defensive
income/bond/stable-value sleeve. App-only CNY cash and USD cash are not a
substitute. The most plausible route to Sharpe above 1.2 without leverage is to
add a durable defensive return source to the backend/App universe, then rerun
the same App-engine validation.
