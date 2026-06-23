# 008: Gold/Nasdaq mechanism zoo — no parameter-grid strategy search

## User request

The user rejected further parameter tweaking and asked to rethink strategy logic from scratch:

- Do **not** tune parameters to force a prettier backtest.
- Search/borrow broad strategy ideas if helpful.
- Try many genuinely different mechanisms: momentum, VAA/PAA-style breadth, trend following, CPPI/TIPP, FAA/EAA, equity-curve switching, etc.
- Keep the product direction centered on gold/Nasdaq/cash.

## External mechanism references used

Search engines and some SSRN pages were partly blocked by anti-bot/CAPTCHA pages. The spike therefore used directly readable pages plus known strategy families:

- Allocate Smartly pages/blog references around VAA, Accelerating Dual Momentum, and “Surfing the Equity Curve”.
- Portfolio Charts permanent portfolio / golden butterfly pages: multi-regime diversification across growth, deflation, inflation, and cash/short-term assets.
- Quantpedia pages on asset-class momentum and time-series momentum.
- Optimal Momentum / dual momentum material via Jina Reader.
- CPPI/TIPP concept: portfolio insurance / floor-based risk budgeting.
- FAA/EAA-style concepts: score assets by momentum, volatility, and correlation/diversification.

The spike does **not** copy exact parameter sets. It translates strategy families into fixed, interpretable gold/Nasdaq/cash rules.

## Universe and execution

Visible holdings:

```text
nasdaq
gold_cny
cash
```

Signal-only assets available from the current data pipeline:

```text
sp500
dowjones
csi300
shanghai_composite
```

Backtest assumptions:

- Coverage: 2002-01-04 to 2026-06-21, 6316 aligned observations.
- T-1 signal, T execution.
- Unit/cash accounting.
- Cash earns the project's demand-deposit cash yield.
- Fees and slippage use the existing AssetTimeMachine spike constants.
- No BTC.
- No hidden holdings outside gold/Nasdaq/cash.

## Baseline

### `BH_25_25_buyhold`

True buy-and-hold 25% Nasdaq + 25% gold + 50% cash.

```text
Full:      7.77% annualized / 21.00% max drawdown
Post-2020: 14.31% / 14.32%
Last 10Y:  12.54% / 14.32%
2024+:     23.81% / 14.08%
Latest:    42.2% Nasdaq / 48.8% gold / 9.0% cash
```

This is the main benchmark. A replacement should either:

1. Beat both return and drawdown, or
2. Offer a clearly different product lane, e.g. materially lower drawdown with only small return sacrifice.

## Mechanism families tested

The script now implements 38 fixed logic candidates / baselines.

| ID | Mechanism |
|---|---|
| `M01_GEM_dual_momentum` | Absolute momentum gate, then relative winner |
| `M02_absolute_momentum_split` | Own each sleeve only if its own trend is positive |
| `M03_core_satellite_relative` | Permanent core plus satellite to stronger positive sleeve |
| `M04_VAA_canary` | External equity canaries decide risk-on/risk-off |
| `M05_PAA_breadth` | Bad-asset breadth controls total risk budget |
| `M06_dual_trend_following` | 200d trend plus 12m absolute momentum |
| `M07_vol_target_trend` | Trend following with volatility-target sizing |
| `M08_inverse_vol_all_weather` | Inverse-vol gold/Nasdaq balance when healthy |
| `M09_CPPI_floor` | Portfolio insurance floor/cushion risk budget |
| `M10_TIPP_lock_in` | Drawdown lock-in guard plus core/winner near highs |
| `M11_ratio_regime` | Nasdaq/gold ratio regime rotation |
| `M12_momentum_crash_protection` | Base barbell plus sleeve cooldown after blowoff rollover |
| `M13_harvest_rebuild` | Blowoff harvest then trend rebuild |
| `M14_four_quadrant_regime` | Equity breadth × gold leadership state machine |
| `M15_synthetic_barbell_taa` | Time the gold/Nasdaq barbell as one synthetic asset |
| `M16_us_leadership_filter` | Nasdaq weight requires broad US equity leadership |
| `M17_crash_reversal_ladder` | Buy recovery after deep drawdown, cut broken trends |
| `M18_correlation_regime` | Hold both when diversifying, follow leader when correlated |
| `M19_virtual_drawdown_budget` | Risk budget from drawdown of virtual gold/Nasdaq barbell |
| `M20_ratio_extreme_reversal` | Ratio trend with extreme-crowding reversal harvest |
| `M21_clear_momentum_or_equal_weight` | Concentrate only when momentum is clear, otherwise 25/25 |
| `M22_health_budget_momentum_satellite` | Virtual barbell health gate plus momentum satellite |
| `M23_health_budget_asymmetric_growth` | Barbell health gate with Nasdaq growth bias |
| `M24_health_budget_safehaven_rotation` | Barbell health gate plus safe-haven rotation |
| `M25_accelerating_dual_momentum_tempered` | Accelerating dual momentum, tempered with ballast |
| `M26_faa_momentum_vol_corr` | FAA-style momentum minus volatility plus correlation regime |
| `M27_eaa_elastic_allocation` | EAA-style positive momentum over vol and corr penalty |
| `M28_harvest_rebuild_health_guard` | Harvest/rebuild with virtual barbell health master guard |
| `M29_virtual_health_reaccumulation` | Barbell health gate with explicit recovery re-accumulation |
| `M30_risk_spread_regime` | Nasdaq/gold and Nasdaq/SP500 risk appetite spread |
| `M31_volatility_shock_cooldown` | Cool sleeves after volatility shock plus negative momentum |
| `M32_two_layer_health_and_spread` | Two-layer health gate plus risk-spread split |
| `M33_health_reaccumulation_plus_satellite` | Health recovery then modest satellite to leading sleeve |
| `M34_health_recovery_with_vol_cap` | Health recovery satellite scaled by volatility |
| `M35_health_phase_three_bucket` | Core barbell + recovery satellite + cash buffer |
| `M36_asset_specific_health_matrix` | Combined health cap plus separate sleeve recovery states |
| `M37_equity_curve_surf_baseline` | Surf the virtual barbell equity-curve trend |
| `M38_gold_shock_absorber_nasdaq_engine` | Nasdaq engine gated by health/US breadth; gold shock absorber |

## Main new finding

The first useful discovery was:

```text
Use the health/drawdown state of the combined virtual gold+Nasdaq barbell as the master risk switch.
```

The second, stronger discovery is:

```text
After the virtual gold+Nasdaq barbell recovers, re-accumulate risk in phases and add a modest satellite to the currently stronger sleeve; scale that satellite down when volatility is elevated.
```

This produces a genuinely better candidate than the simple 25/25 baseline without relying on a parameter grid.

## New best balanced candidate

### `M34_health_recovery_with_vol_cap`

Logic:

```text
1. Build a virtual 50/50 gold/Nasdaq barbell as the product-health signal.
2. Classify the barbell as healthy / bruised / broken by its own drawdown state.
3. Require recovery above a medium trend before adding a satellite.
4. If recovered and Nasdaq leads, add a Nasdaq satellite.
5. If volatility is elevated, scale the Nasdaq satellite down rather than exiting entirely.
6. If bruised, hold a moderate gold/Nasdaq core.
7. If broken, hold only gold when gold trend is positive; otherwise cash.
```

Results:

```text
Full:      8.01% annualized / 15.12% max drawdown
Post-2020: 11.95% / 15.12%
Last 10Y:  11.40% / 15.12%
2024+:     21.82% / 12.42%
2002-2012: 6.77% / 11.79%
2013-2023: 6.36% / 15.12%
Sharpe:    0.86
Calmar:    0.53
Latest:    31.2% Nasdaq / 33.5% gold / 35.3% cash
Trades:    273 monthly target changes/rebalances
```

Against the simple 25/25 baseline:

```text
BH_25_25_buyhold: 7.77% / 21.00%, Calmar 0.37
M34:              8.01% / 15.12%, Calmar 0.53
```

Stress windows:

```text
2008金融危机:     -4.02% / 9.38%
2011黄金拐点:      1.13% / 9.83%
2015A股/全球波动:  6.23% / 3.31%
2018美股回撤:     -5.12% / 5.66%
2020疫情:          2.72% / 15.12%
2022加息:        -11.11% / 12.51%
2026AI波动:        0.93% / 12.42%
```

Top drawdowns:

```text
2020-02-20 -> 2020-03-16: 15.12%
2021-09-03 -> 2022-10-14: 14.70%
2006-05-11 -> 2006-06-13: 11.79%
2012-10-04 -> 2014-05-08: 10.14%
```

Verdict:

```text
PROMOTE TO NEXT-ROUND CANDIDATE.
```

This is the best new non-M13 candidate so far. It beats the 25/25 baseline on both full-cycle annualized return and max drawdown while staying within the gold/Nasdaq/cash product story.

## Nearby variants

### `M33_health_reaccumulation_plus_satellite`

Same recovery/re-accumulation idea, but without the volatility cap.

```text
Full:      7.96% / 14.99%
Post-2020: 12.11% / 14.99%
Last 10Y:  11.47% / 14.99%
2024+:     22.35% / 12.68%
Latest:    39.3% Nasdaq / 28.6% gold / 32.1% cash
```

Verdict:

```text
ALSO PROMISING.
```

It has slightly lower full-cycle return than M34 but slightly lower drawdown. The volatility cap in M34 improves the full-period return/drawdown tradeoff a bit.

### `M35_health_phase_three_bucket`

Three-bucket version: core barbell + recovery satellite + cash buffer.

```text
Full:      7.80% / 14.50%
Post-2020: 12.10% / 14.50%
Last 10Y:  11.46% / 14.50%
2024+:     20.90% / 12.98%
Latest:    22.9% Nasdaq / 28.8% gold / 48.4% cash
```

Verdict:

```text
GOOD LOW-DRAWDDOWN VARIANT.
```

It barely beats the 25/25 return but reduces max drawdown materially.

### `M29_virtual_health_reaccumulation`

Original re-accumulation version before adding satellite/vol cap.

```text
Full:      7.77% / 14.17%
Post-2020: 11.64% / 14.17%
Last 10Y:  11.17% / 14.17%
2024+:     20.94% / 11.83%
Latest:    31.2% Nasdaq / 33.5% gold / 35.3% cash
```

Verdict:

```text
GOOD DEFENSIVE VARIANT.
```

This almost matches 25/25 return with much lower drawdown.

## Aggressive high-return reference

### `M13_harvest_rebuild`

```text
Full:      9.95% / 20.14%
Post-2020: 16.79% / 19.18%
Last 10Y:  15.37% / 19.18%
2024+:     27.00% / 14.18%
Latest:    57.0% Nasdaq / 33.3% gold / 9.7% cash
Trades:    12 event-driven harvest/rebuild actions
```

Verdict:

```text
Best aggressive candidate, but drawdown is still around 20%.
```

Use this only if the product accepts a materially higher drawdown lane.

## Important failures

### Classic GEM-style winner-take-most momentum failed

`M01_GEM_dual_momentum`:

```text
Full: 8.18% / 44.58%
```

Failure mode: winner-take-most puts too much into one asset and gold can itself enter a prolonged failure regime.

### FAA/EAA-style ranking did not transfer cleanly

```text
M26_faa_momentum_vol_corr: 6.61% / 28.63%
M27_eaa_elastic_allocation: 6.47% / 28.26%
```

Momentum/vol/correlation scoring sounds elegant, but in a two-holding universe it still concentrates into the wrong sleeve at bad times.

### VAA/PAA/CPPI were not the breakthrough

```text
M04_VAA_canary: 5.45% / 22.97%
M05_PAA_breadth: 6.62% / 17.46%
M09_CPPI_floor: 4.18% / 11.78%
```

These are useful references, but not candidates to promote.

## Current recommendation

Promote two lanes:

### Balanced main candidate

```text
M34_health_recovery_with_vol_cap
8.01% / 15.12%
```

Why:

- Beats 25/25 buy-and-hold on full-cycle return.
- Reduces full-cycle max drawdown from 21.00% to 15.12%.
- Keeps latest allocation moderate: 31.2% Nasdaq / 33.5% gold / 35.3% cash.
- Strategy story is product-native: gold/Nasdaq barbell health, staged re-accumulation, volatility-aware satellite.

### Aggressive lane

```text
M13_harvest_rebuild
9.95% / 20.14%
```

Why:

- Highest full-cycle return in current strict universe.
- But drawdown is still near 20%, so it should be framed separately from the balanced main candidate.

## Next research directions

Do not continue ordinary momentum/FAA/VAA variants unless there is a new payoff source.

Continue only mechanism-level improvements around M34:

1. Replace close-only virtual-barbell health with real OHLC/range-based health once OHLC data is available.
2. Split the health state into: “Nasdaq broken”, “gold broken”, “both broken”, “barbell only bruised”.
3. Make re-accumulation path explicit for product UX: observe -> partial recovery -> full recovery -> satellite on.
4. Test whether monthly rebalancing can be reduced with tolerance bands without materially changing results.
5. Run through the production backtest engine before any app listing; this spike is still research code.

## Files

- Script: `spikes/008-gold-nasdaq-mechanism-zoo/mechanism_zoo.py`
- Latest JSON: `/tmp/atm_gold_nasdaq_mechanism_zoo.json`
- Latest log: `/tmp/atm_gold_nasdaq_mechanism_zoo_v6.log`
- Earlier logs:
  - `/tmp/atm_gold_nasdaq_mechanism_zoo_v1.log`
  - `/tmp/atm_gold_nasdaq_mechanism_zoo_v2.log`
  - `/tmp/atm_gold_nasdaq_mechanism_zoo_v3.log`
  - `/tmp/atm_gold_nasdaq_mechanism_zoo_v4.log`
  - `/tmp/atm_gold_nasdaq_mechanism_zoo_v5.log`
