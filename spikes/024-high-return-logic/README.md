# High Return Logic

This spike searches for higher annualized return under a strict no-financing
rule.

Constraints:

- Long-only.
- Maximum notional exposure is 100%.
- No margin, leverage, borrowing, or financing.
- Same App-equivalent transaction cost and slippage.

Run:

```sh
/opt/miniconda3/bin/python3.13 -B spikes/024-high-return-logic/high_return_logic.py
```

Data cutoff: 2026-06-19.

## Best Return Candidate

`aggressive_return_router`

Logic:

- Build three 100%-notional offensive engines:
  - full-budget current winner;
  - fill all confirmed assets to full budget;
  - equity breadth accelerator.
- At each rebalance, route to the engine with the best one-year trailing return.
- No financing is used; the selected engine remains capped at 100% notional.

Result:

- Full: 17.64% annualized / 20.96% max drawdown / Sharpe 1.1477
- Post-2020: 17.88% annualized
- Last 10y: 15.64% annualized
- Post-2024: 26.16% annualized
- Trades: 234

Comparison:

- `fill_all_confirmed_to_full`: 17.31% annualized / 21.62% max drawdown /
  Sharpe 1.1587
- `full_budget_current_winner`: 17.22% annualized / 18.68% max drawdown /
  Sharpe 1.0856
- `equity_breadth`: 16.98% annualized / 17.36% max drawdown / Sharpe 1.2385
- `current_gold_handoff`: 12.44% annualized / 9.76% max drawdown / Sharpe
  1.2026

## Product Takeaway

For pure no-financing return, `aggressive_return_router` is the strongest found
so far.  It is a high-return mode, not a high-Sharpe mode: annualized return is
best, but drawdown increases materially.
