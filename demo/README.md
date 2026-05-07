# Demo Data

## Files

- `time-machine-demo.json`: 可复用的演示导入数据，默认生成 365 天连续快照，带起伏。

## Regenerate

```bash
python3 scripts/generate_demo_import_json.py --days 365 --end-date 2026-05-06 --out demo/time-machine-demo.json
```

## Import into simulator

```bash
xcrun simctl launch <DEVICE_ID> com.flyingrtx.AssetTimeMachine \
  -importJSONPath /Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine/demo/time-machine-demo.json \
  -replaceExistingImport \
  -openTimeMachineTab
```

需要完全替换现有数据时，保留 `-replaceExistingImport`。
