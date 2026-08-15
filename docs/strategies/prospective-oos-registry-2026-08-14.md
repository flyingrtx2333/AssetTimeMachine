# 资产时光机策略前瞻 OOS 注册表 — 2026-08-14

状态：**冻结，前瞻观察中**

冻结时间：2026-08-14（Asia/Singapore）

## 目的

从本文件创建后开始，下面候选的参数、逻辑、数据可用性规则和比较基准不得根据 2026-08-14 之后的新市场结果回头修改后继续沿用同一个 OOS 标签。

如果任何候选需要修改，必须创建新的版本和新的冻结日期；旧版本继续保留其全部前瞻记录，不允许覆盖失败结果。

## 共同执行约束

- 信号严格使用 T-1 可知数据，T 日执行；
- NFCI 仅使用 initial-release / first-seen point-in-time 数据；
- gross <= 100%；
- 不融资、不做空、不允许负现金；
- 决策层研究成本固定为 1.00% fee + 0.05% slippage；
- 用户执行成本只影响成交模拟，不改变策略目标权重；
- 默认生产比较口径仍为 1.00% fee + 0.05% slippage；
- 基准为冻结日的 `riskContributionCashConfidenceLowNoise`。

## Baseline：Low Noise

现有 App 低噪增强，2026-08-14 审计后版本。

已知历史参考（不属于前瞻证据）：

- CAGR ~14.45%；
- MDD ~7.93%；
- Sharpe ~1.509。

## Candidate A：Cash Confidence + NFCI C3/L3

冻结规则：

- 底座：`riskContributionCashConfidenceRouter`；
- Credit initial-release 8 次发布变化 <= -0.03；
- Leverage initial-release 4 次发布变化 <= -0.03；
- 单触发：原拟卖美股保留 50%；
- Credit + Leverage 双触发：原拟卖美股保留 100%；
- broad gross derisk >= 5pp：Generic100；
- 不新增正常日常交易日。

历史参考：

- CAGR ~11.56%；
- MDD ~7.24%；
- Sharpe ~1.519。

定位：**最简稳健核心**。

## Candidate B：Candidate A + static 1.30x risk budget

在 Candidate A 最终目标上统一乘 1.30，并 cap gross=100%。

没有其他动态风险放大参数。

历史参考：

- CAGR ~13.69%；
- MDD ~7.81%；
- Sharpe ~1.504。

1.0x–1.5x 历史粗粒度风险倍率呈宽平台；1.30x 仅作为本次冻结版本，不允许未来根据结果调整为 1.25/1.35 等后继续称为同一 OOS。

定位：**平衡核心**。

## Candidate C：Low Noise + NFCI C3/L3

冻结规则与 Candidate A 的 NFCI C3/L3 相同，但底座为 Low Noise。

历史参考：

- CAGR ~15.21%；
- MDD ~7.93%；
- Sharpe ~1.546。

已知风险：Low Noise 最后一层的 24.4% 执行偏离带和主动收益缩放簇存在参数甜点；C3/L3 增量本身在底座 ±10% 扰动中保持正贡献，但 Candidate C 仍继承底座模型选择风险。

定位：**高收益研究版，不自动晋级生产**。

## 明确不纳入本次前瞻候选

- VR80/VR90 governor；
- 50/50 双核心集成；
- RAM 延迟/卖出保护；
- VIX/BAA/实际利率附加 overlay；
- 任何 2026-08-14 后根据新结果设计的规则。

这些方案可继续研究，但必须建立新的冻结版本，不能污染本注册表。

## 前瞻记录规则

至少记录：

- 每个交易日目标权重与实际权重；
- 每次 NFCI 事件的 release_date / available_at / reference_date / first-seen value；
- 每次策略干预原因；
- 日净值、交易成本、换手、现金比例；
- 相对 Low Noise 的 active return；
- 最大回撤及恢复时间。

## 评估时点

- <63 个交易日：只做运行/数据质量检查，不做策略优劣结论；
- 63 个交易日：首次短期健康检查；
- 126 个交易日：中期观察；
- **252 个交易日：第一次主要前瞻 OOS 判定**；
- 504 个交易日：强验证。

不因为短期表现好而提前晋级，也不因为一次坏周就改参数。

## 主要判定指标

Candidate A/B/C 各自与冻结 Baseline 比较：

1. 数据与目标路径无前视、无 revision leakage；
2. 用户成本变化不得改变目标权重；
3. active return；
4. active Sharpe；
5. realized Sharpe；
6. MDD；
7. turnover / cost drag；
8. NFCI 事件命中后的 20/60 日反事实结果；
9. 是否出现历史未覆盖的失效模式。

## 晋级纪律

252 个交易日前原则上不替换生产 Low Noise。

若 Candidate A/B/C 在前瞻期失效：

- 记录 FAIL；
- 不删除；
- 不在原版本上调参数后继续宣称前瞻有效。

若出现新候选：

- 新建 `prospective-oos-registry-<date>-vN.md`；
- 从新冻结日重新计时。

这份注册表的目标不是证明历史回测漂亮，而是从 2026-08-14 起真正建立不可回头修改的前瞻证据。
