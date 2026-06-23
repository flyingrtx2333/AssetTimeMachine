# 003: No-BTC 2001-present strategy verification

## Correction / scope

The accepted AssetTimeMachine strategy scope is now:

- **No BTC**.
- Main evaluation horizon: **2001-to-present / longest available full-history口径**.
- Shorter-history windows can be diagnostic slices only, not main recommendations.

## Data coverage

Current public history coverage for the no-BTC universe:

| Asset | Start | End | Notes |
|---|---:|---:|---|
| gold_cny | 2001-06-25 | 2026-06-20 | Gold determines practical common start |
| nasdaq | 2001-01-02 | 2026-06-19 | USD asset converted to CNY |
| sp500 | 2001-01-02 | 2026-06-19 | USD asset converted to CNY |
| dowjones | 2001-01-02 | 2026-06-19 | USD asset converted to CNY |
| shanghai_composite | 2001-01-02 | 2026-06-20 | China equity proxy available from 2001 |
| shenzhen_component | 2001-01-02 | 2026-06-20 | China equity proxy available from 2001 |
| hang_seng | 2001-01-02 | 2026-06-18 | Hong Kong equity proxy available from 2001 |
| nikkei225 | 2001-01-04 | 2026-06-20 | Japan equity proxy available from 2001 |
| wti | 2001-01-02 | 2026-06-19 | WTI crude oil, USD converted to CNY |
| csi300 | 2002-01-04 | 2026-06-20 | Dynamic universe only; joins after real data exists |
| TLT/IEF/SHY | 2002-07-30 | 2026-06-18 | Yahoo adjusted close, USD converted to CNY; dynamic defense pool only |
| usd_cash | 2001-06-25 | 2026-06-20 | CNY per USD from `usd_per_cny` |

Practical 2001 full-history aligned start is **2001-06-25** because gold starts then.

## Scripts

```bash
python3 spikes/003-no-btc-2001-strategy/no_btc_2001_verify.py
python3 spikes/003-no-btc-2001-strategy/no_btc_2001_dynamic_verify.py
python3 spikes/003-no-btc-2001-strategy/search_no_btc_2001_dynamic_vaa.py
python3 spikes/003-no-btc-2001-strategy/search_no_btc_2001_expanded_universe.py
python3 spikes/003-no-btc-2001-strategy/test_gold_blowoff_overlay.py
python3 spikes/003-no-btc-2001-strategy/test_pf_brake_overlay.py
python3 spikes/003-no-btc-2001-strategy/search_no_btc_2001_bond_defense.py
python3 spikes/003-no-btc-2001-strategy/probe_bond_high_return.py
```

Outputs:

```text
/tmp/atm_no_btc_2001_verify.json
/tmp/atm_no_btc_2001_dynamic_verify.json
/tmp/atm_no_btc_2001_dynamic_vaa_search.json
/tmp/atm_no_btc_2001_expanded_universe.json
/tmp/atm_no_btc_2001_gold_blowoff_targeted.json
/tmp/atm_no_btc_2001_pf_brake_targeted.json
/tmp/atm_no_btc_2001_bond_defense.json
/tmp/atm_no_btc_2001_bond_high_return_probe.json
/tmp/atm_regime_risk_budget_search.json
```

## Tested logics and findings

### 1. Static 2001 universe

Uses only assets with practical 2001 coverage:

- gold_cny
- nasdaq
- sp500
- dowjones
- shanghai_composite

| Strategy | Annualized | Max drawdown | Verdict |
|---|---:|---:|---|
| VAA-style 2001 universe | 3.94% | 10.98% | Too low / slightly too much drawdown |
| Shanghai capped | 3.91% | 10.98% | Not better |
| US + gold only | 2.78% | 15.08% | Rejected |

### 2. Dynamic 2001 universe

Starts in 2001 and lets CSI300 join only after real data exists.

| Strategy | Annualized | Max drawdown | Worst DD | Verdict |
|---|---:|---:|---|---|
| Dynamic VAA | 5.30% | 16.33% | 2015-06-12 → 2018-05-03 | Rejected; China bubble damage too large |
| Dynamic China cap | 4.74% | 13.82% | 2015-06-12 → 2018-05-03 | Rejected; still too much drawdown |
| Dynamic US/gold core + China satellite | 3.78% | 9.94% | 2015-06-12 → 2018-05-03 | Drawdown acceptable but return too low |
| Dynamic China bubble state | 4.88% | 11.98% | 2015-06-12 → 2018-05-03 | Better than simple cap, still not enough |

### 3. VAA/PAA search ported to 2001 dynamic universe

The 2002 VAA/PAA family was ported to the corrected 2001 dynamic universe.

Result:

- Evaluated: 24,192 candidates.
- No `under10_by_return` result.
- No `under11_by_return` result.
- No `under12_by_return` result.
- Best score-side candidates: around **5.2%–5.7% annualized**, but **~14.8% max drawdown**.

Main failure window shifted from 2015 China bubble to **2008/2004-style broad risk + gold drawdown**.

### 4. Expanded 2001 universe: HSI / Nikkei / Shenzhen / WTI

Added non-BTC assets with 2001 coverage:

- hang_seng
- nikkei225
- shenzhen_component
- WTI crude oil

Initial result:

- Evaluated: 1,728 candidates.
- No result under 12% drawdown.
- Best score-side candidates: around **4.8%–5.3% annualized**, but **13%+ max drawdown**.

Increasing rebalance frequency to 5/10 days and adding stricter recent drawdown filters improved the best candidate to:

| Candidate | Annualized | Max drawdown | Worst DD |
|---|---:|---:|---|
| Expanded universe, 5-day rebalance | 5.77% | 12.98% | 2008-03-18 → 2009-04-17 |

Still not shippable.

### 5. Gold blowoff overlay

Diagnosed 2008 window:

| Asset | 2008-03-18 → 2009-04-17 return | In-window max drawdown |
|---|---:|---:|
| gold_cny | -16.56% | 32.22% |
| nasdaq | -28.83% | 51.04% |
| sp500 | -36.95% | 53.55% |
| WTI | -55.62% | 76.70% |

Gold was not a safe haven from the March 2008 high; it was itself in a blowoff/mean-reversion drawdown.

Gold blowoff cap improved the best targeted candidate to:

| Candidate | Annualized | Max drawdown | Slices |
|---|---:|---:|---|
| Expanded + gold blowoff cap | 5.10% | 11.75% | post-2020 8.95% / 11.49%; last10y 6.55% / 11.49% |

This is the best risk/return tradeoff found so far, but still not below the user's preferred <10% max drawdown.

### 6. Portfolio-level drawdown brake

A portfolio drawdown brake was added on top of the gold blowoff candidate.

Best under-11 result:

| Candidate | Annualized | Max drawdown | Verdict |
|---|---:|---:|---|
| Expanded + gold blowoff + portfolio brake | 4.14% | 10.95% | Drawdown improved, but return too low |

Stronger brake can approach the drawdown target, but annualized return falls into the unacceptable 3%–4% range.

### 7. Bond defense pool: TLT / IEF / SHY

TLT/IEF/SHY were fetched from Yahoo chart API as real adjusted-close data and dynamically joined after 2002-07-30.

Low-drawdown result:

| Candidate | Annualized | Max drawdown | Verdict |
|---|---:|---:|---|
| Bond defense pool | 2.30% | 9.79% | Drawdown target met, return far too low |

Higher-return probe with lower defense ballast:

| Candidate | Annualized | Max drawdown | Verdict |
|---|---:|---:|---|
| Bond/FX defense high-return side | 3.58% | 11.58% | Better than low-risk version, still too low |
| Return-top bond/FX candidate | 3.94% | 14.89% | Return still below 5%, drawdown high |

Adding USD cash (`usd_cash`) helped some crisis windows but did not solve the core return problem.

## Current best candidates

| Candidate | Annualized | Max drawdown | Status |
|---|---:|---:|---|
| Expanded universe + 5-day rebalance | 5.77% | 12.98% | Best return, drawdown too high |
| Expanded + gold blowoff cap | 5.10% | 11.75% | Best current tradeoff, still above drawdown preference |
| Expanded + gold blowoff + portfolio brake | 4.14% | 10.95% | Too low return |
| Bond/FX defense | 2.30% | 9.79% | Drawdown OK, return unacceptable |

## Verdict: NO SHIPPABLE STRATEGY YET

No tested no-BTC 2001-to-present strategy currently satisfies both:

- max drawdown around/below 10%, and
- annualized return meaningfully above ~5%.

The best honest candidate is **expanded universe + gold blowoff cap** at approximately **5.10% annualized / 11.75% max drawdown**. It is close enough to remain a research lead, but not good enough to ship as a recommended strategy.

## Strategic conclusion

The main lesson is not “tune parameters harder.” It is:

1. **China equities need a state machine** because 2015-style post-bubble repair is structurally different from ordinary trend rotation.
2. **Gold needs a state machine** because 2008 and 2011 show gold can be the source of drawdown, not just a hedge.
3. **Bond defense solves drawdown but kills return** in the tested framework, especially after 2021-2023 bond weakness.
4. **The missing ingredient is a defensive asset/source with positive carry and 2001 coverage**, not more equity index variants.

## Recommended next step

Do not productize the current candidates as “new best strategy.”

The next research direction should be data-source driven:

- Find a 2001-available defensive carry series that is not BTC and not short-history:
  - China bond fund / bond index / money-market fund proxy,
  - US Treasury total-return index with history before ETFs if licensing/source allows,
  - CNY cash/money-market yield series,
  - or another real carry asset with daily/monthly history.
- Then re-run the same 2001 main口径 with:
  - China equity state machine,
  - gold blowoff state machine,
  - defensive carry selector.

Until that data exists, the honest answer is that the current available asset set cannot meet the user's target without either accepting ~11.5%–13% drawdown or accepting sub-5% annualized return.
