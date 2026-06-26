# Sharpe Two Logic Spike

Goal: search for new logic that can push full-history Sharpe toward or above
2.0 without parameter grids.

Run:

```sh
/opt/miniconda3/bin/python3.13 -B spikes/020-sharpe-two-logic/sharpe_two_logic.py
```

Data cutoff: 2026-06-19.  Transaction cost and slippage follow the
App-equivalent Python engine.

## Best Honest Candidate

`ensemble_current_equity_breadth`

Logic:

- Keep the current gold handoff champion.
- Add the high-return equity breadth accelerator.
- Combine the two target portfolios 50/50 at the target-weight level.

Result:

- Full: 14.76% annualized / 11.59% max drawdown / Sharpe 1.2601
- Post-2020: 14.10% annualized / Sharpe 1.0916
- Last 10y: 12.03% annualized / Sharpe 1.0353
- Post-2024: 22.80% annualized / Sharpe 1.5793
- Trades: 364

Comparison:

- `current_gold_handoff`: 12.44% annualized / 9.76% max drawdown / Sharpe
  1.2026
- `low_freq_equity_breadth_accelerator`: 16.98% annualized / 17.36% max
  drawdown / Sharpe 1.2385

The ensemble is the best Sharpe candidate found here.  It raises return versus
the current champion and raises Sharpe versus both standalone engines.

## Sharpe 2 Boundary

No non-cheating candidate reached Sharpe 2.

Rejected paths:

- Daily confirmation gates: too much churn; thousands of trades and poor
  full-history Sharpe.
- Daily risk-parity baskets: transaction costs and whipsaw dominate.
- High-confidence cash gates: reduce return faster than volatility.
- Dynamic engine risk parity: worse than the simple 50/50 ensemble.
- Volatility-scaled ensemble: lowers volatility but also lowers return; Sharpe
  does not improve.

The main practical constraint is that this is a long-only, no-leverage, real
transaction-cost, public-index strategy.  Full-history Sharpe above 2 likely
requires one of:

- materially more stable return source;
- leverage with volatility targeting;
- an option/hedge/carry leg outside the current asset universe;
- or a cash-heavy metric artifact, which is not a high-return strategy.

## Product Takeaway

If the product needs a new high-Sharpe mode under the current asset universe,
the best candidate is an "engine ensemble": current gold handoff plus equity
breadth acceleration.  It is better than either standalone engine, but it does
not honestly reach Sharpe 2.
