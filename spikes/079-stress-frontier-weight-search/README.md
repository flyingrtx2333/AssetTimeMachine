# Spike 079 - Stress Frontier Weight Search

Goal: after spike 078 improved the high-Sharpe frontier, run a coarse 5% weight
search around the stress-tilted logic to see whether 12%+ annualized return can
also clear 1.6 Sharpe.

Method:
- Use only 5% weight increments.
- Search `OSTIX`, `CORE`, `IAU`, `AAPL`, `LLY`, `ORLY`, optional `COST`.
- Reuse the strongest stress-tilt rules from spike 078.
- 1% fee and 0.05% slippage on external assets.
- No leverage, no shorting, no BTC.

Best full-history Sharpe:

| Basket | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| 50% `OSTIX` / 30% `CORE` / 5% `IAU` / 5% `AAPL` / 5% `LLY` / 5% `ORLY`, stress tilt | 9.97% | 13.05% | 5.74% | 1.6318 |
| 50% `OSTIX` / 25% `CORE` / 5% `IAU` / 10% `AAPL` / 5% `LLY` / 5% `ORLY`, stress tilt | 11.03% | 16.41% | 6.39% | 1.6181 |
| 45% `OSTIX` / 30% `CORE` / 5% `IAU` / 10% `AAPL` / 5% `LLY` / 5% `ORLY`, stress tilt | 11.43% | 15.44% | 6.65% | 1.6096 |

Closest high-return candidate:

| Basket | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| 40% `OSTIX` / 30% `CORE` / 5% `IAU` / 10% `AAPL` / 10% `LLY` / 5% `ORLY`, stress tilt | 11.99% | 15.54% | 7.11% | 1.5782 |

Conclusion:

No 12%+ annualized / 1.6+ Sharpe candidate was found.  The best practical
frontier remains the spike 078 balanced candidate:

`45% OSTIX / 30% CORE / 5% IAU / 10% AAPL / 5% LLY / 5% ORLY` with stress tilt,
about 11.43% annualized and 1.61 Sharpe.
