# iOS App Store refresh · 1.14 (233)

Reference: the developer's [健身计数器 1.1.7 listing](https://apps.apple.com/cn/app/id6753942256).
The shared direction is warm ivory, concise oversized headlines and actual interface detail. The asset app keeps its own gold accent and financial content. Its old two-part decorative cover is replaced with the real product on the first image.

Final delivery: `posters/zh-Hans/` and `posters/en-US/`, five ordered **1320 × 2868 RGB PNGs per language**, without alpha. `overview-*.jpg` shows each sequence at storefront scale. Apple accepts this resolution in the 6.9-inch display group (`APP_IPHONE_67`).

1. Assets at a glance, real Dashboard inside a lifestyle photograph.
2. Dated asset and liability records.
3. Time Machine assets, net worth and liability gap.
4. Daily net-worth changes, using the actual calendar component.
5. Equivalent gold **in grams**, using the current app's recorded asset balances and public gold-price conversion.

## Provenance

- Actual iOS Debug UI: **1.14 (233)**, source `2b64ce2fae29e3990be3a9ce9d34b38f235cdea1`.
- Dedicated iPhone 17 Pro Max simulator, iOS 26.5. No signed-in account or user database was used.
- `raw/` contains the source images. Dashboard, Records, Time Machine and gold images are full-app captures. The calendar is captured in a standalone host of the unmodified current component, with the **same example balances** and October 15 selected to show a populated, centered set of weeks. No calendar values or chart curves were painted into the posters.
- `marketing/make_store_fixture.py` creates 365 days of synthetic account snapshots in both languages. These are account examples, **not strategy results**. Every poster identifies sample data. Gold uses the app's public-market lookup, not an invented gold-return series.
- Dashboard planning values are example user inputs (monthly expense 3,000 CNY, salary 10,000 CNY, inflation 2%, assumed return 4%); the displayed planning estimate comes from the app.
- Only the photograph surrounding the phone is generated, using the built-in `image_gen` tool. The real screenshot and headline are composited deterministically by `marketing/render_store_20261103.swift`. See `image-prompt.md`.
- `reference/` preserves the former asset listing and the fitness reference, including API metadata snapshots. These contain public store assets, not credentials or user records.

## Rendering

From the repository root, with the source captures in place:

```sh
swift marketing/render_store_20261103.swift
```

The renderer checks headline width, draws the AppKit canvas in RGBA, then exports explicit 24-bit RGB PNGs. Store copy is in `metadata.json`; both languages meet Apple's character limits. Upload uses `marketing/refresh_ios_store.rb`, which pins app/version/build, verifies screenshot dimensions and checksums, reads copy back, and only removes inherited smaller-size draft screenshots after both new sets are complete.

No strategy calculations, stored user data or runtime app UI were changed by this refresh. App Store submission status and exact asset verification are recorded in the accompanying receipts; preparing assets alone does not mean the public listing is updated.

## Submitted release

**1.14 (233)** was submitted successfully on November 3, 2026. Apple readback is **WAITING_FOR_REVIEW**, with release policy **AFTER_APPROVAL**. This means it will publish automatically after approval; the public storefront is not claimed live at submission time.

- Version ID: `9ddf8836-eba8-4ad9-a23b-cc5b1524ebaf`.
- Review submission: `494c7eb3-9378-45e0-b153-16dd1fbbbb11`.
- Binary/build: `4c169b4d-c268-46be-9d58-729b2401dfd3`.
- Exact IPA: **17,746,624 bytes**, MD5 `729bbb77144c4cff60e42fe6740b67e0`; Apple's asset size and checksum match the retained signed IPA (`artifact-match.json`).
- All ten images are `COMPLETE`, ordered and checksum matched. Both descriptions, keywords, promotional text and release notes passed readback. The new 6.9-inch sets replace the inherited 6.5-inch images only in the draft; the former live version is preserved.
- English store name is now **Asset Time Machine**. Both subtitles are localized. Existing privacy URLs and review contacts remain unchanged; a review note explains optional sign-in and sample data.
- `prepared.json`, `app-info.json`, `submission-created.json` and `submitted.json` retain the preparation and submission receipts. No App Store pricing, territory availability or privacy declarations were changed.
- The final ten posters are also delivered to the repository-required OneDrive delivery directory on Mac mini. The dedicated capture simulator was removed.

Apple's English image processing exceeded the initial wait period. A subsequent read confirmed completion, and the idempotent preparation resumed without re-uploading images. Submission only proceeded after all ten assets were verified.

Mac navigation issue: separately reported by the user while this refresh was being prepared. Investigation did not reproduce the persistent three-label state. It is **not marked fixed**; the user subsequently prioritized the iOS App Store release.
