# Settings layout · TestFlight 1.14 (219)

Signed source: `7ff18372b3cf1d33b14d41c18a4c285d89ef8fe6`, branch `codex/testflight-settings-219`. This release starts from the published 218 cloud-sync repair and changes only settings layout plus the build number. It does not include the research checkout's later composite strategy.

Apple processing is `BUILD-STATUS: VALID`; the existing `flyingrtx` internal group is `IN_BETA_TESTING`. English, Simplified Chinese and Traditional Chinese notes were read back. Delivery UUID: `551709a2-52a9-4eb7-82cf-bbd6ab8375c1`. No external beta review was submitted.

The normal background archive initially failed with `errSecInternalComponent`. A one-time LaunchAgent in the current user's Aqua login session passed a read-only keychain probe. That session could not read the removable volume, so an independent shallow clone of the exact pushed source was staged on the internal disk. The same maintained `release_testflight.sh --no-bump --skip-debug-build` then archived, exported, validated, uploaded and completed Apple processing automatically. The preceding Debug simulator build had already passed for this source. No keychain access controls or certificates were changed; both temporary jobs were unloaded after completion.

Validation: localization audit, clean source at archive, Debug simulator build, signed Release archive/export, strict recursive signature verification, Apple package validation, upload and independent ASC processing/group readback. The settings layout has not received physical-device visual acceptance.

Internal build directory: `/Users/xiangjunsheng/.codex/worktrees/atm-settings-testflight-219/AssetTimeMachine/build/TestFlight-1.14-219`. Verified durable archive: `/Volumes/小姐姐新家/策略研究数据/AssetTimeMachine/releases/TestFlight-1.14-219`; all 53 original file/symlink entries matched before adding the copy receipt. Initial failed signing evidence remains at `/Volumes/江波龙/Allprojects/AssetTimeMachine-settings-219/build/TestFlight-1.14-219-signing-failure`.
