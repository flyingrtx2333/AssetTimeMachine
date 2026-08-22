# DualCore IWD Role V12 — 2026-08-22

状态：**SUSPENDED / MATCHED TOTAL-RETURN AUDIT FAIL / NOT FOR PRODUCT PROMOTION**

研究协议：`ATM-SVP-2`

原始正式来源：`ATM-SVP2-US-VALUE-PROD-001`（对旧 price-index comparator 的历史 PASS，永久保留）

最新裁决来源：`ATM-SVP2-IWD-SPY-TR-001`（matched total-return audit，FAIL）

候选 ID：`S-IWD-PROD-SP500-ROLE` / 严格对照审计 ID `S-IWD-VS-SPY-TR-ROLE`

冻结策略版本：`nfci-dual-core-iwd-v12 / dualcore-iwd-v12-2026-08-22`（暂停晋级）

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

## 3. 原 production-path 结果（历史证据，旧 comparator）

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

## 4. 原统计稳健性（仅对旧 comparator 成立）

下列 PASS 必须按其原始实验口径解释：IWD 使用 adjusted-close total-return proxy，而冻结 V11 的 `sp500` 角色使用 price-index series。后续发现两者收益口径不一致，因此本节只能作为历史实验记录，不能再作为产品晋级依据。

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

因此在 `ATM-SVP2-US-VALUE-PROD-001` 的**原始实验口径内**，`S-IWD-PROD-SP500-ROLE` 曾得到 `ROBUST_STRATEGY_PASS = true`。该历史记录不回写、不删除，但已被下面的同口径审计否定其产品晋级解释。

## 5. 最新 matched total-return 审计：V12 暂停晋级

`ATM-SVP2-IWD-SPY-TR-001` 修复了最关键的 comparator mismatch：IWD 与控制组都改用 Yahoo adjusted-close total-return proxy，并保持同一条冻结 V11 target/event path。共同评估从 `2000-05-30` 开始。

| 指标 | matched SPY control | **IWD candidate** | 差异 |
|---|---:|---:|---:|
| CAGR | 14.465392% | **14.509755%** | +0.044363pp |
| Sharpe | 1.535352 | **1.547475** | +0.012123 |
| MDD | 7.689054% | **7.689054%** | 0 |
| 固定折 Sharpe 胜出 | — | **5/7** | — |
| worst-fold Sharpe | — | **1.072567** | — |

方向上 IWD 仍略优于 SPY，但冻结统计门槛没有通过：

- `P(CAGR_IWD > CAGR_SPY)` = **67.210%**，低于 90% gate；
- `P(Sharpe_IWD > Sharpe_SPY)` = **88.065%**，低于 90% gate；
- candidate MDD P97.5 = **13.657%**，通过 15% gate；
- cumulative 41-candidate DSR = **97.577%**，通过 95% gate；
- 最终：**ROBUST_STRATEGY_PASS = false**。

因此当前证据只能说明 IWD 有一个很小、方向一致的历史优势，不能证明这是稳健的 value-role alpha。原 V12 的部分表观增益可能来自 price-index 与 total-return proxy 的收益口径差异，而不是可重复的资产角色优势。

已经冻结的 `ATM-SVP2-PROSPECTIVE-IWD-001` 保留为历史治理记录，但其产品晋级解释**暂停**；不能用未来 63/126/252/504 日观察去绕过本次 retrospective matched-control FAIL。

## 6. VBR 为什么不选

同一 formal family 中 VBR 全历史 CAGR 为 **14.660787%**，高于 IWD，但：

- 只有 **4/7** folds Sharpe >= V11，deterministic gate FAIL；
- `P(Sharpe_VBR > Sharpe_V11)` = **81.965%**，低于 90% bootstrap gate；
- 因此 `S-VBR-PROD-SP500-ROLE` 正式 FAIL。

不得因为 VBR 收益更高而降低门槛，也不得把 IWD/VBR 混合后重新搜索。

## 7. 当前裁决与后继研究

当前可以说：

> V12/IWD 在旧 price-index comparator 下曾通过原 production-path 统计门槛；在修复收益口径、改用 matched SPY total-return control 后，IWD 仍呈小幅方向性优势，但未通过冻结 bootstrap 门槛，因此当前状态为 **SUSPENDED / NOT FOR PRODUCT PROMOTION**。

当前不能说：

- “V12 已稳健优于 V11 / SPY”；
- “V12 已完全验证”或“已通过完整 G0-G6”；
- “未来一定优于 V11”；
- “可以根据这次结果继续调 IWD 比例、开始日、ETF、blend 或增加 value timing”。

### 后继 one-shot 架构试验

为了继续寻找比 V11 更高的无杠杆收益，而不是救 IWD 参数，`ATM-SVP2-V11-C3L3-CORE-SWITCH-001` 使用**完全冻结的** V11 C3/L3 压力状态，在 exact V11 防守核心与 exact HighCore 之间做单一机械切换；没有新增数值参数，`max_gross = 1.0`，不融资、不做空。

正式结果同样 **FAIL**：

- CAGR：**14.504572%**，高于 V11 14.345615%；
- Sharpe：**1.516321**，低于 V11 1.522263；
- MDD：**7.771319%**；
- 固定 7 折 Sharpe 仅 **3/7** 不低于 V11；
- bootstrap `P(CAGR > V11)` = **81.320%**；
- bootstrap `P(Sharpe > V11)` = **35.565%**；
- 44-candidate DSR = **96.981%**，单独通过，但不能覆盖 deterministic/bootstrap FAIL；
- `ROBUST_STRATEGY_PASS = false`。

这进一步说明：当前 V11 周边仅靠提高 calm-state 风险暴露，很难稳定提升风险调整收益。该 C3/L3 core-switch campaign 也按预注册 stop rule 关闭，不允许改 OR/AND、阈值、lookback 或混合比例继续搜索。

**当前产品基准仍应保持冻结 V11。** 下一轮研究应进入真正独立的新收益源/新策略架构，并继续遵守总 gross `<=100%`、现金不为负、无任何融资或经济杠杆的硬规则。
