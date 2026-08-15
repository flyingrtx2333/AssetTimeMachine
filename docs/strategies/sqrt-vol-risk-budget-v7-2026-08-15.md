# 平方根波动风险预算 V7 — 2026-08-15

状态：**候选、机制和门槛先冻结，再运行结果。**

## 目的

LowNoise 当前有两层风险利用机制：

1. 9% forecast-volatility target，线性缩放但单次额外限制为 1.15；
2. 按 leader 再乘 1.22 / 1.24 / 1.30。

前述审计表明，完全删除主动风险利用会显著损失 CAGR，但 1.22 / 1.24 / 1.30 本身具有甜点参数风险。V7 不搜索新的倍率，而是将这两层压缩为一个连续、无 leader-specific 参数的平方根波动预算。

## 冻结机制

仅当现有 LowNoise 的长期风险确认条件成立时：

- 当前 leader 不是黄金；
- gross >= 20% 且 < 100%；
- Nasdaq 与 S&P500 都在 MA200 上方；
- Nasdaq 与 S&P500 126 日动量都 > 0；
- 基础策略距离 252 日高点回撤 <= 3%；
- 63 日预测组合波动 < 9%；
- 20 日短期波动 <= 63 日预测波动；

风险缩放改为：

`scale = sqrt(0.09 / forecastVolatility)`

最终仍受 `gross <= 100%` 硬上限约束。

其它说明：

- 删除 1.15 单次 scale cap；
- 删除 leader-specific 1.22 / 1.24 / 1.30 active scales；
- 删除 V5 已确认冗余的 A股 5% exit sentinel；
- 保留 24.4% hard band，以隔离本轮只测试“风险利用机制”，不同时圆整交易带；
- 保留 near-peak buffer、动态换手抑制、恢复袖套、风险贡献、NFCI C3/L3；
- 不融资、不做空、gross<=1，严格 T-1，1% fee + 0.05% slippage；
- 费用只影响执行，不得改变目标路径。

## 固定候选

- V7-0 Current：当前 LowNoise + C3/L3。
- V7-1 SqrtVol：上述平方根波动风险预算 + 删除 A股 exit sentinel。

不增加第三候选，不测试其它指数（0.4、0.6）、其它 target vol（8%、10%）或其它 cap。

## 验收门槛

V7-1 要成为新的优先研究主线，必须同时：

- full CAGR >= 14.0%；
- full Sharpe >= 1.50；
- full MDD <= 8.5%；
- 7 折至少 5 折 Sharpe > 1；
- worst-fold Sharpe > 0；
- block63 Sharpe P2.5 >= 1.15；
- block63 MDD P97.5 <= 15%；
- 1.00% 与 0.03% fee 下 target fingerprint 相同。

若 full Sharpe 与 Current 差 <= 0.035 且通过全部门槛，则因删除 1.15、1.22、1.24、1.30 四个自由度以及 A股哨兵而优先考虑 V7-1；否则按协议 FAIL，不再调平方根指数或目标波动。

## 冻结后的结果

V7-1 `SqrtVol`：CAGR **12.625%**、MDD **9.446%**、Vol **7.909%**、Sharpe **1.492**、434 trades。CAGR <14%、MDD >8.5%、Sharpe <1.50，第一层 full gates 即 FAIL，因此按协议不继续做 fold/bootstrap，也不调整平方根指数或9%目标波动。
