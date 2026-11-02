# Settings ledger · TestFlight 1.14 (224)

Release baseline: 1.14 (223), iOS source 88ac3b4e0e8e0262b34d835010f8828fa115ae69. Only this task's settings changes were cherry-picked onto that baseline; the older worktree's unrelated strategy commit was not included. The newer gain/loss color control and existing cloud/Time Machine fixes are preserved.

Settings use the selected B composition with original AppTypography fonts and AssetTheme/AssetColorPalette colors. No custom font resource, backend, schema or calculation change is included.

Validation against the integrated 224 candidate:
- Debug iOS simulator build passed; localization audit passed (1,549 keys).
- Two real native settings tests passed on iPhone 17 Pro Max: appearance changes, large text, expense navigation, language/frequency/strategy/cloud flows.
- Full onboarding flow passed on iPhone SE 3: automatic first entry, cancel/resume, empty amount rejection, skip/relaunch, settings replay, zero amount save and completion/relaunch.
- Tested runtime file hashes are retained; no simulated backend or mocked account was used. No physical-iPhone acceptance is claimed.

Apple processing: VALID. The flyingrtx internal group includes this build and internalBuildState is IN_BETA_TESTING. en-US, zh-Hans and zh-Hant notes were read back exactly. Formal App Store version/build relationships are unchanged; no external Beta review was submitted.

Signed source: 0c5530d086c1cd0f1937cefcfb9a2263cf7ccf63. Delivery UUID / ASC build ID: 0e15eb8d-1502-47b5-ac49-56c5ba7dbb8b. Main app and Widget both export as 1.14 (224), strict signatures pass, distribution get-task-allow is false, and the removed standalone font is absent. IPA SHA-256: fe6b9272b6469bfcb090a9d16016b64ed26bfe988849bc4f4f4ed2393f1202d9.

Durable archive: /Volumes/江波龙/Allprojects/AssetTimeMachine/build/TestFlight-1.14-224. Copy verification covers 46 files/links. The temporary Aqua job was unloaded after independent Apple VALID and internal availability confirmation. Apple temporarily returned server 500 errors; successful upload, final altool VALID and REST readbacks are retained. The poller was stopped during cleanup after proof was complete.

See receipt.json, package-verification.json and asc-final-readback.json. Native checks remain simulator evidence, not physical-device acceptance.
