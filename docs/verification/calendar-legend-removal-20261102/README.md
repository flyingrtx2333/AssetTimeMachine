# Calendar legend removal · 1.14 (224) · 2026-11-02

Removed the bottom minus/plus color scales from both native Mac and iOS, including the iOS Follow Region caption. Palette controls, daily change amounts, comparison dates, record navigation and linked chart selection are retained. The unused iOS legend/swatch helpers were removed. No models or financial calculations changed.

- Source: `a93ab1e73fe4f29093a362706997f634b51d275c`; iOS change `bcb83ea`, Mac change `95920bc`.
- Native Release build and installed-app signature/identity/entitlement/executable verification: PASS. `/Applications/资产时光机.app` is running 1.14 (224), source `a93ab1e`; the previous fixed app backup is retained.
- Required iOS simulator Debug build, localization audit, signed Release archive and IPA export: PASS. App and Widget both 1.14 (224); strict archive signature and durable IPA checksum verified. No additional business or strategy regression was run for this view-only deletion.
- `mac-after.png` and `ios-after.png`: actual calendar SwiftUI sources with synthetic records, in an AppKit component window and a dedicated iPhone 17 / iOS 26.5 simulator. These are isolated component captures, not signed-in account screenshots. The iOS preview simulator was deleted after capture.
- App Store Connect build `0e15eb8d-1502-47b5-ac49-56c5ba7dbb8b`: `VALID`; existing internal group `flyingrtx`: `IN_BETA_TESTING`. English, Simplified Chinese and Traditional Chinese notes verified by readback. No external review or App Store release submitted. Physical-device update remains pending user acceptance.
- The original CLI validation run reported network timeouts and four warnings, and the helper stopped before its explicit upload step. Official App Store Connect readback already showed build 224 accepted and valid. The accepted build was reused and assigned to the test group; no duplicate upload or package rebuild was attempted. Actual validation logs are preserved without fabricating a CLI upload-success marker.
- Signed archive/IPA, actual logs and final receipt are preserved at the path in `durable-archive.json`. No credentials or personal financial data are included in this evidence.
