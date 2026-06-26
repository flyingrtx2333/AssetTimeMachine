# Spike 051: Event-Driven Asset Handbrake

## Goal

Find a no-leverage, no-BTC improvement over the 047 dynamic sleeve by adding a
new execution-layer logic: between normal rebalance dates, cut only the held
asset that breaks down, instead of cutting the whole portfolio.

## Logic Tested

- Keep the verified 047 dynamic sleeve target generator unchanged.
- Check held assets every trading day.
- If a held asset shows confirmed short-term breakdown, contribution loss, or
  late-cycle decay, reduce only that asset to cash.
- Optional equity-group cut when broad equity breadth is also broken.
- Re-enter either at the next scheduled rebalance, after a short cooldown, or
  after price repair confirmation.

All candidates include fees, slippage, cash yield, no leverage, no shorting, and
no BTC.

## Results

| Candidate | Annualized | Max DD | Vol | Sharpe | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| `baseline_047_dynamic_sleeve` | 13.61% | 9.34% | 9.09% | 1.4054 | Current verified baseline |
| `handbrake_late_cycle_decay_cut40_repair10_group_price` | 10.76% | 7.79% | 7.91% | 1.2908 | Best handbrake candidate |
| `handbrake_confirmed_trend_cut40_repair10_single_contrib` | 10.49% | 8.21% | 7.74% | 1.2873 | Best contribution-loss variant |

## Conclusion

This logic failed. It reduced some drawdowns, but it removed return faster than
it removed volatility and multiplied trades from 348 to roughly 1,000+ in the
best variants. The result is consistent with earlier daily-guard tests: the
dynamic sleeve already avoids much of the slow regime risk, while intracycle
asset cuts mostly chase noise and miss rebounds.

Do not promote this logic.

## Files

- `event_driven_asset_handbrake.py`: durable target-weight replay search.
- `results.json`: generated search output.
