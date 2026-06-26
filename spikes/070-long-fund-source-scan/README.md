# Spike 070 - Long Fund Source Scan

## Goal

After core reshaping, defensive sleeves, and offensive ETF routers failed to
reach the target, scan longer-history active funds, sector funds, ETFs, and a
small diagnostic set of large-cap stocks for a genuinely stronger return source.

Constraints:

- 1% entry fee on external buy-and-hold series.
- CNY conversion through the App's `usd_per_cny` history.
- No leverage.
- No shorting.
- No BTC/crypto.

Individual stocks are diagnostic only, not an App strategy candidate.

## Standalone Screen

Main horizon: 2005-01-03 to 2026-06-23.

Best by full-history Sharpe:

| Symbol | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: |
| `OSTIX` | 4.57% | 17.57% | 3.68% | 1.1948 | 1.0357 |
| `PIMIX` | 6.08% | 17.84% | 4.94% | 1.1809 | 0.6272 |
| `PONAX` | 5.62% | 18.44% | 4.91% | 1.1036 | 0.5610 |
| `CORE` | 11.57% | 11.23% | 10.09% | 1.1015 | 0.8541 |
| `AAPL` | 29.44% | 63.42% | 31.41% | 0.9526 | 0.8249 |
| `VOOG` | 16.71% | 30.53% | 18.53% | 0.8993 | 0.7761 |
| `NVDA` | 37.36% | 86.43% | 47.58% | 0.8839 | 1.2728 |
| `TSM` | 23.49% | 52.76% | 32.73% | 0.7870 | 1.0026 |

Observation: no standalone high-return source comes close to 1.6 Sharpe. The
high-return assets have extreme full-cycle drawdowns; the high-Sharpe income
assets have too little annualized return.

## Static Blend Ceiling

Static blends require:

- at least 20% current `CORE`;
- at least 20% `OSTIX`;
- one or two risk satellites from long-history funds/ETFs/stocks.

Best by full-history Sharpe:

| Weights | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: |
| 70% `OSTIX` / 20% `CORE` / 10% `PRWCX` | 7.30% | 12.03% | 5.19% | 1.3398 | 1.1509 |
| 70% `OSTIX` / 20% `CORE` / 10% `XLP` | 7.20% | 10.91% | 5.19% | 1.3226 | 1.1057 |
| 60% `OSTIX` / 30% `CORE` / 10% `COST` | 9.60% | 10.75% | 7.16% | 1.2753 | 1.1341 |

Best higher-annualized blends:

| Weights | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: |
| 30% `OSTIX` / 50% `CORE` / 10% `COST` / 10% `LLY` | 12.02% | 11.32% | 8.97% | 1.2706 | 1.2615 |
| 20% `OSTIX` / 60% `CORE` / 10% `COST` / 10% `LLY` | 12.37% | 10.41% | 9.29% | 1.2625 | 1.2449 |
| 30% `OSTIX` / 50% `CORE` / 10% `COST` / 10% `SMH` | 12.33% | 11.23% | 9.28% | 1.2600 | 1.2692 |
| 20% `OSTIX` / 60% `CORE` / 10% `COST` / 10% `FSELX` | 13.12% | 12.48% | 9.98% | 1.2455 | 1.2443 |

Observation: adding carefully chosen satellites can lift annualized return above
12% with Sharpe around 1.25-1.27. This is meaningfully better than many prior
external-asset attempts, but still far from the preferred 1.6 Sharpe target.

## Product Fit

This is not suitable for direct App promotion:

- The best higher-return blends rely on individual stock satellites such as
  `COST` and `LLY`.
- The risk-source story becomes stock-picking rather than a durable
  gold/Nasdaq-centered product strategy.
- It is static allocation, not a dynamic strategy with today's rebalance logic.

## Conclusion

Do not promote this into the App.

The useful finding is a boundary:

- external high-return sources can improve annualized return;
- but after full-cycle drawdowns, the best practical Sharpe found here is only
  about 1.27;
- the gap to 1.6 remains large.

Next search should focus on a fundamentally different dynamic edge rather than
another static external satellite blend.

## Files

- `long_fund_source_scan.py`: standalone source scan and static blend ceiling.
- `results.json`: generated output.
