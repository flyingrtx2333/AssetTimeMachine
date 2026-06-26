# Spike 073 - Static Quality Income Frontier

Goal: after dynamic quality rotation failed, test whether the same source works
only when turnover is almost removed.

Method:
- Use current app-equivalent `CORE`, income funds, gold ETF, and a compact set
  of long-history quality equities/sector funds.
- First screen constrained buy-and-hold baskets.
- Replay the best screens with annual rebalancing and explicit 1% fee plus
  0.05% slippage on external assets.
- No leverage, no shorting, no BTC.

Best buy-and-hold screen:

| Basket | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: |
| 50% `CORE` / 30% `PIMIX` / 7% `LLY` / 7% `ORLY` / 7% `SMH` | 13.30% | 14.69% | 9.42% | 1.3305 | 1.3439 |
| 50% `CORE` / 30% `PIMIX` / 7% `COST` / 7% `LLY` / 7% `SMH` | 12.86% | 14.89% | 9.15% | 1.3247 | 1.3791 |

Best annual-rebalance replay:

| Basket | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: |
| 50% `CORE` / 30% `OSTIX` / 7% `AAPL` / 7% `LLY` / 7% `ORLY` | 12.39% | 12.89% | 7.71% | 1.5057 | 1.3385 |
| 30% `CORE` / 30% `OSTIX` / 10% `IAU` / 10% `AAPL` / 10% `LLY` / 10% `ORLY` | 13.56% | 19.87% | 8.47% | 1.4961 | 1.4441 |
| 40% `CORE` / 20% `OSTIX` / 10% `IAU` / 10% `AAPL` / 10% `LLY` / 10% `ORLY` | 14.29% | 18.28% | 8.99% | 1.4832 | 1.4131 |

Conclusion:

Promising, but not yet accepted.  This is the first 1% fee direction that gets
close to the 1.6 Sharpe target while keeping annualized return above 12%.

The key edge is not quality-stock momentum.  It is ultra-low-turnover annual
rebalancing between:

- app `CORE`;
- a high-Sharpe income fund sleeve;
- a small set of long-compounding quality equities;
- optional gold.

Risks:

- The result depends on individual stock choices, so product fit is weaker than
  a pure index/gold strategy.
- Needs a structured follow-up search around this annual-rebalance logic before
  it can be promoted.
