# Spike 067 - Bond / Cash-Plus Defensive Engine

## Goal

After the App default fee moved to 1%, test whether a genuinely new
low-correlation defensive sleeve can lift the current no-leverage/no-BTC
gold/equity engine toward the high-Sharpe target.

All tests use:

- 1% fee.
- 0.05% slippage.
- No leverage.
- No shorting.
- No BTC/crypto.
- App-equivalent current strategy replay for the core engine.

## Data

External assets are Yahoo adjusted-close total-return proxies converted to CNY
with the App's `usd_per_cny` history.

Tested defensive pools:

- Treasury / bond: `VUSTX`, `VFITX`, `VFISX`, `TLT`, `IEF`, `SHY`, `TIP`, `LQD`.
- Cash-plus / income: `OSTIX`, `RPHYX`, `PIMIX`, `PONAX`, `DODIX`, `PTTRX`.
- Balanced / active funds for static-blend ceiling checks: `VWINX`, `PRWCX`, `FPACX`.

These assets are not currently backend-supported App assets. Any passing result
would still need backend history support before product use.

## Test 1: Dynamic Defensive Sleeve

`bond_cashplus_defensive_engine.py` keeps the current App-equivalent core
strategy, then tries:

- filling otherwise idle capital with guarded Treasury/cash-plus assets;
- cutting equity risk during broad stress and routing freed capital to defense;
- slower quarterly / semiannual defensive sleeve rebalancing to reduce 1% fee drag.

Best full-history candidates:

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| `all_defensive_idle33_cap30` | 10.86% | 11.33% | 9.98% | 1.0501 | 270 |
| `cashplus_idle_idle33_cap30` | 10.84% | 11.27% | 9.98% | 1.0493 | 266 |
| `cashplus_credit_idle33_cap30` | 10.82% | 11.49% | 10.00% | 1.0459 | 278 |
| `baseline_current_1pct` | 10.74% | 11.23% | 9.93% | 1.0446 | 213 |

Observation: dynamic defense barely improves full-history Sharpe. The best lift
is only about +0.0055 Sharpe, while trades increase meaningfully. This is not a
product-worthy improvement.

Recent slices also reject it:

- Best dynamic candidate post-2020 Sharpe: about 0.89.
- Best dynamic candidate last-10Y Sharpe: about 0.81.
- 2024+ looks good, but that is too short and regime-specific.

## Test 2: Static Income-Fund Ballast Ceiling

`static_income_blend.py` asks a different question: if we ignore dynamic trading
and simply blend the current core with income funds, what is the upper bound?

Constraint: current core must remain at least 20% of the portfolio.

Best full-history candidates:

| Weights | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe |
| --- | ---: | ---: | ---: | ---: | ---: |
| 20% core / 80% `OSTIX` | 7.08% | 9.76% | 4.63% | 1.4543 | 1.1717 |
| 20% core / 70% `OSTIX` / 10% `PTTRX` | 6.96% | 9.04% | 4.61% | 1.4358 | 1.1330 |
| 20% core / 70% `OSTIX` / 10% `DODIX` | 6.95% | 9.67% | 4.62% | 1.4320 | 1.1384 |
| 20% core / 70% `OSTIX` / 10% `PRWCX` | 7.53% | 12.95% | 5.02% | 1.4257 | 1.1615 |

Observation: static ballast can raise Sharpe much more than dynamic defense, but
only by turning the product into an income-fund-heavy allocation. Annualized
return falls to roughly 7%, which conflicts with the current "annualized too
low" objective.

## Conclusion

Do not promote this spike into the App.

The useful information is negative:

1. Traditional bond/Treasury assets are not the missing high-Sharpe source in
   CNY terms under a 1% fee.
2. Guarded cash-plus funds can make a smoother portfolio, but the return drops
   too much.
3. The best 1% fee App-core-preserving candidate remains near 10.8% annualized
   and ~1.05 Sharpe, not close to 1.6.

Next direction should not be another idle-cash defensive sleeve. To improve
meaningfully, the strategy needs either:

- a new return source that can carry 10%+ annualized with low correlation and
  acceptable product fit; or
- a materially different state machine that reduces full reallocations without
  cutting the current core's return engine.

## Files

- `bond_cashplus_defensive_engine.py`: dynamic defensive-sleeve search.
- `results.json`: dynamic defensive-sleeve output.
- `static_income_blend.py`: static current-core + income-fund blend ceiling.
- `static_blend_results.json`: static blend output.
