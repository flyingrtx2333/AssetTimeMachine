# Spike 074 - Annual Quality Core Frontier

Goal: refine the promising spike 073 result without changing the underlying
logic.  This is a structured annual-rebalance basket:

- `CORE` sleeve from the current app-equivalent strategy;
- high-Sharpe income sleeve, mainly `OSTIX`;
- small quality equity satellites;
- optional gold ETF (`IAU`);
- annual rebalancing only;
- 1% fee and 0.05% slippage on external assets;
- no leverage, no shorting, no BTC.

Coverage:
- Main replay inherits the 2005+ long-history window from spike 073.
- Final run generated 19,857 annual-rebalance candidates.

Best full-history Sharpe:

| Basket | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe | Last-10Y Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 50% `OSTIX` / 30% `CORE` / 5% `IAU` / 5% `AAPL` / 5% `LLY` / 5% `ORLY` | 10.22% | 14.60% | 5.98% | 1.6070 | 1.4592 | 1.5238 |
| 50% `PIMIX` / 30% `CORE` / 5% `IAU` / 5% `AAPL` / 5% `LLY` / 5% `ORLY` | 10.42% | 15.66% | 6.14% | 1.5949 | 1.2896 | 1.4327 |
| 50% `OSTIX` / 25% `CORE` / 10% `IAU` / 5% `AAPL` / 5% `LLY` / 5% `ORLY` | 10.16% | 15.55% | 6.00% | 1.5910 | 1.4894 | 1.5596 |

Best annualized return with Sharpe near the target:

| Basket | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe | Last-10Y Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 45% `OSTIX` / 30% `CORE` / 5% `IAU` / 10% `AAPL` / 5% `LLY` / 5% `ORLY` | 11.68% | 17.01% | 6.96% | 1.5729 | 1.4175 | 1.5168 |
| 40% `OSTIX` / 35% `CORE` / 5% `IAU` / 10% `AAPL` / 5% `LLY` / 5% `ORLY` | 12.04% | 16.19% | 7.22% | 1.5604 | 1.3977 | 1.4826 |
| 40% `OSTIX` / 30% `CORE` / 5% `IAU` / 10% `AAPL` / 5% `COST` / 5% `LLY` / 5% `ORLY` | 12.30% | 18.20% | 7.43% | 1.5486 | 1.4198 | 1.5216 |

Conclusion:

This is the strongest 1% fee candidate found so far.

It reaches the requested Sharpe region, but with a tradeoff:

- maximum Sharpe: 1.6070 with 10.22% annualized return;
- best 12%+ annualized candidate: about 1.56 Sharpe.

This is materially better than the current app-equivalent strategy family under
1% fee, but it is not a clean product answer yet because it relies on individual
stock satellites (`AAPL`, `LLY`, `ORLY`, sometimes `COST/AZO`).  If promoted,
the app should label it as a quality annual-rebalance basket rather than a pure
gold/Nasdaq timing strategy.
