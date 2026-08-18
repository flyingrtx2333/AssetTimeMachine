# AssetTimeMachine Strategy Validation Protocol V1

状态：**FROZEN GOVERNANCE PROTOCOL**  
生效时间：2026-08-18  
协议 ID：`ATM-SVP-1`  
当前纳入策略：`nfci-dual-core-v11` / `dualcore-v11-2026-08-15`

> 本协议不是为了让某个策略“更容易通过”，而是为了让任何策略在研究、验证、上线、失败和退役时都留下不可篡改、可复现、可解释的证据链。

## 0. 总原则

1. **先冻结，后运行**：候选、数据类别、允许修改的自由度、评价指标和 PASS/FAIL 门槛必须在正式验证前确定。
2. **同一批 holdout 只用一次**：一旦看过结果，它立即降级为 development data；失败后不得继续调参并再次把它称作 OOS。
3. **所有试验都计数**：不得只统计最后几个漂亮候选。协议生效后，每个候选族、参数网格、因子筛选和消融实验都必须先写入 trial ledger。
4. **失败永久保留**：FAIL 结果不得删除、覆盖或重命名为“诊断”。
5. **策略版本不可回写**：任何会改变目标仓位路径的逻辑、阈值、资产角色、数据时点或决策规则变化，都必须创建新的 `strategy_version` 并重启 holdout / prospective 计时。
6. **App / Server / Research 同引擎**：App-facing 结果必须由当前 Swift `StrategyTargetProvider` + `BacktestDailySimulator` / `BacktestEngine` 路径产生。Python 只允许做统计审计，不允许实现第二套策略模拟器。
7. **证据边界必须写清**：retrospective、holdout、prospective 三种证据不得混称。

## 1. 数据证据等级

每个数据集只能属于以下一个等级：

- `D0_EXPOSED`：已经用于开发、调参、诊断或被研究者看过完整收益路径的数据。
- `R1_RETROSPECTIVE`：已暴露历史上的预注册回顾性验证。可以证明稳健性，但不能证明 pristine OOS。
- `H2_PRISTINE_HOLDOUT`：在协议与具体替代资产清单冻结后才第一次下载完整收益历史的 holdout。
- `P3_PROSPECTIVE`：策略冻结后真实到来的新市场数据，由服务器 append-only ledger 记录。

规则：证据只能从高等级降级，不能升级。例如一个 H2 holdout 被看过后，下一版本只能把它当 D0。

## 2. 策略生命周期

统一状态：

1. `RESEARCH`：允许开发与调参。
2. `FROZEN_CANDIDATE`：代码、参数、输入定义、成本假设、验收门槛已经冻结。
3. `RETRO_VALIDATED`：通过回顾性稳健性与实现一致性，但还没有 pristine holdout / prospective 结论。
4. `SHADOW`：开始真实时间 append-only 记录，允许在 App 中作为“历史验证通过、未来 OOS 进行中”展示。
5. `PROVISIONAL`：达到 252 个新交易日并通过第一次 prospective 主判定。
6. `VALIDATED`：达到 504 个新交易日并通过强验证门槛。
7. `RETIRED`：逻辑被替代、失效或出现不可接受的数据/实现问题。

当前 V11 的协议状态：`SHADOW`。它不是“完全机构级验证通过”。

## 3. Gate G0 — Implementation Integrity

必须全部通过：

- 策略存在唯一 `strategy_id`、`strategy_version`、App mode 和 server descriptor。
- App / Server 使用同一 Swift 核心目标计算实现。
- 固定 regression fixture 在重构前后 target fingerprint 一致。
- 决策用固定研究 shadow cost；用户实际手续费只影响执行，不改变目标路径。
- 同一 causal input 重复运行必须产生相同 target fingerprint。
- prospective ledger 唯一键禁止 UPDATE；重复计算只允许返回 existing。
- 所有正式指标必须能由 durable Swift 工具或 App engine 重放。

任何一项失败：整套策略验证状态立即降为 `INVALID_IMPLEMENTATION`，之前的收益表现不能掩盖实现问题。

## 4. Gate G1 — Data & Causality Integrity

每次正式验证必须保存 dataset manifest，至少包括：

- 数据源和 series / symbol；
- 首尾日期、行数、缺失率；
- 下载/快照时间；
- 文件 SHA-256；
- corporate action / FX / holiday 处理；
- 是否 point-in-time；
- 宏观数据 release lag / first-seen 规则；
- 决策时区和执行日规则。

硬规则：

- T-1 决策、T 执行；
- NFCI 只能使用 first-seen / initial-release point-in-time；
- cutoff 之后的数据不得影响 cutoff 当日 target；
- 多市场节假日只能做有界 recent-valid forward fill，不能因为某一市场休市删除整天；
- 不融资、不做空、gross <= 100%、现金不得为负。

发现 look-ahead / revision leakage：该版本历史结果全部作废，必须修复后创建新的 validation record。

## 5. Gate G2 — Retrospective Robustness

V11 已冻结的主要门槛：

- full CAGR >= 14.0%；
- full Sharpe >= 1.50；
- full MDD <= 8.5%；
- 7 个连续时间折至少 5 折 Sharpe > 1；
- worst-fold Sharpe > 0；
- block63 bootstrap Sharpe P2.5 >= 1.15；
- block63 bootstrap MDD P97.5 <= 15%；
- 与上一简化版本比较：至少 4/7 折 Sharpe 不低，或至少 6/7 折 MDD 不高；
- 自然参数简化只能按预注册候选运行，不能继续扫描小数甜点。

当前 V11 结果：CAGR 14.345%、Sharpe 1.522、MDD 7.689%、5/7 折 Sharpe > 1、worst fold 0.741、Block63 Sharpe P2.5 1.221、MDD P97.5 13.93%。因此 G2 = PASS。

## 6. Gate G3 — Model Selection / Multiple-Testing Risk

这是本协议相对旧流程新增的核心治理层。

### 6.1 Trial ledger

协议生效后，任何研究运行前必须先登记：

- `trial_id`；
- hypothesis；
- strategy lineage；
- 数据等级；
- 允许变化的参数/规则；
- 候选数量；
- 选择指标；
- PASS/FAIL 门槛；
- 是否允许生成后续候选。

运行结束后追加 RESULT 记录，不允许修改 preregistration。

ledger 使用 SHA-256 hash chain；Git 负责第二层历史审计。

### 6.2 DSR

对于协议生效后形成的新候选族，必须保存该族**所有被测试候选**的 Sharpe 分布，并计算 Deflated Sharpe Ratio：

- DSR probability >= 95%：PASS；
- 90%–95%：WEAK；
- < 90%：FAIL。

DSR 用于校正 multiple testing、selection bias 与非正态收益。不得只把“赢家的 Sharpe”输入 DSR。

### 6.3 CSCV/PBO

当候选族包含多个可比较配置时，固定使用 CSCV/PBO：

- PBO <= 20%：PASS；
- PBO <= 10%：STRONG；
- PBO > 20%：FAIL。

这是本项目治理阈值，不声称是行业统一标准。

当前 C3/L3 粗参数族的 PBO 约 5.7%–11.1%，但它只覆盖 C3/L3 参数族，**不能代表整个历史 strategy zoo 的总 selection risk**。

### 6.4 V11 的 legacy 限制

协议生效前仓库已有大量 grid / strategy-zoo / factor research 程序。历史完整 trial count 无法可靠重建，因此：

- V11 的 retrospective DSR 标记为 `NOT_CERTIFIED_LEGACY_TRIAL_COUNT`；
- 不允许用一个人为缩小的候选数算“漂亮 DSR”；
- 从 ATM-SVP-1 生效后开始，所有新研究必须完整登记，未来新版本可以获得真正可审计的 DSR。

这不会污染已经冻结后的 P3 prospective OOS；prospective 仍然是真正的新数据。

## 7. Gate G4 — Domain-Preserving Generalization

旧的 8 国 country-equity 测试继续保留，结论是 FAIL（Sharpe 0.417 < 0.45；MDD 26.70% > 25%）。它证明 price-only 风控有迁移性，但不等同完整 DualCore 的域内验证。

新的正式 G4 不再“换一堆国家股票”，而是做**角色保持替换**。

### 7.1 角色槽位

冻结 5 个角色：

1. `gold_safe_haven`：黄金风险对冲角色；
2. `us_growth_equity`：美国成长/科技风险资产；
3. `us_broad_equity`：美国广义股票风险资产；
4. `china_large_equity`：中国大盘风险资产；
5. `china_broad_equity`：中国广义股票风险资产。

现金继续使用现有 `CashYieldCNY`，不引入货基、定存、逆回购或外部基金袖套。

### 7.2 Holdout 选择纪律

- 先只检查 metadata：系列是否存在、覆盖年份、更新频率；不得查看完整收益路径、Sharpe、回撤或图形。
- 每个角色只允许预选 **1 个** alternate proxy / alternate source；不得准备五个然后挑最好看的一个。
- exact symbol + source + date coverage 写入独立 holdout manifest 并提交 Git 后，才允许首次下载完整历史。
- 正式运行仅允许：5 个 one-slot substitution + 1 个 all-alternate basket。
- 不允许在看到结果后改变 1.22、25%、50/50、C3/L3 或角色映射。

### 7.3 G4 PASS 门槛

以冻结 V11 retrospective Sharpe / MDD 为 reference，只使用事前公式：

- 5 个 one-slot substitution 至少 4 个 Sharpe > 0；
- one-slot Sharpe 中位数 >= 50% × frozen baseline Sharpe；
- all-alternate basket CAGR > 0；
- all-alternate basket Sharpe >= 50% × frozen baseline Sharpe；
- all-alternate basket MDD <= 2.0 × frozen baseline MDD；
- 所有运行保持 gross / cash / causality 约束；
- ticker 匿名重命名后指标在数值容差内一致。

对 V11 当前 baseline，这意味着 all-alternate 的预注册门槛约为 Sharpe >= 0.761、MDD <= 15.378%。

若 FAIL：本版本 G4 永久 FAIL；这些 holdout 自动降级为 D0。不得继续寻找另一组替代资产直到 V11 PASS。

## 8. Gate G5 — Execution Robustness

正式执行验证只允许固定两种执行假设，不做费用网格：

### Base

- fee = 1.00%；
- slippage = 0.05%；
- T-1 decision / T execution。

### Adverse stress

- fee = 1.50%；
- slippage = 0.10%；
- 额外 1 个交易日执行延迟。

Stress 只回答“优势是否在更差执行下直接消失”，不得用来重新选择参数。

PASS：

- stress CAGR > 0；
- stress Sharpe > 0；
- stress MDD <= 2 × base MDD；
- target path 不因用户费用参数改变；
- 约束不被突破。

容量在当前个人资产配置 App 场景只做 informational check；如果未来策略进入大规模自动执行，必须另建 market-impact / ADV 容量协议。

## 9. Gate G6 — Prospective OOS

V11 冻结日：2026-08-15。服务器 append-only ledger 已启动。

固定里程碑：63 / 126 / 252 / 504 个**冻结后新交易日**。

### 63 / 126 sessions

仅做 operational health check：

- ledger 连续；
- causal input fingerprint 正常；
- 没有 look-ahead / revision / target mismatch；
- 不因收益好坏修改策略。

不得在 63 / 126 天提前宣布 prospective PASS。

### 252 sessions — Primary prospective decision

全部满足才进入 `PROVISIONAL`：

- implementation/data integrity 无重大违规；
- net CAGR > 0；
- realized Sharpe > 0；
- MDD <= 2.5 × frozen retrospective MDD；
- gross / no-short / no-negative-cash 约束 100% 满足；
- 冻结版本没有被回写修改。

V11 对应 MDD 门槛约 19.223%。

### 504 sessions — Strong validation

全部满足才进入 `VALIDATED`：

- realized Sharpe >= 50% × frozen retrospective Sharpe；
- realized CAGR >= 40% × frozen retrospective CAGR；
- MDD <= 2.0 × frozen retrospective MDD；
- 同期累计收益 > `CashYieldCNY` frozen cash benchmark；
- 无实现/数据完整性违规。

V11 对应约：Sharpe >= 0.761、CAGR >= 5.738%、MDD <= 15.378%。

这些是 2026-08-18 在 V11 `new_sessions=1` 时冻结的**项目治理门槛**，不是行业统一标准。冻结时只有 1 个新交易日，尚不足以形成可解释的 prospective Sharpe/CAGR/MDD，且本协议没有读取或使用 prospective performance 指标来选择这些门槛；该事实作为 ledger 事件永久记录。

## 10. Promotion / Failure Matrix

| Gate | 内容 | V11 当前状态 |
|---|---|---|
| G0 | 实现一致性 | PASS |
| G1 | 数据/因果完整性 | PASS |
| G2 | 历史稳健性 | PASS |
| G3 | selection risk / DSR / PBO | PARTIAL：C3/L3 PBO PASS；总 DSR 因 legacy trial count 不完整而不可认证 |
| G4 | 角色保持 pristine holdout | PENDING；旧 8 国方法测试保留 FAIL |
| G5 | 固定执行 stress | PENDING under SVP-1 |
| G6 | 真实未来 OOS | RUNNING |

因此当前最准确的状态是：

**Historically robust + implementation/data validated + prospective shadow running; institutional validation incomplete.**

## 11. 任何新版本必须重新计时的变化

以下任一变化都必须创建新 `strategy_version`：

- 1.22 / 25% / 50-50 / C3-L3 阈值变化；
- 新增/删除因子；
- 资产角色变化；
- data release / point-in-time 定义变化；
- 会改变历史 target fingerprint 的 bug fix；
- 交易触发逻辑变化；
- 风险预算、gross cap、现金模型变化。

纯 UI、文案、性能优化或内部重构只有在完整 regression fingerprint 不变时才允许保留原版本。

## 12. 每次研究的标准工作流

1. 写 hypothesis。
2. 写 preregistration payload 并 append 到 trial ledger。
3. 提交 Git；没有 commit 的 preregistration 不算正式。
4. 运行同一 Swift App engine。
5. 保存 dataset manifest、return series、metrics、fingerprints。
6. append RESULT 到 ledger。
7. 运行 G2/G3 统计：folds、bootstrap、DSR、PBO（适用时）。
8. 只有候选在 D0/R1 阶段通过后，才能冻结 H2 holdout manifest。
9. H2 只运行一次；失败永久保留。
10. 冻结生产候选后启动 P3 append-only prospective ledger。
11. 252/504 到期前不修改策略。

## 13. 参考方法

本协议的 multiple-testing / backtest-overfitting 设计参考：

- Bailey & López de Prado, *The Deflated Sharpe Ratio: Correcting for Selection Bias, Backtest Overfitting and Non-Normality*.
- Bailey, Borwein, López de Prado & Zhu, *The Probability of Backtest Overfitting*.
- Harvey, Liu & Zhu, *…and the Cross-Section of Expected Returns*.

这些文献支持的核心思想是：大量策略/因子被反复测试时，普通 Sharpe、普通 t≈2 和单次 holdout 很容易高估证据强度，因此需要显式记录试验数量、multiple-testing 调整与更严格的 OOS 纪律。
