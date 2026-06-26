# Spike 061 - Currency Cash Selector

Goal: test whether idle cash in the 060 line should remain CNY cash or rotate
into USD cash when USD/CNY trend is favorable.

Logic tested:

- Keep the 060 gold/equity targets intact.
- Convert `usd_per_cny` into a synthetic CNY value for USD cash.
- Use only otherwise idle budget for USD cash.
- Require positive USD cash trend and a cash-hurdle filter.
- Keep total target weight capped at 100%.

Best result:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `currency_idle_hurdle_lb40_ma80_cap100_h10` | 14.67% | 9.44% | 9.14% | 1.4961 |
| 060 best baseline | 14.16% | 9.44% | 9.04% | 1.4642 |

Slices for the best result:

| Slice | Annualized | Sharpe |
| --- | ---: | ---: |
| 2020+ | 14.54% | 1.3481 |
| Last 10Y | 12.53% | 1.2880 |
| 2024+ | 21.92% | 1.7961 |

Key observations:

- Currency cash selection is a real improvement and lifts return without
  increasing max drawdown.
- It still leaves the worst drawdown at 2003-02-04 to 2003-04-07.
- The improvement is meaningful but not enough for the 1.6 Sharpe target.

Conclusion:

This is the best new high-return step from this round. It is product-feasible
because the app already has `usd_per_cny`, but it would require modeling USD
cash as a strategy holding before app promotion.
