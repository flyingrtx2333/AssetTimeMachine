# Unused UI code and merged-branch cleanup — 2026-10-24

Baseline: `74d320c3ec1527c2a34311e4579d1859d639697a` (TestFlight 215 release record).

## Code

Removed 31 unused UI/support types, seven unused private members, the never-scheduled detail-card task and its inert cancellation calls, unused imports, and documentation-only endpoint descriptors. Application source is reduced by 2,104 lines across 14 files.

The deleted types had no consumers outside the removed dependency graph. Symbol references were checked across iOS, native macOS, widgets, and repository scripts. Only declarations and their orphaned dependencies were removed; current views and navigation remain in use. Core calculation sources, SwiftData models, import/export, release artifacts and research evidence are unchanged.

Removed types:

`BacktestTopTab`, `StrategyCapabilityRadarChart`, `BacktestDCASettingSheet`, `BacktestTopTabPicker`, `AssetTimeMachineCloudEntryButton`, `MarketEndpointDoc`, `DashboardTrendCard`, `APIDocumentationView`, `ATMHeader`, `SectionTitle`, `GoldChip`, `InlineStat`, `CompactStat`, `HeroSideMetric`, `MarketPriceRow`, `EndpointCard`, `CapabilityRow`, `SkeletonLine`, `AssetIconView`, `SummaryColumnMetric`, `TimeMachineInlineMetric`, `TimeMachineCurrentAnchorItem`, `TimeMachineCurrentAnchorCard`, `TimeMachineComparisonToggleButtons`, `TimeMachineDualAxisTrendCard`, `TimeMachineHistoryDrilldownRenderData`, `TimeMachineHistoryDrilldownSheet`, `TimeMachineCompactLegendMetric`, `TimeMachineLegendMetric`, `NativeWorkspaceSection`, `NativeTrendCanvas`.

## Git branches

| Branch | Cleanup | Recoverable commit |
| --- | --- | --- |
| `codex/ios-kvo-testflight-20261022` | Deleted merged GitHub branch and macmini local branch | `d2eb461145f5a1a5c49f5b08c70d82331a02a068` |
| `codex/add-ke25-strategy-20261021` | Deleted merged macmini local branch | `d55d7d835e55de5f4d4a13749a8a7af210bf22af` |

Both tips are ancestors of the retained application branch. The remote deletion used an exact-tip lease. `main`, `codex/macos-app`, the active macmini research branch, and the build-206 branch still attached to its release worktree are retained. Research working files are preserved.

## Verification

- iOS Release simulator build: passed (`scripts/validate_xcode_build.sh ios`).
- Native macOS Release build: passed (`scripts/validate_xcode_build.sh native`).
- Localization audit: passed, 1,474 keys / 760 direct calls / 1,068 Chinese literals.
- Whitespace check and removed-symbol reference check: passed.
- Disposable build products were removed by the validation helper.

No new TestFlight build was published for this cleanup; build 215 remains the current published version. The cleanup does not change visible layouts, so a new visual design round or screenshot comparison was not needed.
