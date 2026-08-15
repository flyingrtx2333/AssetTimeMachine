# DualCore Unified122 V10 — 2026-08-15

状态：**候选和门槛先冻结，再运行。**

## 固定候选

- V10-0 DualCore V1：TestFlight 180 冻结版本。
- V10-1 DualCore Unified122：50/50 DualCore、NFCI C3/L3、Cash Confidence 稳健核心、最终25% unified band全部不变；仅高收益 LowNoise 核心：
  - 通用 / 美股确认 / China active scale 全部统一为现有通用 `1.22`；
  - 删除已证实冗余的 A股5% exit sentinel；
  - 保留 24.4% high-core hard band、1.15 low-vol cap、9% volatility target、near-peak buffer、动态换手抑制及其它逻辑。

不测试其它倍率、其它50/50权重或其它交易带。

## 复杂度变化

最终策略减少：

- leader-specific 1.24 参数；
- leader-specific 1.30 参数；
- A股5% exit sentinel 规则簇。

保留一个统一 active scale 1.22。

## 验收门槛

V10-1 必须同时：

- full CAGR >=14.0%；
- full Sharpe >=1.50；
- full MDD <=8.5%；
- 与 V1 full Sharpe 差不超过0.020；
- 7折至少5折 Sharpe>1；
- worst-fold Sharpe>0；
- block63 Sharpe P2.5 >=1.15；
- block63 MDD P97.5 <=15%；
- 至少4/7折 Sharpe不低于V1，或者至少6/7折 MDD不高于V1；
- 1.00% / 0.03% fee target fingerprint完全相同。

若通过全部门槛，V10-1 成为“简化优先研究候选”；但不能覆盖 V1 自 2026-08-14 起已经冻结的 prospective OOS 序列，必须作为新版本独立登记。

## 冻结后的结果

| 版本 | CAGR | MDD | Vol | Sharpe | Trades |
|---|---:|---:|---:|---:|---:|
| DualCore V1 | 14.580% | 7.689% | 8.828% | 1.534 | 460 |
| **Unified122 V10** | **14.414%** | **7.689%** | **8.756%** | **1.530** | **455** |

V10 正式 **PASS**：5/7 时间折 Sharpe 不低于 V1，6/7 时间折 MDD 不高于 V1；block63 Sharpe P2.5=**1.232**，MDD P97.5=**13.83%**；full Sharpe 仅比 V1 低 **0.0041**。1.00% 与 0.03% fee 下 target fingerprint 均为 `93c230647f9ddc70`。因此 1.24、1.30 与 A股5% exit sentinel 可从新研究版本中删除。V1 prospective 序列保持冻结不变。
