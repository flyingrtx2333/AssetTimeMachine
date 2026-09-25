# 资产时光机 / Asset Time Machine

一个面向个人的 iPhone 本地资产记录与走势分析应用。

> 核心目标不是做复杂记账，而是按天记录自己的总财富状态，长期观察总资产、净资产和资产构成如何变化。

## 产品定位

资产时光机是一款 **本地优先（local-first）** 的个人财富记录工具。

它的核心是：

- 每天记录自己的总资产状态
- 默认继承前一天数据，只改变化项
- 自动计算总资产、总负债、净资产
- 观察财富随时间的走势与结构变化

黄金等值、BTC 等值、纳指等值、房价等值等，属于 **额外分析视角**，不是产品主功能。

## 平台策略

- 当前仅维护 iOS / iPhone 版本
- SwiftUI + SwiftData 单端 iOS 工程
- 优先优化 iPhone 的录入、查看、分析、导入导出体验
- 暂不维护 macOS 目标

## 核心功能

### 1. 每日资产记录

按天记录个人资产快照，自动汇总：

- 总资产
- 总负债
- 净资产

默认行为：

- 第一天手动录入
- 后续日期默认继承前一天数据
- 用户只修改当天发生变化的项目
- 若某天未更新，则资产状态默认保持不变

### 2. 资产走势分析

围绕总财富做长期观察：

- 今日总资产 / 净资产
- 较昨日、上周、上月变化
- 历史走势曲线
- 历史高点 / 低点
- 最大回撤
- 阶段涨跌幅

### 3. 资产构成分析

查看自己的财富结构如何变化：

- 金融资产占比
- 实物资产占比
- 负债占比
- 各资产小类占比

### 4. 时光机视图

查看任意一天的财富状态：

- 当天总资产 / 净资产
- 当天资产构成
- 与今天对比
- 与历史高点对比
- 历史关键变化回顾

### 5. 额外价值锚点分析

在核心资产记录之外，提供附加分析视角：

- 黄金等值
- BTC 等值
- 纳指等值
- 房价等值

这些功能用于帮助理解财富变化，不替代总资产主视图。

### 6. 数据导入导出

- 本地 JSON 导出
- 本地 JSON 导入
- 便于备份、迁移、后续同步扩展

### 7. 量化策略回测

App 内策略指标必须以当前 Swift `BacktestEngine` 的实际运行为准。策略只允许通过 Swift target provider 输出目标仓位；成交、费用、滑点、现金收益、持仓、净值和指标统一由 `BacktestDailySimulator` 计算。

当前产品口径：

- 回测引擎：`AssetTimeMachine/Backtest/BacktestEngine.swift`
- 统一底座：`MarketDataFrame`、`StrategyTargetProvider`、`BacktestExecutionConfig`、`BacktestDailySimulator`
- 产品策略库：`AdvancedBacktestStrategyTemplate.productCatalog`
- 完整研究策略库：`AdvancedBacktestStrategyTemplate.all`
- 行情数据：`https://api.flyingrtx.com/api/v1/money/public/history`
- 回测区间：全历史，按各策略可用数据起点自动决定
- 初始资金：100,000 CNY
- App 默认交易费：1.00%
- App 默认滑点：0.05%
- 夏普比率：按日收益计算，当前采用无风险利率为 0 的口径

1% 交易费是产品默认和基线口径，不得为了改善回测数字擅自降低。成本敏感性测试可以通过环境变量临时运行，但不能替代 App 默认结果。

固定快照验证命令（只验证对应冻结输入下的可复现性，不代表当前线上表现）：

```bash
xcrun swiftc \
  -parse-as-library \
  -module-cache-path /private/tmp/atm-swift-module-cache \
  AssetTimeMachine/Backtest/BacktestModels.swift \
  AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift \
  AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift \
  AssetTimeMachine/Backtest/BacktestFXConverter.swift \
  AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift \
  AssetTimeMachine/Backtest/BacktestEngine.swift \
  tools/strategy_metric_dump.swift \
  -o /private/tmp/strategy_metric_dump

ATM_HISTORY_FIXTURE=tools/fixtures/backtest-history/public_history.json \
  /private/tmp/strategy_metric_dump --verify-app-baseline

ATM_HISTORY_FIXTURE=tools/fixtures/backtest-history/public_history.json \
  /private/tmp/strategy_metric_dump \
  --verify-app-baseline \
  --baseline tools/expected_backtest_metrics/app/current_app_default.json
```

历史精选策略固定基准（2026-08-10 刷新，行情有效至 2026-08-07；交易费 1%、滑点 0.05%）：

| 精选策略 | 全历史年化 | 全历史最大回撤 | 最近10年年化 | 最近10年最大回撤 | 全历史 Sharpe |
|---|---:|---:|---:|---:|---:|
| 低噪增强（当前推荐） | 14.44% | 7.93% | 13.42% | 7.58% | 1.508 |
| 进取配置 | 10.55% | 14.09% | 6.71% | 12.66% | 1.020 |
| 均衡配置 | 9.63% | 13.02% | 5.68% | 13.02% | 1.010 |
| 金纳双趋势 | 10.20% | 16.93% | 13.94% | 16.93% | 0.904 |
| 防守配置 | 8.58% | 11.67% | 5.55% | 11.67% | 0.992 |

上表是冻结 fixture 的历史回归基线，**不是当前线上策略成绩，也不能直接用于产品推荐或发布文案**。当前线上复跑必须使用生产 API、当前 Swift 引擎和当前成本，并单独记录抓取时间、逐序列末日、输入 SHA-256、代码 HEAD 与结果窗口；禁止以旧 fixture 的漂亮数字覆盖线上复跑。

`低噪增强`的完整生产逻辑、执行时序、参数、回测切片与风险边界见
[`docs/strategies/low-noise-enhanced.md`](docs/strategies/low-noise-enhanced.md)。它在最终产品层严格限制总风险资产仓位不超过 100%，不允许融资或负现金。

当前后端序列按价格变化计算，回测引擎不会额外注入股票股息再投资；若未来接入总回报指数，需要建立新的独立基线，不能与当前数字直接混用。

新策略研究只能新增 Swift `StrategyTargetProvider`/Swift CLI 搜索入口，并必须通过同一个 `BacktestDailySimulator` 与 pinned fixture baseline 验证后，才能更新 README 或 App 可见指标。

新的研究工作材料统一放在位于相邻 FlyingrtxFast 仓库的 `research/asset-time-machine/workspace/` 目录：策略家族与非正式测试在 `strategies/`，因子工作在 `factors/`，研究简报在 `studies/`，通用研究工具在 `tools/`。正式 ATM-SVP 的 preregistration、数据清单、结果和 Git 提交仍必须保留在本仓库的 `tools/research-results/strategy-validation/`，以维持可复现和审计边界。

### 冻结研究、当前线上复跑与点时宏观数据

- **冻结 fixture / 正式历史工件**回答“该历史实验当时在那份输入与代码下产生了什么”；它们不可重写，但不自动等于当前 App 成绩。
- **当前线上复跑**回答“当前 App 引擎在生产行情库的当前可用输入下如何表现”。它是 `POST_HOC_CURRENT_REPLAY`，不消耗或替代正式验证预算，也不单独构成策略准入证据。
- 线上复跑使用 `https://api.flyingrtx.com/api/v1/money/public/history`，默认不得带 `refresh=true`，除非用户明确授权服务器刷新。美元资产必须同时请求 `usd_per_cny`，并记录每条序列实际末日，不能只看请求结束日期。
- 涉及 NFCI 的策略必须从 `https://api.flyingrtx.com/api/v1/money/public/nfci-asof` 取得含 `release_date`、`reference_date`、`available_at` 的首次可见/as-of 记录；**不得**用当前修订版 FRED/ALFRED 序列或观察期日期替代可用时间。
- 任何线上复跑都须保存原始响应及归一化输入的 SHA-256、接口/环境、抓取时间、代码 HEAD、引擎与成本配置、覆盖末日和全部报告窗口。若与旧工件不同，只能报告差异，不得回头调参“救回”旧结果。
- V11 的旧冻结结果（14.35% CAGR / 7.69% MDD / 1.52 Sharpe）仅为历史 ATM-SVP 工件，且仍有 `G3 PARTIAL`、`G4 INVALID_SOURCE_UNAVAILABLE`、`G6 RUNNING` 等限制。2026-09-04 的服务器当前回放为全史 6.03% CAGR / 15.86% MDD / 0.686 Sharpe；详见研究归档 `../FlyingrtxFast/research/asset-time-machine/workspace/studies/v11-online-replay-2026-09-04/ONLINE_REPLAY.md`。V11 不是当前推荐、准入或对外宣传基线。

## 资产分类设计

一级分类固定，二级项目由用户自定义。

### 一级分类

#### 1. 金融资产

例如：

- 现金
- 银行存款
- 股票
- 基金
- 数字货币
- 理财
- 黄金
- 外币资产

#### 2. 实物资产

例如：

- 房产
- 车产
- 手机
- 电脑
- 收藏品
- 其他大件资产

#### 3. 负债

例如：

- 花呗
- 白条
- 美团月付
- 信用卡欠款
- 房贷
- 车贷
- 消费贷
- 其他借款

### 二级项目

用户可以自由增加自己的细项，例如：

- 招行活期
- 建行定存
- 微信零钱
- 币安 BTC
- 家庭房产
- 房贷 A

## 数据录入设计

每个资产项目支持两种计价方式：

### 1. 直接金额

适合：

- 现金
- 银行存款
- 理财市值
- 房产估值
- 各类负债

### 2. 数量 × 单价

适合：

- 黄金
- BTC
- 外币
- 某些股票/基金
- 房产面积 × 单价（后续可扩展）

## 设计原则

### 1. 本地优先

所有核心数据默认保存在本地，优先保证隐私与可控性。

### 2. 先总量，后解释

先解决“我一共有多少资产、怎么变了”，再解决“用什么尺度理解这些变化”。

### 3. 尽量减少用户重复录入

默认继承前一天数据，让记录动作更像“确认今天的财富状态”，而不是每天重填一张表。

### 4. 固定大类，可配置小类

保证分析维度稳定，同时保留用户个性化资产结构。

## 技术方案

- SwiftUI + SwiftData
- Apple Charts 走势图
- Xcode iOS 工程，TestFlight 分发

## 当前进度

项目已进入 **持续迭代 / TestFlight 发布阶段**，当前 TestFlight 版本为 1.13。

已完成并在线上运行的功能：

- 每日资产快照记录，默认继承前一天数据，自动汇总总资产 / 总负债 / 净资产
- 仪表盘走势图与统计卡片，历史高低点、最大回撤、阶段涨跌
- 时光机视图：查看任意一天的财富状态与构成，并与今天 / 历史高点对比
- 资产构成分析（大类占比、细项占比）
- 价值锚点分析：黄金 / BTC / 纳指 / 房价等值
- 本地 JSON 导入导出，走势视频导出
- 云同步（AssetTimeMachine cloud，经 Flyingrtx 后端）
- 行情数据接入 `https://api.flyingrtx.com`，含本地缓存
- 量化策略回测模块：内置高级策略模板、单资产 / 多资产 / 轮动策略、回测历史记录与调仓提醒
- 多语言（简中、繁中、英文字符串目录）、通知服务、聚焦资产记录的新手引导

当前迭代重心：

- 回测引擎重构与指标基线固化（golden metrics 固定 fixture 校验）
- 策略模板持续筛选与调优（以 App 引擎实测为准）
- App Store / TestFlight 发布节奏维护

## 项目信息

- 中文名：资产时光机
- 英文名：Asset Time Machine
- Xcode Project：`AssetTimeMachine`
- Bundle ID：`com.flyingrtx.AssetTimeMachine`

---

如果后续产品定义更新，请优先同步本 README，避免文档和实现方向再次跑偏。
