# ATM-SVP-1 操作入口

正式协议：`docs/strategies/validation/strategy-validation-protocol-v1.md`

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
  --file <stdout.log> --file <swift-output.csv> --file <statistics.json>
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

## G4 pristine role holdout

`role-holdout-manifest-template.json` 只能先做 metadata-only 填写。exact alternate symbols/source 冻结并提交 Git 之前，不得下载/查看完整收益历史。冻结后只允许 5 次单角色替换 + 1 次全替换，共 6 次正式运行；看过结果后不得为同一 V11 另找第二套 holdout。
