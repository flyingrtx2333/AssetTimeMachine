# 016: Meta loss/vol gate strategy with real unit verification

## Question

The previous best low-drawdown candidate (~7.97% / 9.92%) was not good enough. Search for a stronger strategy without BTC, using real units/cash accounting and no broad parameter fitting.

## Key discovery

Old `/tmp` research logs contained a promising `loss_vol_gate` meta strategy showing ~12% annualized / ~9% drawdown under weight-return approximation. A later unit-validation file appeared to invalidate it (~6% annualized / ~20% drawdown), but that validation used `base_w[i-1]` at rebalance time, effectively lagging the meta target by a full rebalance interval.

This spike rewrote a clean unit simulator:

- signal: T-1;
- execution: T close price;
- real cash + asset units;
- fee = 0.10%;
- slippage = 0.05%;
- idle cash earns historical Chinese demand-deposit style cash yield;
- no BTC;
- assets: `gold_cny`, `nasdaq`, `sp500`, `csi300`, `shanghai_composite`.

## Files

```text
meta_loss_vol_unit_verify.py
meta_loss_vol_heat_cap_explore.py
README.md
```

Main outputs:

```text
/tmp/atm_meta_loss_vol_unit_verify_016.txt
/tmp/atm_meta_loss_vol_unit_verify_016.json
/tmp/atm_meta_loss_vol_heat_cap_016.txt
/tmp/atm_meta_loss_vol_heat_cap_016.json
```

Commands run:

```bash
python3 -m py_compile spikes/016-meta-loss-vol-unit-verify/meta_loss_vol_unit_verify.py
python3 spikes/016-meta-loss-vol-unit-verify/meta_loss_vol_unit_verify.py
python3 -m py_compile spikes/016-meta-loss-vol-unit-verify/meta_loss_vol_heat_cap_explore.py
python3 spikes/016-meta-loss-vol-unit-verify/meta_loss_vol_heat_cap_explore.py
```

## Strategy logic

Working name:

```text
近期亏损波动元策略 + 黄金卫星 + 单权益热度上限
```

Plain-language rule:

1. Run the existing champion momentum engine as the main engine.
2. Track the champion's shadow equity curve.
3. If the champion has a recent loss cluster or high realized-volatility loss cluster, temporarily switch to the `tail_def` defensive engine.
4. Add a small gold satellite when gold has positive momentum, is above MA120, and is outperforming S&P over 60 days.
5. Keep a February weak-equity cap.
6. Add a simple single-equity heat cap so one equity index cannot dominate the portfolio during stale bull phases.

The heat cap is not a broad fitted parameter; it came directly from root-cause analysis of the max drawdown: 2007 drawdown was caused by ~74% Nasdaq exposure. Capping single equity exposure solves that specific failure mode.

## Clean-unit validation results

Coverage:

```text
2002-01-04 to 2026-06-22, 6366 aligned observations
```

### Base clean unit: meta + gold satellite, no extra heat cap

```text
M01_meta_loss_vol_gold_sat_clean_unit
Full:      12.93% / 10.26%
Post-2020: 14.20% / 9.08%
Last 10Y:  12.15% / 9.08%
2024+:     22.79% / 7.31%
2002-2012: 12.76% / 10.26%
2013-2023: 11.02% / 9.08%
Latest:    S&P 75.0%, cash 25.0%
```

Stress:

```text
2008:  7.31% / 5.79%
2015:  2.32% / 8.87%
2020: 10.63% / 9.08%
2022: -5.80% / 7.57%
2026:  7.14% / 6.30%
```

Rejected only because full-cycle DD is slightly above 10%.

### Recommended aggressive candidate: single equity cap 68%

```text
H03_equity_single_cap68
Full:      12.45% / 9.94%
Post-2020: 13.73% / 9.08%
Last 10Y:  11.64% / 9.08%
2024+:     22.36% / 7.31%
Latest:    S&P 68.0%, cash 32.0%
```

Top drawdowns:

```text
2007-01-24 -> 2007-08-16: 9.94%, held Nasdaq ~66.5%
2011-08-22 -> 2012-06-04: 9.18%, held S&P ~67.2%
2020-02-24 -> 2020-03-18: 9.08%, held Gold ~73.9%
2021-02-17 -> 2021-03-10: 8.52%, held Shanghai Composite ~66.6%
2017-11-22 -> 2018-04-02: 8.20%, held Nasdaq ~63.3%
```

Stress:

```text
2008:  7.27% / 5.79%
2015:  2.39% / 8.07%
2020: 10.63% / 9.08%
2022: -5.50% / 6.99%
2026:  6.55% / 6.30%
```

### More conservative candidate: single equity cap 66%

```text
eqcap0.66
Full:      12.27% / 9.85%
Post-2020: 13.56% / 9.08%
Last 10Y:  11.45% / 9.08%
2024+:     22.21% / 7.31%
Latest:    S&P 66.0%, cash 34.0%
```

### Comfort candidate: single equity cap 64%

```text
eqcap0.64
Full:      12.08% / 9.76%
Post-2020: 13.35% / 9.08%
Last 10Y:  11.22% / 9.08%
2024+:     21.95% / 7.31%
Latest:    S&P 64.0%, cash 36.0%
```

### Testing additional gold caps

Gold cap can reduce post-2020/2024+ drawdown further, but full-cycle max DD remains controlled by the 2007 equity episode unless the equity cap is lowered. Examples:

```text
eq0.68_gold0.72: 12.01% / 9.94%, post2020 DD 8.73%
eq0.66_gold0.72: 11.83% / 9.85%, post2020 DD 8.73%
eq0.64_gold0.72: 11.63% / 9.76%, post2020 DD 8.73%
```

Gold caps are therefore optional. They improve comfort but reduce return; not the first recommended change.

## Recommendation

For a shippable high-quality strategy, the best current trade-off is:

```text
Meta Loss/Vol Rotation + Gold Satellite + Single-Equity Heat Cap 68
```

Headline:

```text
12.45% annualized / 9.94% max drawdown
```

If the product wants slightly more comfort and still wants to stay above 12%:

```text
Single-equity cap 64: 12.08% / 9.76%
```

Do not package this as a pure gold/Nasdaq strategy. It is a broader tactical index rotation strategy with gold as defensive/satellite component. Current active holding is S&P, not Nasdaq/gold.

## Next production step

Before showing this in App strategy cards, reproduce the exact rule in the App's production backtest engine and compare against this spike's clean unit output. The previous false-negative unit validation shows that rebalance indexing is easy to get wrong: use target decision at rebalance day `i` generated from T-1 signal, not stale `base_w[i-1]`.
