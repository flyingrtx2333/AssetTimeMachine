# High Sharpe Logic Spike

This spike searches for new strategy logic, not parameter grids.  The goal is
high annualized return and high Sharpe; max drawdown is recorded but not used as
the primary filter.

Run:

```sh
/opt/miniconda3/bin/python3.13 -B spikes/019-high-sharpe-logic/high_sharpe_logic.py
```

Data cutoff: 2026-06-19.

## Best Candidate

`equity_breadth_accelerator`

Logic:

- Keep the current gold rollover cap plus confirmed US handoff.
- If at least two equity markets are confirmed by trend, stop leaving idle cash
  unused.
- Fill the remaining budget into the confirmed equity markets by risk-adjusted
  momentum.
- Gold remains part of the base champion logic, but the extra return engine is
  equity breadth, not extra gold timing.

Result:

- Full: 16.98% annualized / 17.36% max drawdown / Sharpe 1.2385
- Post-2020: 14.58% annualized / Sharpe 1.0359
- Last 10y: 12.55% annualized / Sharpe 0.9698
- Post-2024: 23.17% annualized / Sharpe 1.5066
- Trades: 364

For comparison, current `current_gold_handoff`:

- Full: 12.44% annualized / 9.76% max drawdown / Sharpe 1.2026
- Post-2020: 13.67% annualized / Sharpe 1.1433
- Last 10y: 11.52% annualized / Sharpe 1.0878
- Post-2024: 22.57% annualized / Sharpe 1.6403
- Trades: 183

## Interpretation

This candidate is a return-first Sharpe improvement:

- Annualized return improves by about 4.54pp.
- Full-history Sharpe improves from 1.2026 to 1.2385.
- Drawdown rises materially, from 9.76% to 17.36%.
- Trade count roughly doubles.

That matches the requested direction: higher return and higher full-history
Sharpe, while accepting worse drawdown.

## Rejected Candidates

- `fill_all_confirmed_to_full`: highest annualized return at 17.31%, but Sharpe
  drops to 1.1587.
- `full_budget_current_winner`: 17.22% annualized, but Sharpe drops to 1.0856.
- `us_growth_accelerator`: better return than current, but Sharpe drops to
  1.0941.
- Risk-adjusted full baskets over all/core assets are worse on Sharpe and
  introduce much deeper drawdowns.

## Product Takeaway

If we want a new high-return/high-Sharpe mode, the strongest candidate from this
spike is not "more gold protection"; it is "equity breadth acceleration": keep
the existing champion as the base, then use confirmed multi-equity breadth to
deploy idle cash.
