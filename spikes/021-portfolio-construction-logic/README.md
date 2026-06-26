# Portfolio Construction Logic

This spike tests new portfolio-construction logic rather than parameter grids.
It asks whether confirmed-asset optimization can push Sharpe materially higher.

Run:

```sh
/opt/miniconda3/bin/python3.13 -B spikes/021-portfolio-construction-logic/portfolio_construction_logic.py
```

Data cutoff: 2026-06-19.

## Result

Best candidate in this spike:

`equity_breadth_tangency`

- Full: 16.44% annualized / 17.75% max drawdown / Sharpe 1.2126
- Post-2020: 14.32% annualized / Sharpe 1.0225
- Last 10y: 12.35% annualized / Sharpe 0.9531
- Post-2024: 23.68% annualized / Sharpe 1.5605

Comparison:

- `current_gold_handoff`: 12.44% annualized / 9.76% max drawdown / Sharpe
  1.2026
- Prior best `ensemble_current_equity_breadth`: 14.76% annualized / 11.59%
  max drawdown / Sharpe 1.2601

## Interpretation

Portfolio optimization over the current five assets did not improve the
frontier.  Minimum variance, tangency, inverse-volatility, and anti-correlated
pair construction all underperform the simpler engine ensemble.

The issue is not just weight construction.  The useful edge is in when to use
the offensive equity-breadth engine versus the defensive gold-handoff engine.
