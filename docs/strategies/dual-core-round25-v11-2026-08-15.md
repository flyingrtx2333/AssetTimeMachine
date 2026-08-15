# DualCore Round25 V11 — 2026-08-15

状态：**候选和门槛先冻结，再运行。**

## 固定候选

- V11-0：已通过的 Unified122 V10。
- V11-1 Round25：在 V10 基础上只做一项简化：LowNoise 高收益核心的 base hard band 与 NFCI high-core sleeve band 均从 `24.4%` 圆整为自然 `25%`。

其它全部保持 V10：统一 active scale=1.22、A股 exit sentinel 删除、50/50 DualCore、Cash Confidence 稳健核心、NFCI C3/L3、最终25% unified band、9% volatility target、1.15 low-vol cap、near-peak buffer、动态换手抑制均不变。

不测试 23%、24%、26%、27% 或其它带宽。

## 目的

消除策略中剩余的明显历史小数 `24.4%`。如果 25% 仅造成很小的风险收益损失且通过固定门槛，则优先选择更自然、可解释的25%。

## 验收门槛

V11-1 必须同时：

- full CAGR >=14.0%；
- full Sharpe >=1.50；
- full MDD <=8.5%；
- 与 V10 full Sharpe 差 <=0.025；
- 7折至少5折 Sharpe>1；
- worst-fold Sharpe>0；
- block63 Sharpe P2.5>=1.15；
- block63 MDD P97.5<=15%；
- 至少4/7折 Sharpe不低于 V10，或者至少6/7折 MDD不高于 V10；
- 1.00% / 0.03% fee target fingerprint相同。

若通过则 V11 成为新的简化优先研究候选；否则保留 V10 的24.4%，不继续搜索带宽。

## 冻结后的结果

| 版本 | CAGR | MDD | Vol | Sharpe | Trades |
|---|---:|---:|---:|---:|---:|
| Unified122 V10 | 14.414% | 7.689% | 8.756% | 1.530 | 455 |
| **Round25 V11** | **14.345%** | **7.689%** | **8.761%** | **1.522** | **451** |

V11 正式 **PASS**。5/7折 Sharpe>1，worst-fold Sharpe=0.741；block63 Sharpe P2.5=**1.221**，MDD P97.5=**13.93%**；6/7折 MDD 不高于 V10，full Sharpe 仅低 **0.0075**。1.00% 与0.03% fee 下 target fingerprint 均为 `ba67c8aa24bc7168`。因此新简化候选可将 high-core 的 24.4% hard band 圆整为自然25%，不再保留24.4%。
