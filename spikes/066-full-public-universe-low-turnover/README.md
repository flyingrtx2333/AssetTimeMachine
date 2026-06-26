# Spike 066 - Full Public Universe Low-Turnover Search

## Goal

Test whether expanding from the App's current core assets to the backend's full
non-crypto public history can create a better 1% fee strategy.

## Universe

Included:

- `gold_cny`
- `gold_usd` as normalized signal/tradable candidate in the broader endpoint
- `nasdaq`
- `sp500`
- `dowjones`
- `nikkei`
- `hsi`
- `shanghai_composite`
- `shenzhen_component`
- `csi300`
- `chinext`
- `oil_wti_cny`
- `oil_brent_cny`
- synthetic `usd_cash`

Excluded:

- BTC/ETH/BNB/SOL/XRP/DOGE.
- Leverage and shorts.

## Logic Tested

Low-turnover tactical allocation:

- monthly, quarterly, and half-year rebalance;
- top 1-3 assets by trend-adjusted return per volatility;
- defensive gold/cash bias variants;
- separate commodity handling so oil is not ranked as a normal equity sleeve;
- max single-asset and gross-exposure caps;
- 5% no-trade band.

All candidates used:

- 1% fee;
- 0.05% slippage;
- no leverage;
- no shorting.

## Best Results

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| `commodity_separate_r63_top2_asset60_gross70_score50` | 6.90% | 31.32% | 12.50% | 0.5785 | 238 |
| `commodity_separate_r63_top2_asset80_gross70_score50` | 7.07% | 32.05% | 12.85% | 0.5779 | 239 |
| `commodity_separate_r63_top2_asset45_gross70_score50` | 6.56% | 30.57% | 11.93% | 0.5740 | 237 |
| `commodity_separate_r63_top2_asset80_gross85_score50` | 8.22% | 37.48% | 15.36% | 0.5740 | 239 |
| `commodity_separate_r63_top2_asset80_gross100_score50` | 9.13% | 43.44% | 17.52% | 0.5699 | 237 |

The best candidates were still dominated by 2008 or 2015 drawdowns. Oil added
return in some windows but raised volatility and tail risk more than enough to
erase the benefit.

## Conclusion

Expanding to the full current non-crypto public universe does not solve the
objective. The best full-history Sharpe in this search is only about 0.58 under
1% fee.

This supports the current working diagnosis: the missing 1.6 Sharpe source is
not hidden in the existing public endpoint. A real improvement likely requires a
new lower-correlation asset source with durable history, or a materially better
state machine for the existing 063 return engine.

## Files

- `full_public_universe_search.py`: durable tactical allocation search.
- `results.json`: generated full-history and slice metrics.
