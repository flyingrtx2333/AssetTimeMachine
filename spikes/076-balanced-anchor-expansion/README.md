# Spike 076 - Balanced Anchor Expansion

Goal: improve the spike 074 annual quality/core basket by replacing or
complementing the `OSTIX` stable anchor with balanced or income funds.

Method:
- Keep annual rebalancing and the same quality/core/gold structure.
- Test single stable anchors and dual-anchor combinations.
- Candidate anchors include `OSTIX`, `PIMIX`, `PONAX`, `PRWCX`, `VWINX`,
  `VWELX`, `VBIAX`, `BERIX`, bond funds, and allocation funds.
- 1% fee and 0.05% slippage on external assets.
- No leverage, no shorting, no BTC.

Result:

The best anchors by full-history Sharpe were still:

`OSTIX`, `PIMIX`, `PONAX`.

Best overall:

| Basket | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| 50% `OSTIX` / 30% `CORE` / 5% `IAU` / 5% `AAPL` / 5% `LLY` / 5% `ORLY` | 10.22% | 14.60% | 5.98% | 1.6070 |
| 50% `OSTIX` / 30% `CORE` / 5% `IAU` / 4% `AAPL` / 4% `COST` / 4% `LLY` / 4% `ORLY` | 9.93% | 14.21% | 5.81% | 1.6066 |
| 50% `PIMIX` / 30% `CORE` / 5% `IAU` / 4% `AAPL` / 4% `COST` / 4% `LLY` / 4% `ORLY` | 10.19% | 15.35% | 5.98% | 1.6002 |

Best 12%+ annualized result:

| Basket | Annualized | Max DD | Vol | Sharpe |
| --- | ---: | ---: | ---: | ---: |
| 35% `VWINX` / 35% `CORE` / 10% `IAU` / 7% `AAPL` / 7% `LLY` / 7% `ORLY` | 12.20% | 19.33% | 8.37% | 1.3735 |

Conclusion:

Reject.  Balanced funds raise annualized return but introduce too much equity
beta and drawdown.  They do not improve the 12%+ annualized / high-Sharpe
frontier.  `OSTIX` remains the strongest stable anchor found so far.
