# 009: Strict 12% annualized / 8% max drawdown target

## Why this spike exists

The user rejected the previous `M34_health_recovery_with_vol_cap` result:

```text
M34: 8.01% annualized / 15.12% max drawdown
```

The correct historical standard is much stricter:

```text
Annualized return >= 12%
Max drawdown <= 8%
```

Anything below that should not be promoted as a good strategy.

## Current strict universe

Visible holdings remain:

```text
nasdaq
gold_cny
cash
```

No BTC. No hidden unrelated assets. Other available series are only signal candidates unless explicitly allowed:

```text
sp500
dowjones
csi300
shanghai_composite
```

## Hard baseline facts

Using the same full aligned data window:

```text
Coverage: 2002-01-04 to 2026-06-21
```

Static all-in asset baselines:

```text
100% Nasdaq: 10.02% / 58.32%
100% Gold:   10.68% / 44.13%
80N/20G:     10.15% / 43.35%
70N/30G:     10.22% / 37.90%
60N/35G:     10.15% / 33.49%
30N/60G:     10.12% / 31.36%
```

Static no-leverage weights cannot reach 12% annualized. Even the individual return engines do not reach 12% full-cycle by themselves.

Best fixed-weight portfolio under 8% max drawdown:

```text
5% Nasdaq / 0% Gold: 1.92% / 6.77%
0% Nasdaq / 0% Gold: 0.48% / 0.00%
```

So the 12/8 target requires very strong tactical rotation, not just better weights.

## Prior candidates fail the real gate

```text
M13_harvest_rebuild: 9.95% / 20.14%
M34_health_recovery_with_vol_cap: 8.01% / 15.12%
BH_25_25_buyhold: 7.77% / 21.00%
```

None are close to the original 12/8 target.

## New mechanisms tested in this spike

### Daily/event-driven hard risk-control attempts

Tested:

- `S01_daily_portfolio_dd_circuit_breaker`
- `S02_daily_dual_sleeve_trailing_stop_reentry`
- `S03_daily_nasdaq_engine_gold_airbag`
- `S04_daily_ratio_breakout_with_stop`
- `S05_daily_barbell_equity_curve_pyramid`
- `S06_daily_return_stack_without_leverage`
- `S07_daily_gold_breakout_nasdaq_reentry`
- `S08_daily_m34_more_aggressive`
- weekly variants of several above

Best full-cycle returns remained far below the target. Daily hard stop systems exited too often and traded too much; they reduced some local risk but destroyed return.

Top examples:

```text
S03_weekly_nasdaq_engine_gold_airbag: 3.71% / 22.08%
S01_weekly_portfolio_dd_circuit_breaker: 3.28% / 21.99%
S02_daily_dual_sleeve_trailing_stop_reentry: 2.63% / 15.21%
```

Verdict:

```text
INVALIDATED.
```

Naive hard stops are not the path to 12/8.

### Strategy equity-curve surfing attempts

Tested aggressive engines and surfed their own equity curves:

- `E01_allin_best_abs_mom`
- `E02_nasdaq_growth_gold_crisis`
- `E03_breakout_pair`
- `E04_m13_like_high_base`
- SURF variants with m34-lite or gold/cash fallback

Raw engines either had high drawdown or not enough return:

```text
E04_m13_like_high_base: 10.32% / 38.07%
E01_allin_best_abs_mom: 7.83% / 32.85%
E02_nasdaq_growth_gold_crisis: 6.73% / 30.94%
```

Surfing the equity curve reduced exposure too aggressively and collapsed return:

```text
Most SURF variants: ~0.7% to 2.2% annualized with 12%+ drawdown
```

Verdict:

```text
INVALIDATED as implemented.
```

### Expanded-universe sanity check

As a diagnostic only, allowed visible holdings among all available six series:

```text
nasdaq
gold_cny
sp500
dowjones
csi300
shanghai_composite
```

This was not treated as a recommendation, just a test of whether the strict gold/Nasdaq universe was the only blocker.

Simple fixed expanded-universe mechanisms also failed:

```text
X02_protective_momentum: 4.79% / 24.07%
X03_weekly:              4.75% / 15.29%
X02_weekly:              4.42% / 17.51%
```

Verdict:

```text
INVALIDATED.
```

The extra four equity indexes in the current data pipeline do not add enough new payoff source.

## Oracle sanity check

Perfect lookahead rotation is not tradable, but it shows what kind of information edge would be required.

```text
Perfect 1-day lookahead:   381.69% / 0.87%, 5968 trades
Perfect 5-day lookahead:   129.55% / 12.31%, 1215 trades
Perfect 21-day lookahead:   58.12% / 12.91%, 294 trades
Perfect 63-day lookahead:   34.31% / 21.58%, 99 trades
Perfect 126-day lookahead:  24.19% / 24.92%, 49 trades
```

Naive past-momentum analogs failed:

```text
5-day past momentum:   -0.17% / 61.85%
21-day past momentum:   6.04% / 61.39%
63-day past momentum:  10.76% / 28.84%
126-day past momentum:  9.76% / 30.99%
```

Interpretation:

```text
The target is theoretically possible only with a very strong timing edge, but ordinary trend/momentum is nowhere near enough.
```

## Current honest conclusion

Under the strict current constraints:

```text
Visible holdings: gold + Nasdaq + cash only
No leverage
No BTC
Full period from 2002
T-1 signal / T execution
Real cash/fees/slippage
```

No candidate found so far reaches:

```text
12% annualized / 8% max drawdown
```

The previous `M34` should be downgraded:

```text
M34 is not a candidate for the user's original standard.
It is only a lower-drawdown improvement over 25/25, not an app-worthy breakthrough.
```

## What has to change to reach 12/8

One of these must likely change:

1. **Add a genuinely different payoff source**
   Example categories: managed futures/CTA, option convexity, carry/short-duration/cash-plus, commodities beyond gold, or a real alternative trend asset. But some of these were previously rejected as outside the gold/Nasdaq product story.

2. **Use leverage plus strong risk control**
   But leverage makes the 8% drawdown constraint harder, not easier. It needs a much better hedge/stop mechanism than tested so far.

3. **Use a shorter start date**
   Post-2020 / last-10-year numbers are much better, but the user explicitly prefers full-cycle/all-available history. Short windows should not be used as the main conclusion.

4. **Find a genuinely predictive signal not currently in the dataset**
   The current six close-price series do not appear to contain enough edge for 12/8 with simple interpretable mechanisms.

## Files

- Main strict-target script: `spikes/009-strict-12-8-target/strict_12_8_target.py`
- Strategy-surf script: `spikes/009-strict-12-8-target/strategy_surf.py`
- Expanded-universe probe: `spikes/009-strict-12-8-target/expanded_universe_probe.py`
- Latest strict-target JSON: `/tmp/atm_gold_nasdaq_strict_12_8.json`
- Latest logs:
  - `/tmp/atm_gold_nasdaq_strict_12_8_v1.log`
  - `/tmp/atm_oracle_bounds_v2.txt`
  - `/tmp/atm_strategy_surf_12_8_v1.log`
  - `/tmp/atm_expanded_universe_12_8_probe.log`
