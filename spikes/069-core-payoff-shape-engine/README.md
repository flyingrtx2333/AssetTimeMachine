# Spike 069 - Core Payoff-Shape Engine

## Goal

After defensive sleeves and offensive ETF rotation both failed under 1% fees,
test whether the current App-equivalent core strategy can be reshaped directly:

- keep the same gold/equity core targets;
- deploy unused cash when state is strong;
- reduce target exposure when state weakens;
- keep all trades on scheduled rebalance dates;
- no leverage, no shorting, no BTC.

## Method

`core_payoff_shape_engine.py` replays the current App-equivalent core strategy at
the target-weight layer. It then scales the core target weights by state:

- `equity_curve`: based on the strategy's own trailing return and drawdown.
- `target_quality`: based on weighted target momentum, volatility, and breadth.
- `combined`: requires both equity-curve and target-quality confirmation.
- `vol_efficiency`: scales by target return quality per expected volatility.

All candidates use:

- 1% fee.
- 0.05% slippage.
- no leverage; total target exposure capped at 100%.
- App cash yield on unused cash.

## Results

Baseline target-level replay:

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| `baseline_target_replay` | 10.70% | 11.23% | 9.92% | 1.0428 | 246 |

Best full-history candidates:

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| `equity_curve_always_full_weak60` | 12.13% | 11.96% | 11.04% | 1.0599 | 247 |
| `combined_always_full_weak60` | 12.11% | 11.96% | 11.03% | 1.0588 | 248 |
| `target_quality_always_full_weak60` | 12.49% | 13.00% | 11.50% | 1.0487 | 249 |
| `target_quality_strong110_weak60` | 11.58% | 12.05% | 10.72% | 1.0436 | 250 |

Observation: filling unused cash in strong/neutral states raises annualized
return to about 12%, but volatility and drawdown rise with it. Sharpe barely
moves from 1.04 to 1.06.

Recent slices reject the direction:

- `equity_curve_always_full_weak60` post-2020 Sharpe: 0.9116.
- Last-10Y Sharpe: 0.8073.
- 2024+ is strong, but too short and regime-specific.

## Conclusion

Do not promote this into the App.

The current core has enough unused cash that full-deployment states can lift
annualized return, but this does not change the payoff shape enough. It mostly
scales the same return stream, so Sharpe stays near 1.05.

The next search should look for a truly different high-quality return source,
not another exposure governor around the current core.

## Files

- `core_payoff_shape_engine.py`: target-weight state-scaling replay.
- `results.json`: generated metrics and state counts.
