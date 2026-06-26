# Spike 046 - Volatility Tail-Hedge Sleeve

Goal: test whether a small VIXY/VXX sleeve can provide true crisis payoff
without financing or shorting.

Logic:
- Use VIXY/VXX only after real ETF history begins.
- Activate only when broad equity stress and volatility-product trend agree.
- Carve 5%-10% from equity exposure; no leverage.

Best result remained the baseline:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `baseline_one_way` | 13.53% | 9.87% | 9.53% | 1.3381 |
| `tail_strict_cap5` | 9.31% | 22.04% | 10.22% | 0.8946 |

Conclusion:

Volatility ETFs decay too much and produce very poor full-cycle results. This
should not be used in the app.
