# Spike 041 - Carry / Total-Return Assets

Goal: test whether real long-history total-return assets can raise the current
no-leverage champion above 1.4 Sharpe.

Tested:
- QQQ/SPY adjusted close as tradable total-return proxies for Nasdaq/S&P.
- Vanguard Treasury mutual funds VUSTX/VFITX/VFISX as idle-cash carry assets.
- No leverage, no shorting, no BTC.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `index_risk_off_duration_cap15_per15` | 13.61% | 9.92% | 9.55% | 1.3421 |
| `index_baseline` | 13.53% | 9.87% | 9.53% | 1.3381 |

Conclusion:

Treasury/carry assets barely improved Sharpe and did not solve the 1.4 target.
QQQ/SPY total-return proxies did not improve the product result. Do not promote.
