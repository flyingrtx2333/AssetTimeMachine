# 014: E02 campaign validity, OHLC stops, and high-return barbell tail control

## Question

Spike 013 diagnosed that E02's remaining full-cycle blocker is not a missing buy condition. The 2004 drawdown window showed E02 still holding high gross exposure after the original breakout campaign had gone stale:

```text
2004-01-12 -> 2005-04-15
E02 held roughly 49% Nasdaq + 39% gold near the trough.
Nasdaq and S&P had both lost medium-trend confirmation.
```

This spike asks:

```text
Can we improve the current gold / Nasdaq / cash frontier by modelling the lifetime of a holding campaign, or by using real daily OHLC stop execution instead of close-only exits?
```

Visible holdings remain:

```text
nasdaq
gold_cny
cash
```

No BTC. No new visible assets. S&P/GC OHLC are used only as signals/execution aids.

## Files

```text
e02_campaign_validity.py   # campaign-level validity model around E02
e02_ohlc_stop.py           # E02 with real daily OHLC intraday fixed/trailing stops
barbell_ohlc_tail.py       # 25N/35G drift-harvest high-return base + OHLC tail controls
README.md
```

Verification commands run:

```bash
python3 -m py_compile spikes/014-e02-campaign-validity/e02_campaign_validity.py
python3 spikes/014-e02-campaign-validity/e02_campaign_validity.py

python3 -m py_compile spikes/014-e02-campaign-validity/e02_ohlc_stop.py
python3 spikes/014-e02-campaign-validity/e02_ohlc_stop.py

python3 -m py_compile spikes/014-e02-campaign-validity/barbell_ohlc_tail.py
python3 spikes/014-e02-campaign-validity/barbell_ohlc_tail.py
```

Output JSON:

```text
/tmp/atm_e02_campaign_validity_014.json
/tmp/atm_e02_ohlc_stop_014.json
/tmp/atm_barbell_ohlc_tail_014.json
```

## Data / execution notes

Main close-price backtest口径 is inherited from existing AssetTimeMachine spikes:

- real historical data via existing `CORE.fetch()` / `CORE.align()`;
- CNY convention and cash yield;
- real units/cash accounting;
- T-1 signal / T execution;
- fees/slippage inherited from project scripts;
- full aligned history `2002-01-04` to `2026-06-21`, `n=6316`;
- report full period, post-2020, last 10Y, post-2022, and top drawdowns.

OHLC availability verified during this spike:

```text
Nasdaq .IXIC daily OHLC from Sina: 2004-01-02 -> 2026-06-18, 5651 rows
COMEX GC daily OHLC from Sina:    2016-06-21 -> 2026-06-19, 2589 rows
```

Because GC OHLC only starts in 2016, gold OHLC tests do not solve 2004. Nasdaq OHLC covers the 2004 window.

---

## Round A — E02 campaign-level validity

Script:

```text
e02_campaign_validity.py
```

Mechanism tested:

1. Track each sleeve's campaign start, entry price, high watermark, confirmation, and invalidation cooldown.
2. Stop unconfirmed campaigns that go underwater after a quarter.
3. Expire confirmed campaigns after large giveback + lost regime.
4. Cap high-gross stale campaigns.
5. Combine campaign expiry with rare liquidity shock caps.

Reference:

```text
REF_E02_loose
Full:      7.95% / 11.38%
Post-2020: 12.66% / 11.38%
Last 10Y:  10.43% / 11.38%
Post-2022: 13.06% / 9.24%
```

Best useful campaign result:

```text
C08_unconfirmed_time_stop_plus_shock
Full:      7.11% / 10.47%
Post-2020: 12.42% / 9.38%
Last 10Y:  10.14% / 9.38%
Post-2022: 12.68% / 9.24%
```

What worked:

```text
Campaign validity directly attacked the diagnosed 2004 stale-holding failure.
C02/C08 reduced full-cycle DD from 11.38% to 10.47%.
C08 also reduced post-2020 DD to 9.38%.
```

What failed:

```text
Annualized return fell from 7.95% to ~7.1%.
The return cost is too high for the user's preference.
```

Important negative result:

```text
Confirmed-giveback expiry was too aggressive. It created new 2011/2012 drawdown windows and reduced return sharply.
```

Takeaway:

```text
Campaign validity is directionally right, but close-only state rules still react too late and then over-cashify. It is not a shippable improvement.
```

---

## Round B — E02 with real daily OHLC intraday stops

Script:

```text
e02_ohlc_stop.py
```

Mechanism tested:

- Keep E02 entry logic unchanged.
- Add real daily OHLC fixed/trailing stop execution.
- Nasdaq OHLC uses Sina .IXIC, 2004+.
- Gold OHLC uses GC ratio applied to existing CNY gold close, 2016+.

Best result in this round:

```text
OHL4_nasdaq_gold_intraday_loose
Full:      7.18% / 11.85%
Post-2020: 9.95% / 11.85%
Last 10Y:  9.55% / 11.85%
Post-2022: 10.69% / 10.40%
```

Other reference variants:

```text
OHL1_nasdaq_intraday_loose
Full:      7.51% / 12.15%

OHL2_nasdaq_intraday_medium
Full:      7.22% / 12.16%

OHL3_nasdaq_intraday_tight
Full:      6.76% / 12.90%
```

What failed:

```text
OHLC stops did not improve E02. They often stopped Nasdaq earlier, but left new gold / mixed windows as the main drawdown. Tight stops lowered post-2020 DD but pushed full-cycle return and other windows worse.
```

Takeaway:

```text
The blocker is not simply "close-only stop too slow". E02's issue is portfolio/campaign state, not just intraday execution precision.
```

---

## Round C — 25N/35G high-return barbell + OHLC tail controls

Script:

```text
barbell_ohlc_tail.py
```

Rationale:

E02 may be too low-exposure to reach a breakthrough. So this round started from the higher-return 25N/35G drift/harvest/rebuild engine, then attempted to cut tail risk.

Reference:

```text
REF_25N35G_blowoff_rebuild
Full:      9.98% / 19.95%
Post-2020: 16.79% / 19.18%
Last 10Y:  15.37% / 19.18%
Post-2022: 16.91% / 16.95%
```

Close-signal improvement:

```text
B01_goldtrap_cap_close
Full:      10.04% / 19.33%
Post-2020: 16.81% / 19.20%
Last 10Y:  15.39% / 19.20%
Post-2022: 16.94% / 16.98%
```

This is a tiny improvement over the 007 reference, but still an aggressive ~19% DD strategy.

Best tail-control results:

```text
B03_nasdaq_ohlc_loose
Full:      7.70% / 13.59%
Post-2020: 10.67% / 13.46%
Last 10Y:  9.75% / 13.46%
Post-2022: 12.71% / 13.46%

B11_nasdaq_ohlc_half_harvest
Full:      7.80% / 15.05%
Post-2020: 10.49% / 12.87%
Last 10Y:  10.28% / 12.87%
Post-2022: 12.45% / 12.87%

B12_shock_nasdaq_excess_to_base
Full:      7.95% / 17.33%
Post-2020: 10.75% / 12.07%
Last 10Y:  10.49% / 12.07%
Post-2022: 12.63% / 12.07%
```

What worked:

```text
Full-exit OHLC stops can reduce ~20% DD to ~13-15%.
Excess-only stops preserve more campaign participation.
Rare shock caps reduce 2020 drawdown.
```

What failed:

```text
Every meaningful DD reduction reduced annualized return too much.
Excess-only stops preserved return better than full exits, but did not solve 2008 and still kept DD too high.
```

Takeaway:

```text
High-return barbell + tail stop is not enough. The current payoff source is still long-only Nasdaq/gold beta; without leverage, options, or a genuinely diversifying payoff source, tail cuts mostly convert the strategy back toward cash.
```

---

## Current frontier after 014

### Low-drawdown branch

Still best honest reference:

```text
REF_E02_loose
Full:      ~7.95% / 11.38%
```

Best partial improvement from 014:

```text
C08_unconfirmed_time_stop_plus_shock
Full:      7.11% / 10.47%
Post-2020: 12.42% / 9.38%
Last 10Y:  10.14% / 9.38%
```

Verdict:

```text
Not promotable. Better DD, too much return sacrifice.
```

### Aggressive branch

Best aggressive close-signal branch:

```text
B01_goldtrap_cap_close
Full:      10.04% / 19.33%
```

Similar to prior 013 `O05_gold_trap_cap`, but still high-DD.

Verdict:

```text
Can remain as an aggressive research branch. Do not position it as low drawdown.
```

---

## Verdict: PARTIAL / NOT SHIPPABLE

014 did not find a new shippable strategy.

It did validate three important facts:

1. **Campaign validity is the right diagnosis for E02's 2004 stale-holding problem**, but simple close-only expiry rules reduce return too much.
2. **Real daily OHLC stops are not a silver bullet**. For E02 they do not improve the frontier; for 25N/35G they reduce drawdown only by sacrificing the return engine.
3. **The current no-BTC, no-new-held-asset universe is near a real frontier** under this backtest口径. With only long Nasdaq / long gold / cash, drawdown control mostly means cashification.

No candidate should be directly added to the app as a new flagship strategy.

## Recommendation

Do not keep polishing MA thresholds, stop percentages, or pressure-score gates.

The only next research directions worth a real spike are structural, not parameter-level:

```text
1. A genuinely different return source that can remain hidden as signal/hedge while visible holdings stay Nasdaq/gold/cash.
2. Real tradable proxy data with longer OHLC history for gold and Nasdaq instruments, then re-test with product-realistic execution.
3. A stateful campaign engine integrated into the app only as a risk explanation/alert layer, not as a new backtested flagship yet.
```

For now:

```text
Keep E02 as the honest low-DD reference.
Keep 25N/35G + gold trap cap as aggressive research only.
Do not claim 12/8 solved.
```
