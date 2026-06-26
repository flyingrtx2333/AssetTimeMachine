# 085: App-only contagion and diversification state machines

Goal: after promoting the equity-curve state gate, test new App-only logic
without adding external tickers, BTC, leverage, or financing.

Two mechanisms were tested:

1. Contagion shelter: if gold and equities both weaken, or their rolling
   correlation turns positive during a joint selloff, scale down risk and reopen
   in stages.
2. Diversification credit: when gold and US equities are both in positive
   trends and their rolling correlation is low, use idle cash to raise the
   gold/equity barbell, still capped at 100% gross exposure.

Run:

```bash
PYTHONPATH=tools python3 -B spikes/085-app-only-contagion-state-machine/app_only_contagion_state_machine.py
```

Python App-equivalent research check through 2026-06-26:

| Candidate | Annualized | Max DD | Vol | Sharpe | Post-2020 Sharpe | Last-10Y Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| promoted state gate baseline | 11.13% | 9.90% | 9.69% | 1.103 | 0.851 | 0.803 | 267 |
| contagion joint weakness | 9.91% | 9.90% | 8.76% | 1.089 | 0.824 | 0.772 | 269 |
| contagion correlation failure | 8.65% | 9.90% | 8.18% | 1.023 | 0.744 | 0.716 | 270 |
| diversification credit, 20% gold / 100% gross loose corr | 11.62% | 9.90% | 9.70% | 1.146 | 0.950 | 0.909 | 266 |
| diversification credit, 30% gold / 95% gross loose corr | 11.50% | 9.90% | 9.65% | 1.141 | 0.965 | 0.927 | 269 |
| diversification credit, 25% gold / 95% gross | 11.47% | 9.90% | 9.62% | 1.141 | 0.964 | 0.923 | 268 |

Interpretation:

- The contagion shelter idea is too defensive. It lowers volatility, but loses
  more return than it saves.
- The better new logic is the opposite: only when diversification is actually
  working, deploy more of the idle cash into a gold/US-equity barbell.
- Best current candidate is `div_credit_gold20_gross100_loosecorr`, but it is
  not product truth until replayed through the Swift App engine.

Next step:

- If promoted, add this as a new Swift overlay after the equity-curve state
  gate.
- Then rerun `tools/strategy_metric_dump.swift` before updating any App-visible
  metric.
