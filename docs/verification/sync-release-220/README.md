# Sync recovery · TestFlight 1.14 (220)

Signed source: `a388ed545312f151551f7e8bff1f2ba26c52bd70`, branch `codex/testflight-settings-219`. Merges the verified recovery branch into published 219 and updates the app/widget build number to 220. The 219 settings page is byte-for-byte unchanged; strategy code also matches 219. The approved native Mac B workspace and restored logo changes remain in the merged history.

Historical value differences can be reviewed by asset, date and field. Confirmation preserves unrelated records and later dates, saves private backups of both replicas, and survives interruptions/restarts. New edits invalidate an older decision. This does not remove deletion, account-ownership or unknown-baseline protection.

Apple processing is `BUILD-STATUS: VALID`; build 220 is independently verified in the existing `flyingrtx` internal group with `IN_BETA_TESTING`. English, Simplified Chinese and Traditional Chinese notes were written and read back. Delivery UUID: `32265fc2-59ac-4e91-8fa7-961e8f755f7b`. No external beta review was submitted; previous builds were retained.

Validation: localization audit, exact source/settings/strategy comparisons, Debug simulator build, signed Release archive/export, strict recursive archive signature verification, app/widget IPA version checks, Apple package validation/upload, processing and internal-group readback. The actual shared reconciler and native CloudStore match verified repair `0d04c85`; its focused merge/inheritance/deletion and 50 isolated transport checks are retained in the linked evidence. No unrelated strategy regression was run.

The maintained release helper ran automatically from a clean internal-disk release clone in macmini's existing Aqua session, after a read-only keychain probe. It exited 0; both one-time probe/release jobs were unloaded. No certificates or keychain access controls were changed. The separate research checkout was preserved.

Durable archive: `/Volumes/小姐姐新家/策略研究数据/AssetTimeMachine/releases/TestFlight-1.14-220`. All 53 original files/symlinks matched the internal release output before the final receipts were appended. IPA SHA-256: `8690ede706e1b90af86e5eff39e97e0056f2426b645020beea5d6cc7ff48c7fc`.

Physical-device upgrade and real-account sync acceptance remain pending installation; isolated transport, component checks and successful distribution do not replace that acceptance. No production asset data was changed during this release.

See [preflight](preflight.json), [Apple readback](asc-final-readback.json), [artifact verification](artifact-verification.json), [desktop release](desktop-release.json), [durable copy](durable-archive.json), and [repair evidence](../../../evidence/sync-conflict-recovery-20261027/README.md).
