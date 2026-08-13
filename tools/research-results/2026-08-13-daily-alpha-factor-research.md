# AssetTimeMachine 日频 Alpha 因子研究 — 2026-08-13

> 状态：研究中。生产策略未修改。
>
> 生产控制组：`riskContributionCashConfidenceLowNoise` / 无杠杆低噪增强
> - 年化 14.446908%
> - 最大回撤 7.931053%
> - 波动率 8.904863%
> - Sharpe 1.508859
> - 2020+ 年化 16.865344%
> - 近10年年化 13.441569%
> - 2022+ 年化 20.390228%
> - 454 笔交易
> - gross <= 1，融资天数 0

## 1. 研究目标

把此前以策略规则/参数搜索为主的实验升级成正式 Alpha 因子研究流程。生产候选优先只使用：

1. 已有资产日价格；
2. 如确有必要，再使用 VIX / VIX3M / DFII10 等稳定日频公开数据；
3. 不依赖复杂周频 vintage 数据。

任何因子不得因为“完整历史回测好看”而直接进入生产策略。

## 2. 当前研究流水线

### 2.1 Exact App factor panel

由 Swift 生产引擎生成：

- `tools/cash_confidence_factor_panel_dump.swiftpart`
- `tools/research-results/daily_factor_panel.csv`

共 6395 个交易日；控制组精确复现 14.446908% / 7.931053% / 454 trades。

### 2.2 因子动物园筛选

`daily_alpha_factor_lab.py`

- 182 个日频候选因子；
- 18 个预测目标；
- 3276 个 factor-target 检验；
- 动量、波动率、下行波动、回撤、均线距离、趋势效率、相对强弱、breadth、dispersion；
- VIX / VIX3M / 实际利率日频变换；
- strict close-t -> future return；
- overlapping forward return 使用 Newey-West HAC；
- 开发期 <= 2014；验证期 2015–2020；holdout 2021+；
- 开发期 Benjamini-Hochberg FDR；
- holdout 不进入初始 selection score。

### 2.3 条件/增量回归

`daily_alpha_incremental_regression.py`

控制当前生产策略目标仓位后检查：

- 标准化 conditional beta；
- Newey-West t；
- partial R²；
- validation ΔOOS R²；
- holdout ΔOOS R²；
- AR(1) persistence；
- raw persistent level（例如 DFII10 level）不允许直接晋级。

### 2.4 五资产横截面 Rank IC

`daily_cross_sectional_factor_lab.py`

每天在黄金、Nasdaq、S&P500、CSI300、上证五个 sleeve 内排名，计算：

- daily cross-sectional Spearman Rank IC；
- Top2-Bottom2 forward spread；
- Newey-West t；
- BH multiple-testing correction；
- dev / validation / holdout。

### 2.5 控制生产权重后的横截面增量 Alpha

`daily_cross_sectional_incremental.py`

逐日做：

`future return rank ~ production target-weight rank + candidate factor rank`

再对每日 candidate beta 时间序列做 Newey-West 检验。

这是判断“候选因子究竟是现有策略的重新包装，还是仍有独立预测信息”的核心测试。

## 3. 第一批真正值得保留的因子

### 3.1 RAM(60,20)

定义：60 日收益 / 20 日实现波动率，再在五资产横截面排名。

控制生产目标权重后的 5 日增量结果：

- dev beta +0.082
- NW t +3.47
- BH q 0.003746
- validation beta +0.047
- holdout beta +0.011
- 与生产目标权重平均 Rank correlation +0.304
- Top1 与生产目标 Top1 重合约 40.9%

结论：存在独立于当前配置权重的短周期横截面预测信息。

### 3.2 RAM(252,60)

定义：252 日收益 / 60 日实现波动率，再做横截面排名。

20 日 standalone cross-sectional：

- dev Rank IC +0.107
- NW t +2.89
- BH q 0.03453
- validation IC +0.024
- holdout IC +0.127
- validation Top2-Bottom2 +0.15%
- holdout Top2-Bottom2 +0.62%

控制生产权重后的 5 日增量：

- beta +0.068
- NW t +2.69
- BH q 0.0362
- validation beta +0.049
- holdout beta +0.044
- 与生产目标权重平均 Rank correlation +0.438
- Top1 重合率约 50.7%

结论：长期风险调整动量不是当前策略的简单重复。

### 3.3 因子冗余

- momentum60 vs RAM60/20：平均每日横截面 Rank correlation 0.884；同簇。
- momentum252 vs RAM252/60：0.893；同簇。
- RAM60/20 vs RAM252/60：0.429；可视为两个不同时间尺度的趋势簇。

因此不应同时把纯动量和风险调整动量重复加入模型。

## 4. 策略收益回归归因

生产策略日收益对 US / Gold / China 三个 sleeve return 的 HAC 回归：

- beta US ≈ 0.149
- beta Gold ≈ 0.269
- beta China ≈ 0.069
- R² ≈ 0.434
- 线性年化截距近似 8.335%
- intercept Newey-West t ≈ 6.31

注意：该截距只能说明“静态 US/Gold/China beta 无法解释全部策略收益”，不能直接宣称 8.335% 是纯 Alpha，因为策略包含动态时变暴露及可能遗漏的风险因子。

## 5. 经济实现测试

### 5.1 直接 Top2 因子袖套 — 拒绝

将当前组合 2.5% / 5% / 7.5% gross 混入 RAM60/20 + RAM252/60 Top2 因子组合：

- 每5日更新显著增加交易次数至约 746–807；
- 现代样本收益下降；
- 2021+ 激活同样没有改善。

结论：统计预测力没有覆盖交易成本及与基础组合的交互，拒绝“直接因子加仓”实现。

### 5.2 因子作为减仓确认器

事件级反事实归因：当基础策略降低总 gross，且卖出 RAM composite Top2 >= 5pp 时：

- 约 59–63 个事件；
- 5 日 base-trade edge 均值约 -0.32%；
- NW t 约 -2.96 至 -3.15；
- base trade 胜率约 27–29%。

短/长因子单独也复现：

RAM60/20 Top2 被卖：
- validation 5d edge -0.358%，base win 19%；
- holdout -0.458%，base win 30%。

RAM252/60 Top2 被卖：
- validation -0.378%，base win 22%；
- holdout -0.422%，base win 27%。

说明“基础策略短期过早卖出高排名资产”是真实而可解释的错误模式。

### 5.3 5 日临时减仓延迟 — 尚未晋级

精确 Swift、1% fee + 0.05% slippage、无杠杆：

- composite Top2 延迟25%：14.529297%，但 DD 8.584762% -> 违反 8%硬约束；
- RAM60/20 Top2 延迟25%：14.518878%，DD 8.582588% -> 拒绝；
- RAM252/60 Top2 延迟25%：14.466853%，DD 8.307695% -> 拒绝；
- RAM252/60 Top2 延迟25%，仅从2015+激活：14.518465% / DD 7.931053%，2020+ 17.171911%，2022+ 20.653455%，但 full Sharpe 1.504694 低于生产 1.508859，现代 Sharpe 也未全面改善。

结论：因子有预测能力，但当前“5日简单延迟”仍不是生产级实现。

## 6. 当前研究结论

### 成立

1. 正式因子研究方法对本项目是有效的；
2. RAM60/20 与 RAM252/60 是目前第一批通过统计筛选、横截面 IC、条件增量检验并具备经济解释性的日频因子；
3. 它们能解释基础策略的一类短期错误减仓；
4. 仅靠现有每日资产价格即可计算，不需要新增后台数据源。

### 不成立/已拒绝

1. “因子显著 -> 直接把Top2加进组合”；
2. 通过简单增加更新频率来兑现 5 日 IC；
3. 无条件延迟所有高排名资产减仓；
4. 仅凭完整历史收益选择参数。

## 7. 后续正式晋级门槛

下一候选必须同时满足：

1. 开发期统计显著并通过 multiple-testing correction；
2. validation 方向和经济收益保持；
3. holdout 不坍塌；
4. 控制生产权重后仍有增量预测力；
5. exact Swift App engine；
6. 1% fee + 0.05% slippage；
7. gross <= 1、融资 0；
8. full DD <= 8%；
9. full / recent / modern Sharpe 不出现明显退化；
10. ablation / event jackknife；
11. 候选策略出现后计算 Deflated Sharpe Ratio / backtest-overfitting diagnostics，并记录研究 trial count。

当前生产策略维持不变。
