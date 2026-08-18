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

1. 从 `preregistration-template.json` 创建正式 prereg payload。
2. 在**运行实验之前**写入 hash-chain ledger：

```bash
python3 scripts/strategy_validation_ledger.py append \
  --event PREREGISTER \
  --payload-file <preregistration.json>
```

3. 立即 `git add` + `git commit` 该 preregistration/ledger；没有事前 commit 的正式结果不计入 ATM-SVP-1。
4. 使用 Swift App engine 运行实验并保存全部候选结果。
5. 创建 RESULT payload，再追加：

```bash
python3 scripts/strategy_validation_ledger.py append \
  --event RESULT \
  --payload-file <result.json>
```

6. 再运行 `python3 scripts/validate_strategy_protocol.py`。

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
