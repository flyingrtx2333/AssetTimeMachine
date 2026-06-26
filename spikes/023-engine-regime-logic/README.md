# Engine Regime Logic

This spike extends engine-selection logic with a state machine over engine
equity curves.

Run:

```sh
/opt/miniconda3/bin/python3.13 -B spikes/023-engine-regime-logic/engine_regime_logic.py
```

Data cutoff: 2026-06-19.

## Result

Best full-history Sharpe in this spike:

`cash_buffer_offense`

- Full: 15.27% annualized / 15.30% max drawdown / Sharpe 1.2962
- Post-2020: 13.02% annualized / Sharpe 1.0598
- Last 10y: 10.99% annualized / Sharpe 0.9915
- Post-2024: 21.38% annualized / Sharpe 1.5770

Prior best:

`engine_return_lead_blend`

- Full: 15.58% annualized / 13.68% max drawdown / Sharpe 1.2960
- Post-2020: 14.29% annualized / Sharpe 1.0916
- Last 10y: 12.15% annualized / Sharpe 1.0298
- Post-2024: 23.87% annualized / Sharpe 1.6325

## Interpretation

The cash-buffer offense route technically has the highest full-history Sharpe,
but the improvement is negligible: 1.2962 versus 1.2960.  It gives up too much
return and too much recent performance to be a better product candidate.

The more useful strategy remains `engine_return_lead_blend`: it keeps higher
return, better recent slices, and nearly identical Sharpe.

## Takeaway

Engine regime logic confirms the current frontier:

- return-first high-Sharpe candidate: `engine_return_lead_blend`;
- pure metric max Sharpe candidate: `cash_buffer_offense`, but not worth
  shipping as the main candidate.

Sharpe remains capped around 1.30 under the current asset universe and no
leverage/no-new-return-source constraints.
