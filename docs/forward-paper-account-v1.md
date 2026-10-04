# 独立前瞻记账工具 v1

这是工程验证用的信号跟随模拟账户，当前支持 NFCI V1、V11。策略计算及成交结算均调用共享 Swift 核心。它不使用原冻结账本的历史模型持仓作为初始持仓，也不改变原 G3/G4/G6 结论。

## 身份与起点

- 注册使用实际系统时间，无 CLI 回填日期选项。每个账户获得新 `paper-v4-UUID`；本金 100,000 CNY。计价从首个注册后行情日期开始，首日遵循共享引擎开账惯例，不另计注册时刻到首条报价的部分日现金收益。
- 固定规则版本、完整冻结参数、参数哈希、源提交、实际运行二进制哈希、settlement-v4、每笔成交成本和 25% 最终交易带。
- 现有策略的内部决策模拟成本保持冻结值；账户最终成交成本独立传入，单位为每笔百分比。
- 新源码、参数或二进制需要新注册，不允许接续旧账户。保留正在观察的二进制；重新构建可能改变二进制哈希。
- 该账户跟随共享核心发布的模型目标。模型信号使用其历史模型状态；新账户从现金开始。不能把它描述为以新账户状态反馈计算的策略运行。

## 操作

使用 Release `AssetTimeMachineResearch`。每次 `--output` 必须是不存在的目录。下面的 SHA 必须替换为实际构建源码提交，数据文件必须保存对应公开行情和宏观 as-of 快照。

```sh
AssetTimeMachineResearch paper-register --strategy nfci-dual-core-v11 \
  --commission-percent 0.025 --slippage-percent 0.05 \
  --source-commit SOURCE_SHA --output ACCOUNT/000-register

AssetTimeMachineResearch paper-signal --account ACCOUNT/000-register/account.json \
  --history HISTORY.json --macro NFCI_ASOF.json \
  --source-commit SOURCE_SHA --output ACCOUNT/001-signal

AssetTimeMachineResearch paper-advance --account ACCOUNT/001-signal/account.json \
  --history NEXT_HISTORY.json --source-commit SOURCE_SHA --output ACCOUNT/002-account
```

之后始终从最新 `account.json` 先 `paper-advance` 已最终发布的行情，再 `paper-signal` 新观察，输出新目录。尚无注册之后的最终行情时，advance 返回明确错误，不虚构历史成交。同一信号日期重复记录被拒绝。禁止从过时修订分叉续算；目录哈希链支持核对父修订，但本地文件不具备服务器签名或不可删除保证。

## 记账约束

- 信号记录时间必须在注册后；执行日的中国日历午夜必须晚于实际记录时间。历史 `execution_date_hint` 不用来回填成交。
- 跨市场 date-only 报价至少到次日中国时间 08:00 才能视为最终数据。真正成交仍须满足共享引擎的真实报价及卖出资金结算规则。
- 休市或结算期间的新目标替代旧目标；同一执行日多个记录取最后目标并保留之前的再平衡请求。
- 保存每日目标、现金、持仓估值、持仓数量、逐笔模拟成交、手续费、总收益、最大回撤。回撤包括相对初始本金的第一日成本损失。
- `pricedSessions` 仅统计全部契约资产有真实报价的日期，信号数量另算。星期六/日按共享行情对齐规则处理。
- 后续行情必须延续以前的全部对齐行情/FX 价格及真实观察标记；以前的净值和成交也必须逐字段不变，否则停止并保留原文件。
- 输入是 CNY 估值的价格指数模拟，含核心现金收益模型；不是可交易 ETF 总收益、实盘成交或持仓账户同步。

## 边界

`ENGINEERING_PAPER_FORWARD` 不自动成为 G6 PASS，也不能直接推荐策略。需要独立复核、匹配实际可交易资产与基准、完整尝试台账、足够真正前瞻观察及正式版本绑定。注册当日收益/回撤未知，不能用 0 冒充。

本次交付本地可连续记账的 CLI 与测试。尚未为线上旧冻结任务接入新账户的自动收集或 HTTP 展示；原冻结计算二进制和原账本继续保留。

## 本次工程注册

2026-10-05 中国时间 00:11–00:12 为 V1/V11 各注册一本独立账本，并记录截至 2026-10-02 的首条模型信号。源代码固定为 `261a7803c222484cfeacd501aa906a88265ecd2b`，成本为每笔 0.025% 费率、0.05% 滑点。账户编号、实际记录时间、输入及文件哈希见 `tools/research-results/forward-paper-v4-2026-10-05/REGISTRATION.json`。

运行二进制与必需资源仅保留一份于 `build/forward-paper-v4/`，不提交生成的二进制。后续从各自 `001-signal/account.json` 继续使用这个固定运行文件与 SOURCE_SHA。首轮 advance 确认注册后尚无最终报价，因此无回填成交，收益/回撤为 null；这不是已开始在线自动监测的 G6 账户。
