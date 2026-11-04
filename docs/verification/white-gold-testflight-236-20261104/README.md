# White and gold icon — TestFlight 1.14 (236)

Build 236 updates the AssetTimeMachine app icon to warm white and champagne gold. Relative to signed build 235, runtime changes are limited to the icon assets and build number; application and widget executable UUIDs remain identical.

- Signed source: `85e50874abe44e0a60eae10df29b287a10c4216b`.
- Delivery UUID / Apple Build ID: `705e1cdf-77a6-4735-9512-d8b689a9a261`.
- Apple processing: `BUILD-STATUS: VALID`.
- Internal availability: `IN_BETA_TESTING`, existing group `flyingrtx` membership confirmed.
- English, Simplified Chinese and Traditional Chinese TestFlight notes saved and read back.
- The App Store review remains on build 235, `WAITING_FOR_REVIEW`; no replacement or withdrawal was performed.

Verification includes all 13 source icon dimensions/opacity, iOS and macOS asset-catalog compilation, localization audit, signed Release archive/export, strict/deep code signature, App Store distribution entitlements, main/widget executable-to-dSYM UUID matching, and exact Apple asset size/MD5 matching. The exported icon's decoded RGB pixels exactly match the independently compiled white/gold source icon. The pixel comparison normalizes RGB because archive export removes the redundant alpha channel.

No product logic or data schema changed. No personal device was installed, and no account or user records were modified. This is package and TestFlight availability verification, not physical-device visual acceptance. Existing Swift concurrency warnings remain unchanged.

The one-shot Aqua publisher completed successfully and was unloaded. Durable archive, IPA and full logs are preserved at `/Users/xiangjunsheng/Library/Application Support/AssetTimeMachineReleases/TestFlight-1.14-236`.
