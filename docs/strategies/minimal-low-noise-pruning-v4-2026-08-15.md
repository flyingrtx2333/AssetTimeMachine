# 最小充分策略删减验证 V4 — 2026-08-15

状态：**候选、删减顺序和门槛先冻结，再运行结果。**

## 目标

不再追求更高的历史最优 Sharpe。目标是删除 LowNoise 中已知高模型风险或与 NFCI C3/L3 功能重复的规则，寻找“自由度更少、仍保留大部分收益/风险特征”的最小充分实现。

所有候选都叠加同一冻结 NFCI C3/L3：Credit 8-release change <= -0.03，Leverage 4-release change <= -0.03，单触发保留 50% 美股计划减仓，双触发保留 100%，broad de-risk 使用 Generic100；严格 T-1，gross<=1，不融资，不做空，1% fee + 0.05% slippage。

## 冻结删减顺序

- V4-0 Current：当前 LowNoise + C3/L3，作为基准。
- V4-1 Round25：只把 hard trade band 从 24.4% 改为自然的 25%。
- V4-2 NoActive：V4-1 + 删除 1.22 / 1.24 / 1.30 三套主动收益放大（统一为 1.00）。保留已证实宽平台的 9%低波动风险利用。
- V4-3 NoNearPeak：V4-2 + 删除 LowNoise 内部 near-peak de-risk retention。理由：NFCI 已承担更有外部经济解释的“避免过早减仓”职责，检查二者是否重复。
- V4-4 NoSentinel：V4-3 + 删除低噪 A 股 5% exit sentinel 补丁。
- V4-5 Minimal：V4-4 + 删除同 leader / 总风险变化小于2%时的 20%/30%/50% 动态换手抑制；只依赖统一 25% hard band 决定成交。

结果出来后不得增加 V4-6，也不得搜索 23%、27%、1.10、1.15 等补考参数。

## 保留的结构

以下不是本轮删减对象：

- 趋势和多模型风险预算；
- 风险贡献/相关性再分配；
- 稳健/进攻状态切换；
- 水下恢复袖套；
- Cash Confidence 主干；
- 9%低波动风险利用（此前 7.2%–10.8% 扰动为宽平台）；
- NFCI C3/L3；
- gross<=100%、无融资、无做空、成本与信号层隔离。

## 固定验证

沿用既有 7 个连续时间折：
2012-07-05—2014、2015—2016、2017—2018、2019—2020、2021—2022、2023—2024、2025—latest。

每个候选必须报告：

1. Full CAGR / MDD / Vol / Sharpe / trades；
2. 7 个时间折 CAGR / MDD / Sharpe；
3. 63 日 moving-block bootstrap：Sharpe P2.5/P50，MDD P50/P97.5；
4. 相对 V4-0 每折 active return；
5. 目标仓位 fingerprint；
6. fee 1.00% vs 0.03% target-path invariance；
7. 规则自由度计数（删除数量）。

## 冻结验收门槛

简化候选要成为新的优先研究版本，必须同时满足：

- Full Sharpe >= 1.48；
- Full CAGR >= 14.0%；
- Full MDD <= 9.0%；
- 7 折至少 5 折 Sharpe > 1；
- worst-fold Sharpe > 0；
- block63 Sharpe P2.5 >= 1.15；
- block63 MDD P97.5 <= 15%；
- 至少 4/7 折 Sharpe 不低于 V4-0，**或者** Full Sharpe 与 V4-0 差 <= 0.035 且至少删除 3 个规则簇并在 7 折中至少 5 折 MDD 不高于 V4-0；
- 费用变化不得改变目标路径。

最终选择遵循最小描述长度原则：在通过门槛的候选中，优先删除规则最多者；只有复杂度相同才比较 Sharpe/CAGR。
