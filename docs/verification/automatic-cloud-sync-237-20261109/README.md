# Automatic cloud sync — TestFlight 1.15 (237)

Released 2026-11-09 from `1ddaded08d3033af6de1266b9140791ba8bd6ff7`.

Same-account relogin recovers verified shared history automatically. Per-field manual edit clocks and verified copy ancestry prevent stale carried-forward balances and newer quote refreshes from overriding user edits. Unknown ownership and genuinely ambiguous legacy changes retain their existing protections.

Validation: focused native cloud transport checks 34/34; user-edit reconciliation, inheritance and logical-deletion scripts passed; native Mac and iOS simulator Release compilation and localization audit passed. Private exported records were reconciled read-only, preserving history and matching the expected manual corrections; financial exports remain outside Git.

Apple accepted 1.15 (237), delivery `7624daa0-e03e-4383-9c96-2567ecd05fa8`, with `VALID` processing and `IN_BETA_TESTING` for existing internal group `flyingrtx`. Group-centric membership and three-locale notes were read back. Main app and widget signatures, distribution entitlements and executable/dSYM UUIDs passed. Apple's exact ASSET bytes/MD5 match the exported IPA; see the adjacent receipts.

The initial 1.14 (237) upload was rejected because the 1.14 release train was closed; only marketing version changed for the successful upload. No formal App Store/external Beta review was submitted. The agent did not install on a personal phone. The user subsequently confirmed successful automatic sync with a healthy cloud status; they reported slow completion, which remains a separate performance follow-up.

Durable release artifacts on Mac mini: `/Users/xiangjunsheng/Library/Application Support/AssetTimeMachineReleases/TestFlight-1.15-237`. The one-time Aqua publishing job completed and was unloaded. Source synchronization does not replace either installed Mac binary.
