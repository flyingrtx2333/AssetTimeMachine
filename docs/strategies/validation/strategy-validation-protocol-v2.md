# AssetTimeMachine Strategy Validation Protocol V2

状态：**FROZEN GOVERNANCE PROTOCOL**  
生效时间：2026-08-20  
协议 ID：`ATM-SVP-2`  
当前纳入策略：`nfci-dual-core-v11` / `dualcore-v11-2026-08-15`

> ATM-SVP-2 是 ATM-SVP-1 的治理升级，不修改 V11 策略、参数、数据时点、目标仓位路径或 prospective OOS 时钟。V1 的冻结文件永久保留且不得原地修改。除本文件明确替换的 G4 规则外，V1 的 G0/G1/G2/G3/G5/G6、证据等级、trial ledger、失败保留、版本重置和 prospective 纪律全部继续生效。

## 1. 为什么必须升级而不是修改 V1

ATM-SVP-1 原 G4 使用全历史 V11 指标作为跨资产替换门槛：Sharpe 至少保留 50%（约 0.761），MDD 不超过全历史 MDD 的 2 倍（约 15.378%）。

在任何 pristine G4 holdout 被下载、烧毁或打开之前，我们完成了只使用已暴露 V11 原始资产的 runner dry-run，并发现：一旦把所有 G4 substitution 统一到由五个候选 metadata 决定的共同评价窗口，**原资产 identity baseline 本身会因时间区间变化而显著不同于全历史 baseline**。

最终 metadata 候选集对应的机械共同窗口为 `2011-08-02 — 2026-08-18`。只使用现有暴露数据、完全不替换任何资产时，V11 identity baseline 为：

- CAGR：约 4.320%；
- Sharpe：约 0.498；
- MDD：约 18.697%。

因此 V1 G4 的 0.761 / 15.378% 门槛会让“完全不换资产”的 identity control 自己 FAIL。该结果证明 V1 G4 将**时间窗口效应**和**资产替换效应**混在了一起，无法识别我们真正想验证的因果问题。

这不是 holdout 结果驱动的改门槛：截至 V2 冻结时，五个 exact holdout 的完整收益历史仍未打开，`HOLDOUT_BURNED` 尚未发生，正式六个 substitution 的收益、Sharpe、MDD 均未知。因此必须在开封前升级治理协议，而不是原地修改 V1。

## 2. V2 继承边界

以下内容完整继承 ATM-SVP-1：

- G0 Implementation Integrity；
- G1 Data & Causality Integrity；
- G2 Retrospective Robustness；
- G3 Model Selection / Multiple-Testing Risk；
- G5 Execution Robustness；
- G6 Prospective OOS；
- V11 retrospective DSR 仍为 `NOT_CERTIFIED_LEGACY_TRIAL_COUNT`；
- G5 已完成的 blind execution-cost / +1-session delay 证据继续有效；
- V11 prospective ledger 与 63 / 126 / 252 / 504 session 时钟连续，不重启；
- 任何 target-path-changing 变化仍必须创建新的 strategy version 并重新计时。

V2 **只替换 G4 的实验识别和门槛参考系**。

## 3. Gate G4 — Domain-Preserving Generalization V2

### 3.1 五个经济角色不变

固定角色仍为：

1. `gold_safe_haven`；
2. `us_growth_equity`；
3. `us_broad_equity`；
4. `china_large_equity`；
5. `china_broad_equity`。

每个角色仍只允许一个 exact alternate source / series。不得看完结果后换第二组。

### 3.2 Metadata-only 选择与 one-shot holdout

正式 source 在打开完整历史前必须：

1. 只检查名称、发布方、资产角色、币种、单位、频率、首个可用日和最近可用日；
2. 通过当前 Git + Git 历史 exposure scan；
3. 将 source、source series id、raw fixture symbol、neutral role symbol、currency/unit、normalization rule、metadata coverage 写入 holdout manifest；
4. Git 冻结 exact manifest；
5. 在任何 full-history fetch 前 append 并 commit `HOLDOUT_BURNED`；
6. 同一 `strategy_version` 只允许一次 pristine holdout burn；
7. burn 后即使下载失败、数据不可用或正式结果 FAIL，也不得为 V11 换第二组 holdout。

### 3.3 统一评价窗口

五个 alternate source 的覆盖期通常不同。为了隔离“资产替换”而不是“时间区间”效应，六个正式 substitution 必须使用完全相同的窗口：

`evaluation_start = max(五个 metadata_coverage_start)`  
`evaluation_end = min(五个 metadata_coverage_end)`

该窗口由代码在 manifest freeze 时机械推导，研究者不得手工挑选。

正式 runner 同时保留两类 control：

- **full-history identity control**：原 V11、原完整暴露历史，必须精确复现冻结 V11 baseline / target fingerprint；
- **common-window identity control**：原 V11、原资产，但只在 G4 共同窗口运行，用作 substitution 的同窗口 reference。

只有 5 个 one-slot + 1 个 all-alternate 算入正式 G4 run budget；两个 identity control 不属于替代候选。

### 3.4 Common-window reference 必须在 holdout 开封前冻结

exact holdout manifest 冻结后，已经可以从 metadata 得到共同窗口。此时、但在 `HOLDOUT_BURNED` 与 full-history open **之前**，使用现有暴露 V11 原资产计算 common-window identity reference，并 append/commit `G4_REFERENCE_BASELINE_FROZEN`：

- evaluation start / end；
- CAGR；
- Sharpe；
- MDD；
- trades；
- target fingerprint；
- source fixture SHA；
- execution Git commit。

之后 G4 门槛只能按下面的固定公式由该 reference 推导，不允许手工改数字。

### 3.5 V2 G4 进入正式 holdout 的前置条件

common-window identity reference 必须同时：

- CAGR > 0；
- Sharpe > 0；
- MDD <= 25%；
- gross <= 100%；
- 不做空、无负权重、无负现金；
- common-window runner 的 identity mapping/neutral-symbol plumbing 校验通过。

若原策略在共同窗口自己都不满足这些最低条件，则 G4 标记 `NOT_INTERPRETABLE`，不得用该 holdout 给出“跨资产通过/失败”的强结论，也不得为了找一个更好窗口而改 metadata source。

### 3.6 V2 G4 PASS 门槛

令 common-window identity Sharpe 为 `SR_base`，MDD 为 `MDD_base`。

六个 substitution 必须同时满足：

1. 5 个 one-slot substitution 至少 4 个 Sharpe > 0；
2. one-slot Sharpe 中位数 >= `0.50 × SR_base`；
3. all-alternate basket CAGR > 0；
4. all-alternate basket Sharpe >= `0.50 × SR_base`；
5. all-alternate basket MDD <= `min(25%, 1.25 × MDD_base)`；
6. 所有运行 gross <= 100%，无做空、无负权重/负现金；
7. 5 个 source series 全部通过 frozen normalization，外部 ticker/source id 不进入 V11 规则判断；
8. 正式六个候选全部报告，不允许丢弃表现差的 role；
9. 正式结果出来后不得搜索 delay、窗口、替代 symbol、normalization 或阈值使同一 V11 重做 G4。

其中 50% Sharpe retention 延续 V1 的“至少保留一半风险调整优势”原则，只把 reference 从错误的全历史窗口改成正确的同窗口 identity。MDD 使用 `1.25 × MDD_base` 表示最多允许 25% 的相对回撤膨胀，并再以 25% 做绝对硬上限，避免 common-window baseline 较高时产生过宽容的风险门槛。

这些是 AssetTimeMachine 项目治理门槛，不声称为行业统一阈值。

### 3.7 失败规则

- G4 PASS：只能说明完整 V11 的**经济角色结构对具体价格代理具有可迁移性**，不等于世界任意资产都适用；
- G4 FAIL：本 V11 的 role-preserving G4 永久 FAIL；holdout 降级为 exposed development data；不得换第二组 source 重考；
- 数据源/解析存在事前未发现的实现错误：必须先记录本 trial `INVALID`，保留全部证据；只有可证明是实现错误而非表现不佳时，才允许在不更换 burned source 的前提下新建修复 trial。

## 4. G4 之外的当前状态

ATM-SVP-2 生效时，V11 状态为：

- G0：PASS；
- G1：PASS；
- G2：PASS；
- G3：PARTIAL（C3/L3 PBO 有效；整体 retrospective DSR 因 legacy trial count 不完整不可认证）；
- G4：PENDING，尚未 burn/open pristine holdout；
- G5：PASS；
- G6：RUNNING。

因此最准确的整体表述仍是：

**Historically robust + implementation/data validated + execution robust + prospective shadow running; institutional validation incomplete until G4 and prospective OOS mature.**

## 5. V1 冻结与 V2 可审计性

- `ATM-SVP-1` 文档和 policy SHA 必须继续通过原 freeze record；
- V2 有独立 policy / freeze record；
- trial ledger append `PROTOCOL_UPGRADE`，明确 `from=ATM-SVP-1`、`to=ATM-SVP-2`、升级发生在 G4 holdout burn/open 之前；
- V2 的任何后续治理变化同样不得原地编辑；必须创建 ATM-SVP-3。
