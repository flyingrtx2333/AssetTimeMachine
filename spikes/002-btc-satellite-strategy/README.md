# 002: BTC satellite strategy verification

## Question

Can we break through the no-BTC strategy ceiling by adding a very small, strictly gated BTC satellite allocation?

This is a separate strategy family, not a replacement for the 2002 full-cycle no-BTC strategy, because BTC history in the current public API starts on 2017-08-17.

## Data

The script uses the existing AssetTimeMachine public history endpoint via `tools/search_btc_satellite_strategies.py`.

Coverage from the verification run:

| Series | Start | End |
|---|---:|---:|
| gold_cny | 2001-06-25 | 2026-06-20 |
| nasdaq | 2000-01-13 | 2026-06-19 |
| sp500 | 2000-01-13 | 2026-06-19 |
| btc | 2017-08-17 | 2026-06-20 |

The BTC strategy therefore starts at 2017-08-17.

## Strategy logic

The verified configuration is intentionally fixed; no new parameter grid was run here.

Core idea:

- Conservative base: mostly gold + Nasdaq + S&P 500.
- BTC is only a 5% target sleeve.
- BTC must pass trend and momentum gates.
- BTC must also pass volatility and recent drawdown filters.
- Overall portfolio uses target-vol / max-exposure scaling.
- If equities are weak and gold is healthy, part of the cut risk redeploys to gold.

This is a **small satellite** model, not a crypto-heavy strategy.

## Results

Verification command:

```bash
python3 spikes/002-btc-satellite-strategy/btc_satellite_verify.py
```

Machine-readable output:

```text
/tmp/atm_btc_satellite_verify.json
```

### 2017-08-17..2026-06-20

| Strategy | Annualized | Max drawdown | Sharpe | Notes |
|---|---:|---:|---:|---|
| BTC satellite | 8.92% | 9.87% | 0.87 | Best return under ~10% drawdown in this family |
| No-BTC same framework | 7.85% | 9.27% | 0.79 | Same framework without BTC |
| Current VAA same window | 7.23% | 9.52% | 1.03 | Existing no-BTC VAA family |
| OHLC crisis gate | 7.06% | 8.81% | 1.02 | Lower drawdown, lower return |
| Mania safe-haven gate | 6.92% | 8.81% | 1.01 | Lower drawdown, lower return |

### Post-2020

| Strategy | Annualized | Max drawdown |
|---|---:|---:|
| BTC satellite | 9.77% | 9.87% |
| No-BTC same framework | 8.34% | 9.27% |
| Current VAA same window | 8.24% | 9.52% |

### Post-2022

| Strategy | Annualized | Max drawdown |
|---|---:|---:|
| BTC satellite | 10.46% | 8.96% |
| No-BTC same framework | 9.76% | 9.27% |
| Current VAA same window | 8.86% | 8.12% |

## Verdict: INVALIDATED BY PRODUCT PREFERENCE

### What worked technically

- BTC satellite improved annualized return in the available 2017+ window.
- Max drawdown stayed just under 10% in the verification run.

### Why this direction is rejected

- The user explicitly does **not** want BTC in AssetTimeMachine strategy development.
- The user wants the main strategy evaluation to focus on **2001-to-present / full available history**. BTC history in the current public API starts only on 2017-08-17, so it cannot support the required main backtest horizon.
- Shorter-history satellite windows must not be used as main strategy conclusions.

## Recommendation

Do not productize BTC strategies.

Keep this spike only as an archived negative result: technically interesting, but outside the accepted strategy universe and accepted backtest horizon.

Continue development only on no-BTC strategies evaluated on the 2001-to-present/full-history口径.
