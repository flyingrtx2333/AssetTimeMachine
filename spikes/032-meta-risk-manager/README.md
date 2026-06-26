# Spike 032 - Meta Risk Manager

Goal: test whether dynamically selecting among several no-leverage risk-budget
engines can beat the fixed current champion and cross 1.4 Sharpe.

Sub-engines:
- Baseline one-way volatility-managed champion.
- Smooth/profit-lock risk budget.
- Softer smooth risk budget.
- Basket volatility budget at 10%.
- Basket volatility budget at 9%.

Meta selectors:
- Best trailing 120/240-session Sharpe.
- Best trailing 120/240-session return.
- Best trailing return adjusted by recent drawdown.
- Positive-Sharpe-only selector.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `smooth_best` | 12.28% | 7.96% | 8.53% | 1.3577 |
| `meta_sharpe_120` | 12.11% | 9.72% | 8.46% | 1.3514 |

Conclusion:

The risk-budget engines are not complementary enough. Dynamic selection did
not improve on the best fixed defensive engine and did not approach 1.4.
