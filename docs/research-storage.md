# 策略研究存储入口

统一入口：[/Volumes/小姐姐新家/策略研究数据/AssetTimeMachine/研究总入口](/Volumes/小姐姐新家/策略研究数据/AssetTimeMachine/研究总入口/README.md)。

产品策略与统一引擎维护在本仓库 `Sources/AssetTimeMachineBacktestCore/`；研究运行支持在 `Sources/AssetTimeMachineResearchSupport/`，测试在 `Server/Tests/CoreTests/`。研究协议、报告和工具维护在 [/Volumes/江波龙/Allprojects/FlyingrtxFast/research/asset-time-machine/workspace](/Volumes/江波龙/Allprojects/FlyingrtxFast/research/asset-time-machine/workspace/STORAGE_INDEX.md)。完整数据与回测证据维护在 `/Volumes/小姐姐新家/策略研究数据/AssetTimeMachine`。

存储配置以研究工作区 `RESEARCH_STORAGE.json` 为准。原仓库及正式验证路径保持；统一入口的目录链接不构成新的源码分支或第二份可编辑代码。新研究材料统一写入外盘，避免在代理工作目录和系统临时目录形成新的正式结果。

发布归档统一使用 `RESEARCH_STORAGE.json.releaseArchiveRoot`：`/Volumes/小姐姐新家/策略研究数据/AssetTimeMachine/releases`。2026-10-27 已归拢外盘根目录四个历史发布目录，原路径保留为隐藏兼容链接；新发布目录不再建到磁盘根目录。
