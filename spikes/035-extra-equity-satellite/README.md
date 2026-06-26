# Spike 035 - Extra Equity Satellite

Goal: keep the current champion as the core and use idle cash for a small
opportunity satellite from additional no-BTC indices.

Extra assets:
- `dowjones`, converted from USD to CNY.
- `shenzhen_component`, CNY local index.
- `chinext`, CNY local index.

The extra assets are not allowed into the core rotation. They can only use idle
cash when their own trend/risk quality is strong.

Best results:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `risk_clean_no_weak_months_cap15_per10_top2` | 14.56% | 10.40% | 10.04% | 1.3620 |
| `risk_clean_smooth_after_cap15_per10_top2` | 13.09% | 8.49% | 9.06% | 1.3604 |
| `risk_clean_only_cap15_per10_top2` | 14.92% | 10.40% | 10.33% | 1.3556 |

Conclusion:

This is the most promising high-return direction found in the latest round:
it raises annualized return while keeping Sharpe above the previous defensive
variants. It still does not break 1.4, mainly because 2015 and 2020 tail
volatility remain too large. Do not promote to app yet, but this is worth
continuing before returning to defensive-only overlays.
