# Spike 077 - Annual Rebalance Calendar

Goal: keep the spike 074 assets unchanged and test whether changing the fixed
rebalance calendar improves the high-Sharpe annual quality/core basket.

Method:
- Test annual rebalancing in each month from January through December.
- Test semiannual rebalancing pairs: Jan/Jul, Feb/Aug, ..., Jun/Dec.
- Use the strongest baskets from spike 074.
- 1% fee and 0.05% slippage on external assets.
- No leverage, no shorting, no BTC.

Best result:

| Basket / Calendar | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `max_sharpe_074`, Mar/Sep semiannual | 10.14% | 14.87% | 5.92% | 1.6094 |
| `max_sharpe_074`, January annual | 10.22% | 14.60% | 5.98% | 1.6070 |
| `middle_1168`, January annual | 11.68% | 17.01% | 6.96% | 1.5729 |
| `annual_12`, January annual | 12.04% | 16.19% | 7.22% | 1.5604 |

Conclusion:

Reject as a major improvement.  Calendar choice can slightly improve the
maximum-Sharpe variant, but it does not improve the 12%+ annualized frontier.
The default January annual replay remains the cleaner product interpretation.
