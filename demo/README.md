# Demo Data

## Files

- `time-machine-demo.json`: 可复用的演示导入数据，默认生成三年（1096 天）连续快照。金融资产覆盖账户现金、外币、贵金属、ETF 与 A 股，并包含三段可见回撤和整体上行走势。

## Regenerate

```bash
python3 scripts/generate_demo_import_json.py --days 1096 --end-date 2026-08-20 --out demo/time-machine-demo.json
```

## Import into simulator

```bash
xcrun simctl launch <DEVICE_ID> com.flyingrtx.AssetTimeMachine \
  -importJSONPath /Users/xiangjunsheng/Desktop/AllProjects/AssetTimeMachine/demo/time-machine-demo.json \
  -replaceExistingImport \
  -openTimeMachineTab
```

需要完全替换现有数据时，保留 `-replaceExistingImport`。
