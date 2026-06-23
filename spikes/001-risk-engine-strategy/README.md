# 001: Risk-engine strategy spike

## Question

Can we improve AssetTimeMachine's current VAA/PAA-style strategy by changing **logic**, not by parameter sweeping?

Specifically: add a separate risk engine using real OHLC data for equity clusters:

- US equity risk cluster: Nasdaq + S&P 500 OHLC
- China equity risk cluster: CSI 300 + Shanghai Composite OHLC
- Gold remains close-only for now because the current AssetTimeMachine full-cycle public history does not expose gold OHLC.

## Data used

Execution/backtest prices use the existing AssetTimeMachine public-history helpers via `tools/search_no_btc_vaa_paa_2002.py`.

Extra OHLC signal data is fetched from free providers:

- Sina US daily K-line for Nasdaq and S&P 500
- Sina China daily K-line for CSI 300 and Shanghai Composite

Observed OHLC coverage in this run:

| Series | Coverage |
|---|---|
| Nasdaq OHLC | 2004-01-02..2026-06-18 |
| S&P 500 OHLC | 2004-01-02..2026-06-18 |
| CSI 300 OHLC | 2005-11-17..2026-06-18 |
| Shanghai Composite OHLC | 2005-11-17..2026-06-18 |

## Strategy prototypes

All prototypes keep the current proven VAA/PAA alpha engine as the base, then add a different logic layer:

1. `vaa_ohlc_crisis_gate`
   - Adds an independent OHLC crash gate per regional equity cluster.
   - If a cluster shows waterfall/trend-break/bubble-break behavior, block that cluster and route part of risk to gold if gold is healthy.

2. `vaa_mania_aware_crisis_gate`
   - Adds proactive mania control before the crash gate.
   - If a regional equity cluster has already had a huge one-year advance, do not allow double exposure to that cluster.
   - If the manic cluster starts wobbling, cut harder before full crash confirmation.

3. `vaa_extension_aware_crisis_gate`
   - Caps regional exposure when a cluster trades far above its 200-session trend.
   - This tested whether trend overextension alone catches bubble risk earlier.

4. `vaa_region_cluster_one_per_region`
   - Prevents same-region double exposure.
   - Too conservative / return drag.

5. `vaa_core_satellite_state_machine`
   - Splits a defensive core from a tactical sleeve.
   - Too conservative / return drag.

## Results

### Full window: 2002-01-04..2026-06-20

| Strategy | Annualized | Max drawdown | Sharpe | Notes |
|---|---:|---:|---:|---|
| Current VAA same window | 7.07% | 9.52% | 0.99 | Baseline |
| OHLC crisis gate | 6.94% | 9.26% | 0.98 | Small improvement, low cost |
| Mania-aware crisis gate | 6.41% | 8.81% | 0.97 | Meaningful drawdown cut, return cost ~0.66pp |
| Extension-aware crisis gate | 6.67% | 8.81% | 1.00 | Drawdown cut, but not enough return |

### Stress window: 2006-01-04..2026-06-20

This window matters because it starts shortly before the 2007 China equity bubble damage.

| Strategy | Annualized | Max drawdown | Sharpe | Notes |
|---|---:|---:|---:|---|
| Current VAA same window | 7.43% | 15.27% | 0.98 | Fails user drawdown preference in this start window |
| OHLC crisis gate | 7.37% | 14.99% | 0.99 | Too late for 2007 bubble |
| Mania-aware crisis gate | 6.47% | 9.68% | 0.95 | Actually fixes the 2007-style drawdown, but costs return |
| Extension-aware crisis gate | 6.91% | 15.00% | 1.00 | Overextension signal did not catch main damage |

### Recent window: 2016-06-20..2026-06-20

| Strategy | Annualized | Max drawdown | Sharpe |
|---|---:|---:|---:|
| Current VAA same window | 5.68% | 12.60% | 0.81 |
| OHLC crisis gate | 6.13% | 11.64% | 0.90 |
| Mania-aware crisis gate | 6.09% | 11.64% | 0.90 |
| Extension-aware crisis gate | 6.13% | 11.64% | 0.90 |

## Verdict: PARTIAL

### What worked

- The OHLC crisis gate improved recent/post-2020 behavior without changing the alpha engine.
- The mania-aware gate solved the 2006-start failure mode: max drawdown fell from 15.27% to 9.68%.
- The result confirms the diagnosis: the real structural failure is **regional bubble concentration**, especially China equity double exposure.

### What did not work

- Crisis detection alone triggers too late for 2007/2015-style bubbles.
- Overextension vs 200-day trend did not catch the main damage well enough.
- Purely conservative state-machine variants reduce return too much.
- The best robust drawdown fix (`mania_aware`) still lowers full-cycle annualized return from 7.07% to 6.41%, so it is not yet a clear replacement for the current main strategy.

### Recommendation

Do not ship this as a replacement yet.

Continue development in the **mania-aware risk engine** direction, but the next logic step should not be another threshold adjustment. It should introduce a richer, non-price-only signal for bubble/fragility:

1. Real OHLC + volume persistence for China and US clusters.
2. A cluster-level "fragility score" based on:
   - blowoff advance,
   - rising range/volume,
   - failed rebound after first break,
   - breadth/dual-index divergence if more China indices/funds are available.
3. Treat mania control as an overlay for entry/risk sizing, not as a full replacement of the VAA alpha engine.

## Second iteration notes

After the first verdict, three more logic ideas were tested:

1. `vaa_fragility_hard_crisis_gate`
   - Fragility score uses blowoff advance, range expansion, volume expansion, internal divergence, failed rebound, trend crack, and long-trend loss.
   - Result on 2006-start window: 5.85% annualized / 10.48% max drawdown.
   - Verdict: too much return drag; not better than simple mania control.

2. `vaa_fragility_soft_crisis_gate`
   - Softer cap version of fragility score.
   - Result on 2006-start window: 6.51% annualized / 11.93% max drawdown.
   - Verdict: return improves slightly, but drawdown no longer meets the core objective.

3. `vaa_mania_substitution_crisis_gate`
   - When China/US cluster is manic, cut exposure and migrate some risk to the other healthy equity cluster.
   - Result on 2006-start window: 6.45% annualized / 9.68% max drawdown.
   - Verdict: not better. In 2007, moving China bubble risk to US equities still leaves exposure to the later global crisis.

4. `vaa_mania_safe_haven_crisis_gate`
   - When equity cluster is manic, harvest cut exposure into gold/cash rather than another equity cluster.
   - Result on 2006-start window: 6.50% annualized / 9.68% max drawdown.
   - Verdict: slight improvement over plain mania-aware, but still not enough to justify replacing the current no-BTC main strategy.

Updated conclusion:

- Within the no-BTC universe, the cleanest robust overlay remains simple **mania-aware risk control**.
- More complex fragility scoring did not beat the simpler rule; it either over-trades/over-cuts or fails to reduce drawdown enough.
- The real next breakthrough likely requires a new asset sleeve or new macro source, not more price-only complexity.

## How to run

```bash
python3 spikes/001-risk-engine-strategy/risk_engine_strategy.py
```

Detailed machine-readable output is written to:

```text
/tmp/atm_risk_engine_strategy_results.json
```
