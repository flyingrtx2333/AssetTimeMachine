# ATM-SVP 策略验证操作入口

当前治理协议：`docs/strategies/validation/strategy-validation-protocol-v2.md`（`ATM-SVP-2`）；`ATM-SVP-1` 仍独立冻结并作为继承基线保留。

## 冻结正式工件与当前线上复跑

- 本目录的 protocol、ledger、manifest 和 RESULT 是**正式、冻结的历史证据**；不得为追随当前线上数据而改写旧结果。
- 当前线上行情重跑须标为 `POST_HOC_CURRENT_REPLAY`，不写入正式 RESULT、不消耗 formal-run budget、也不改变既有 Gate 状态。它的用途是发现数据/代码漂移，而不是重新挑选参数。
- 使用生产接口时默认只读：`/api/v1/money/public/history?...&period=all&include_ohlc=true` 不得附带 `refresh=true`，除非用户明确授权刷新服务端数据。保存请求、抓取时间、逐序列实际末日、原始/归一化输入 SHA-256、代码 HEAD、引擎/成本配置和全窗口输出。
- NFCI 策略必须使用生产 `/api/v1/money/public/nfci-asof` 的 point-in-time 行（`release_date`、`reference_date`、`available_at`）。严禁把当前修订宏观序列或旧 local CSV 静默替换为“等价”输入。
- 当正式旧结果与当前线上复跑不一致，两个结果都保留并明确标注各自的代码、数据和成本口径；不得用后验调参把当前复跑调回旧数字。

### V11 current-data note

V11 的 14.35% CAGR / 7.69% MDD / 1.52 Sharpe 是 2026-08-20 冻结工件中的历史输出，不能作为当前产品成绩。2026-09-04 在 Flyingrtx 生产行情与 NFCI as-of 数据、当前 App engine、1.00% 单边费率和 0.05% 滑点下的只读线上复跑为：全史 6.03% CAGR、15.86% MDD、0.686 Sharpe（463 笔交易）。完整输入 hash 与窗口在研究归档：`/Volumes/江波龙/Allprojects/AssetTimeMachineResearch/studies/v11-online-replay-2026-09-04/ONLINE_REPLAY.md`。该记录不改变 V11 的 `G3 PARTIAL`、`G4 INVALID_SOURCE_UNAVAILABLE`、`G6 RUNNING` 状态，且 V11 不得作为当前推荐/宣传基线。

## 当前状态

运行：

```bash
python3 scripts/validate_strategy_protocol.py
```

预期至少输出：

- `PROTOCOL_VALID ATM-SVP-1`
- G0 / G1 / G2 = PASS
- G3 = PARTIAL（V11 legacy trial count 不完整）
- G4 / G5 = PENDING
- G6 = RUNNING

## 新实验怎么开始

1. 从 `preregistration-template.json` 创建正式 prereg payload；必须填完整候选族、dataset/holdout manifest、固定选择指标、PASS/FAIL 门槛和 Swift engine 入口。
2. 在**运行实验之前**写入 hash-chain ledger：

```bash
python3 scripts/strategy_validation_ledger.py append \
  --event PREREGISTER \
  --payload-file <preregistration.json>
```

3. 立即 `git add` + `git commit`：preregistration、ledger、dataset/holdout manifest、正式 Swift research code 都必须在实验前进入 Git。
4. 用 formal-run wrapper 执行，禁止直接手工跑“正式结果”：

```bash
python3 scripts/strategy_validation_formal_run.py \
  --trial-id <trial-id> \
  --output-dir tools/research-results/strategy-validation/runs/<trial-id> \
  -- <committed Swift-engine command and arguments>
```

wrapper 会先通过 `strategy_validation_run_guard.py`，确认 preregistration 已存在于当前 Git HEAD 且工作树干净，然后保存 run authorization、执行 commit、命令、stdout/stderr 和 return code。

5. 对正式输入数据和结果附件生成 SHA-256 manifest：

```bash
python3 scripts/strategy_validation_artifact_manifest.py \
  --trial-id <trial-id> --kind dataset \
  --output <dataset-manifest.json> \
  --file <input-1> --file <input-2>

python3 scripts/strategy_validation_artifact_manifest.py \
  --trial-id <trial-id> --kind result \
  --output <artifact-manifest.json> \
  --file <run-authorization.json> --file <execution.json> \
  --file <stdout.txt> --file <stderr.txt> \
  --file <swift-output.csv> --file <statistics.json>
```

6. 从 `result-template.json` 创建 RESULT；必须绑定 `preregistration_record_hash`、`execution_git_commit`、run receipt、dataset manifest、artifact manifest，而且正常 PASS/FAIL/INCONCLUSIVE 必须报告**全部 preregistered candidate**。
7. 追加 RESULT：

```bash
python3 scripts/strategy_validation_ledger.py append \
  --event RESULT \
  --payload-file <result.json>
```

8. 再运行 `python3 scripts/validate_strategy_protocol.py`。checker 会重算 frozen-policy SHA、ledger hash-chain、result evidence SHA，并验证执行 Git commit/receipt 是否一致。

## DSR

只有确认 trial-family 输入包含该研究族**所有测试候选**时才允许计算：

```bash
python3 scripts/strategy_validation_stats.py dsr \
  --series-csv <swift-engine-portfolio-series.csv> \
  --series-column portfolio_value \
  --series-kind value \
  --trial-sharpes <all-trial-sharpes.csv> \
  --trial-sharpe-column sharpe \
  --trial-family-id <trial-family-id> \
  --certify-complete-trial-family
```

V11 的 pre-ATM-SVP-1 历史 trial family 不完整，因此不得用该命令人为挑选少量历史候选来生成 retrospective DSR。

## G3 / 模型选择纪律

- **所有正式尝试都计入 trial accounting**：成功、失败、INCONCLUSIVE、INVALID、被放弃的参数点、ablation、factor screen、数据变换和 follow-up variant 都不能因为“最后没选它”而消失。
- **禁止只保存赢家**：PREREGISTER 必须先冻结完整 candidate family / search budget / selection rule；RESULT 必须报告全部 preregistered candidates。
- **禁止追着结果继续搜索直到过线**：前一次 formal result 较弱，不构成新增 grid、因子、资产集或参数邻域的许可。只有 preregistration 明确允许的 follow-up 才能继续；否则必须作为新的 trial family 重新事前注册。
- **历史 trial count 不完整就不能认证 G3 PASS**：PBO 较低、参数邻域平滑、Bootstrap 好看只能作为局部证据，不能替代完整 multiple-testing accounting，也不能把 `NOT_CERTIFIED_LEGACY_TRIAL_COUNT` 改成 PASS。
- **产品文案必须保留失败和不确定性**：G0–G6 是本项目的治理 Gate，不是行业认证。`PARTIAL / PENDING / RUNNING / FAIL` 不能被压缩成“完全验证”“机构级验证通过”或“泛化通过”。

## G4 pristine role holdout

`role-holdout-manifest-template.json` 只能先做 metadata-only 填写。exact alternate symbols/source 冻结并提交 Git 之前，不得下载/查看完整收益历史。冻结后只允许 5 次单角色替换 + 1 次全替换，共 6 次正式运行；看过结果后不得为同一 V11 另找第二套 holdout。

G4 的不可逆流程固定为：

1. **Metadata only**：只查看 series 名称、角色定义、频率、首尾可用日期等 metadata，不看价格曲线、收益、Sharpe、MDD。
2. 用 `strategy_validation_exposure_scan.py` 对五个 exact alternate symbol 做大小写不敏感的当前 Git + `git log -S` 历史扫描；任何已有研究暴露都拒绝。
3. 将 scan 路径和 metadata evidence 写入 holdout manifest，然后：

```bash
python3 scripts/strategy_validation_holdout.py freeze --manifest <holdout.json>
```

4. commit frozen manifest + exposure scan。
5. **在任何完整历史下载之前先永久烧掉这组 holdout**：

```bash
python3 scripts/strategy_validation_holdout.py burn --manifest <holdout.json>
git add tools/research-results/strategy-validation/trial-ledger.jsonl
git commit -m "research(validation): burn G4 role holdout"
```

6. 只有 burn 已存在于当前 Git HEAD 且工作树干净时，才允许：

```bash
python3 scripts/strategy_validation_holdout.py authorize-open \
  --manifest <holdout.json> \
  --receipt <holdout-open-authorization.json>
```

`HOLDOUT_BURNED` 是故意在取数**之前**提交的：即使数据源故障、下载失败或正式 G4 FAIL，这五个替代资产也已经永久失去 pristine 身份，同一 V11 不得再换第二套。

### G4 role normalization / runner

外部 source symbol 不允许直接进入 V11 逻辑。holdout manifest 必须同时冻结 source currency/unit/frequency、normalization rule 和固定中性 symbol：`atm_g4_gold_safe_haven`、`atm_g4_us_growth_equity`、`atm_g4_us_broad_equity`、`atm_g4_china_large_equity`、`atm_g4_china_broad_equity`。

`build_g4_role_fixture.py` 只负责把 immutable raw source series 归一化/改名并与现有 V11 base fixture 合并，不实现策略。ATM-SVP-1 当前只实现 `identity` normalization；任何新的换算公式必须在 holdout freeze/burn 前实现、测试并提交，开封后不得补公式。

正式 G4 使用 `run_v11_role_generalization.py` + `tools/v11_role_generalization.swiftpart`。Swift 仍调用 `.nfciDualCoreSimplifiedV11` 和原 `BacktestEngine`，固定运行 1 个 baseline identity control + 5 个 one-slot substitution + 1 个 all-alternate。只有 6 个 substitution 是正式 run budget；baseline 只是实现一致性 control。正式模式必须带 `strategy_validation_holdout.py authorize-open` 产生的 receipt，并且 receipt 必须绑定 frozen manifest 的精确 SHA。
