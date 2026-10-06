# 行业趋势价格版研究

研究入口：`AssetTimeMachineResearch industry-trend-screen --etfs ... --history ... --output ... --source-commit ...`。

这是固定的 D0 价格口径探索，不注册产品策略、不执行外部 Notebook。规则与窗口冻结在同仓研究副本：`FlyingrtxFast/research/asset-time-machine/workspace/studies/industry-notebook-price-screen-2026-10-06/DECLARATION.json`。公开 Notebook 默认波动窗口20日，论文写14日；本轮明确采用代码默认参数。

20/40日通道，Keltner宽度2.8倍平均绝对价格变动，EMA adjust=false；20日收益总体标准差，日目标0.015，单资产上限20%，总敞口100%。实际报价覆盖后才计入可用资产，T−1信号，后续真实收盘与 settlement-v4 结算；日维护调仓保留。10万元本金，每笔0.025%手续费，零滑点；USD信号/CNY估值，人民币活期现金。

ETF分红现金未计入，不能把本轮成绩认作完整股东回报或原论文精确复现。31只历史篮子是作者回溯选择，2025+也是已暴露历史，不是新的纯净OOS。程序输出全部逐日资产、现金、目标、成交、提交时点和预声明窗口，并对未持有目标持续三个报价机会的情况标记执行复核。
