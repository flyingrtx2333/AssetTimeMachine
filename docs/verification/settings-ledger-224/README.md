# Settings ledger · TestFlight 1.14 (224)

Release baseline: 1.14 (223), iOS source 88ac3b4e0e8e0262b34d835010f8828fa115ae69. Only this task's settings changes were cherry-picked onto that baseline; the older worktree's unrelated strategy commit was not included. The newer gain/loss color control and existing cloud/Time Machine fixes are preserved.

Settings use the selected B composition with original AppTypography fonts and AssetTheme/AssetColorPalette colors. No custom font resource, backend, schema or calculation change is included.

Validation against the integrated 224 candidate:
- Debug iOS simulator build passed; localization audit passed (1,549 keys).
- Two real native settings tests passed on iPhone 17 Pro Max: appearance changes, large text, expense navigation, language/frequency/strategy/cloud flows.
- Full onboarding flow passed on iPhone SE 3: automatic first entry, cancel/resume, empty amount rejection, skip/relaunch, settings replay, zero amount save and completion/relaunch.
- Tested runtime file hashes are retained; no simulated backend or mocked account was used. No physical-iPhone acceptance is claimed.

Apple processing, distribution availability and the final signed-package receipt will be appended after completion. No App Store or external Beta review is requested.
