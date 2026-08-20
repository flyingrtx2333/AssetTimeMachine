# 资产时光机 Factor Shadow 前瞻注册表 — 2026-08-21 V2

状态：**FROZEN PROSPECTIVE RESEARCH SHADOW**

冻结日期：2026-08-21（Asia/Shanghai）

协议：`ATM-SVP-2`

Trial：`ATM-SVP2-PROSPECTIVE-FACTOR-001`

## 目的

当前 retrospective factor discovery campaign 已按 preregistered stop-rule 结束。以下 3 条候选均已在历史样本上暴露，因此它们的历史结果只能用于说明为什么值得继续观察，不能再用于改参数或追加候选。

从本文件冻结后，只允许用 **2026-08-21 之后新到达的数据**积累独立前瞻证据。任何参数、source、lookback、stale rule、retention/completion 语义发生变化，都必须创建新候选版本并重新计时；旧版本记录永久保留。

## 共同约束

- 底座固定：`nfci-dual-core-v11` / `dualcore-v11-2026-08-15`。
- V11 本身不做任何参数或 target-path 修改。
- 信号日期使用 V11 forward snapshot 的 `signal_date`；factor 只允许使用 `date <= signal_date` 的观测。
- factor stale tolerance 固定 7 calendar days。
- ratio direction lookback 固定 20 个共同 source observations。
- factor 只能在 **V11 自己真实推荐 rebalance 的 event** 上改变 shadow target；event 之间 shadow target 保持上一次状态。
- gross <= 100%，不融资、不做空、不允许负现金。
- 研究成本固定 1.00% fee + 0.05% slippage；后续 realized NAV 必须按实际 shadow target 变动扣除。
- 3 条候选不得互相组合，不允许根据未来表现删除弱候选。
- matched control 与 candidate 同时记录，用于区分“factor timing 信息”与“单纯延缓去风险/提高 gross”的效果。

## Frozen Candidate 1 — F-CREDITCASH-PROSPECTIVE

历史 lineage：`F-CREDITCASH` / `ATM-SVP2-ORTHO-FACTOR-006`。

Frozen rule：

- Yahoo adjusted close：`HYG / SHY`。
- common-date ratio = HYG / SHY。
- risk-on iff 最新 usable ratio >= 20 个共同观测前 ratio。
- 只在 V11 `rebalance_recommended == true` 且当前 V11 positive gross 在 `(0,1)` 时有资格干预。
- risk-on：把 V11 当前已经为正的持仓同比例补到 exactly 100% gross。
- risk-off / unavailable：保持 V11 event target。
- matched control：factor available 时无条件补到 100% gross。

已知历史参考（仅用于 disclosure，不属于前瞻证据）：CAGR 16.067258%，Sharpe 1.377913，MDD 12.777213%，4/7 folds Sharpe 不差于 matched control；因 MDD >12% 且 Sharpe < V11，历史 gate FAIL。

## Frozen Candidate 2 — F-BREADTH-PROSPECTIVE

历史 lineage：`F-BREADTH` / `ATM-SVP2-ORTHO-FACTOR-003`。

Frozen rule：

- Yahoo adjusted close：`RSP / SPY`。
- risk-on iff最新 usable ratio >= 20 个共同观测前 ratio。
- 只在 V11 event 上比较“上一个 V11 event base target”与“当前 V11 event base target”。
- 只有当前 event 是 de-risk event 时允许干预。
- risk-on：保留该次每个资产减仓量的 exactly 50%，gross cap 100%。
- risk-off / unavailable：保持当前 V11 event target。
- matched control：factor available 的 de-risk event 无条件保留 50%。

已知历史参考：screening CAGR 14.4254%、Sharpe 1.4701、MDD 9.10%；paired block-bootstrap `P(CAGR > V11)=61.395%`，未通过 robustness，因此不得称为 robust factor。

## Frozen Candidate 3 — F-HIGHBETA-PROSPECTIVE

历史 lineage：`F-HIGHBETA` / `ATM-SVP2-ORTHO-FACTOR-004`。

Frozen rule：

- Yahoo adjusted close：`SPHB / SPLV`。
- risk-on iff 最新 usable ratio >= 20 个共同观测前 ratio。
- event/de-risk 判定与 F-BREADTH 完全相同。
- risk-on：保留该次每个资产减仓量的 exactly 50%，gross cap 100%。
- matched control：factor available 的 de-risk event 无条件保留 50%。

已知历史参考：screening CAGR 14.392%、Sharpe 1.494、MDD 8.52%；paired block-bootstrap `P(CAGR > V11)=59.620%`，未通过 robustness。

## Append-only Snapshot 规则

每个新 market session 至少记录：

- snapshot timestamp；
- V11 `signal_date` / `execution_date_hint` / dataset hash / causal input fingerprint；
- V11 event target / target fingerprint / `rebalance_recommended`；
- 上一个 V11 event base target；
- 6 条 factor source 的原始 recent-window observations 与 input SHA；
- 每个 factor latest usable observation date、20-observation prior date、ratio/state；
- candidate target、matched-control target、target fingerprint；
- 是否 eligible event / de-risk event / intervention；
- prior shadow target 与 current shadow target；
- append-only previous record hash / current record hash。

不得在结果不理想时删除或改写旧 snapshot。

## 评估时钟

- <63 新 sessions：只做数据/运行完整性检查。
- 63 sessions：operational health check，不做优劣结论。
- 126 sessions：中期 observation。
- 252 sessions：第一次 provisional factor assessment；若 event 数不足则标记 INCONCLUSIVE，不得强行判定。
- **504 sessions：primary prospective factor decision**。

## 504-session Primary Gate

每个 candidate 独立评估，只有同时满足以下条件才可标记 `PROSPECTIVE_FACTOR_PASS`：

1. append-only/data-causality integrity 全部通过；
2. 至少 8 个 factor-available eligible V11 events；
3. 至少 4 个实际 factor interventions；
4. candidate net annualized return > V11 shadow；
5. candidate realized Sharpe >= V11 shadow Sharpe；
6. candidate realized Sharpe > 自己的 matched control Sharpe；
7. candidate MDD <= 15%；
8. gross/short/cash constraints 全程通过。

若 504 sessions 时事件数不足，结论只能是 `INCONCLUSIVE_LOW_EVENT_COUNT`，不得改阈值或回看历史找新版本救场。

## 停止纪律

- 本 registry 只有上述 3 条 candidate。
- 在 504-session primary decision 前，不得根据新结果给这 3 条调 10/30/60-day lookback、改 50% retention、改 100% completion、改 source 或组合它们。
- 如提出新 factor hypothesis，必须新建独立 registry/trial，从新的冻结日开始，不能共享本 trial 的 prospective 标签。
