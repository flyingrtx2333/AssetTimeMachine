# Time Machine summary and calendar cleanup · 1.14 (226)

Source: `d0d75c4cf61017e8dc020e296d7d847bad416b8b`.

- Both apps lead with **主资产**, using the existing total-assets field. The secondary line contains net assets and the selected date. iOS replaces its old period-change subtitle; Mac removes the duplicate total-assets metric while retaining liabilities and the last-record change.
- Remove the entire daily-calendar heading row, year picker and palette button. Remove the iOS separator immediately before the calendar and the native Mac separator immediately after it. Calendar cells, selected-day amounts, comparison dates and record navigation remain.
- Calendar year follows the selected chart date, falling back to the latest record year. Native Mac receives that date directly from the parent, preserving indexed selection and avoiding a new scan on each hover. Color preferences remain in Settings on both platforms.
- Native Release build, iPhone simulator Debug build, signed device archive and localization audit passed. No models, sync code or strategy calculations changed; no strategy regression was rerun.
- Local Mac installation is 1.14 (226), source `d0d75c4`. Its signature, application identity, entitlements and installed executable were verified. The previous app is retained in the fixed backup location.

Screenshots use synthetic records, without signing in or accessing production data:

- `mac-dark.png` / `mac-light.png`: full native fixture window at 820×660 points. Main assets ¥120,000, net assets ¥100,000, liabilities ¥20,000, selected date 2026-09-29.
- `ios-dark.png` / `ios-light.png`: the actual shared SwiftUI hero and calendar in an isolated iPhone 17 Pro Max simulator host. Main assets ¥213,300, net assets ¥193,300, selected date 2026-10-28. These are component captures, not a full signed-in app flow.
- `ios-previous-year.png`: programmatic selection of 2025-07-18 updates the chart probe, summary (¥203,960 / ¥183,960) and calendar year/day together. This is not a claim of physical touch testing.
- `ios-hidden.png`: both summary amounts and selected-day amount remain masked.

TestFlight **1.14 (226)** is `VALID` and `IN_BETA_TESTING` in the existing internal group `flyingrtx`. Delivery, verified software asset and processed build share ID `56495d66-6260-4154-a3c8-583e29313fe3`. Apple and local IPA both contain 17,746,308 bytes and the same MD5 (`artifact-match.json`). Archive/export UUIDs and the durable backup IPA SHA256 also match. All three release-note translations were verified by readback. No App Store release or external beta review was submitted. Physical-device acceptance remains pending.

The uploader recovered from two Apple API HTTP 500 messages and explicitly reported `UPLOAD SUCCEEDED with no errors`. The helper's old scan for any `ERROR:` falsely rejected that log before its asset-verification step. The exact existing delivery was verified directly with the maintained asset verifier, then assigned to the internal group; the IPA was not rebuilt or uploaded again. The helper now requires the final upload-success marker instead of rejecting recovered log messages, while retaining the remote-asset and processing gates. Shell syntax and the actual recovered upload log were checked. This helper-only follow-up does not change the app source or signed package above.

Signed archive, IPA, actual logs, capture recipes and release receipts are preserved at the path in `durable-archive.json`. The dedicated synthetic-data simulator was deleted; other simulators and user data were preserved.
