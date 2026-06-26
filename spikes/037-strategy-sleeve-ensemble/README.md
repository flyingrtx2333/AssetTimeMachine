# Spike 037 - Strategy Sleeve Ensemble

Goal: test whether fixed capital sleeves across behaviorally different
no-leverage strategy engines can raise full-history Sharpe.

Method:
- Blend fee-adjusted strategy NAV curves as a first-pass theoretical screen.
- Limit cash to at most 10% so the result cannot be mostly cash dilution.
- This is not final app parity; any passing candidate would need a combined
  target-weight replay.

Best results:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `one_way_plus_basket_vol9:0.40 + smooth_profit_lock:0.50` | 10.77% | 7.89% | 7.40% | 1.3772 |
| `one_way_plus_basket_vol9:0.50 + smooth_profit_lock:0.40` | 10.69% | 8.09% | 7.35% | 1.3767 |
| `baseline_one_way_vol` | 13.54% | 9.87% | 9.53% | 1.3388 |

Conclusion:

Static sleeves reduce volatility and drawdown, but they do not reach Sharpe 1.4
unless return is materially diluted. The sub-strategies are too correlated to
create a clean high-return Sharpe breakthrough. Do not promote this logic.
