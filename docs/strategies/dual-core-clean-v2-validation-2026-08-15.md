# DualCore Clean V2 冻结验证 — 2026-08-15

状态：候选先冻结，再运行。

## 固定候选

- V1 Current：TestFlight 180 的 `NFCI 双核心（前瞻）`，50/50 DualCore，不修改。
- V2 Clean：保持 50/50、NFCI C3/L3、Cash Confidence 稳健核心、最终25% unified band全部不变；只对高收益 LowNoise 核心做三项简化：
  1. LowNoise hard band 24.4% -> 25%；
  2. NFCI high-core sleeve band 24.4% -> 25%；
  3. leader-specific active scale 1.22/1.24/1.30 -> 单一 1.20；
  4. 删除 V5 已确认冗余的 A股5% exit sentinel。

不测试其它倍率、其它混合权重或其它带宽。

## 目标

用一个统一风险利用倍率替代三套 leader-specific 倍率，去掉一个历史补丁，并消除 24.4% 小数，同时尽量保持 DualCore V1 的风险收益特征。

## 验收门槛

V2 Clean 必须：full CAGR>=14%、Sharpe>=1.50、MDD<=8.5%；至少5/7时间折 Sharpe>1；worst-fold Sharpe>0；block63 Sharpe P2.5>=1.15、MDD P97.5<=15%；费用变化不得改变 target path。若 full Sharpe 与 V1 差<=0.04 且风险/时间折不明显恶化，则因自由度更少而允许作为新的简化研究版本，但不能回写或修改已冻结 V1 的 prospective OOS 记录。

## 冻结后的结果

| 版本 | CAGR | MDD | Vol | Sharpe | Trades |
|---|---:|---:|---:|---:|---:|
| DualCore V1 | **14.580%** | 7.689% | 8.828% | **1.534** | 460 |
| Clean V2 | 13.854% | **7.632%** | **8.588%** | 1.503 | 462 |

Clean V2 风险略低且 Sharpe 仍约 1.50，但 CAGR 低于预注册的 14% hard gate，因此正式 FAIL。不得因为只差约0.15pp而事后放宽门槛，也不继续搜索 1.18/1.22/1.25 或其它混合权重。TestFlight 180 的冻结 V1 不修改。
