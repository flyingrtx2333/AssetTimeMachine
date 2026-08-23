# AssetTimeMachine Strategy Validation Protocol V3

状态：**FROZEN GOVERNANCE PROTOCOL**  
生效时间：2026-08-23  
协议 ID：`ATM-SVP-3`  
继承：`ATM-SVP-2`

> V3 不修改任何既有策略代码、参数、历史 RESULT、V11 prospective OOS 时钟或 V2 G4 证据。V1/V2 永久保留。V3 只修正一个治理语义：**策略验证、研究目标达成、与其他策略的相对比较必须是三个独立维度。**

## 1. 核心原则

以后不得因为一个策略没有超过 V11、matched control、前一版本或其他候选，就把该策略本身标记为 `REJECTED` / “验证失败”。

每个正式策略 RESULT 必须同时报告：

1. `validation_status`：策略本身是否通过统一的严谨性/稳健性验证；
2. `objective_status`：本次预注册研究目标是否达成，例如 CAGR>=16%、Sharpe>=1.4；
3. `comparison_status`：若本次包含相对比较，是否显著胜过 V11 / matched control / peer strategy。

三者不得互相覆盖。一个合法结果可以是：

- `validation=PASS / objective=FAIL / comparison=FAIL`；
- 这表示“策略本身有效、研究过程严谨，但没有达到本次高收益目标，也没有胜过基准”。

历史 ATM-SVP-1/2 RESULT 的单一 `status` 保持原样，不重写；策略库使用 V3 三轴解释层重新分类。

## 2. Strategy Validation（主状态）

V3 的回顾性策略验证使用统一绝对底线，而不是冠军筛选门槛：

- 正式 preregistration / run guard / execution commit / artifact manifest 证据链存在；
- full CAGR > 0；
- full Sharpe > 0；
- full MDD <= 25%；
- 固定时间折中至少 70% Sharpe > 0；若 worst-fold Sharpe > 0，则自动满足该项；
- 若本 trial 提供固定 execution/slippage stress：stress CAGR > 0、stress Sharpe > 0、stress MDD <= 2 × base MDD；
- gross <= 100%，现金非负，不融资、不做空、无经济杠杆；
- 无 look-ahead、revision leakage、target fingerprint / implementation integrity 违规。

这些是“这个策略是否有可重复的正向历史证据”的最低验证标准，不是收益目标。

### 2.1 状态

- `PASS`：上述统一验证底线通过；
- `WEAK`：统一底线通过，但可用的 DSR/PBO 等 model-selection 证据低于项目强通过阈值；
- `FAIL`：统一绝对验证底线本身失败；
- `INCOMPLETE`：证据链不足，不能严谨判定。

缺少某一 trial 中未要求的 execution stress 只能形成 warning，不自动把一个本来有效的正式策略判 FAIL；完整产品晋级仍须按相应 G5/G6 要求补齐。

## 3. Objective Attainment（目标达成）

以下属于研究目标，不属于策略有效性：

- CAGR >= 16%；
- Sharpe >= 1.40；
- MDD <= 12%；
- 至少 5/7 折 Sharpe > 1；
- 某个高收益区间、目标交易频率或其他产品目标。

这些可以决定“是否完成这次研究任务”或“是否值得进入某个产品档位”，但不得决定策略是否严谨有效。

## 4. Comparative Superiority（相对比较）

以下全部属于独立 comparison axis：

- CAGR / Sharpe / MDD 是否优于 V11；
- 是否优于 matched SPY / no-SMA / equal-weight control；
- P(candidate > control) 是否达到 90% / 95%；
- fold 中有多少次胜过另一个策略；
- candidate-minus-control delta。

比较失败只允许写 `comparison=FAIL` 或“不支持替代/优越性声明”。不得据此写“策略验证失败”。

## 5. Model-selection 风险

DSR / PBO 仍属于严谨性证据，但其作用是描述“这个结果受策略搜索污染的风险”。

- DSR >=95%：强；
- 90%–95%：较弱；
- <90%：弱；
- 候选族/历史 trial count 不完整：`NOT_CERTIFIED`。

当一个策略的统一绝对验证底线全部通过、但 selection-risk 证据较弱时，策略库使用 `validation=WEAK`，而不是假装这个策略不存在或直接归入“拒绝策略”。

## 6. 生命周期映射

策略库展示映射：

- `validation=PASS` -> `validated` / 验证通过；
- `validation=WEAK` -> `candidate` / 验证较弱；
- `validation=FAIL` -> `rejected` / 验证失败；
- `validation=INCOMPLETE` -> `research` / 证据不足；
- `promoted` 仍表示产品采用，不等于验证本身；
- `superseded_by` 只表示某个比较/alpha/替代声明被后续证据替代，不自动取消策略自身 validation。

## 7. 与 G0-G6 的关系

V3 不降低 G0-G6：

- G0/G1 的实现与因果违规仍可直接使 validation FAIL/INVALID；
- G3 selection risk 独立显示为强/弱；
- G4/G5/G6 仍决定更高证据等级、holdout、execution robustness 和 prospective 状态；
- `RETRO_VALIDATED` 不等于 `VALIDATED`（504 prospective sessions）。

因此“验证通过”必须带证据等级，例如 `R1 retrospective validation PASS`，不得冒充 pristine holdout 或 prospective strong validation。

## 8. 历史记录

V1/V2 的 `status: FAIL` 若原本代表“没有打败 V11/控制组”仍永久保留。V3 不修改它，只在策略库中附加：

- `validation_status`；
- `objective_status`；
- `comparison_status`；
- `validation_failures/warnings`；
- `objective_failures`；
- `comparative_failures`。

这保证历史不可篡改，同时纠正策略库语义。
