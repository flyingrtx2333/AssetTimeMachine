# Record editor brightness · 1.14 (229)

App source: `45b4fc00b301577c3546d2eca6d1dccbf9875c24`.

The Records and historical-snapshot editor overlays both used a fixed 42% black rectangle. The shared `RecordValueEditorSheet` also used ultra-thin material, allowing the dimmed content to tint its surface. This reproduces the reported gray page and input panel with the decimal keyboard visible.

Three style replacements remove that effect: both outside-tap rectangles are transparent, and the shared panel uses the opaque adaptive `AssetTheme.surface`. Hit-test shapes, outside cancellation, close/save callbacks, focus, keyboard handling, mutation barriers and financial calculations are unchanged.

`before-light.png` is the actual 228 app; `after-light.png` and `after-dark.png` are the actual 229 Debug app. Captures use a dedicated iPhone 17 Pro Max / iOS 26.5 simulator, identical 1320×2868 dimensions, the real Records page and decimal keyboard. Data is synthetic: two example accounts, ¥12,000 and ¥88,000. No production account or user export was used. The DEBUG preview flag holds the editor open, so these captures do not claim an end-to-end close/save test.

`visual-comparison.json` records unmodified PNG samples: the light page changes from RGB (147,146,143) to (254,251,246), and the panel changes from (181,179,177) to (254,254,254). The dark appearance keeps its normal dark page and opaque raised surface.

iPhone Debug build, signed Release archive and localization audit passed (1,552 keys, 766 direct calls). No new automated test suite or strategy regression was added for this three-line style change. Native Mac uses a separate editor; its 228 build remains unchanged. Physical-device acceptance remains pending.

Release identity, internal-group availability and durable archive checks are recorded in the adjacent receipts. Archives are retained in Mac mini's persistent Application Support release directory using buffered copying, fsync and per-file SHA256 checks.

TestFlight **1.14 (229)** is `VALID` and `IN_BETA_TESTING` in internal group `flyingrtx`. Delivery, verified Apple upload and processed build share ID `67780da9-53e3-4b53-9d4c-cd8388a31f96`. Apple and local IPA both contain **17,752,925 bytes**, MD5 **`d0580861f9b85fcc89115243682e5b88`**. All three release-note translations were verified by readback. No App Store release or external review was submitted. The archive/export executable UUIDs match, and the durable backup's exact IPA SHA256 and strict app signature pass. The dedicated synthetic-data simulator was removed.
