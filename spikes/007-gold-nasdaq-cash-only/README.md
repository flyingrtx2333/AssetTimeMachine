# 007: Gold + Nasdaq + Cash only strategy spike

## Boundary

Hard visible-holding boundary:

- Holdings may only be:
  - `nasdaq`
  - `gold_cny`
  - cash
- No BTC.
- No cash-plus funds, short-bond funds, CTA, managed futures, commodities, or multi-asset fund sleeves.
- Other series may be used only as signals, not as holdings.
- Backtest uses real unit/cash accounting, demand-deposit cash yield, fees, slippage, full/post-2020/10Y/recent slices, and stress windows.

## Important correction after user feedback

The first round of this spike was too conservative. It started by trying to create low-exposure timing strategies from scratch. That was the wrong baseline.

The correct baseline is the user's simple barbell:

```text
25% Nasdaq + 25% gold + 50% cash, buy and hold
```

True buy-and-hold, starting immediately and without periodic rebalancing, produced:

```text
D_25_25_none
Full:      7.77% annualized / 21.00% max drawdown
Post-2020: 14.31% / 14.32%
Last 10Y:  12.54% / 14.32%
2024+:     23.81% / 14.08%
Latest:    42.2% Nasdaq / 48.8% gold / 9.0% cash
```

So the right question is not “can a timing strategy beat cash-heavy comfort?” but:

```text
Can a gold/Nasdaq/cash policy beat the naive buy-and-hold barbell, or at least reduce its 21% drawdown without killing return?
```

## Mechanisms tested

### First-round mechanisms: too timid

These included:

- dual momentum router;
- gold/Nasdaq state machine;
- gold crisis bridge;
- cash-first trend;
- volatility-budgeted sleeves;
- Nasdaq-primary small-gold sleeve;
- gold-vs-Nasdaq relative strength relay;
- monthly, biweekly, weekly, and daily execution variants.

They were useful diagnostically, but most were too cash-heavy and failed to beat the simple 25/25 buy-and-hold baseline.

### Second-round mechanisms: barbell-first

The second round starts from the barbell and only modifies it when there is a clear economic reason:

1. `D_*_none`
   - True buy-and-hold baseline.
2. `cap40_trim30`
   - If either sleeve drifts above 40%, harvest it back toward 30%.
3. `cap45_trend_trim30`
   - Harvest only when a large sleeve also starts breaking trend.
4. `blowoff_harvest`
   - If a sleeve had a strong 1Y run and then rolls over over 1M, harvest profits.
5. `blowoff_rebuild`
   - Harvest profits after blowoff, but buy back the base sleeve once medium trend recovers.
6. `soft_band_rebalance`
   - Soft drift-band rebalancing instead of full monthly rebalance.
7. `blowoff_rebuild_dd_guard`
   - Adds a drawdown guard. Tested, but generally not better than plain `blowoff_rebuild`.

Execution was corrected to T-1 signal, T execution.

## Best current candidate

### `D_25N_35G_blowoff_rebuild`

Starting allocation:

```text
25% Nasdaq + 35% gold + 40% cash
```

Mechanism:

```text
1. Start with a simple gold/Nasdaq/cash barbell.
2. Let winners drift instead of forcing constant rebalancing.
3. If a sleeve has a strong 1Y run and then short-term momentum rolls over, harvest that sleeve back toward 25%.
4. If harvesting left a sleeve below its base weight, buy it back only after medium trend recovers.
```

Verified T-1 signal / T execution result:

```text
Full:      9.98% annualized / 19.95% max drawdown
Post-2020: 16.79% / 19.18%
Last 10Y:  15.37% / 19.18%
2024+:     27.00% / 14.18%
Latest:    57.1% Nasdaq / 33.3% gold / 9.7% cash
Trades:    13 counted trade events in the script output
```

Comparison against simple 25/25 buy-and-hold:

```text
25/25 buy-and-hold:          7.77% / 21.00%
25N/35G blowoff + rebuild:   9.98% / 19.95%
```

Comparison against the same 25N/35G starting allocation buy-and-hold:

```text
25N/35G buy-and-hold:        8.49% / 24.68%
25N/35G blowoff + rebuild:   9.98% / 19.95%
```

So this mechanism is not just taking more risk; it improves both return and drawdown versus the same starting-weight buy-and-hold baseline.

## Stress behavior for best candidate

`D_25N_35G_blowoff_rebuild` top drawdowns:

```text
2008-03-18 -> 2008-11-19: 19.95%
2020-02-20 -> 2020-03-16: 19.18%
2021-11-19 -> 2022-06-16: 18.67%
2006-05-11 -> 2006-06-13: 13.77%
2025-02-13 -> 2025-04-08: 13.26%
```

This is still not a low-drawdown strategy. It is a higher-return gold/Nasdaq barbell that improves naive buy-and-hold's drawdown, not a <10% drawdown product.

## Candidate trade log sanity check

The 25N/35G blowoff-rebuild candidate is not high-frequency. The inspected action log had roughly a dozen action points from 2002 to 2026. Example actions:

```text
2002-01-04 initial 25% Nasdaq / 35% gold
2006-08-14 harvest gold after it drifted above 50%
2006-09-11 rebuild gold after recovery
2010-01-05 harvest gold after strong run/rollover
2016-02-03 rebuild gold
2022-03-29 rebuild gold during trend recovery
2026-04-06 harvest gold after blowoff
2026-06-06 rebuild gold after recovery
```

This is product-explainable: it is not a black-box tactical model.

## Other useful candidates

### More conservative harvest-only candidate

`D_25N_35G_blowoff_harvest`

```text
Full:      6.98% / 15.37%
Post-2020: 12.01% / 13.51%
Last 10Y:  10.56% / 13.51%
Latest:    50.6% Nasdaq / 20.9% gold / 28.6% cash
```

This has much lower drawdown than 25/25 buy-and-hold, but gives up too much full-cycle return.

### Soft-band candidate

`D_25_25_soft_band_rebalance`

```text
Full:      7.45% / 20.75%
Post-2020: 11.65% / 12.10%
Last 10Y:  10.87% / 12.10%
Latest:    31.9% Nasdaq / 25.6% gold / 42.5% cash
```

This is easier to explain but does not beat the 25/25 buy-and-hold return.

## Current verdict

The strict gold/Nasdaq/cash universe can produce a candidate that beats naive buy-and-hold, but only if the strategy starts from the barbell and uses drift/harvest/rebuild logic rather than over-timing exposure.

Best current candidate:

```text
D_25N_35G_blowoff_rebuild
9.98% annualized / 19.95% max drawdown
```

Product framing:

```text
Gold-Nasdaq Barbell with Profit Harvesting
```

Plain-language explanation:

```text
长期持有黄金和纳指两条主线；不频繁预测市场；让趋势资产自然上涨；当某条主线涨得过热并开始转弱时，先把利润收回现金；等趋势重新恢复，再把底仓买回来。
```

Do not frame it as a low-drawdown strategy. Frame it as:

```text
比朴素金纳长期持有更会收割泡沫、更少回撤的进取型金纳策略。
```

## Files

- First-round script: `spikes/007-gold-nasdaq-cash-only/gold_nasdaq_cash_only.py`
- Barbell-first script: `spikes/007-gold-nasdaq-cash-only/barbell_drift_policies.py`
- Latest JSON result: `/tmp/atm_gold_nasdaq_drift_policies.json`
- Logs:
  - `/tmp/atm_gold_nasdaq_drift_policies_v5_t1.log`
  - `/tmp/atm_gold_nasdaq_drift_policies_v6_guard.log`
