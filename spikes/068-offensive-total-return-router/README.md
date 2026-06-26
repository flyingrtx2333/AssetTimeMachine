# Spike 068 - Offensive Total-Return Router

## Goal

Find a higher-return source after the 1% fee change. Spike 067 showed that
bond/cash-plus defense can smooth the curve but cannot lift annualized return.
This spike tests whether offensive total-return assets can supply the missing
return while preserving high Sharpe.

All tests use:

- 1% fee for external buy-and-hold sleeves.
- 1% fee and 0.05% slippage for routed trading sleeves.
- No leverage.
- No shorting.
- No BTC/crypto.
- CNY conversion for USD assets through the App's `usd_per_cny` history.

## Data

External Yahoo adjusted-close assets:

- Offensive: `QQQ`, `XLK`, `SMH`, `SOXX`, `GLD`, `IAU`, `SPY`, `XLY`, `XLV`, `XLP`, `XLU`.
- Income / ballast: `OSTIX`, `PIMIX`, `PONAX`, `DODIX`, `PTTRX`, `VWINX`.
- Active/balanced: `PRWCX`, `FPACX`.

The App-equivalent current core strategy is included as `CORE`.

Main comparison horizon: 2005-01-03 to 2026-06-23, so GLD/sector data can be
used while still covering GFC, 2011, 2015, 2020, and 2022.

## Standalone Screen

| Asset | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `CORE` | 11.57% | 11.23% | 10.09% | 1.1015 |
| `QQQ` | 14.23% | 57.33% | 21.21% | 0.7135 |
| `XLK` | 14.66% | 56.99% | 22.10% | 0.7097 |
| `SMH` | 18.28% | 69.03% | 29.10% | 0.7040 |
| `SOXX` | 17.88% | 70.64% | 30.00% | 0.6809 |
| `OSTIX` | 4.57% | 17.57% | 3.68% | 1.1948 |
| `PIMIX` | 6.08% | 17.84% | 4.94% | 1.1809 |

Observation: high-return offensive assets have too much full-cycle volatility
and drawdown. Income assets have better Sharpe but low annualized return.

## Static Blend Ceiling

The static search blends `OSTIX` with one or two offensive/core assets on 10%
weight increments.

Best by Sharpe:

| Weights | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: |
| 90% `OSTIX` / 10% `CORE` | 5.87% | 12.74% | 3.88% | 1.4441 | 1.2547 |
| 80% `OSTIX` / 10% `CORE` / 10% `PRWCX` | 6.35% | 15.71% | 4.36% | 1.3882 | 1.2098 |
| 80% `OSTIX` / 20% `CORE` | 6.90% | 9.38% | 4.84% | 1.3589 | 1.1530 |

Best candidates above annualized-return thresholds:

| Threshold | Best Weights | Annualized | Max DD | Vol | Sharpe |
| --- | --- | ---: | ---: | ---: | ---: |
| >= 10% | 60% `OSTIX` / 30% `CORE` / 10% `SMH` | 10.42% | 11.78% | 8.06% | 1.2304 |
| >= 11% | 40% `OSTIX` / 50% `CORE` / 10% `SMH` | 11.30% | 11.41% | 8.88% | 1.2123 |
| >= 12% | 30% `OSTIX` / 50% `CORE` / 20% `SMH` | 12.84% | 15.80% | 10.66% | 1.1508 |
| >= 14% | 30% `OSTIX` / 30% `CORE` / 40% `SMH` | 14.59% | 23.84% | 14.41% | 0.9873 |

Observation: adding offensive assets can restore annualized return, but Sharpe
falls quickly. This is not close to 1.6.

## Low-Frequency Offensive Router

`offensive_total_return_router.py` also tests 42/63-session top-N momentum
routers across technology/sector/gold assets, using income/gold assets as safe
fallback.

Best by full-history Sharpe:

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| `router_r5_s3_rb63_top3_g70` | 6.24% | 30.92% | 13.23% | 0.5090 | 225 |
| `router_r5_s1_rb42_top3_g70` | 6.11% | 22.30% | 12.92% | 0.5089 | 295 |
| `router_r5_s1_rb42_top3_g85` | 7.06% | 26.33% | 15.54% | 0.5027 | 303 |

Observation: router logic fails. It improves recent bull-market windows but does
not survive full history; GFC/sector crashes dominate.

## Conclusion

Do not promote this spike into the App.

This asset pool cannot satisfy "annualized too low, Sharpe preferably 1.6" under
1% fees:

- High-Sharpe static blends are mostly income ballast and have annualized return
  below 7%.
- Annualized return above 10% is possible, but best Sharpe is only about 1.23.
- Annualized return above 12% pushes Sharpe down to about 1.15.
- Low-frequency offensive rotation is much worse than the current App core.

Next direction should not be sector/technology ETF rotation. The search needs a
return source whose standalone full-cycle Sharpe is already materially stronger,
or a new logic that changes the current core's payoff shape rather than adding
high-volatility satellites.

## Files

- `offensive_total_return_router.py`: standalone, static blend, and low-frequency router search.
- `results.json`: generated output.
