# Spike 030 - Smooth Risk Budget

Goal: test whether smoother portfolio-state exposure control can push the
current no-leverage champion above 1.4 Sharpe.

Base strategy:
- `coreGoldSatelliteOneWayVolManagedMomentum`
- Latest app-equivalent baseline to 2026-06-23:
  - 13.53% annualized
  - 9.87% max drawdown
  - 1.3381 Sharpe

Tested logic:
- Smooth drawdown-based exposure curve.
- Loss-confirmed drawdown throttle.
- Two-speed drawdown throttle.
- Profit-lock throttle after strong recent gains.
- Convex drawdown throttle.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `profit_lock_lb90_s12_h45_m50` | 12.28% | 7.96% | 8.53% | 1.3577 |

Conclusion:

Smooth risk budgeting improved drawdown and full-history Sharpe slightly, but
it did not break 1.4 and gave up too much annualized return. This is a useful
defensive variant, not a better main strategy.
