# Engine Selection Logic

This spike tests a higher-level strategy idea: treat strategies as engines and
route between them.

Engines:

- `current_gold_handoff`: defensive/balanced engine.
- `equity_breadth`: offensive high-return engine.

Run:

```sh
/opt/miniconda3/bin/python3.13 -B spikes/022-engine-selection-logic/engine_selection_logic.py
```

Data cutoff: 2026-06-19.

## Best Candidate

`engine_return_lead_blend`

Logic:

- If the offensive equity-breadth engine has one-year return leadership, tilt
  toward it.
- If it has return leadership but is in a recent drawdown, use a more defensive
  blend.
- Otherwise fall back to the current gold-handoff engine.

Result:

- Full: 15.58% annualized / 13.68% max drawdown / Sharpe 1.2960
- Post-2020: 14.29% annualized / Sharpe 1.0916
- Last 10y: 12.15% annualized / Sharpe 1.0298
- Post-2024: 23.87% annualized / Sharpe 1.6325
- Trades: 295

Comparison:

- `current_gold_handoff`: 12.44% annualized / 9.76% max drawdown / Sharpe
  1.2026
- `equity_breadth`: 16.98% annualized / 17.36% max drawdown / Sharpe 1.2385
- Prior best static ensemble: 14.76% annualized / 11.59% max drawdown / Sharpe
  1.2601

## Interpretation

This is the best logic found so far.  It improves both return and full-history
Sharpe versus the current champion and versus the simple static ensemble.

It still does not reach Sharpe 2.  Under the current constraints:

- long-only;
- no leverage;
- same five public index assets;
- real transaction cost and slippage;
- no future-looking labels;

the honest Sharpe ceiling found so far is about 1.30.

Getting near 2 likely needs a genuinely new return stream or structure, not
more routing among these five assets.  Examples: carry/yield instruments,
option/hedge legs, futures-like volatility targeting with leverage, or a larger
uncorrelated asset universe.
