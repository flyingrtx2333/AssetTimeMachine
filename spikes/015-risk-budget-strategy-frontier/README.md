# 015: Risk-budget strategy frontier

## Question

Can we find a better AssetTimeMachine strategy after the E02 / barbell OHLC frontier, without BTC and without broad parameter fitting?

Preference constraints used in this spike:

- main product story should remain around gold / Nasdaq;
- no BTC;
- use 2002-to-current full available history as the headline window;
- validate post-2020, last-10Y, 2024+, early/late slices, and stress windows;
- real units/cash accounting, cash yield, fees/slippage, T-1 signal / T execution inherited from existing project spike modules;
- do not promote scratch metrics directly into strategy cards before App-engine reproduction.

## Files

```text
risk_budget_frontier.py
README.md
```

Key output files:

```text
/tmp/atm_risk_budget_frontier_015.json
/tmp/atm_risk_budget_frontier_015.txt
/tmp/atm_canary_app_logic_search.json
/tmp/atm_canary_app_logic_rerun_015.txt
```

Verification commands run:

```bash
python3 -m py_compile spikes/015-risk-budget-strategy-frontier/risk_budget_frontier.py
python3 spikes/015-risk-budget-strategy-frontier/risk_budget_frontier.py
python3 spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py
```

## Mechanisms tested

### A. E02 + equity-curve insurance budget

Mechanism: keep the E02 breakout/chandelier entry engine, but reduce gross exposure only after actual portfolio drawdown, plus rare liquidity-shock and gold-trap caps.

Result:

```text
C01_e02_equity_insurance
Full:      5.94% / 8.84%
Post-2020: 10.43% / 8.75%
Last 10Y:  8.58% / 8.75%
2024+:     13.99% / 8.34%
```

Verdict: rejected. It solves drawdown but cashifies too much; return falls below the user's acceptable range.

### B. 25N/35G barbell + TIPP floor

Mechanism: start from the higher-return 25% Nasdaq / 35% gold drift-harvest-rebuild engine, then use a TIPP-style portfolio floor to size risk.

Result:

```text
C02_barbell_tipp_floor
Full:      4.85% / 7.43%
Post-2020: 8.53% / 6.72%
Last 10Y:  7.26% / 6.72%
2024+:     18.29% / 6.72%
```

Verdict: rejected. Drawdown is good, but the mechanism preserves the floor by sitting mostly in cash, especially current latest exposure (~12% invested). Too defensive.

### C. S&P-permission regime allocator

Mechanism: use S&P as a market-permission signal; visible holdings remain Nasdaq / gold / cash.

Result:

```text
C03_regime_allocator
Full:      3.42% / 12.82%
Post-2020: 6.05% / 8.75%
Last 10Y:  6.19% / 8.75%
2024+:     11.20% / 8.75%
```

Verdict: invalidated. It does not solve full-cycle drawdown and return is too low.

### D. Shock recovery ladder

Mechanism: E02 insurance plus staged re-entry after liquidity shock.

Result:

```text
C04_shock_recovery_ladder
Full:      5.72% / 8.79%
Post-2020: 9.93% / 8.34%
Last 10Y:  7.83% / 8.34%
2024+:     13.26% / 8.34%
```

Verdict: rejected. Better than pure TIPP, but still too much return sacrificed.

### E. CPPI/TIPP relative trend allocator

Mechanism: a portfolio cushion chooses exposure, then allocates risk between Nasdaq and gold by relative trend.

Result:

```text
C05_cppi_relative_trend
Full:      2.26% / 7.42%
Post-2020: 4.39% / 7.12%
Last 10Y:  3.54% / 7.12%
2024+:     10.75% / 7.12%
```

Verdict: invalidated. Too cash-like.

## Canary / App-like low-drawdown frontier check

Reran the existing App-like canary strategy search to establish the practical low-drawdown frontier.

Current baseline:

```text
CURRENT 双金丝雀动量防守
Full:      7.32% / 9.25%
Post-2020: 8.36% / 9.25%
Last 10Y:  7.10% / 9.25%
Latest:    Nasdaq 17.5% / S&P 23.0% / cash rest
```

Best under 10% drawdown found by the existing canary script:

```text
canary_rb20_top2_off0.42_bal0.35_def0.15_max0.9_weak1_ama220_dma220_vc0.45
Full:      7.97% / 9.92%
Post-2020: 9.05% / 9.92%
Last 10Y:  7.68% / 9.92%
2024+:     18.25% / 6.56%
2002-2012: 8.34% / 9.01%
2013-2023: 5.36% / 9.92%
Latest:    Nasdaq 18.4% / S&P 24.1% / cash rest
```

Stress slices:

```text
2008: -1.71% / 8.20%
2015: -7.64% / 8.94%
2020: -3.81% / 6.73%
2022: -7.01% / 7.57%
2026:  7.79% / 6.34%
```

Important caveat: the top drawdown window in 2021-2023 used gold + CSI300 + Shanghai Composite. This improves the full-cycle frontier but is no longer a strict gold/Nasdaq-only visible-holdings story.

## Strict gold/Nasdaq universe check

Using the same canary logic and best fixed parameters, but constraining offensive holdings:

```text
gold_nasdaq_only_offense
Full: 5.72% / 12.05%
Latest: Nasdaq 42.7%

gold_nasdaq_sp500
Full: 5.59% / 12.39%
Latest: Nasdaq 18.4% / S&P 24.1%

gold_nasdaq_sp500_dow
Full: 5.46% / 11.19%
Latest: Nasdaq 18.4% / S&P 24.1%

full_current_best
Full: 7.97% / 9.92%
Latest: Nasdaq 18.4% / S&P 24.1%
```

Takeaway: the sub-10% / ~8% frontier currently depends on allowing a broader index rotation universe. Strict gold/Nasdaq visible holdings still cannot match it under this data and execution口径.

## Verdict: PARTIAL

### What worked

- The strongest practical candidate today is still an App-like canary rotation family, not a new gold/Nasdaq-only stop-loss or TIPP mechanism.
- A fixed canary variant improves the current baseline from ~7.32% / 9.25% to ~7.97% / 9.92% while keeping all major slices under ~10% drawdown.

### What did not work

- New risk-budget / floor / shock-ladder mechanisms mostly solved drawdown by moving too much to cash, causing 2-6% annualized full-cycle returns.
- Strict gold/Nasdaq-only or gold/Nasdaq/S&P-only variants failed to reach both acceptable return and drawdown: they land around 5.5-5.7% annualized with 11-12% drawdown.

### Recommendation

Do not promote the new risk-budget mechanisms. If the goal is a shippable low-drawdown strategy today, the candidate worth App-engine reproduction is:

```text
双金丝雀增强版 / Canary Enhanced
Universe: gold_cny, nasdaq, sp500, dowjones, csi300, shanghai_composite
Rule: Nasdaq + S&P canary, 20/60/120/240 momentum, MA filters, top-2 offensive, gold ballast/defense
Metrics to reproduce in App engine: ~7.97% annualized / ~9.92% max drawdown
```

Positioning caveat: do not package it as a pure gold/Nasdaq strategy. It is a broader low-drawdown index rotation strategy with gold as defensive anchor and Nasdaq/S&P as current active holdings.
