# Compact iOS Time Machine toolbar · 1.14 (227)

App source: `c8aac333dd7128dd71666ca21586172d88da99d1`.

- Move the amount-visibility and video-export buttons from the separate top-right row into the left side of the date/range row. Remove the old page header.
- Use plain 15-point eye and `square.and.arrow.up` icons, retaining 44×44-point hit areas and localized accessibility labels. The date uses a compact localized numeric format; the existing range menu remains on the right.
- Privacy still toggles the same persisted preference. Export calls the existing preview presenter and retains the same minimum-record and presentation guards. No video generation, data, sync or calculation code changed.
- The native Mac app and its source are unchanged from 226. Its previous build verification is reused; no native Mac reinstall was performed for this iOS-only change.

`ios-dark.png`, `ios-hidden.png` and `ios-english-light.png` are actual SwiftUI component captures with synthetic records on a dedicated iPhone SE (3rd generation), iOS 26.5 simulator, 375×667 points. The toolbar fits one row in Chinese and English; the hidden state uses the slashed eye and masks amounts. The English host includes the real compiled localization catalogs. These are component captures, not a full signed-in application or a physical-touch/video-encoding acceptance run.

The iPhone simulator Debug build, signed Release archive and localization audit passed (1,549 keys, 763 direct calls). Business/strategy regression was not expanded for this layout-only change. Release receipts record exact Apple/local IPA identity, build processing, internal-group availability and release-note readback. Physical-device acceptance remains pending.

TestFlight **1.14 (227)** is `VALID` and `IN_BETA_TESTING` in internal group `flyingrtx`. Apple and local IPA both contain **17,737,638 bytes**, MD5 **`14770787ba4ce37a8163e6e95e76ff7c`**. Explicit upload receipt, Apple build upload and processed build share ID `1bdcae1f-3f4c-4523-a27d-2873e8311987`. English, Simplified Chinese and Traditional Chinese notes were verified by readback. No App Store release or external review was submitted.

The first group-assignment request returned HTTP 422. A subsequent authenticated read confirmed the build was already assigned and `IN_BETA_TESTING`; the idempotent publisher then completed all readbacks. No duplicate IPA upload or rebuild was needed. Archive/export executable UUIDs and the durable backup SHA256 were verified. Signed archive, IPA, logs and capture recipes are preserved at the path in `durable-archive.json`. Only this task's synthetic-data simulator was deleted.
