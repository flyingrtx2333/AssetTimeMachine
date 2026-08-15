# 几何中点风险预算 V8 — 2026-08-15

状态：**候选、机制和门槛先冻结，再运行结果。**

## 目的

V7 证明“仅按 forecast vol 比例连续缩放”不能替代 LowNoise 的主动风险利用。V8 不再把风险利用大小直接绑定到波动率数值，而把 9% forecast-volatility 仅作为“环境足够平稳”的资格条件；一旦资格条件成立，风险仓位从当前 gross 向 100% 上限只推进到几何中点。

## 冻结机制

沿用当前 LowNoise 已存在的资格条件：

- leader 不是黄金；
- gross >= 20% 且 < 100%；
- Nasdaq 与 S&P500 都在 MA200 上方；
- 两者 126 日动量都 > 0；
- 基础策略距离 252 日高点回撤 <= 3%；
- 63 日预测组合波动 < 9%；
- 20 日短波动 <= 63 日波动。

资格成立时：

`targetGross = sqrt(currentGross * 1.0)`

等价于：

`scale = sqrt(1.0 / currentGross)`

最终仍 capped at gross<=100%。它没有 leader-specific 倍率，也没有额外 scale cap。

例如 gross 为 50% / 60% / 70% / 80% 时，新 gross 分别为约 70.7% / 77.5% / 83.7% / 89.4%。

其它规则：

- 删除 1.15 scale cap；
- 删除 1.22 / 1.24 / 1.30；
- 删除 V5 已确认冗余的 A股 5% exit sentinel；
- 保留 24.4% hard band，本轮不同时优化交易带；
- 保留 near-peak buffer、动态换手抑制、风险贡献、恢复袖套、NFCI C3/L3；
- 不融资、不做空、gross<=1，严格 T-1；
- 1% fee + 0.05% slippage，费用不得改变 target path。

## 固定候选

- V8-0 Current：当前 LowNoise + C3/L3。
- V8-1 GeometricHeadroom：上述几何中点风险预算。

不增加第三候选，不测试算术中点、0.4/0.6权重、其它波动阈值或其它 gross 目标。

## 验收门槛

V8-1 必须同时：

- full CAGR >= 14.0%；
- full Sharpe >= 1.50；
- full MDD <= 8.5%；
- 7 折至少 5 折 Sharpe > 1；
- worst-fold Sharpe > 0；
- block63 Sharpe P2.5 >= 1.15；
- block63 MDD P97.5 <= 15%；
- 1.00% / 0.03% fee target fingerprint 相同。

若 full Sharpe 与 Current 差 <=0.035 且通过全部门槛，则因删除 1.15、1.22、1.24、1.30 四个自由度和 A股哨兵而优先考虑简化版；否则按协议 FAIL，不继续调中点位置。

## 冻结后的结果

V8-1 `GeometricHeadroom`：CAGR **12.504%**、MDD **9.253%**、Vol **7.973%**、Sharpe **1.468**、448 trades。第一层 full gates 即 FAIL，因此不继续调中点位置或做候选扩展。
