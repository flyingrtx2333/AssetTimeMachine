# Spike 075 - Quality Satellite Expansion

Goal: keep the annual-rebalance `CORE` / `OSTIX` / `IAU` structure from spike
074 and expand the quality equity satellite universe to see whether 12%+
annualized return can also clear 1.6 Sharpe.

Method:
- Expanded long-history quality universe: compounders, staples, insurers,
  payment networks, selected sector funds.
- First screen each symbol's marginal contribution inside
  `30% CORE / 50% OSTIX / 5% IAU / 15% single satellite`.
- Combine the top 16 marginal symbols into fixed annual-rebalance anchor
  structures.
- 1% fee and 0.05% slippage on external assets.
- No leverage, no shorting, no BTC.

Top marginal symbols:

`AAPL`, `COST`, `ORLY`, `MCD`, `AZO`, `XLP`, `LLY`, `WM`, `MA`, `KO`,
`FSPTX`, `AON`, `TJX`, `RSG`, `XLV`, `AJG`.

Best result:

| Basket | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe | Last-10Y Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 50% `OSTIX` / 30% `CORE` / 5% `IAU` / 5% `AAPL` / 5% `LLY` / 5% `ORLY` | 10.22% | 14.60% | 5.98% | 1.6070 | 1.4592 | 1.5238 |
| 50% `OSTIX` / 30% `CORE` / 5% `IAU` / 5% `AAPL` / 5% `AZO` / 5% `LLY` | 10.08% | 14.36% | 5.92% | 1.6000 | 1.4453 | 1.5167 |
| 45% `OSTIX` / 30% `CORE` / 5% `IAU` / 5% `AAPL` / 5% `COST` / 5% `LLY` / 5% `ORLY` | 10.85% | 15.79% | 6.44% | 1.5810 | 1.4656 | 1.5351 |

Conclusion:

No improvement over spike 074.  Expanding the quality satellite universe did not
produce a 12%+ annualized basket above 1.6 Sharpe.

The strongest current candidate remains:

`50% OSTIX / 30% CORE / 5% IAU / 5% AAPL / 5% LLY / 5% ORLY`

This is the current high-Sharpe answer, while the better annualized tradeoff is
still the 12.04% annualized / 1.56 Sharpe version from spike 074.
