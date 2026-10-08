# 期权期限结构：两个相反假说，固定D0研究

研究日期2026-09-06，Asia/Taipei。收益暴露前固定本文件；证据等级D0_EXPLORATORY_CURRENT_APP，非正式ATM-SVP，不授予G0—G6状态。本轮不改之前连续信息策略，不以试错方式调参。

## 新信息与经济假说

Cboe VIX是SPX期权隐含的30天波动率，VIX3M是约三个月隐含波动率。二者之比衡量短期风险相对于中期风险的集中程度；不是VIX期货价格曲线，不声称可以赚取期货展期收益。信号来自SPX期权，对纳指的映射不是同指数文献精确复现。两个竞争假说：A短期风险需求集中时风险资产仍可能继续承压，转向黄金；B集中保险需求反映恐慌风险补偿，做多纳指等待正常化。假说不是既有V11/HighCore/CorrVar组合或阈值微调，不使用标的历史收益/波动率作为输入。

来源：Cboe VIX term structure https://www.cboe.com/en/tradable-products/vix/term-structure/ ; VIX3M dashboard https://www.cboe.com/us/indices/dashboard/vix3m/ ; Cboe daily CSV https://cdn.cboe.com/api/global/us_indices/daily_prices/VIX_History.csv 和 https://cdn.cboe.com/api/global/us_indices/daily_prices/VIX3M_History.csv 。Fassas & Hourvouliades (2019), VIX Futures as a Market Timing Indicator, DOI 10.3390/jrfm12030113，只作不同期限风险与股票预测关系的机制背景，不把隐含波动率比值当作原论文期货曲线。

## 六个固定映射

每个App历史信号日S，取日期严格小于S的最新共同Cboe日收盘，确保即使指数晚于股票收盘仍至少跨完整日期隔离；下一App执行日才可交易。VIX与VIX3M必须同日真实观测，不分别填充后拼接。共同观测距S超过7个日历日或不存在时，两候选及曲线对照全现金；既不填0也不换源。normal表示VIX<=VIX3M，stress表示VIX>VIX3M。阈值1是曲线斜率符号的自然分界，无优化、平滑、止损或持有期调参。所有策略只在目标改变时发新指令。

经济候选（2个，同一研究家族的相反假说，不宣称两个互不相关的因子）：
- `defensive_gold` / 期限倒挂金纳防守001：normal持100%纳指，stress持100%黄金。
- `panic_premium` / 期限倒挂恐慌承接001：stress持100%纳指，normal持人民币活期现金。

预定对照（4个，不可事后改名为新策略）：
- `defensive_cash`：normal持100%纳指，stress持现金；检验候选A换成黄金的影响。
- `reverse_rotation`：normal持100%黄金，stress持100%纳指；候选A方向反转对照。
- `nasdaq`：持续100%持有纳指。
- `product`：当前App原样金纳双趋势，保留它自身的全部信号和调仓逻辑。

无杠杆、无做空、无借款、无数字资产或外部策略基金，目标及实际总暴露<=100%，现金非负。闲置现金仅用CashYieldCNY。研究不交易任何期货/期权/VIX产品。实际资产域仅gold_cny、nasdaq；usd_per_cny只用于账户转换。模拟价格角色不等同可交易ETF总回报或券商成交。

## 数据、执行与固定窗口

只读生产公开历史/api/v1/money/public/history，symbols=gold_cny,nasdaq,usd_per_cny，period=all，include_ohlc=true，不传refresh=true。原始响应和规范化输入均留SHA。Cboe CSV同样保留URL、抓取时间、内容哈希、日期覆盖及缺失同日数量。拒绝无效、重复、非正或非有限close，不猜CSV字段含义。全部数据截于2026-09-06，比较终点机械取三条市场序列和两条Cboe输入实际末日的最小值；开端固定2008-01-01，Cboe共同覆盖必须始于2008年前，否则本轮DATA_BLOCKED，不能事后换回测开端。Cboe源当前可下载历史并非逐日首发vintage认证，结果只能作探索证据。

账户初始人民币100000元。指标含2008-01-01初始现金锚点，不把它当市场报价。信号由Swift生成，成交/估值/费用/汇率/指标全部调用当前App BacktestDailySimulator/BacktestMetricsCalculator；Python只采集、编译、保存、审核与汇报，不算策略收益。

每笔费用0.025%（万2.5）；主场景滑点0，预先唯一压力场景每笔0.05%不利滑点。6映射×2场景=12项执行全部保留；不得看结果后改成本或扩大搜索。App产品默认费用不改。

固定报告窗口：full_2008、2008—2015、2016—2019、2016起、2020起、2022起；同一连续账户时间切片，不重置账户，不称作独立前瞻OOS。记录逐年收益、最大回撤峰谷、最小现金、平均/最大实际仓位、成交笔数、买卖成本、逐日目标与实际持仓。

## 证伪和判定轴

A的机制方向检查：全期CAGR及Sharpe是否同时高于reverse_rotation；B的描述性风险补偿检查：全期Sharpe是否高于defensive_cash（不同暴露未风险匹配，不作为独立alpha因果证明）。所有候选都分别判断：
1. 自身正式验证NOT_FORMAL_D0，独立审阅PENDING，不能因比较失败标成正式验证FAIL。
2. 目标CAGR>=20%且MDD<=10%。
3. 产品替代：主场景全期CAGR和Sharpe均更高、MDD不更高；2016起、2020起、2022起CAGR和Sharpe均不低于产品；压力场景全期CAGR和Sharpe不低于产品。每一条件分别留存，不能只展示过关的窗口。

若历史表现有吸引力，最多记D0_REVIEW_REQUIRED；不能加入推荐或真实交易。收益暴露前完成合成单测、未来数据污染/截断前缀检查、日期与费用核对、作者复核、源文件/资源/二进制与输入哈希冻结。暴露后发现实现错误按INVALID保留，不事后修复重跑挽救成绩。所有结果更新本地总表；只有真实远程写入与回读后才记同步成功。

## 未纳入收益搜索的持仓路线

CFTC持仓报告的统计日不等于发布日期，2018—2019、2023和2025等期间有延迟及补发。仅凭年度CSV不能认证当日可见信息。该路线本轮只做来源资格审计，不读取完整持仓序列、不测试收益、不算成新候选；待逐份可用时间及修订证据齐备再另立研究。官方说明：https://www.cftc.gov/MarketReports/CommitmentsofTraders/HistoricalViewable/index.htm 和 https://www.cftc.gov/MarketReports/CommitmentsofTraders/HistoricalSpecialAnnouncements/index.htm 。
