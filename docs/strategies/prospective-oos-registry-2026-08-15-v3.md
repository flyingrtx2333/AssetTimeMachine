# 资产时光机前瞻 OOS 注册表 V3 — Simplified DualCore

冻结日期：2026-08-15（V4–V11 retrospective pruning 完成之后）
状态：**冻结，等待未来数据**

本文件新增一个在 2026-08-15 简化审计后形成的候选。它不得覆盖 `prospective-oos-registry-2026-08-14-v2.md` 中 Candidate D / TestFlight 180 的 DualCore V1；两条 prospective 序列必须独立保留。

## Candidate E — Simplified DualCore V11

正式 App 实现标识：

- `AdvancedBacktestStrategyMode.nfciDualCoreSimplifiedV11`
- product template id: `nfci-dual-core-v11`
- 冻结回归：`scripts/verify_nfci_dual_core_frozen_versions.py`
- 1% target fingerprint: `ba67c8aa24bc7168`

固定结构：

1. 高收益核心：`LowNoise + NFCI C3/L3`，但：
   - 所有 active leader 统一 scale = 1.22；
   - 删除 leader-specific 1.24；
   - 删除 leader-specific 1.30；
   - 删除 A股5% exit sentinel；
   - high-core hard rebalance band = 25%，不再使用24.4%。
2. 稳健核心：`CashConfidence + NFCI C3/L3 + static 1.30x risk budget`，保持不变。
3. 最终目标：`0.50 * high_core + 0.50 * stable_core`。

固定约束：

- 最终 unified hard band = 25%；
- gross<=100%；
- 不融资、不做空、不允许负现金；
- NFCI 使用 first-seen / initial-release point-in-time；
- Credit 8-release change <= -0.03；
- Leverage 4-release change <= -0.03；
- 单信号保留50%计划美股减仓，双信号保留100%；
- broad de-risk 使用 Generic100；
- 严格 T-1；
- 决策影子成本固定1.00% + 0.05%；
- C3/L3 overlay 的允许决策日期同样来自固定研究成本 shadow，不得由用户实际成交记录决定；
- 用户手续费只影响最终执行，不改变目标路径。

冻结前 retrospective 参考（不属于未来 OOS）：

- CAGR ~14.35%；
- MDD ~7.69%；
- Vol ~8.76%；
- Sharpe ~1.522；
- trades ~451；
- block63 Sharpe P2.5 ~1.221；
- block63 MDD P97.5 ~13.93%；
- 5/7时间折 Sharpe>1；
- 相对 V10 有6/7时间折 MDD不高；
- 1.00% / 0.03% target fingerprint = `ba67c8aa24bc7168`。

## 简化来源

本候选不是通过继续扫描参数得到：

- A股5% exit sentinel 通过独立删除、7折和bootstrap后判定冗余；
- 1.24 / 1.30 被折叠到策略原本已有的通用1.22，不搜索新的统一倍率；
- 24.4% 只测试自然25%圆整，不搜索其它带宽；
- V6/V7/V8 更激进的理论替代全部按预注册门槛 FAIL，并保留失败记录。

## 前瞻纪律

从 2026-08-15 冻结后：

- 不修改1.22；
- 不修改25% high-core / final band；
- 不修改50/50；
- 不修改 C3/L3 阈值；
- 不根据未来回撤重新加入已删除的哨兵；
- 不根据短期胜负恢复1.24/1.30；
- 任何逻辑变化必须建立新的注册表并重新计时；
- Candidate D / V1 的既有 prospective 数据不得重标为 Candidate E。

评估时点：63 / 126 / 252 / 504 个新交易日；252日为第一次主要 prospective OOS 判定。

Candidate E 在252个新交易日前只能称为“简化冻结前瞻候选”，不得宣称真正未来泛化已经通过。

## 前瞻账本正式启动记录

2026-08-15 已完成服务器端 append-only prospective ledger 上线。第一组真实冻结决策使用跨资产共同可用数据截止日 **2026-08-14**，下一执行日提示为 **2026-08-17**；这两条记录是在未来收益发生前由服务器上的同一 Swift `BacktestEngine` 计算并写入，不属于 retrospective 回测重算。

- Candidate D / DualCore V1：target fingerprint `19e4a12b8a0a39a2`；目标总风险仓约 **57.02%**、现金约 **42.98%**；当前无需调仓。
- Candidate E / Simplified V11：target fingerprint `50c817f267015ca6`；目标总风险仓约 **56.27%**、现金约 **43.73%**；当前无需调仓。
- 两条策略当时看到相同 NFCI 点时状态：Credit 8-release 未触发，Leverage 4-release **触发**。
- 初始不可变数据库记录：V1 payload SHA `caf23ded3d43d61de16d63e3c0e663b881be26308361eb353a7c80b664fa7a98`；V11 payload SHA `3bb6826696298a880f3a08afbda734c1412bd60c7b2e38e2d95095f7d2616f95`。
- 数据库唯一约束为 `(strategy_version, signal_date)`；重复计算不允许 UPDATE。
- 实际重复运行同一 2026-08-14 signal 后验证结果为 **`inserted=0, existing=2`**，数据库仍只保留原两条记录。
- 决策一致性现在由 Swift 生成的 causal input fingerprint 约束：只纳入共同 cutoff 之前真正可影响决策的市场/OHLC/FX 与 NFCI first-seen 输入；cutoff 后新增数据和机器浮点尾数不会制造伪冲突，而真实因果输入、目标权重、NFCI状态或 engine version 变化会触发不可变性报警。

从本节记录开始，63 / 126 / 252 / 504 个新交易日的 prospective 计数才具有真正的未来 OOS 含义。第一主要判定仍严格等待 **252 个新交易日**，不得因短期胜负提前修改 V1 或 V11。
