# 低噪增强结构平滑验证 V2 — 2026-08-14

状态：**候选和门槛先冻结，再运行**

本轮是 `retrospective-nested-optimization-v1` 之后的新独立研究轮次。上一轮已经看过全部结果，因此本轮不能修改 V1 的 winner 结论；V2 只回答“能否用更平滑、低自由度的结构替换已确认的甜点参数”。

## 1. 固定问题

现有 LowNoise + C3/L3 的两处模型风险：

1. `rebalanceBand=24.4%` 使用 hard-to-target 执行：一旦越界，就把全部偏差一次性打回目标，形成不连续跳变；
2. 主动收益缩放按 leader 使用约 `1.22 / 1.24 / 1.30` 三套离散倍率，在 ±10% 扰动下退化明显。

## 2. 新执行机制：trade-to-band-boundary

当已有持仓超出无交易带时，不再一次性交易到目标，而只交易到带宽边界：

- 超配：卖出 `current - target*(1+band)`；
- 低配：买入 `target*(1-band) - current`；
- 新建仓位仍按完整目标进入；
- 清仓仍完整退出。

该机制的目标是消除阈值 crossing 的净值跳变，不是提高历史收益。

## 3. 冻结候选

所有候选都叠加同一冻结 NFCI C3/L3，1% fee + 0.05% slippage，不融资，gross<=1。

- V2-0 `hard-current`：当前 LowNoise + C3/L3；hard band 24.4%，原 leader-specific active scale。基准。
- V2-1 `soft25-current-scale`：soft boundary band 25%，保留原 active scale。
- V2-2 `soft20-current-scale`：soft boundary band 20%，保留原 active scale。只用于检查 soft-band 宽平台，不因结果再新增 22.5/27.5。
- V2-3 `hard25-unified120`：hard band 25%，把所有 leader 的 active scale 统一为 1.20。
- V2-4 `soft25-unified120`：soft boundary 25% + 单一 active scale 1.20。
- V2-5 `soft25-no-active-scale`：soft boundary 25%，active scale=1.00，仅保留已有 9% 波动目标等其它机制。

候选到此结束；运行结果后不得追加 V2-6。

## 4. 验证

沿用 V1 固定的 7 个连续时间折：2012-07-05—2014、2015—2016、2017—2018、2019—2020、2021—2022、2023—2024、2025—latest。

同时报告：

- full CAGR / MDD / vol / Sharpe；
- 每折 CAGR / MDD / Sharpe；
- 63日 moving-block bootstrap；
- 相对 V2-0 的 fold-level active return；
- 参数敏感性：soft20 vs soft25 只判断平台，不选择中间值；
- 成本 target-path invariance。

## 5. 硬门槛

结构替代候选要进入“优先研究”必须同时：

1. full Sharpe >= 1.48；
2. full MDD <= 9%；
3. 7折中至少5折 Sharpe >1；
4. worst-fold Sharpe >0；
5. block63 Sharpe P2.5 >=1.15；
6. block63 MDD P97.5 <=15%；
7. 相对 V2-0 至少4/7折 Sharpe不差，或 full Sharpe差距不超过0.03且参数敏感性显著更平滑；
8. 不允许靠降低手续费改变目标路径。

最终排序优先级：

1. 结构平滑和参数平台；
2. time-fold robust score；
3. MDD；
4. 最后才看 full Sharpe/CAGR。

即使 V2-0 历史指标最高，也允许更平滑候选以小幅收益代价晋级研究主线；但不能牺牲到硬门槛以下。

## 6. 冻结后的实际结果

协议冻结后一次性运行 V2-0...V2-5；未追加新候选。保守起见，第7条相对基准门槛只使用明确可量化的“至少4/7折 Sharpe 不差于 V2-0”，没有事后发明“显著更平滑”的数值阈值帮助候选过关。

| 候选 | CAGR | MDD | Sharpe | 7折中 Sharpe>1 | 不差于V2-0折数 | block63 Sharpe P2.5 | block63 MDD P97.5 | 判定 |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| V2-0 hard-current | 15.21% | 7.93% | 1.546 | 5 | 7 | 1.238 | 14.58% | PASS |
| V2-1 soft25/current | 13.68% | 9.42% | 1.489 | 5 | 2 | 1.171 | 15.17% | FAIL |
| V2-2 soft20/current | 13.66% | 8.67% | 1.484 | 5 | 1 | 1.156 | 15.05% | FAIL |
| V2-3 hard25/unified1.20 | 14.43% | 7.66% | 1.496 | 5 | 3 | 1.178 | 14.70% | FAIL |
| V2-4 soft25/unified1.20 | 13.09% | 8.29% | 1.459 | 5 | 2 | 1.133 | 15.02% | FAIL |
| V2-5 soft25/no-active | 11.78% | 8.49% | 1.496 | 5 | 2 | 1.176 | 13.32% | FAIL |

Soft 20% 与 Soft 25% 的 full Sharpe 仅差约 0.005，说明 trade-to-boundary 本身确实减少了“单一带宽尖峰”；但它同时降低收益利用率、增加成交次数，而且在多数时间折不如 V2-0。因此本轮不能把“更平滑”误写成“更优”。

**V2 最终结论：FAIL to replace C0.** 当前 hard LowNoise + C3/L3 仍是本轮唯一通过全部预注册硬门槛的候选。下一轮如继续优化，必须建立新协议，不允许在 V2 内追加参数补考。
