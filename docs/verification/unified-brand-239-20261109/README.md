# Unified in-app brand — build 239

The application icon had been updated to white and gold, but the separate brand_logo image was still black and gold. It is used by the native welcome screen, native sharing view, iOS backtest poster and iOS trend video. The native toolbar also still drew a generic system hourglass.

The shared brand resource now copies the approved 256px AppIcon artwork byte for byte. Existing dimensions and layout constraints remain unchanged. The native toolbar loads that same resource as an original-color image, with the existing system symbol retained only as a missing-resource fallback.

Native Release, iOS simulator Release and localization passed. The compiled native bundle successfully decoded the 256px non-template brand image, and its extracted artwork was visually verified as white and gold. Source-file equality to the approved artwork is recorded in asset-verification.json. The cloud/cache runtime code and its existing 42 checks are unchanged from d2176dc, so unrelated sync tests were not repeated.

Both installed native Mac apps were updated to 1.15 (239), source 2b370d6, and reopened with verified signatures. The actual installed brand resource was extracted and visually confirmed on each Mac. The local system-resolved application icon was also verified as white and gold. The Mac mini canonical fixed build product was refreshed.

TestFlight 1.15 (239), signed source 2b370d6747a941ed3cce489536b20c5c00e826c6, is VALID and IN_BETA_TESTING for existing internal group flyingrtx. Delivery 97b4dffb-a16e-488c-b221-2d162e510679 matches the exact exported IPA by Apple ASSET bytes/MD5. Main app and widget distribution signatures, entitlements, version/build and executable/dSYM UUIDs passed. The exported iOS asset catalog contains the 256px brand_logo rendition. Internal-group membership and all three locale notes were read back. No formal App Store or external Beta review was submitted, and no personal phone installation was performed by the agent.

Durable release artifacts: /Users/xiangjunsheng/Library/Application Support/AssetTimeMachineReleases/TestFlight-1.15-239. Both one-time Aqua jobs were unloaded after completion.


## Dock display follow-up

The user subsequently supplied a Dock screenshot that still showed the old artwork. The current app, its small ICNS renditions, the resolved Dock bookmark and both NSWorkspace/NSRunningApplication icon images were correct. A simple Dock restart still displayed the stale image. Refreshing this application's registration and rebuilding its single recent-app entry, then reloading Dock, corrected the actual displayed tile. Pinned Dock entry identities and order were verified unchanged. No app-code change or further TestFlight upload was needed. The user's full Dock preference backup remains private outside Git.

Actual Dock captures: `dock-before.png` and `dock-after.png`; see `dock-repair.json`. System icon lookup alone is insufficient to establish what Dock currently displays.
