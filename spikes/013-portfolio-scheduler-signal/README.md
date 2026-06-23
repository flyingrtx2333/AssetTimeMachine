# 013: Portfolio scheduler signals for gold / Nasdaq / cash

## Boundary

Visible holdings remain fixed to:

```text
nasdaq
gold_cny
cash
```

External assets are signal-only:

```text
sp500
dowjones where available from existing aligned data
```

No BTC. No new visible held assets. This spike deliberately avoids a broad parameter grid; each candidate is a fixed, interpretable mechanism.

## Backtest口径

Same research口径 as prior AssetTimeMachine spikes:

- AssetTimeMachine real historical data via existing `CORE.fetch()` / `CORE.align()`;
- CNY price convention and demand-deposit cash yield;
- real units/cash accounting;
- T-1 signal / T execution;
- fee `0.10%` and slippage `0.05%` inherited from existing scripts;
- full aligned history `2002-01-04` to `2026-06-21`, `n=6316`;
- report full period, post-2020, last 10Y, post-2022, and stress/top drawdown windows.

Verification commands run:

```bash
python3 -m py_compile spikes/013-portfolio-scheduler-signal/portfolio_scheduler_signal.py
python3 spikes/013-portfolio-scheduler-signal/portfolio_scheduler_signal.py

python3 -m py_compile spikes/013-portfolio-scheduler-signal/portfolio_scheduler_signal_v2.py
python3 spikes/013-portfolio-scheduler-signal/portfolio_scheduler_signal_v2.py

python3 -m py_compile spikes/013-portfolio-scheduler-signal/portfolio_scheduler_signal_v3.py
python3 spikes/013-portfolio-scheduler-signal/portfolio_scheduler_signal_v3.py
```

Outputs:

```text
/tmp/atm_portfolio_scheduler_signal_013.json
/tmp/atm_portfolio_scheduler_signal_013_v2.json
/tmp/atm_portfolio_scheduler_signal_013_v3.json
```

## Round 1 — portfolio scheduler with external pressure signal

Script:

```text
portfolio_scheduler_signal.py
```

Mechanisms tested:

1. base portfolio scheduler using Nasdaq/gold/cash target weights;
2. SP500 pressure score controlling Nasdaq risk budget;
3. pressure cut + staged re-entry;
4. portfolio high-water trailing budget;
5. barbell relative strength with external US confirmation;
6. M13 harvest/rebuild plus pressure brake;
7. E02 plus scheduler override.

Key result:

| Candidate | Full ann/DD | Post-2020 ann/DD | Last 10Y ann/DD | Verdict |
|---|---:|---:|---:|---|
| `REF_E02_loose` | `7.95 / 11.38` | `12.66 / 11.38` | `10.43 / 11.38` | still best low-DD reference |
| `P05_m13_harvest_with_pressure_brake` | `6.25 / 15.23` | `8.31 / 9.12` | `7.86 / 9.12` | return too low |
| `P01_pressure_scaled_scheduler` | `3.71 / 18.28` | `9.46 / 8.67` | `8.25 / 10.32` | full-cycle failure |
| `P02_pressure_ladder_rebuild` | `2.47 / 30.82` | `7.51 / 13.38` | `7.63 / 13.38` | invalidated |

Takeaway:

```text
A continuously rebalanced target-weight scheduler is too cash-heavy / over-traded in this data. It does not beat E02 and should not be promoted.
```

## Round 2 — start from the proven 25N/35G drift engine, add rare brakes

Script:

```text
portfolio_scheduler_signal_v2.py
```

Reference from spike 007:

```text
REF_D_25N_35G_blowoff_rebuild
Full:      9.98% / 19.95%
Post-2020: 16.79% / 19.18%
Last 10Y:  15.37% / 19.18%
Post-2022: 16.91% / 16.95%
```

Best result from this round:

```text
O05_gold_trap_cap
Full:      9.82% / 18.88%
Post-2020: 16.17% / 18.88%
Last 10Y:  15.01% / 18.88%
Post-2022: 16.64% / 16.16%
Latest:    55.2% Nasdaq / 33.3% gold / 11.5% cash
Trades:    27
```

Comparison:

| Candidate | Full ann/DD | Change vs 007 reference | Verdict |
|---|---:|---:|---|
| `REF_D_25N_35G_blowoff_rebuild` | `9.98 / 19.95` | baseline | aggressive reference |
| `O05_gold_trap_cap` | `9.82 / 18.88` | `-0.16 ann / -1.07 DD` | useful aggressive improvement, not low-DD |
| `O03_recession_nasdaq_cap` | `8.58 / 19.80` | return hit, tiny DD improvement | not worth it |
| `O02_shock_cash_then_fast_rebuild` | `6.95 / 14.67` | DD lower, return too low | reject |

Takeaway:

```text
The best aggressive improvement is to keep the 25N/35G drift/harvest engine and cap gold after blowoff/liquidity-trap signals. It improves drawdown slightly without killing return, but it is still an ~19% DD strategy, not suitable as the low-drawdown main strategy.
```

## Round 3 — E02 low-drawdown frontier overlays

Script:

```text
portfolio_scheduler_signal_v3.py
```

Reference:

```text
REF_E02_loose
Full:      7.95% / 11.38%
Post-2020: 12.66% / 11.38%
Last 10Y:  10.43% / 11.38%
Post-2022: 13.06% / 9.24%
```

### Useful but not promotable: rare shock cap

```text
L03_e02_rare_shock_cap
Full:      7.86% / 11.32%
Post-2020: 12.29% / 9.78%
Last 10Y:  10.15% / 9.78%
Post-2022: 12.68% / 9.24%
Latest:    58.8% Nasdaq / 41.2% cash
Trades:    554
```

What improved:

```text
2020 drawdown fell from 11.38% to 9.78%.
```

What did not improve:

```text
Full-period max DD remains ~11.32%, because the worst remaining window becomes 2004-01 to 2005-04.
```

### Diagnostic: 2004 failure mode

The E02 reference top drawdowns showed:

```text
2020-02-20 -> 2020-03-18: 11.38%, held gold only (~32%)
2004-01-12 -> 2005-04-15: 11.32%, held ~49% Nasdaq + ~39% gold
```

Direct signal inspection at 2005-04-15 showed:

```text
nasdaq m63 -8.61%, m126 -0.76%, below MA120 and MA200
sp500  m63 -3.54%, below MA120 and MA200
gold   m21 -3.15%, below MA120 but above MA200
E02 still held ~88% gross exposure
```

So the 2004 issue is not a missing buy rule. It is:

```text
post-entry trend expiry is too slow when E02 has high gross exposure.
```

### Stale-trend expiry tests

| Candidate | Full ann/DD | Post-2020 ann/DD | Verdict |
|---|---:|---:|---|
| `L10_e02_stale_cap_plus_rare_shock` | `5.84 / 10.15` | `8.80 / 10.15` | DD better but return too low |
| `L12_e02_high_gross_stale_plus_shock` | `6.90 / 10.29` | `11.02 / 9.74` | better DD but not enough return |
| `L13_e02_high_gross_stale_soft_cap` | `7.21 / 11.38` | `11.80 / 11.38` | return better, DD not solved |

Takeaway:

```text
High-gross stale caps correctly reduce the 2004 window, but the return cost is still too high unless the cap is soft; when soft, full max DD is not solved. This is an honest frontier, not a shippable breakthrough.
```

## Current best candidates by use case

### Aggressive gold/Nasdaq barbell candidate

```text
O05_gold_trap_cap
Full:      9.82% / 18.88%
Post-2020: 16.17% / 18.88%
Last 10Y:  15.01% / 18.88%
Post-2022: 16.64% / 16.16%
```

Recommendation:

```text
Keep researching as an aggressive strategy variant. Do not present it as low-drawdown.
```

### Low-drawdown frontier candidate

```text
L03_e02_rare_shock_cap
Full:      7.86% / 11.32%
Post-2020: 12.29% / 9.78%
Last 10Y:  10.15% / 9.78%
Post-2022: 12.68% / 9.24%
```

Recommendation:

```text
Keep as a recent-period improvement to E02, but do not promote as the main full-cycle solution because the 2004 full-cycle DD remains above 10%.
```

### Lowest tested DD with still-visible return

```text
L12_e02_high_gross_stale_plus_shock
Full:      6.90% / 10.29%
Post-2020: 11.02% / 9.74%
Last 10Y:  9.35% / 9.74%
Post-2022: 10.82% / 9.24%
```

Recommendation:

```text
Reject for promotion: it improves DD but violates the user's return preference. It is too close to cash-defensive behavior.
```

## Verdict: PARTIAL

No candidate solved the aspirational target:

```text
12% annualized / 8% max drawdown
```

No candidate should be directly promoted as a new low-drawdown flagship strategy.

This spike did produce two useful lessons:

1. **Aggressive branch:** `O05_gold_trap_cap` improves the existing 25N/35G drift/harvest candidate slightly and remains product-explainable.
2. **Low-DD branch:** E02's remaining full-cycle blocker is the 2004 stale high-gross exposure window. Rare shock caps solve the 2020 issue, but 2004 requires a better post-entry expiry/rebuild mechanism that does not cashify the whole strategy.

## Next research direction

Do not keep broadening assets or sweeping thresholds. The next mechanism should directly target the diagnosed failure:

```text
A campaign-level holding-validity model:
- each E02 buy campaign has an entry date, entry reason, and expected regime;
- a high-gross campaign expires if the market regime that justified the breakout no longer exists;
- rebuild must be tied to a fresh campaign, not immediate daily rebalancing;
- expiry should be stateful, not a raw daily MA cap that repeatedly suppresses returns.
```

In app terms, this means E02 needs a **campaign state model**, not another one-line buy/sell condition.
