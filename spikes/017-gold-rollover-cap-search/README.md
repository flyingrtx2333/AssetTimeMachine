# 017: Gold rollover cap search

## Question

Find a better no-BTC AssetTimeMachine strategy candidate using the current
App-equivalent backtest engine, without treating one-off research scripts as
product truth.

The previous App-equivalent baseline is strong but has one uncomfortable
failure mode:

```text
baseline_cap64: 12.43% annualized / 11.92% max drawdown
max drawdown window: 2003-02-04 -> 2003-04-07
```

Root cause: the strategy treats gold as a defensive/satellite asset, but after
a sharp gold run-up, gold itself can become the drawdown source.

## Mechanism

Keep the current App-equivalent `coreGoldSatelliteHeatCappedMomentum` engine.
Patch only the gold satellite overlay:

1. If gold exposure is above a cap.
2. And gold had a strong medium-term run-up.
3. And gold has rolled over in the short term.
4. Cap gold exposure for that rebalance.

This is not a broad new asset story. It targets the observed 2003 gold-heavy
failure mode.

## Files

```text
gold_rollover_cap_search.py
results.json
README.md
```

Command run:

```bash
python3 -B spikes/017-gold-rollover-cap-search/gold_rollover_cap_search.py
```

The script:

- imports `tools/atm_app_equivalent_backtest.py`;
- fetches real public history from `api.flyingrtx.com`;
- prepares aligned series once;
- replays candidates through the same unit/cash/trade-cost mechanics as the
  App-equivalent engine;
- reports full history plus 2020+, last 10Y, 2022+, and 2024+ slices.

## Search space

Narrow search around the known effective mechanism:

```text
cap:             44%, 45%, 46%, 48%, 50%
long lookback:   75, 90, 105 sessions
long threshold:  6%, 8%, 10%
short lookback:  15, 20, 25 sessions
short threshold: -1%, 0%, +1%
```

Total candidates:

```text
405
```

## Best result

Multiple nearby parameter sets tie. The top by return under 10% max drawdown:

```text
cap=44%, long=75, long_threshold=6%, short=15, short_threshold=0%
Full:      12.43% annualized / 9.76% max drawdown / Sharpe 1.21
Post-2020: 13.26% annualized / 9.08% max drawdown
Last 10Y:  11.26% annualized / 9.08% max drawdown
Post-2022: 12.82% annualized / 7.36% max drawdown
Post-2024: 21.89% annualized / 7.36% max drawdown
Trades:    177
Coverage:  2002-01-04 -> 2026-06-19
Worst DD:  2007-01-24 -> 2007-08-16
```

The 45% cap variants produce the same headline result in this search window,
which suggests this is a mechanism plateau rather than a fragile single
parameter.

## Recommendation

Use the more explainable plateau member for product implementation:

```text
Gold blowoff rollover cap
cap: 45%
medium-term run-up: 90 sessions > 8%
short-term rollover: 15 sessions < 0%
```

Expected App-equivalent result:

```text
12.43% annualized / 9.76% max drawdown
```

This is materially better than the current baseline because it keeps nearly the
same annualized return while moving max drawdown below 10%.

## Caveat

This spike uses the tracked Python App-equivalent engine, not the Swift engine
directly. Before shipping the strategy card, implement the rule in
`BacktestEngine` and compare the Swift output against `results.json`.
