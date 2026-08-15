# 资产时光机前瞻 OOS 注册表 V2 — DualCore

冻结日期：2026-08-14（在 V3 retrospective target-ensemble 验证完成之后）
状态：**冻结，等待未来数据**

本文件新增一个 V3 后才形成的候选，因此与较早的 `prospective-oos-registry-2026-08-14.md` 分开记录。V1 注册表中的 A/B/C 不得被本文件覆盖。

## Candidate D — DualCore C3/L3 50/50 Target Blend

每天分别因果计算两套冻结目标：

1. `LowNoise + NFCI C3/L3`；
2. `CashConfidence + NFCI C3/L3 + static 1.30x risk budget`。

最终目标权重：

`0.50 * target_1 + 0.50 * target_2`

约束：

- 权重固定 50/50，不允许根据未来结果调整；
- 单账户统一执行；
- hard rebalance band = 25%；
- gross<=100%；
- 不融资、不做空、不允许负现金；
- NFCI 使用 first-seen / initial-release point-in-time；
- 决策影子成本固定 1.00% + 0.05%；
- 用户执行费用只影响最终成交，不改变目标路径。

冻结前 retrospective 参考（不属于未来 OOS）：

- CAGR ~14.58%；
- MDD ~7.69%；
- Sharpe ~1.535；
- 7个历史时间折里 4折 Sharpe 高于 C0；
- 7/7折 MDD 低于 C0；
- block63 MDD P97.5 ~14.09%。

## 对照组

- Production baseline：2026-08-14 审计后的 LowNoise；
- High-return research baseline：Candidate C / `LowNoise + C3/L3`。

## 前瞻纪律

从冻结时点后：

- 不调整 50/50；
- 不调整25%执行带；
- 不调整 C3/L3 阈值；
- 不根据未来某次回撤加入新 gate；
- 任何逻辑变化必须另建 V3 注册表并重新计时；
- 原版本失败必须保留。

评估时点与原注册表相同：63 / 126 / 252 / 504 个交易日；252日作为第一次主要 prospective OOS 判定。

主要观察：

1. 相对 LowNoise / Candidate C 的 active return；
2. realized Sharpe；
3. MDD 与 drawdown duration；
4. 交易成本与换手；
5. 7类历史风险状态之外是否出现新失效模式；
6. NFCI 事件实时 first-seen 数据完整性；
7. 用户手续费变化 target fingerprint 必须不变。

Candidate D 在252个交易日前只可称为“冻结前瞻观察候选”，不得因为短期表现好提前宣称正式泛化成功。

## 真实前瞻账本起点

服务器 append-only prospective ledger 已于 2026-08-15 上线。Candidate D 的第一条不可变真实决策记录以 **2026-08-14** 为 signal date、**2026-08-17** 为下一执行日提示，target fingerprint=`19e4a12b8a0a39a2`。该记录在后续收益发生前由冻结 Swift 引擎生成；重复运行同一 signal date 已验证只返回 existing，不允许 UPDATE。自此记录开始计入 Candidate D 的 63 / 126 / 252 / 504 新交易日前瞻序列。
