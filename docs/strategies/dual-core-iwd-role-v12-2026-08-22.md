# DualCore IWD Role V12 — 2026-08-22

状态：**FROZEN RETROSPECTIVE ROBUST CANDIDATE / PROSPECTIVE OOS REQUIRED**  
研究协议：`ATM-SVP-2`  
正式来源：`ATM-SVP2-US-VALUE-PROD-001`  
候选 ID：`S-IWD-PROD-SP500-ROLE`  
建议策略版本：`nfci-dual-core-iwd-v12 / dualcore-iwd-v12-2026-08-22`

## 1. 相对 V11 唯一的经济变化

V12 不修改 V11 的任何预测信号、NFCI C3/L3 逻辑、目标权重计算、调仓事件、25% unified band、9% volatility target、1.15 low-vol cap、near-peak buffer、动态换手抑制、现金模型、费用或风险上限。

唯一变化是资产实现：

- V11 的 `sp500` broad-U.S.-equity 目标权重仍按原规则产生；
- V12 在该组合角色上实际使用 **IWD / iShares Russell 1000 Value ETF** 的 adjusted-close total-return proxy；
- `gold_cny`、`nasdaq`、`csi300`、`shanghai_composite` 不变；
- gross 仍 `<=100%`；
- 不融资、不做空、不允许负权重；
- IWD 不参与信号计算，只改变 `sp500` 角色实际获得的资产收益。

因此这不是“再加一个择时因子”，而是**保持同一套风险与择时机制、升级 broad-US 资产角色的实现**。

## 2. 为什么必须做 production-path 实验

早期 `ATM-SVP2-US-VALUE-ROLE-001` 从 2004-01-30 重新以现金启动 V11 与 IWD/VBR，混入了路径重启效应，不能直接作为生产策略升级证据。

`ATM-SVP2-US-VALUE-PROD-001` 改为：

1. 从原始起点完整运行冻结 V11；
2. 2004-02-02 前候选与 V11 完全相同；
3. 2004-02-02 后只替换 `sp500` 角色实际收益；
4. V11 完整 target fingerprint 必须保持 `ba67c8aa24bc7168`；
5. IWD/VBR 候选执行事件 target fingerprint 必须与 V11 完全相同；
6. IWD 与 VBR 两个旧候选全部继续报告，不允许只挑历史更漂亮的一条。

正式 smoke 与 formal run 均通过这些实现完整性检查。

## 3. 正式结果

| 指标 | V11 control | **V12 / IWD role** | 差异 |
|---|---:|---:|---:|
| 全历史 CAGR | 14.345615% | **14.468031%** | **+0.122416pp** |
| 全历史 Sharpe | 1.522263 | **1.542584** | **+0.020321** |
| 全历史 MDD | 7.689054% | **7.689054%** | 0 |
| 2004-02-02+ CAGR | 14.594439% | **14.727241%** | **+0.132802pp** |
| 2004-02-02+ Sharpe | 1.533946 | **1.555816** | **+0.021870** |
| 2004-02-02+ MDD | 7.386487% | 7.402337% | +0.015850pp |
| 2020+ CAGR | 17.621393% | **17.793990%** | **+0.172597pp** |
| 2020+ Sharpe | 1.632712 | **1.667149** | +0.034437 |
| 2022+ CAGR | 21.078444% | **21.271905%** | **+0.193461pp** |
| 2022+ Sharpe | 1.785248 | **1.817952** | +0.032704 |

固定 7 折中 **5/7** 的 IWD Sharpe 不低于同折 V11；worst-fold Sharpe = **0.694282**。

## 4. 统计稳健性

63-session paired circular moving-block bootstrap，20,000 replicates，seed `20260822`：

- `P(CAGR_IWD > CAGR_V11)` = **90.985%**；
- `P(Sharpe_IWD > Sharpe_V11)` = **98.215%**；
- median CAGR delta > 0；
- median Sharpe delta > 0；
- candidate MDD P97.5 = **13.193%**，低于 15% gate；
- 全部 bootstrap gates：**PASS**。

完整 post-protocol multiple-testing accounting 共 40 个 performance-bearing candidate：

- cumulative DSR probability = **97.2015%**；
- frozen gate = 95%；
- DSR：**PASS**。

因此 `S-IWD-PROD-SP500-ROLE`：**ROBUST_STRATEGY_PASS = true**。

## 5. VBR 为什么不选

同一 formal family 中 VBR 全历史 CAGR 为 **14.660787%**，高于 IWD，但：

- 只有 **4/7** folds Sharpe >= V11，deterministic gate FAIL；
- `P(Sharpe_VBR > Sharpe_V11)` = **81.965%**，低于 90% bootstrap gate；
- 因此 `S-VBR-PROD-SP500-ROLE` 正式 FAIL。

不得因为 VBR 收益更高而降低门槛，也不得把 IWD/VBR 混合后重新搜索。

## 6. 当前能说什么、不能说什么

可以说：

> V12/IWD 是 ATM-SVP-2 下第一个在完整 production-path 资产角色试验中同时通过 deterministic、paired bootstrap 和完整 post-protocol DSR 的新策略候选；其历史风险调整表现优于冻结 V11，且未增加全历史最大回撤。

不能说：

- “V12 已完全验证”；
- “V12 已通过完整 G0-G6”；
- “未来一定优于 V11”；
- “可以根据这次结果继续调 IWD 比例、开始日或增加 value timing”。

下一阶段必须冻结策略版本并从新 freeze date 开始 prospective OOS。V11 继续作为不可修改的对照策略。
