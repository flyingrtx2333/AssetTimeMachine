# Spike 031 - Seasonal Quality Risk

Goal: check whether weak calendar windows explain enough dead volatility to
push the current no-leverage champion above 1.4 Sharpe.

Diagnostic:
- The champion's weak months by annualized daily-return Sharpe were February,
  June, September, and October.
- Strong months were mostly November and December.

Tested logic:
- Weak-season equity scale-down only when selected assets have poor momentum.
- Weak-season equity scale-down when US core momentum is poor.
- Weak-season total risk scale-down when selected quality is poor.
- Autumn/summer-autumn profit lock.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `autumn_profit_lock_total_lb20_f35` | 13.30% | 9.87% | 9.27% | 1.3517 |

Conclusion:

Seasonal quality filters marginally improved Sharpe but did not break 1.4. The
effect is too small to justify adding calendar complexity to the app.
