# 单一连续风险预算替代 V6 — 2026-08-15

状态：候选先冻结，再运行。

## 假设

LowNoise 当前同时存在两层“风险利用”机制：
1. 9% forecast-volatility target，但单次 scale 被硬限制为 1.15；
2. 随 leader 再乘 1.22 / 1.24 / 1.30。

这两层功能高度重叠，后三个倍率又已显示参数甜点风险。V6 不搜索新倍率，而是删除 leader-specific active scale，并取消 1.15 的额外 scale cap，让已有 9% volatility target 自己连续决定风险利用；总 gross<=1 仍是最终硬上限。因此新增参数数量为 0，反而删除 4 个自由度（1.15、1.22、1.24、1.30）。

## 冻结候选

- V6-0 Current：当前 LowNoise + C3/L3。
- V6-1 SingleVolBudget：hard band 固定自然值25%；删除 1.22/1.24/1.30；删除已在 V5 判定冗余的 A股5% exit sentinel；保留 near-peak buffer 和动态换手抑制；保留 9% volatility target，但不再额外限制为1.15倍，唯一上限是 gross<=100%。

不增加第三候选，不测试8.5%、9.5%、1.18、1.25等参数。

## 验收

沿用 7 连续时间折和 block63 bootstrap。V6-1 若要进入新主线，必须：full CAGR>=14%、Sharpe>=1.48、MDD<=9%；至少5/7折 Sharpe>1；block63 Sharpe P2.5>=1.15、MDD P97.5<=15%；且费用变化不改变 target path。若与 Current 的 Sharpe差<=0.035且满足上述门槛，则因删除4个自由度优先考虑简化版。

## 冻结后的结果

V6-1 `SingleVolBudget`：CAGR **11.964%**、MDD **12.593%**、Sharpe **1.360**、496 trades。直接未通过 full hard gates，因此按协议 FAIL，不再搜索新的 volatility target 或 scale cap。结论：现有 9% volatility top-up 与 leader-specific active scale 虽功能相关，但不能简单合并为“无额外scale cap的单一波动目标”。
