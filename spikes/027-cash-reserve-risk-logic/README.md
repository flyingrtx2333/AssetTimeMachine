# Spike 027 - Cash Reserve Risk Logic

Goal: push the prior no-financing engine router above Sharpe 1.3 while keeping max notional exposure at or below 100%.

Inputs:
- App-equivalent Python backtest path via `tools/atm_app_equivalent_backtest.py`.
- Prior current/breadth engine router from `spikes/022-engine-selection-logic/engine_selection_logic.py`.

Core idea:

The previous best strategy was already close to Sharpe 1.3. Instead of adding new assets or leverage, this spike treats cash as an explicit risk budget. The strongest variant uses one-way volatility management: when the routed offensive engine has higher trailing engine volatility than the current defensive engine, it scales the target weights down. It never scales weights up.

Reference used as structural inspiration:
- Moreira and Muir, "Volatility Managed Portfolios", NBER Working Paper 22208: https://www.nber.org/papers/w22208

Result summary:

| Candidate | Annualized | Max DD | Sharpe | Notes |
| --- | ---: | ---: | ---: | --- |
| `one_way_vol_managed` | 13.54% | 9.87% | 1.3388 | New best Sharpe; no leverage; DD under 10% |
| `profit_lock_after_fast_offense` | 15.48% | 13.68% | 1.3074 | Higher return, larger DD |
| `offense_cash_reserve` | 14.49% | 12.43% | 1.3015 | Also crosses Sharpe 1.3 |
| `cash_buffer_offense_retest` | 15.26% | 15.30% | 1.3002 | Retest of spike 023 logic, now slightly above 1.3 |
| `baseline_return_lead_blend` | 15.58% | 13.68% | 1.2960 | Prior practical best |

Current champion:

`one_way_vol_managed`

- Full cycle: 13.54% annualized, 9.87% max drawdown, 1.3388 Sharpe.
- Post-2020: 13.06% annualized, 1.1602 Sharpe.
- Last 10y: 11.09% annualized, 1.1028 Sharpe.
- Post-2024: 20.03% annualized, 1.5750 Sharpe.
- Worst drawdown window: 2015-05-27 to 2015-09-29.

Implementation notes:

- Reuses the prior return-lead engine blend.
- Computes trailing engine volatility from the app-equivalent engine equity curves.
- If the routed state is offensive and its trailing volatility is higher than the current engine's trailing volatility, scale target weights by `current_vol / routed_vol`.
- The scale is capped at 1.0, so this is strictly one-way risk reduction and cannot borrow or finance.

Conclusion:

This is the first clean no-financing candidate in the current spike sequence to exceed Sharpe 1.3 while also keeping full-cycle drawdown below 10%. It is a strong candidate for Swift implementation after another review of edge cases and UI copy.
