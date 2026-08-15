# 资产时光机：审计后策略优化与嵌套验证协议 V1

日期：2026-08-14
状态：**参数族/验证方法先冻结，再运行结果**

> 重要：当前历史已经被多轮研究暴露，因此本协议只能提供 retrospective nested / walk-forward 证据，不能冒充 pristine prospective OOS。真正前瞻 OOS 继续由 `prospective-oos-registry-2026-08-14.md` 独立记录。

## 1. 优化目标

不再追求单一全历史最高 Sharpe，而是降低已确认的模型选择风险：

- Low Noise `24.4%` 执行偏离带存在明显历史甜点；
- Low Noise `1.22/1.24/1.30` 主动收益缩放簇存在明显历史甜点；
- NFCI C3/L3 模块本身目前通过费用不变性、底座扰动、HAC/bootstrap、粗参数 CSCV/PBO。

因此本轮只允许**降低自由度 / 参数平均 / 简化底座**，不允许加入新的宏观因子、年份规则或细小阈值。

## 2. 冻结候选族

所有候选均：T-1 决策、T 执行，gross<=1，不融资，不做空；决策研究成本冻结 1.00% fee + 0.05% slippage；NFCI 使用 point-in-time initial-release。

### C0 — LowNoise + C3/L3
当前高收益参考。用于比较，不视为默认赢家。

### C1 — CashConfidence + C3/L3
最简因子核心。

### C2 — CashConfidence + C3/L3 + static 1.30x
固定风险预算，cap gross=1。1.30 已在前瞻注册表中冻结，本轮不再改小数。

### C3 — Simple Scale Ensemble
独立资本等权组合三个预先固定的简单风险版本：1.00x / 1.20x / 1.40x，各 1/3。目的不是找最佳风险倍率，而是平均参数风险。按三个袖套各自承担交易成本，故相对单账户净额执行偏保守。

### C4 — LowNoise Parameter Ensemble + C3/L3
对已确认最脆的两组 Low Noise 参数做对称参数平均，而不是选择历史最佳点：

- trade band：0.90x / 1.00x / 1.10x of 24.4%；
- active-return scale cluster：0.90x / 1.00x / 1.10x of distance-to-1；
- 3×3 = 9 个冻结专家，独立资本等权 1/9；
- 每个专家叠同一 C3/L3；
- 不优化专家权重。

### C5 — Dual Core 50/50
50% C0 + 50% C2。权重固定 50/50，不搜索 60/40、70/30。

候选族到此为止；结果出来后不得新增 C6 再用同一协议声称同一轮 winner。

## 3. 时间验证

主要评估区间从 2012-07-05（NFCI point-in-time 可用）开始。

### 3.1 固定连续外层折

按自然年份切成 7 个互不重叠测试折：

1. 2012-07-05—2014-12-31
2. 2015-01-01—2016-12-31
3. 2017-01-01—2018-12-31
4. 2019-01-01—2020-12-31
5. 2021-01-01—2022-12-31
6. 2023-01-01—2024-12-31
7. 2025-01-01—最新

每个候选分别报告每折 CAGR / Sharpe / MDD，不能只报告平均值。

### 3.2 Walk-forward selector

从第3折开始，每个测试折只允许使用之前已经结束的折来选候选。

训练评分固定为：

`score = median(previous-fold Sharpe) - 0.50 * std(previous-fold Sharpe) - 1.00 * max(0, worstMDD - 10%)`

不使用测试折信息；测试折结束后才记录结果。该 selector 是固定算法，不在运行后改权重。

### 3.3 Leave-one-fold-out 稳健性

对最终固定候选做 fold jackknife：任意删除一个测试折后，比较相对 LowNoise 的累计 active return / Sharpe 是否仍保持同方向。

## 4. 通过门槛

“审计后优化候选”至少同时满足：

1. 全历史 1%+0.05% 成本下 Sharpe >= 1.48；
2. 全历史 MDD <= 9%；
3. 7个时间折中至少 5 折 Sharpe > 1.0；
4. 最差折 Sharpe > 0；
5. 相对 LowNoise：至少 4/7 折 Sharpe 不低于基准，或累计 OOS Sharpe 高于基准 >= 0.02；
6. block63 bootstrap Sharpe 95%下界 >= 1.15；
7. block63 bootstrap MDD P97.5 <= 15%；
8. 费用变化不得改变目标路径；
9. 不允许通过结果后再改变候选参数或 ensemble 权重。

若没有候选同时满足，不宣布新策略，只保留原生产 LowNoise并继续前瞻观察。

## 5. 选择偏差纪律

- 本轮候选数固定为6；
- 报告所有候选，不只报告赢家；
- 最终排名同时给 full、fold median、worst fold、bootstrap、walk-forward selector；
- 历史结果只决定“研究候选”，不直接替换 App；
- 真正生产替换仍需 2026-08-14 之后 prospective OOS。
