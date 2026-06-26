# Spike 054: Multi-Speed Trend Vote

## Goal

Test a standalone strategy that does not use the 047 dynamic sleeve machinery:
short, medium, and long trend engines vote independently, then the portfolio
holds consensus assets.

## Logic Tested

- Trend windows such as 60/120/240 and 80/160/320 sessions.
- Weekly or biweekly rebalance.
- One or two winners per trend window.
- Require one or two window votes before entry.
- Optional inverse-volatility weighting and capped gross exposure.
- No leverage, no shorting, no BTC.

## Results

Best full-history candidate:

| Candidate | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| `vote_w80_160_320_rb21_top1_mv2_exp90_cap100_tv12_ma_ivol` | 8.04% | 25.13% | 11.60% | 0.7039 |

Some recent windows looked good, for example 2024+ Sharpe above 1.6, but the
full-history drawdowns were far too large.

## Conclusion

This route failed. Simple multi-speed trend voting is much weaker than the
existing 047/053 lines. It does not provide the independent, high-Sharpe return
source needed for the product strategy.

Do not promote this logic.

## Files

- `multispeed_trend_vote.py`: standalone multi-speed trend vote search.
- `results.json`: generated output.
