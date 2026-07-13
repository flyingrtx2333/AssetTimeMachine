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

实际验证命令：

```bash
cd ~/Desktop/AllProjects/AssetTimeMachine

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

固定历史数据实测结果（2026-07-13 运行，数据截至 2026-07-03；交易费 1%、滑点 0.05%）：

| 产品策略 | 类型 | 全历史年化 | 全历史最大回撤 | 最近10年年化 | 最近10年最大回撤 | 全历史夏普 |
|---|---|---:|---:|---:|---:|---:|
| 进取风险预算 | 精选 | 10.50% | 14.09% | 6.62% | 12.63% | 1.02 |
| 均衡权益状态 | 精选 / 默认 | 9.60% | 13.02% | 5.67% | 13.02% | 1.01 |
| 稳健锁盈防守 | 精选 | 8.55% | 11.67% | 5.56% | 11.67% | 0.99 |
| 凸性极速空头组合 | 实验 | 11.73% | 13.47% | 11.23% | 13.47% | 1.04 |
| 风险贡献再分配 | 实验 | 10.57% | 9.79% | 9.15% | 9.49% | 1.15 |
| 双趋势金纳杠铃 | 独立 | 10.15% | 16.98% | 13.56% | 16.98% | 0.89 |

前三条精选策略共享黄金/权益元策略底座，分别代表进取、均衡和稳健风险档位。`双趋势金纳杠铃` 是独立双资产路线。两条实验策略分别承担不同目标：`凸性极速空头组合` 在三条底层逻辑的目标权重上加入3%的严格T−1指数空头模型，总风险最高110%，负现金按5%年化融资；该空头袖套是研究用反向收益模型，不代表可直接购买的单一产品。`风险贡献再分配` 先按40%高夏普状态机、25%进取风险预算和35%双趋势金纳统一融合，并按底层仓位共识使用1.00/1.20/1.40倍风险档；每42个交易日估计最多126日协方差，当单一资产风险贡献超过65%时，将60%目标权重向低波动、低正相关资产重新分配。它还加入严格T−1的美股弱势跳增制动：美股既有仓位至少10%、目标拟一次增加10%至20%，且纳指与标普近5日动量同时转负时，只执行新增仓位的60%；正常减仓、普通增仓和大级别状态切换不受影响。当前固定基线中，该规则只影响2010与2012两次调仓，最近十年、2020年后和2022年后指标均保持不变。目标变化超过8%才成交。它替换了较弱的共识变速版本，但仍未达到8%最大回撤目标，也不会替换默认的“均衡权益状态”。所有数字均已扣除1%交易费与0.05%滑点，夏普继续按日收益、零无风险利率计算。

当前后端序列按价格变化计算，回测引擎不会额外注入股票股息再投资；若未来接入总回报指数，需要建立新的独立基线，不能与当前数字直接混用。


新策略研究只能新增 Swift `StrategyTargetProvider`/Swift CLI 搜索入口，并必须通过同一个 `BacktestDailySimulator` 与 pinned fixture baseline 验证后，才能更新 README 或 App 可见指标。

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

项目已进入 **持续迭代 / TestFlight 发布阶段**，当前版本 1.10。

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
- 多语言（中英字符串目录）、通知服务、新手引导

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
