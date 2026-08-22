# ATM-SVP-2 正式研究收益-风险前沿诊断 — 2026-08-22

状态：**DIAGNOSTIC ONLY — 不构成新 trial，不允许据此回头调已失败候选。**

本报告只读取已经落账的正式结果 JSON，并加入冻结 V11 控制线。它用于回答“当前正式证据距离高收益目标还有多远”，不生成新信号、不搜索参数。

## 核心结论

- 唯一正式候选数：**33**；另加冻结 V11 控制。
- 全部正式记录中最高 CAGR：**16.153%**（F-CURVE），对应 MDD **18.779%**、Sharpe **1.232**。
- 最高 Sharpe：**1.522**（V11-CONTROL），CAGR **14.346%**、MDD **7.689%**。
- `CAGR >=20% 且 MDD <=10%`：**0 个**。
- `CAGR >=18% 且 MDD <=10%`：**0 个**。
- 当前 formal result 中 `robust_factor_pass=true`：**0 个**。

## 最大回撤约束下的最高历史 CAGR

| MDD 上限 | 最高 CAGR | 候选 | MDD | Sharpe |
|---:|---:|---|---:|---:|
| 8% | 14.346% | V11-CONTROL | 7.689% | 1.522 |
| 10% | 14.607% | F-MOVE | 8.521% | 1.504 |
| 12% | 14.607% | F-MOVE | 8.521% | 1.504 |
| 15% | 16.067% | F-CREDITCASH | 12.777% | 1.378 |
| 20% | 16.153% | F-CURVE | 18.779% | 1.232 |

## 三维 Pareto 前沿（高 CAGR / 高 Sharpe / 低 MDD）

| 候选 | CAGR | MDD | Sharpe | Trial |
|---|---:|---:|---:|---|
| V11-CONTROL | 14.346% | 7.689% | 1.522 | FROZEN-V11 |
| F-MOVE | 14.607% | 8.521% | 1.504 | ATM-SVP2-LIT-STRESS-001 |
| F-TIC-FLOW-CONTRARIAN-US | 14.434% | 8.613% | 1.516 | ATM-SVP2-TIC-001 |
| F-MARGIN-LEV-US | 14.440% | 8.613% | 1.517 | ATM-SVP2-MARGIN-001 |
| F-CREDITCASH | 16.067% | 12.777% | 1.378 | ATM-SVP2-ORTHO-FACTOR-006 |
| F-VRP-PROXY | 14.768% | 13.380% | 1.412 | ATM-SVP2-VRP-001 |
| F-CURVE | 16.153% | 18.779% | 1.232 | ATM-SVP2-ORTHO-FACTOR-001 |

## 全部正式候选（按 CAGR 降序）

| 候选 | CAGR | MDD | Sharpe | Robust | Trial |
|---|---:|---:|---:|---|---|
| F-CURVE | 16.153% | 18.779% | 1.232 | NO | ATM-SVP2-ORTHO-FACTOR-001 |
| F-CREDITCASH | 16.067% | 12.777% | 1.378 | NO | ATM-SVP2-ORTHO-FACTOR-006 |
| F-BIOTECH | 15.656% | 19.086% | 1.368 | NO | ATM-SVP2-ORTHO-FACTOR-005 |
| F-VIXTERM | 15.508% | 21.156% | 1.341 | NO | ATM-SVP2-ORTHO-FACTOR-006 |
| F-VVIX | 15.318% | 19.096% | 1.276 | NO | ATM-SVP2-ORTHO-FACTOR-006 |
| F-GROWTHBOND | 15.119% | 19.325% | 1.261 | NO | ATM-SVP2-ORTHO-FACTOR-005 |
| F-VRP-PROXY | 14.768% | 13.380% | 1.412 | NO | ATM-SVP2-VRP-001 |
| F-MOVE | 14.607% | 8.521% | 1.504 | NO | ATM-SVP2-LIT-STRESS-001 |
| F-TRANSPORT | 14.505% | 17.190% | 1.242 | NO | ATM-SVP2-ORTHO-FACTOR-005 |
| F-MARGIN-LEV-US | 14.440% | 8.613% | 1.517 | NO | ATM-SVP2-MARGIN-001 |
| F-TIC-FLOW-CONTRARIAN-US | 14.434% | 8.613% | 1.516 | NO | ATM-SVP2-TIC-001 |
| F-BREADTH | 14.425% | 9.102% | 1.470 | NO | ATM-SVP2-ORTHO-FACTOR-003 |
| F-HIGHBETA | 14.392% | 8.521% | 1.494 | NO | ATM-SVP2-ORTHO-FACTOR-004 |
| F-EPU | 14.376% | 8.824% | 1.485 | NO | ATM-SVP2-LIT-STRESS-001 |
| V11-CONTROL | 14.346% | 7.689% | 1.522 | CONTROL | FROZEN-V11 |
| F-HESHARE-US-COMPLETION | 14.344% | 18.978% | 1.403 | NO | ATM-SVP2-HESHARE-001 |
| F-BANKS | 14.325% | 8.521% | 1.485 | NO | ATM-SVP2-ORTHO-FACTOR-004 |
| F-INDUTIL | 14.321% | 8.521% | 1.465 | NO | ATM-SVP2-ORTHO-FACTOR-004 |
| F-NET-PAYOUT-YIELD-US | 14.321% | 7.689% | 1.518 | NO | ATM-SVP2-NPY-001 |
| F-CYCLICAL | 14.286% | 8.582% | 1.456 | NO | ATM-SVP2-ORTHO-FACTOR-003 |
| F-SLOOS-STANDARDS | 14.257% | 8.574% | 1.468 | NO | ATM-SVP2-SLOOS-001 |
| F-SEC-INSIDER-BUY-BREADTH-US | 14.243% | 8.060% | 1.489 | NO | ATM-SVP2-INSIDER-001 |
| F-CREDIT | 14.222% | 8.574% | 1.450 | NO | ATM-SVP2-ORTHO-FACTOR-003 |
| F-BDLEV-ANNUAL-US | 14.210% | 8.628% | 1.488 | NO | ATM-SVP2-BDLEV-001 |
| F-COT-LEV-SPX | 14.199% | 8.060% | 1.489 | NO | ATM-SVP2-COT-001 |
| F-BAA | 14.154% | 8.589% | 1.443 | NO | ATM-SVP2-LIT-STRESS-001 |
| HR-B | 13.834% | 13.003% | 1.300 | NO | ATM-SVP2-HR-ARCH-001 |
| F-SIZE | 8.059% | 25.837% | 0.740 | NO | ATM-SVP2-ORTHO-FACTOR-001 |
| F-USD | 6.476% | 45.873% | 0.604 | NO | ATM-SVP2-ORTHO-FACTOR-001 |
| F-COPGOLD | 6.052% | 41.662% | 0.570 | NO | ATM-SVP2-ORTHO-FACTOR-002 |
| HR-C | 4.464% | 24.022% | 0.447 | NO | ATM-SVP2-HR-ARCH-001 |
| F-SKEW | -1.762% | 82.020% | -0.091 | NO | ATM-SVP2-ORTHO-FACTOR-002 |
| HR-A | -6.093% | 77.972% | -0.359 | NO | ATM-SVP2-HR-ARCH-001 |
| F-FUNDING | -6.694% | 94.520% | -0.517 | NO | ATM-SVP2-ORTHO-FACTOR-002 |

## 解释

正式研究样本里，没有任何候选同时达到 18%/20% 年化与 <=10% 最大回撤。这个事实不证明数学上绝无可能，但它说明在当前资产集合、long-only/无融资约束、现有 V11 周边 overlay 架构下，继续做小参数变化缺乏证据基础。

下一轮应优先研究**新的独立收益源或新数据域**，而不是再扩大原有事件保留比例、lookback、threshold 或 gross 微调。任何新候选仍需按 ATM-SVP-2 先冻结再运行。
