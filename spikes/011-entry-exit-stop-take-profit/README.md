# 011: Entry / exit / stop-loss / take-profit logic, fixed gold + Nasdaq holdings

## User correction

The user rejected the previous direction of repeatedly adding assets:

```text
不，还是要改买入卖出逻辑，止盈止损策略，而非不停加资产
```

This spike therefore fixes visible holdings to:

```text
nasdaq
gold_cny
cash
```

No new holding assets are added.

## Target

Original strict target remains:

```text
Annualized return >= 12%
Max drawdown <= 8%
```

## Backtest口径

Same project口径 as previous spikes:

- real AssetTimeMachine API history;
- USD assets converted to CNY using the existing app convention;
- T-1 signal / T execution;
- real holdings/units/cash;
- cash earns historical demand-deposit rate from existing code;
- fee `0.10%` and slippage `0.05%`;
- full aligned history: `2002-01-04` to `2026-06-21`;
- stress windows: 2008, 2011 gold turn, 2015, 2018, 2020, 2022, 2026 AI volatility.

## Mechanisms tested

The spike models event/campaign state explicitly:

```text
entry price
campaign high
fixed stop
trailing stop
take-profit after rollover
cooldown after stop
portfolio drawdown brake
re-entry after recovery
```

Candidate families:

1. `E01_trend_pullback`
   - buy after healthy trend pullback + short recovery;
   - sell by fixed stop / trailing stop;
   - take profit only after rollover.

2. `E02_breakout_chandelier`
   - buy 126d/63d breakouts;
   - chandelier-style stop;
   - partial take-profit after large gain and rollover.

3. `E03_core_satellite_stops`
   - core barbell + momentum satellite;
   - stop/take cuts satellite first.

4. `E04_M34_stop_overlay`
   - previous M34 health-recovery logic;
   - add explicit stop/take/cooldown overlay.

5. `E05_deep_recovery`
   - buy only after deep drawdown repair;
   - no falling-knife entries.

6. `E06_profit_ladder`
   - base/rebuild logic;
   - add exposure in trends;
   - harvest only excess after profit rollover.

7. `E07/E08/E09/E10_M13_overlays`
   - keep previous high-return M13 buy/rebuild logic;
   - add stop-loss, take-profit, portfolio stop, or stop-only variants.

8. `E11/E12_adaptive_breakout`
   - more active breakout/pullback entry;
   - dynamic stops;
   - winner-preserving profit harvest;
   - one aggressive and one defensive variant.

## Key result table

Best references and candidates:

| Strategy | Full ann / DD | Post-2020 ann / DD | Last 10Y ann / DD | Notes |
|---|---:|---:|---:|---|
| `M13_ref_harvest_rebuild` | `9.95% / 20.14%` | `16.79% / 19.18%` | `15.37% / 19.18%` | high return, DD too high |
| `M34_ref_health_recovery_volcap` | `8.01% / 15.12%` | `11.95% / 15.12%` | `11.40% / 15.12%` | previous lower-DD reference |
| `E02_daily_breakout_chandelier_loose` | `8.00% / 11.45%` | `12.71% / 11.27%` | `10.50% / 11.27%` | best new entry/exit improvement |
| `E02_daily_breakout_chandelier_medium` | `6.82% / 13.41%` | `6.72% / 13.41%` | `7.77% / 13.41%` | stop/take too active |
| `E02_daily_breakout_chandelier_strict` | `5.62% / 12.58%` | `6.22% / 10.59%` | `7.40% / 10.59%` | stricter stops cut return |
| `E10_M13_stop_only_medium` | `2.33% / 7.68%` | `3.09% / 5.53%` | `2.85% / 5.53%` | <8 DD but cash-like return |
| `E09_M13_takeprofit_only` | `2.49% / 8.02%` | `3.28% / 5.53%` | `2.97% / 5.53%` | near 8 DD but return destroyed |
| `E11_adaptive_breakout_budget` | `3.77% / 13.17%` | `6.97% / 12.64%` | `6.14% / 12.64%` | too many brakes/stops |
| `E12_adaptive_breakout_defensive` | `2.91% / 10.64%` | `4.72% / 9.51%` | `4.41% / 9.51%` | lower DD, poor return |

No candidate reached 12/8.

```text
PASS_COUNT = 0
```

## Best useful improvement

`E02_daily_breakout_chandelier_loose` is the best useful mechanism found in this spike:

```text
Full:      8.00% / 11.45%
Post-2020: 12.71% / 11.27%
Last 10Y:  10.50% / 11.27%
```

Compared with M34:

```text
M34: 8.01% / 15.12%
E02: 8.00% / 11.45%
```

So entry/exit logic can reduce drawdown meaningfully while preserving almost the same full-cycle return.

This is a real improvement, but still not app-worthy under the strict original 12/8 target.

## Why hard stop-loss / take-profit failed

The spike shows a clear pattern:

### 1. Hard daily stops protect drawdown but kill compounding

M13 with stop-only:

```text
E10_daily_M13_stop_only_medium: 2.33% / 7.68%
```

This gets below 8% max DD, but it becomes cash-like. The strategy stops out of long-run winners and then fails to re-enter with enough exposure.

### 2. Take-profit-only also kills return

```text
E09_daily_M13_takeprofit_only: 2.49% / 8.02%
```

Taking profits without a better re-entry engine turns the strategy into “sell winners, sit in cash.” It controls drawdown but sacrifices the only return source.

### 3. M34 + event stops is worse than plain M34

Plain M34:

```text
8.01% / 15.12%
```

M34 with daily stop overlays dropped to roughly:

```text
~5% / 13%-20%
```

The extra stop/take logic creates too much churn and prevents recovery participation.

### 4. The best structure is not “more stops”

The best structure was:

```text
buy fewer but higher-quality breakouts
let winners run
use trailing stop only after gains exist
take profit only on rollover
avoid full exit unless trend truly breaks
```

That is exactly why E02 beats most other stop/take candidates.

## Failure windows for best candidate

`E02_daily_breakout_chandelier_loose` top drawdowns:

```text
2004-01-12 -> 2005-04-15: 11.45%
2020-02-20 -> 2020-03-18: 11.27%
2026-01-28 -> 2026-03-30: 9.13%
2011-09-16 -> 2012-06-01: 8.72%
```

Stress windows:

```text
2008金融危机:  1.68% / 6.43%
2011黄金拐点:  4.99% / 8.72%
2015波动:      2.62% / 2.54%
2018美股回撤: -0.16% / 1.92%
2020疫情:    -12.63% / 11.27%
2022加息:     -0.50% / 4.71%
2026AI波动:   15.85% / 9.13%
```

The remaining blockers are mostly:

1. early-history 2004-2005 mixed gold/Nasdaq drawdown;
2. 2020 fast air-pocket where even gold/partial cash was not enough;
3. 2026 Nasdaq drawdown while still in trend.

## Verdict: PARTIAL

Entry/exit/stop-loss/take-profit logic is the right direction compared with merely adding assets.

However:

```text
Current best improvement: 8.00% / 11.45%
Strict target:            12.00% / 8.00%
```

The useful lesson is not “add more stop-loss.” The useful rule is:

```text
Use breakout-quality buy conditions + trailing stop after profit + rollover take-profit.
Avoid hard stop/take overlays that sell winners too early.
```

## Files

Script:

```text
spikes/011-entry-exit-stop-take-profit/entry_exit_stop_take_profit.py
```

Outputs:

```text
/tmp/atm_entry_exit_stop_take_profit_011.json
/tmp/atm_entry_exit_stop_take_profit_011_v1.log
/tmp/atm_entry_exit_stop_take_profit_011_v2.log
/tmp/atm_entry_exit_stop_take_profit_011_v3.log
/tmp/atm_entry_exit_stop_take_profit_011_v4.log
```
