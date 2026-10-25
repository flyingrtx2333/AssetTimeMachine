# Strategy library metric refresh · 2026-10-24

The 25 visible product strategies use one generated reference snapshot shared by iOS and native macOS. The old template literals remain historical diagnostic inputs for non-product inventory; product getters and subtitles read the verified snapshot instead. Engine/rule-version or default-cost mismatches suppress reference values rather than silently showing stale numbers.

## Evidence and scope

- Source: current public `period=all`, 12-symbol, `include_ohlc=true` history, plus real QUAL history from the same endpoint and release-time-aware NFCI data. Retained in `tools/fixtures/backtest-history/`.
- Replay: maintained `AssetTimeMachineMetricDump --catalog-metrics`, initial cash 100,000 CNY, existing App engine and strategy parameters. Each template keeps its own App default fees/slippage. KVO, KE25 and recent overlays use 0.025% / 0%; other catalog entries use 0.025% / 0.05%.
- Every result ends on 2026-10-23. Actual start dates vary by strategy and are retained individually. No common-start comparison or formal-validation claim is made.
- Receipt: `tools/expected_backtest_metrics/app/strategy_catalog_metrics.json`, including input hashes, rule versions, parameter hashes, costs, periods and unrounded metrics.
- Generated presentation source: `Sources/AssetTimeMachineBacktestCore/Domain/StrategyCatalogMetrics.generated.swift`. Do not edit values manually.
- The separate historical 1% / 0.05% golden baseline was refreshed from the same new 12-symbol snapshot with the maintained refresh helper. It is not the product display source.

No strategy rules, parameters, catalog order, recommendation or formal gate status changed. This is a historical replay refresh, not a new research candidate or investment-performance guarantee.

## Repeat the refresh

```bash
python3 scripts/update_strategy_catalog_metrics.py --refresh
python3 scripts/update_strategy_catalog_metrics.py tools/expected_backtest_metrics/app/strategy_catalog_metrics.json --check
```

`--refresh` fetches public inputs, uses the maintained helper to rebuild the metric CLI and historical golden rows once, then replays the visible catalog at each strategy's current defaults. It rejects incomplete/nonfinite results. Review input, golden, receipt and generated-source diffs before shipping. The header shows the common cutoff; native row tooltips retain exact periods and costs.

## Verification

- Generated Swift source reproduces exactly from the retained CLI JSON.
- Public input hashes match the replay receipt.
- All 25 compiled product-template values match the independent replay receipt bit-for-bit; current costs, strategy versions and frozen-parameter hashes match.
- Native macOS and iOS device Release builds passed.
- The actual native strategy-library component was rendered against the compiled Core catalog in an isolated window. General and KVO-search captures are in `evidence/strategy-catalog-20261024/`; the cutoff and populated KVO metrics are visible. These are static component captures, not proof of full-window interaction or device testing.
- The maintained metric CLI was rebuilt successfully against the final presentation model as well.

## Installation status

After the user closed the previous app, the signed candidate was installed at `/Applications/资产时光机.app` and opened on the Quant page. Installed version: 1.14 (215), source revision `3552862-modified`. The installed signature, bundle metadata and executable hash match the verified candidate. User data and credentials were not modified by the installer. The iOS change has not been uploaded to TestFlight.
