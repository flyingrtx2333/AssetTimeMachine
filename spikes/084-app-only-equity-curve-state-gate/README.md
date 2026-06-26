# 084: App-only equity-curve state gate

Hypothesis: after the App-only 240-session offensive router chooses a target
engine, the strategy's own equity curve can act as a second risk state. If the
strategy has recently lost momentum or entered drawdown, scale the active sleeve
and hold the remainder in idle CNY cash until the equity curve recovers.

Constraints:

- App-only assets used by the current strongest strategy:
  `gold_cny`, `nasdaq`, `sp500`, `csi300`, `shanghai_composite`
- No BTC
- No external assets such as OSTIX/IAU
- No leverage or financing
- Fee 1.00%, slippage 0.05%
- 8% no-trade/rebalance band to reduce churn

Run:

```bash
PYTHONPATH=tools python3 -B spikes/084-app-only-equity-curve-state-gate/app_only_state_gate.py
```

Python research check through 2026-06-26:

| Candidate | Annualized | Max DD | Vol | Sharpe | Trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| Existing one-way vol managed | 10.65% | 11.23% | 9.91% | 1.038 | 281 |
| 240d full-offense vol router + 8% band | 11.60% | 12.74% | 10.54% | 1.061 | 264 |
| Equity-curve state gate, high Sharpe | 8.22% | 8.18% | 6.95% | 1.136 | 269 |
| Equity-curve state gate, balanced return | 11.13% | 9.90% | 9.69% | 1.103 | 267 |

Interpretation: the state gate is better than the prior App-only router, but
still far from Sharpe 2. The balanced-return variant is the better product
candidate because it improves return, drawdown, and Sharpe versus the current
App strategy without relying on external assets.

Swift App-engine promotion check:

```bash
xcrun swiftc \
  -parse-as-library \
  -module-cache-path /private/tmp/atm-swift-module-cache \
  AssetTimeMachine/Backtest/BacktestModels.swift \
  AssetTimeMachine/Backtest/BacktestEngine.swift \
  tools/strategy_metric_dump.swift \
  -o /private/tmp/strategy_metric_dump

/private/tmp/strategy_metric_dump
```

| App strategy | Annualized | Max DD | Vol | Sharpe | Range |
| --- | ---: | ---: | ---: | ---: | --- |
| 权益曲线状态机 | 11.00% | 10.24% | 9.61% | 1.100 | 2002-01-04..2026-06-26 |
