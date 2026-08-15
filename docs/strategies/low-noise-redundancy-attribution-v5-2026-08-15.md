# LowNoise 冗余规则单项归因 V5 — 2026-08-15

状态：先冻结候选，再运行。

目的：V4 顺序删减确认“主动风险利用”作为功能不可整体删除，但后续规则的边际贡献被前序删减混淆。本轮保持当前 1.22/1.24/1.30 风险利用逻辑和 NFCI C3/L3 不变，只做单项/组合删除，识别真正冗余规则。

固定候选：

- V5-0 Current：当前 LowNoise + C3/L3。
- V5-1 NoNearPeak：仅删除 LowNoise near-peak de-risk retention。
- V5-2 NoSentinel：仅删除 A股 5% exit sentinel。
- V5-3 NoDynamicTurnover：仅删除 20%/30%/50% 动态换手抑制。
- V5-4 NoNearPeakNoSentinel：删除 near-peak + sentinel。
- V5-5 StructuralPrune：删除 near-peak + sentinel + dynamic turnover，保留主动风险利用。
- V5-6 StructuralPruneRound25：V5-5 再把 24.4% hard band 圆整为 25%。

结果后不得追加候选。V5 只做归因，不搜索新小数。优先判断：删除后 full Sharpe/CAGR/MDD、7时间折、交易数是否实质恶化。若规则删除后全历史差异很小且大多数时间折不恶化，则标记为冗余候选。

## 冻结后的结果

| 候选 | CAGR | MDD | Sharpe | Trades | 结论 |
|---|---:|---:|---:|---:|---|
| Current | 15.209% | 7.931% | 1.545 | 436 | 基准 |
| NoNearPeak | 13.894% | 9.068% | 1.495 | 463 | 明显有害，near-peak保留 |
| NoSentinel | **15.228%** | **7.931%** | **1.547** | **434** | 冗余，可删除 |
| NoDynamicTurnover | 14.754% | 7.931% | 1.506 | 475 | 动态换手有实质价值，保留 |
| NoNearPeakNoSentinel | 13.913% | 9.068% | 1.497 | 461 | FAIL |
| StructuralPrune | 13.690% | 7.580% | 1.478 | 500 | 收益/Sharpe不足 |
| StructuralPruneRound25 | 13.664% | 7.670% | 1.481 | 479 | 收益不足 |

`NoSentinel` 进一步做 7 个固定时间折与 3000 次 block63 bootstrap：6/7 折 Sharpe 不低于 Current，7/7 折 MDD 不高于 Current；bootstrap Sharpe P2.5 从 1.2420 升至 1.2446，MDD 中位从 9.951% 降至 9.944%。1.00% 与 0.03% 执行费下 target fingerprint 均为 `936855d0daa2f740`。因此 A股5% exit sentinel 正式标记为冗余规则。
