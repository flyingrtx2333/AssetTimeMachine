# 策略与回测迁移报告

核对日期：2026-10-02。本机与 Linux 计算、兼容和隔离服务验证已完成；原生 Mac 完整内存验收、可复现源提交及生产发布门禁尚未完成。本报告不改变策略准入状态、冻结日期、OOS 起点或已有研究结论。

## 基准与保护范围

迁移前源提交为 `d801a9bb3dd447c30c986107527c5b39c972f11a`，执行口径为 settlement-v4。编辑前复制原计算源码、Package、测试入口及 22 个已有未提交文件，并记录 SHA-256。基准算法未修改；只添加独立诊断入口、必要访问级别及基础规则的只读逐日观察点，使旧源码能够单独构建并输出现金/持仓；另外 506,392 次检查确认观察点未改变原报告、净值、交易或区间指标。

已有 Mac/UI/同步工作保留在原工作区。主 App 入口、顶层 ContentView、Dashboard UI 和本地化目录与编辑前备份逐字节一致。用户随后要求修复反复请求钥匙串，`CloudSync.swift` 的初始化改用共享凭证缓存，并在预览模式跳过凭证读取；同步、合并及上传逻辑保持原样。其他共享界面文件只调整类型来源、展示适配或调用参数。当前 AGENTS.md 中另一个工作流加入的 Mac 构建清理规则保留；本次只更新共享核心路径、维护命令及既有 settlement-v4 成本说明。

本次没有读取、恢复或上传真实账户数据，也没有切换数据库。工作区尚未提交，所以新运行证据中的实际源提交为 `unknown`；规则版本仍明确指向原规则源。发布前必须形成可复现的完整源提交及对应镜像。

## 迁移清单

| 步骤 | 完成内容 | 状态 |
|---|---|---|
| 固定基准 | 原源码、既有工作区备份、公开五项/NFCI、全模板及运行模式逐日轨迹 | 完成 |
| 模型与执行层 | Foundation 值类型、行情对齐、成交结算、指标；去除 SwiftUI/SwiftData/主题及服务器替身 | 完成 |
| 策略与参数 | 72 个定义覆盖 41 个原模板及 60 个模式；静态工厂、独立状态、类型化冻结参数、显式宏观快照 | 完成 |
| 研究工具 | 两个共享库、维护 CLI、配置与证据、原 Git 版本历史回放；移除活动工具的源码拼接 | 完成 |
| 各端接入 | iPhone/Catalyst、Worker/Compute、研究 CLI 使用共享库；原生 Mac 保留按需完整量化 | 本机编译通过 |
| Linux 与资源镜像 | Release 117 项测试、72 项同平台旧/新完整轨迹、隔离 Worker、运行镜像内资源读取 | 通过 |
| Mac 日常内存 | 1 年三轮及 5 年第一轮有效；其他轮次因窗口创建阻塞未完成 | 未通过完整门禁 |
| 生产发布 | 隔离 Linux Worker 对照、不可变镜像切换、旧缓存清理、上一镜像回退 | 未执行 |

### 代码归属对照

| 原职责/入口 | 当前归属 |
|---|---|
| App BacktestEngine 中的策略分派与计算 | Core 的 `Strategies/StrategyRuntimeRegistry`、各策略家族；App 入口为薄转发 |
| 行情、FX、日期、真实观察与 OHLC | Core 的 `MarketData` |
| 目标执行、结算、现金和账务 | Core 的 `Execution` |
| 区间回放和收益风险指标 | Core 的 `Metrics` |
| 全局研究覆盖、宏观数据回退 | 每次配置的不可变参数与显式 as-of 输入；无可变全局覆盖或单例回退 |
| 颜色、翻译、SwiftData 回测记录 | App 的 Models/Presentation/RecordAdapter；核心只接收展示上下文和值输入 |
| 指标 dump、执行复核、成本验证 | ResearchSupport Commands 与 SwiftPM 可执行产品 |
| RSRangeBreadth/Intraday 正式工具 | ResearchSupport Formal；原协议、工件、保护规则保留 |
| 独立历史模拟器 | ResearchSupport Legacy，版本 `asset-agnostic-legacy-d801a9bb` |
| 旧搜索/分片脚本 | 兼容入口要求显式原 Git ref，在独立临时 checkout 回放 |
| HTTP、授权、发布名单、队列及缓存 | 原 Python 服务与 Swift Worker 适配；公开请求不开放研究参数 |

## 已通过的验证

| 验证 | 结果 |
|---|---|
| 全部 72 项逐日回放 | 2,719,366 个数值对照，0 失败，最大金额差异 0；72 项均有逐日现金/持仓/目标轨迹，日期、交易方向/顺序、净值与指标一致 |
| 当前公开五项与 NFCI | 保留真实公共行情的单独对照；7 项 Worker/Compute 接入对照 9,091 次检查，最大差异 0 |
| 原完整模板轮动对照 | 989,350 次检查，0 失败 |
| Swift Release 测试 | Core/Research 全量 113 项、Worker 3 项通过；补充旧融资默认配置后，相关配置组 10 项通过，覆盖总计 117 项 |
| Linux Release 测试 | 完整 117 项通过，0 失败；首轮遗漏的宏观 CSV 测试资源已加入 Docker validation 阶段 |
| Linux 72 项完整轨迹 | 在同一 x86_64/Linux 环境重新编译迁移前源码，分为 12 批回放；2,719,375 次数值检查，最大差异 0，交易方向与顺序一致 |
| Python 后端契约 | 51 项通过；另由当前编译后的 Swift 注册表核对 5 项授权/版本/参数边界契约 |
| 登录与同步兼容 | 18 项 Apple 登录、资产安全和同步冲突离线测试通过；线上主库、行情库 SELECT 1 及公共行情 HTTP 检查通过 |
| T−1、休市与执行 | 真实报价才能成交、卖出资金结算、旧目标替换、费用与会计恒等式测试通过 |
| 参数与宏观并发 | 不同研究参数与不同宏观快照的并发结果等于各自串行结果；无状态串扰 |
| 区间与兼容 | 完整预热后截取、规则策略逐日状态、配置往返、旧记录读取/再编码、新来源字段、缺失输入和取消错误通过 |
| 内部冻结成本 | 7 档最终成交费率下，低噪内部目标路径保持一致；内部与最终成本分别记录 |
| Worker 生命周期 | 五项真实 HTTP 请求/响应经后端模型校验；缓存命中、重启加载缓存、关闭时清理活跃计算进程通过 |
| Linux Worker 接入 | 五项公开策略及两项 NFCI 与当前生产旧 Compute 比较，9,091 次检查，最大差异 0；全部结果经后端模型解析，缓存重载与服务关闭清理通过 |
| 运行镜像与资源 | 验证镜像启动并读取公共 fixture；镜像内 RecentWindow 策略资源回放 58,778 次检查，最大差异 0 |
| 取消与超时 | 取消轮询、取消排队任务、超时均终止真实测试子进程并清空临时文件；排队取消不再启动新进程 |
| 各端 Release | macOS Package、iPhone arm64、Mac Catalyst、原生 macOS 编译通过；iPhone/Catalyst/原生编译验证未使用分发签名 |

对照使用固定 `SWIFT_DETERMINISTIC_HASHING=1`，控制迁移前既有集合迭代造成的浮点尾差；没有改变生产计算顺序。金额容差为 `max(1e-8, abs(before) × 1e-12)`，目标及指标绝对容差为 `1e-12`。比较程序拒绝非有限数值。

基础规则的目标权重是执行后实际仓位；四个既有实验模式允许融资，单列不融资约束检查，不能将其合法负现金误判为账务不平。全部模式的现金加持仓等于净值检查通过。共享接口允许原冻结模板已有的 110%/120% 配置，公开不融资策略的限制保持。

72 项覆盖使用公共行情加明确标记的独立合成角色/平坦序列补齐各模式所需数据；这些补齐序列只验证工程等价，不用于策略收益结论。原公开五项/NFCI 的公共行情对照单独保留。HTTP 比较按原 Worker 的 snake_case 编码核对计算进程内部 camelCase 输出；内部协议没有修改。

两个既有实验模式 `coreGoldSatelliteEquityBreadthMomentum`、`coreGoldSatelliteRiskEfficiencyMomentum` 在 ARM/macOS 与 x86_64/Linux 间有历史平台差异：约 `1e-12`–`1e-10` CNY 的余额建仓导致交易条数不同，逐日净值最大差异为 `5.82e-10` CNY。迁移前源码在 Linux 上也出现同样差异；每个平台分别对照迁移前后均通过。此次没有修改清零阈值或运算顺序。早期跨平台逐笔比较失败报告保留，不能把错位比较后的金额差异当成收益差异。

Linux 运行宿主只有约 2GB 内存。后续验证容器限制为 768MB 内存、1GB 含交换空间、0.75 CPU，编译只用 1 个任务。一次全量证据序列化触及容器上限，被停止；改为显式 `ATM_REPLAY_STRATEGIES` 每批 6 项，共 12 批后完成。策略逐日计算保持完整，错误或重复的选择会在运行前返回错误。首次 Worker 请求在并行编译期间超时；构建结束后单独运行的完整接入对照通过。

## Release 耗时与峰值内存

在其他构建和测试结束后，旧/新 Release 二进制交替执行三轮相同六策略回放；固定相同行情、NFCI、0.025% 最终费率及 Swift 哈希种子。每轮独立进程，内存由 vmmap 的 physical footprint 读取。

| 指标 | 迁移前 | 迁移后 |
|---|---:|---:|
| 三轮耗时中位数 | 33.082 秒 | 33.091 秒 |
| 峰值 footprint 中位数 | 134.6 MB | 127.2 MB |
| 三轮峰值范围 | 123.1–135.2 MB | 94.5–140.3 MB |

耗时基本一致。峰值内存有波动，新版单轮最高值高于旧版最高值；本次不据此声称所有运行的峰值更低。该测试包含重回放及完整轨迹输出，不能替代日常页面低于 100MB 或同一 App 内连续浏览无增长的验收。

## 未通过的发布门禁与后续动作

1. **Mac 完整内存与交互验收**：桌面已解锁。早期四轮有效 Release 窗口测量中，1 年数据三轮稳定 30 秒后的 footprint 为 59.8、58.7、58.4MB，5 年第一轮为 59.5MB；明细读取 P95 为 9.12–20.06ms。之后检查完整采样发现阻塞点是 `CloudStore.init → SecItemCopyMatching → 旧式钥匙串解密`，并非已证实的 SwiftUI 窗口问题。预览模式已隔离凭证存储，正式凭证改为 Data Protection 钥匙串、禁止自动认证弹窗、缓存读取及静默旧凭证迁移；开发签名补齐应用身份与钥匙串组，旧凭证保留。独立模拟 Security 操作的 12 项检查通过，尚未用真实账户登录验证。重新测量的 1 年三轮为 58.6、60.2、60.1MB。五年/十年完整轮次、同进程持续增长、hover 绘制和重操作后 60 秒验收仍未完成；本轮因用户提出钥匙串问题停止。已有 UI 窗口试验均撤回，仅保留测试范围的前台激活与绘制计时。上述内存来自无沙盒测试产品，不能证明开发签名交付版本全部达标。
2. **可复现提交与发布**：当前代码仍位于保护既有 UI/Mac/同步工作的未提交工作区，`final-source-manifest.json` 保存实际计算源文件哈希。验证运行镜像为 `sha256:2e78cb2a2f920a99ce68d9505ebcc8549ced7678eb5cc2607e48b1babd6952a1`，仅用于隔离验证。形成可复现完整源提交及不可变发布镜像、完成 Mac 门禁后，才切换生产 Worker 并清理旧计算缓存。TestFlight 单独安排。
3. **服务运行状态**：SSH、公共行情及两类数据库探测已恢复，生产回测 Worker 健康。另观察到两个既有 scheduler 容器反复因 OperationalError 重启，尚未确定具体原因；本次未变更这些进程或数据库配置。服务器恢复与此前构建的因果关系没有确认。

原冻结 Compute 二进制在服务器 `/opt/assettimemachine-forward/AssetTimeMachineBacktestCompute`，再次核对 SHA-256 仍为 `b16a922f5c0b4182e0ef48af178cebf7bfa4cf99e1e0a15000e7e706b358fb32`。当前旧 Worker 镜像 tag `aca9916f660366200c10423412b92203c9fbc1e9`，digest `sha256:d34c3eb123bdca8b1e1f2b9b61e7c6a04eab1b7310b019b7b63295585df99532`。生产镜像及冻结程序均未修改。

## 本机证据索引

证据保存在忽略提交的 `build/architecture-refactor/`；原始失败诊断与成功复核分别保留，没有用成功结果覆盖旧证据。

- `source.json`、`preexisting.json`、`before/`、`preexisting/`：迁移源与已有工作区保护。
- `public-parity.json`、`all-before-stable.json`、`all-current-stable.json`：公共数据及原模板回放。
- `complete-trace-before.json`、`complete-trace-current.json`、`complete-trace-parity.json`：72 项完整轨迹对照；`baseline-rule-observer.patch`、`baseline-observer-preservation.json`：原源码只读观察点及输出不变的证明。
- `registry-full-current-v2.json`、`registry-full-parity-v2.json`：全部 72 个注册运行器与原引擎的逐日对照。
- `final-all-tests-v2.log`、`final-configuration-tests.log`、`worker-cancellation.log`：113+3 项及补充旧默认配置组 10 项通过；最初全量测试暴露的进程等待阻塞已由有界退出清理修正。
- `final-backend-tests.log`、`final-compiled-backend-contract.log`：51 项及新编译注册表契约。
- `local-worker-canary/http-parity.json`：7 项接入、缓存及服务退出复核。
- `controlled-release-benchmark/report.json`、`summary.json`：三轮旧/新 Release 原始测量。
- `final-research-evidence/`、`cost-invariance.log`：参数、数据哈希、版本与冻结成本证据。
- `ios-validation-final.log`、`catalyst-validation-final.log`、`native-release-complete.log`：各端最终编译。
- `latest-linux-tests-passed.log`、`linux-full-before.json`、`linux-full-current.json`、`linux-same-platform-parity.json`：Linux 117 项测试及 72 项同平台零差异对照。
- `legacy-platform-differences.json`、`linux-cross-platform-parity.json`：迁移前已经存在的两项跨平台极小余额交易差异及原始失败报告。
- `linux-worker-canary-complete/parity.json`、`checks.json`：Linux 七项接入与退出清理证明。
- `runtime-resource-parity.json`、`runtime-validation-artifacts.log`：实际运行镜像中的资源回放、二进制和原冻结程序校验值。
- `auth-sync-compatibility-tests-final.log`：18 项 Apple 登录与同步兼容测试。
- `native-final-performance-visible.log`、`native-reopen-sample.txt`：四轮部分有效内存值及后续窗口创建阻塞采样。
- `native-full-final/`、`native-isolation-after-keychain.sample`：凭证隔离后三轮 1 年数据及无钥匙串等待的主线程采样；完整矩阵尚未完成。
- `keychain-adapter-tests-final.log`、`native-keychain-fix-build.log`：禁止自动弹窗、凭证缓存、静默迁移及退出保持的 12 项检查；正式 Mac 签名已补齐授权的应用身份与钥匙串组。
- `final-source-manifest.json`：实际计算源文件哈希，尚不等同于完整发布源提交。
