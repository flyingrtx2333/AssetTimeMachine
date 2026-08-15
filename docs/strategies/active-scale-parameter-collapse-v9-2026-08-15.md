# Active Scale 参数折叠 V9 — 2026-08-15

状态：**候选和门槛先冻结，再运行。**

## 目的

V6–V8 说明：主动风险利用功能不能简单删除，也不能被单一波动/几何预算直接替代。但这并不证明 leader-specific 的 1.24 与 1.30 两个特例有必要。

V9 只做参数折叠，不发明新倍率：把所有 leader 的 active scale 统一为当前策略已经存在的通用 `1.22`。

## 固定候选

- V9-0 Current：当前 LowNoise + C3/L3，active scale = 通用1.22 / 美股确认1.24 / China1.30。
- V9-1 Unified122：三种 leader 全部使用现有通用 1.22；删除 V5 已确认冗余的 A股5% exit sentinel；其它规则全部不动，包括 24.4% hard band、1.15 low-vol top-up cap、9% volatility target、near-peak buffer、动态换手抑制、恢复袖套、风险贡献与 NFCI C3/L3。

不测试 1.20、1.21、1.23、1.24 或其它倍率。1.22 不是新优化值，而是现有默认通用 scale。

## 自由度变化

删除：

- 美股确认特例 1.24；
- China 特例 1.30；
- A股5% exit sentinel 规则簇。

保留一个通用 active scale 1.22。

## 验收门槛

V9-1 必须同时：

- full CAGR >= 14.0%；
- full Sharpe >= 1.50；
- full MDD <= 8.5%；
- 7折至少5折 Sharpe >1；
- worst-fold Sharpe >0；
- block63 Sharpe P2.5 >=1.15；
- block63 MDD P97.5 <=15%；
- 1.00% / 0.03% fee target fingerprint 相同。

若通过全部门槛且 full Sharpe 与 Current 差 <=0.035，则因减少两个 leader-specific 参数和一个历史补丁而优先考虑 V9-1；否则 FAIL，不再搜索统一倍率。

## 冻结后的结果

V9-1 `Unified122`：CAGR **14.932%**、MDD **7.670%**、Vol **9.003%**、Sharpe **1.539**、428 trades。5/7 时间折 Sharpe 不低于 Current，6/7 折 MDD 不高于 Current；block63 Sharpe P2.5=**1.235**，MDD P97.5=**14.56%**；full Sharpe 仅低 **0.0064**，正式 PASS。

费用不变性测试最初暴露出 C3/L3 overlay 使用实际 `report.trades` 作为允许调仓日的架构耦合；随后改为固定1.00%+0.05% shadow 的决策交易日历。修复后 V9 在1.00%和0.03%执行费下 target fingerprint 均为 `fc060655807b7e26`，且 TestFlight 180 DualCore V1 默认1%结果与 fingerprint 完全不变。该修复属于信号/执行层隔离，不改变冻结V1默认路径。
