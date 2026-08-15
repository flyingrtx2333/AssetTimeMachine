# 目标仓位模型集成 V3 — 2026-08-14

状态：**候选、权重、验证门槛先冻结，再运行结果**

V1 证明 C3/L3 增量稳健但 LowNoise 存在两个参数甜点；V2 的 soft-boundary 结构未能替换 C0。本轮不再寻找新的单点参数，而使用目标仓位层模型平均来降低参数选择风险。

## 1. 共同约束

- exact Swift App engine；
- T-1 信号、T 执行；
- 1.00% fee + 0.05% slippage；
- 决策影子引擎成本冻结，不受用户执行费用影响；
- NFCI initial-release point-in-time；
- gross<=1、无融资、无做空、无负现金；
- 专家自身全部因果运行，再只对同日目标权重做等权平均；
- 最终平均目标在**一个账户**统一执行，相反交易可以自然净额抵消。

## 2. 冻结候选

### V3-0 Baseline C0
`LowNoise + C3/L3`，当前 retrospective winner。

### V3-1 Bag9 Target Ensemble
9个专家固定为：

- LowNoise trade band factor：0.90 / 1.00 / 1.10 × 24.4%；
- LowNoise active-scale distance-to-1 factor：0.90 / 1.00 / 1.10；
- 3×3=9专家；
- 每个专家均叠同一 C3/L3；
- 每日目标权重 1/9 等权平均；
- 单账户最终执行使用 hard rebalance band = 25%。

专家权重不得优化。

**敏感性诊断**：同一个 Bag9 目标另外用 hard band 20% 和 30% 重放，只判断执行参数是否仍呈尖峰；20/30结果不得用于替换25%的冻结候选。

### V3-2 Dual Core Target Blend
每日目标：

`0.50 * (LowNoise+C3/L3) + 0.50 * (CashConfidence+C3/L3+static1.30x)`

统一 hard band=25%，单账户执行。不得搜索其它混合权重。

### V3-3 Triple Core Equal Target Blend
每日目标：

`1/3 * C0 + 1/3 * (CashConfidence+C3/L3) + 1/3 * (CashConfidence+C3/L3+1.30x)`

统一 hard band=25%，不得优化权重。

候选到此结束；结果后不得新增 V3-4。

## 3. 验证

沿用既有7个连续时间折：

1. 2012-07-05—2014-12-31
2. 2015—2016
3. 2017—2018
4. 2019—2020
5. 2021—2022
6. 2023—2024
7. 2025—latest

报告 full、每折、block63 bootstrap、相对 C0 active-return、leave-one-fold-out。

## 4. 硬门槛

V3-1/2/3 必须：

1. full Sharpe >=1.50；
2. full MDD <=8.5%；
3. full CAGR >=14.0%；
4. >=5/7折 Sharpe>1；
5. worst fold Sharpe>0；
6. >=4/7折 Sharpe >= C0，**或** full Sharpe距C0不超过0.03且 MDD 至少降低0.30pp；
7. block63 Sharpe P2.5 >=1.18；
8. block63 MDD P97.5 <=15%；
9. target-path 对用户手续费不变；
10. Bag9 的20/25/30执行带 full Sharpe最大-最小差 <=0.06，才可称为“已降低执行带尖峰”。

若 V3-1 不满足第10条，即使25%版本其它指标很好，也不能以“参数集成解决了带宽过拟合”为理由晋级。

## 5. 排名原则

通过硬门槛后按以下顺序：

1. 模型/执行参数敏感性更低；
2. 7折 robust score；
3. block63 尾部MDD；
4. full Sharpe；
5. CAGR。

本轮仍是 retrospective validation。任何赢家只成为新的研究主线；真正替换生产仍等待 2026-08-14 之后冻结的 prospective OOS。

## 6. 冻结后的实际结果

协议冻结后只运行 V3-1/2/3 与 Bag9 的20/25/30带宽诊断，没有追加候选或搜索混合权重。

| 候选 | CAGR | MDD | Sharpe | block63 Sharpe P2.5 | block63 MDD P97.5 | 相对C0 Sharpe不差折数 | 判定 |
|---|---:|---:|---:|---:|---:|---:|---|
| C0 baseline | 15.21% | 7.93% | 1.546 | 1.238 | 14.58% | 7/7 | 基准 |
| V3-1 Bag9 target | 14.76% | 7.93% | 1.508 | 1.195 | 14.71% | 2/7 | FAIL |
| V3-2 DualCore 50/50 target | 14.58% | 7.69% | 1.535 | 1.231 | 14.09% | 4/7 | **PASS** |
| V3-3 TripleCore equal target | 13.37% | 7.36% | 1.538 | 1.227 | 13.39% | 5/7 | FAIL（CAGR<14%） |

Bag9 同一目标在 hard band 20/25/30% 下 Sharpe 分别为 1.498 / 1.508 / 1.478，spread=0.030 < 0.06，说明参数平均确实显著降低了执行带尖峰；但它没有在足够多时间折击败 C0，因此不能因为“更平滑”而晋级。

DualCore 是本轮**唯一新候选 PASS**：

- 7个时间折中 4 折 Sharpe 高于 C0；
- 7/7 时间折 MDD 都低于 C0；
- full Sharpe 仅比 C0 低约0.011；
- full CAGR 低约0.63pp；
- block63 尾部 MDD 从约14.58%降到14.09%。

配对 moving-block bootstrap（同一重采样块同时作用于 C0 与 DualCore）进一步说明其本质是风险/模型分散，而非免费 Alpha：

- CAGR 差中位约 -0.59pp/年，95%区间基本为负；
- MDD 差中位约 -0.24~-0.38pp；约69%~73%的重采样路径里 DualCore MDD 更低；
- Sharpe 差中位约 -0.011，约28%~31%的重采样路径里 DualCore Sharpe反而更高。

因此 V3 不改变“C0 是高收益 retrospective winner”的事实；DualCore 晋级为**审计后平衡研究候选**，用于降低对 LowNoise 甜点参数的依赖。

## 7. 成本不变性

C0 与 C2 底层模型分别用 1.00% 与 0.03% 用户执行费重新生成完整6395日目标权重，输出 CSV byte-for-byte identical。DualCore 最终目标因此不随用户费改变。

DualCore 单账户重放：

- 1.00% fee：14.58% CAGR / 7.69% MDD / 1.535 Sharpe；
- 0.03% fee：16.93% CAGR / 7.39% MDD / 1.764 Sharpe；
- target fingerprint 均为 `9b20947b8640091b`。

即用户执行成本只改变真实成交结果，不改变策略身份。

**V3 结论：DualCore PASS as balanced research candidate; C0 remains the higher-return research winner.**
