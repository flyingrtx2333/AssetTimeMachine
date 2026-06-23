# 012: E02 risk gates, re-entry, product-rule compatibility, and M13/M34 tail control

## User direction

Continue searching, but keep the user's correction from 011:

```text
不再靠不断加资产；继续改买入条件、卖出条件、止盈止损、再买入逻辑。
```

Visible holdings remain fixed to:

```text
nasdaq
gold_cny
cash
```

No BTC. No new held assets.

## Target

The original aspirational target is still:

```text
12% annualized return / 8% max drawdown
```

This spike continues to report full 2002+ history as the main口径, plus post-2020, last-10y, and known stress windows.

## Backtest口径

Same as previous spikes:

- AssetTimeMachine real history API;
- CNY pricing convention;
- T-1 signal / T execution;
- real units/cash holdings;
- historical CNY cash yield;
- fee `0.10%` and slippage `0.05%`;
- full aligned history `2002-01-04` to `2026-06-21`;
- stress windows include 2008, 2011 gold turn, 2015, 2018, 2020, 2022, 2026 AI volatility.

## Important correction discovered

A real bug existed in the 011 M13 overlay helper:

```py
st['m13_base_target'] = Z.M13_rebalance_harvest_rebuild(...) or {}
```

But `Z.M13_rebalance_harvest_rebuild(...)` returns `None` to mean:

```text
no rebalance / keep current holding
```

not:

```text
clear to cash
```

So some earlier M13 overlay results were artificially bad, especially the claims that stop-only / take-profit-only variants fell to ~2% annualized with very low DD.

The helper is now fixed so `None` preserves the cached/current target instead of clearing to cash.

After the fix:

| Candidate | Corrected result |
|---|---:|
| `M13_ref_harvest_rebuild` | `9.95% / 20.14%` |
| `E09_daily_M13_takeprofit_only` | `7.08% / 22.27%` |
| `E10_daily_M13_stop_only_loose` | `6.28% / 21.46%` |
| `E07_daily_M13_stop_take_loose` | `5.43% / 14.47%` |

So the corrected lesson is more precise:

```text
Daily stop/take overlays on M13 still do not solve 12/8, but they are not as catastrophically bad as the bugged 2% runs implied.
```

## Scripts and outputs

Scripts:

```text
spikes/012-e02-risk-gates-reentry/e02_risk_gates_reentry.py
spikes/012-e02-risk-gates-reentry/e02_limited_ratchet_variants.py
spikes/012-e02-risk-gates-reentry/product_rule_dual_sleeve.py
spikes/012-e02-risk-gates-reentry/m13_m34_tail_control.py
spikes/012-e02-risk-gates-reentry/hybrid_e02_t04.py
```

Outputs:

```text
/tmp/atm_e02_risk_gates_reentry_012.json
/tmp/atm_e02_limited_ratchet_variants_012.json
/tmp/atm_product_rule_dual_sleeve_012.json
/tmp/atm_m13_m34_tail_control_012.json
/tmp/atm_hybrid_e02_t04_012.json
```

Verification:

```bash
python3 -m py_compile spikes/012-e02-risk-gates-reentry/*.py
```

passed.

## 1. E02 risk gates and re-entry

Reference from 011:

```text
REF_E02_loose_from_011: 8.00% / 11.45%
post2020: 12.71% / 11.27%
last10y: 10.50% / 11.27%
```

Tested mechanisms:

- SP500/Nasdaq liquidity-shock gate;
- slow barbell damage ratchet;
- gold liquidity-trap filter;
- shock cash + fast re-entry;
- combined shock/ratchet/gold-filter;
- regime-scaled E02;
- defensive low-DD E02.

Main results:

| Candidate | Full ann/DD | Post-2020 ann/DD | Last 10Y ann/DD | Notes |
|---|---:|---:|---:|---|
| `REF_E02_loose_from_011` | `8.00 / 11.45` | `12.71 / 11.27` | `10.50 / 11.27` | still best low-DD return balance |
| `R02_slow_damage_ratchet` | `6.10 / 9.88` | `9.03 / 9.88` | `8.15 / 9.88` | DD lower, return too low |
| `R06_regime_scaled_e02` | `4.19 / 8.51` | `6.95 / 8.51` | `6.16 / 8.51` | close to DD target, return poor |
| `R07_defensive_lowdd` | `2.68 / 8.09` | `3.84 / 7.11` | `4.15 / 7.11` | near 8 DD, cash-like return |

Takeaway:

```text
Ratchets and shock gates can reduce drawdown, but the return cost is too high.
```

## 2. Limited ratchet variants

A small mechanism-level test around R02 varied only the interpretable ratchet strength, not a broad grid.

Best under 10% DD:

| Candidate | Full ann/DD | Notes |
|---|---:|---|
| `K_selective_sleeve_ratchet` | `6.20 / 9.25` | best lower-DD version |
| `C_R02_like` | `6.10 / 9.88` | original R02-like |

Best return among variants:

| Candidate | Full ann/DD | Notes |
|---|---:|---|
| `D_late_ratchet` | `7.52 / 11.64` | higher return but no DD improvement vs E02 |
| `A_light_ratchet` | `7.37 / 11.72` | same problem |
| `F_slow_only` | `7.34 / 11.45` | basically E02 with lower return |

Takeaway:

```text
Mild ratchet barely improves DD; strong ratchet pushes return toward ~6%.
```

## 3. Product-compatible rule search

The app's current advanced single-asset rules support:

```text
alwaysBuy / neverSell
consecutive up/down
MA20 / MA60 above/below/cross
BOLL middle/upper/lower
fixed stop-loss / take-profit
cooldown
position cap / trade amount
```

A dual-sleeve product-compatible simulation tested Nasdaq and gold as two independent single-asset rule systems sharing cash.

Best results were poor:

| Candidate | Full ann/DD | Notes |
|---|---:|---|
| `always_with_stops` | `4.85 / 20.13` | high DD, low return |
| `ma_golden_cross` | `3.58 / 11.95` | lower DD but weak return |
| `boll_reversal` | `3.41 / 9.43` | low DD, cash-like return |

Takeaway:

```text
The current App single-asset advanced-rule vocabulary is not expressive enough to reproduce E02/M34-style portfolio logic.
```

If this kind of strategy is productized, the engine needs a portfolio-level strategy preset or extra concepts like portfolio drawdown gate, barbell health, trailing stop from campaign high, and rollover take-profit — not just per-asset fixed stop/take.

## 4. M13/M34 tail-control after fixing M13 overlay semantics

References:

| Candidate | Full ann/DD | Post-2020 ann/DD | Last 10Y ann/DD |
|---|---:|---:|---:|
| `REF_M13` | `9.95 / 20.14` | `16.79 / 19.18` | `15.37 / 19.18` |
| `REF_M34` | `8.01 / 15.12` | `11.95 / 15.12` | `11.40 / 15.12` |

Mechanism candidates:

| Candidate | Full ann/DD | Post-2020 ann/DD | Last 10Y ann/DD | Notes |
|---|---:|---:|---:|---|
| `T01_M13_blowoff_tail_hedge` | `9.46 / 19.33` | `16.31 / 19.33` | `15.11 / 19.33` | preserves return, barely cuts DD |
| `T02_M13_excess_drift_pdd_trim` | `7.29 / 19.37` | `10.96 / 14.53` | `10.39 / 14.53` | too much return sacrifice for weak DD cut |
| `T03_M13_asym_monthly_sleeve_stops` | `7.24 / 14.16` | `11.40 / 12.81` | `10.36 / 12.81` | DD cut meaningful, return below M34/E02 |
| `T04_M34_lift_excess_tail_brake` | `8.54 / 16.02` | `13.25 / 16.02` | `12.55 / 16.02` | best higher-return M34 variant, but DD too high |

Takeaway:

```text
M13 is hard to de-risk without giving up the drift/compounding source.
M34 is a better skeleton for moderate-risk strategy work.
T04 improves M34's return but does not solve DD.
```

## 5. Hybrid E02 + T04

Goal: combine E02's lower DD with T04/M34's healthier return.

Results:

| Candidate | Full ann/DD | Post-2020 ann/DD | Last 10Y ann/DD | Notes |
|---|---:|---:|---:|---|
| `REF_T04_M34_lift` | `8.54 / 16.02` | `13.25 / 16.02` | `12.55 / 16.02` | higher return, DD too high |
| `H03_T04_stronger_tail` | `8.33 / 14.92` | `12.62 / 14.92` | `12.02 / 14.92` | improves T04 DD but still far above E02 |
| `REF_E02_loose` | `8.00 / 11.45` | `12.71 / 11.27` | `10.50 / 11.27` | best under 12% DD |
| `H05_E02_plus_T04_only_when_flat` | `5.71 / 10.03` | `9.38 / 8.91` | `7.89 / 8.91` | lower DD but return too low |
| `H02_E02_core_when_healthy` | `5.41 / 11.50` | `7.65 / 9.86` | `7.32 / 9.86` | worse than E02 |

Takeaway:

```text
Adding healthy-regime core exposure to E02 increases churn and/or tail exposure enough that it does not beat E02.
Adding stronger tail caps to T04 reduces DD only modestly while keeping DD >14%.
```

## Current frontier after 012

No candidate reached 12/8.

```text
PASS_COUNT = 0
```

Current useful frontier:

| Strategy | Full ann/DD | Role |
|---|---:|---|
| `E02_daily_breakout_chandelier_loose` | `8.00 / 11.45` | best low-DD frontier; strongest below 12% DD |
| `T04_M34_lift_excess_tail_brake` | `8.54 / 16.02` | best higher-return M34 variant; not low-DD |
| `H03_T04_stronger_tail` | `8.33 / 14.92` | better T04 DD, still too high |
| `K_selective_sleeve_ratchet` | `6.20 / 9.25` | best lower-DD variant, but return too low |

## Final verdict: PARTIAL / still unsolved

What worked:

- Fixed a real M13 overlay bug.
- Confirmed E02 remains the best low-drawdown frontier.
- Found a higher-return M34 variant (`T04`) that improves M34's return from `8.01%` to `8.54%`.
- Confirmed product-level single-asset rules are insufficient for this strategy class.

What did not work:

- Liquidity shock gates reduce return too much.
- Portfolio ratchets can lower DD but push return to ~6% or below.
- Product-compatible MA/BOLL/fixed stop rules do not approach E02.
- M13 still cannot be pushed toward low DD without major return sacrifice.
- E02 + T04 hybrid does not beat E02 on the low-DD frontier.

Recommendation:

```text
Do not claim 12/8 solved.
Do not keep adding ordinary long-only assets.
Do not productize M13 daily stop/take overlays.
For a shippable strategy today, E02 is the honest low-DD candidate, and T04 is the honest higher-return/aggressive candidate.
```

If continuing research, the next genuinely different idea should not be another small threshold tweak. It likely needs one of:

1. a real intraday/OHLC stop model with actual high/low data, not close-only synthetic stops;
2. a portfolio-level preset engine in the App to support campaign high, trailing stop, rollover take-profit, and barbell health;
3. a different payoff source used only as signal or hedge, while still keeping visible holdings centered on Nasdaq/gold/cash.
