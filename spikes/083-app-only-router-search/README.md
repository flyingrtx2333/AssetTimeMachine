# 083: App-only router search

Hypothesis: with only App assets, the best chance to improve Sharpe is not a
new external asset, but a router between the existing App-only defensive engine
and offensive breadth engine.

Asset universe:

- `gold_cny`
- `nasdaq`
- `sp500`
- `csi300`
- `shanghai_composite`
- idle CNY cash

Cost assumptions:

- fee: 1.00%
- slippage: 0.05%
- no leverage or financing

Run:

```bash
PYTHONPATH=tools python3 -B spikes/083-app-only-router-search/app_only_router_search.py
```

## Result

The best App-only candidate found in this pass is a stricter router variant of
the existing one-way volatility-managed strategy:

- Compare the gold-handoff defensive engine and equity-breadth offensive engine
  on 240-session trailing return.
- If the offensive engine has positive return and beats the defensive engine,
  route 100% of the active sleeve to the offensive engine.
- If offensive volatility is higher than defensive volatility, scale the active
  sleeve by `defensiveVol / offensiveVol`, leaving the rest in idle CNY cash.
- If the offensive engine is in an 8% drawdown window, fall back to 70% defensive
  / 30% offensive.

Current-date check, using data through 2026-06-26:

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| App-only 240d full-offense vol router | 11.49% | 12.71% | 10.53% | 1.053 | 281 |
| Existing one-way vol managed | 10.65% | 11.23% | 9.91% | 1.038 | 281 |
| Gold handoff defensive child | 9.44% | 11.38% | 9.98% | 0.925 | 183 |
| Equity breadth offensive child | 13.00% | 18.85% | 13.10% | 0.969 | 364 |

Search-date output, using data through 2026-06-19, found the same top logic:

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| App-only 240d full-offense vol router | 11.54% | 12.71% | 10.53% | 1.058 | 281 |
| Existing one-way vol managed | 10.70% | 11.23% | 9.92% | 1.043 | 281 |

Interpretation: this is a real but small improvement. It increases return and
Sharpe by letting a confirmed offensive engine take the full active sleeve when
it is already winning, but the App-only asset pool did not produce anything near
Sharpe 2 under 1% fee/no-leverage assumptions.
