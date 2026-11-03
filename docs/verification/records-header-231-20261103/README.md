# Records header · 1.14 (231)

App source: `5ad9631ffc0d800547cfddfeba891be6cf4dbb9a`.

The history `NavigationLink` was nested in the Records hero inside a `List` row. SwiftUI supplied a row disclosure arrow and stretched the history entry, leaving the clock far from the add button.

The clock is now an ordinary button. Its existing history destination is registered on the enclosing navigation content, outside the list row. The eye, history and add buttons form a fixed-width, right-aligned group with their existing 44-point hit areas and accessibility labels. The history callback dismisses the keyboard before navigating. The zero-balance and add-asset callbacks remain unchanged.

## Verification

- The single iPhone Debug build passed before visual review. The release helper reuses that completed check with `--skip-debug-build`; the exact build log is retained in the durable archive.
- [Before (230)](before-light.png), [after light](after-light.png) and [after dark](after-dark.png) show the actual Records page on the same dedicated iPhone 17 Pro Max / iOS 26.5 simulator, at 1320×2868 pixels. The extra arrow is gone and all three icons are compactly aligned on the right. Each capture waited eight seconds after launch.
- The same synthetic store is used before and after: two example accounts with amounts 12,000 and 88,000. No signed-in account or real user export was used.
- The destination is still `SnapshotArchiveView`; the navigation registration and callback were checked in source. These screenshots do not claim a physical tap/back-navigation test. No new test suite or strategy regression was added for this small UI change.
- The independent native Mac target does not compile this iPhone/Catalyst view. Its existing local 230 installation is unaffected.

TestFlight **1.14 (231)** is `VALID` and `IN_BETA_TESTING` in internal group `flyingrtx`. The verified upload and processed build share ID `68d891ba-0066-4cfb-87da-bfadac55fdf1`. Apple and the local IPA both contain **17,757,703 bytes**, MD5 **`38448cd3ca7752cb1c47f37bd9232aae`**. Three localized release notes passed readback. The strict archive signature, archive/IPA UUID equality and per-file SHA256 checks passed. Release artifacts are retained in Mac mini’s persistent Application Support directory. No App Store release or external beta review was submitted. Physical-device acceptance remains pending.
