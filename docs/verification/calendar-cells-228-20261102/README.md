# Daily-change matrix amounts · 1.14 (228)

App source: `fc2a63ee13d0c1b606f0dcb4195a50d833a53a27`.

- iOS and native Mac cells are now 56×40 points, with signed amounts printed inside. The annual week-column layout scrolls horizontally to the selected week; the main page retains its vertical scroll.
- Shared five-level palettes make magnitude differences clearer in both appearances. Thresholds use the year's distinct nonzero magnitudes, so equal changes stay equal and a single large change does not flatten the other colors. Zero is neutral; missing/future observations stay empty; a first observation without a comparison shows a dash.
- Below 100, both languages retain cents (`+23.45`, `−0.01`). Chinese uses 百/千/万/亿/兆 (`+1.2百`, `−3.4千`, `+1.2万`); English uses plain hundreds and K/M/B/T (`+120`, `−3.4K`, `+12K`). Rounded coefficients advance to the next unit at its boundary. The selected-day detail and Mac tooltip retain exact currency amounts.
- iOS privacy masks the new labels along with the existing detail values. Region defaults, explicit rise/fall color preferences, record opening and linked selection are retained. Lazy week columns and equatable cells preserve limited redraws during selection and hover.
- No persisted schema, cloud service, net-change calculation or strategy code changed.

Verification:

- The existing shared calendar check passed, extended only for compact amounts, sign/rounding boundaries, tied magnitudes, outliers, and minimum 4.5:1 text contrast in all five palette levels. Existing closing-balance, missing-date, cross-year and region-preference checks remain included.
- Native Release build, iPhone simulator Debug build, signed device archive and localization audit passed (1,552 keys, 766 direct calls). No strategy regression was expanded.
- Native installation is 1.14 (228), source `fc2a63e`; signature, identity, entitlements and executable equality were verified. Its fixed previous-app backup was retained.
- `mac-calendar-dark.png` / `mac-calendar-light.png` show the actual native calendar component with varied synthetic changes. `mac-dark.png` / `mac-light.png` show the full 820×660-point native fixture window; the larger matrix continues below the fold in the page's scroll view.
- `ios-dark.png`, `ios-english-light.png` and `ios-hidden.png` show the actual shared calendar component on a dedicated 375-point iPhone SE simulator. The host uses synthetic records, not a signed-in account. No physical-touch acceptance is claimed. Initial cold-launch frames were blank; the saved captures were taken after the UI settled.
- The selected synthetic date is 2026-07-18 on Mac (+¥12,000.00, shown as +1.2万) and 2026-10-27 on iOS (−¥680.00, shown as −6.8百 / −680). Edge columns are clipped by the horizontal viewport while scrolling; complete cells fit their values.

Release identity, TestFlight availability and durable archive receipts are saved alongside these screenshots. Physical-device acceptance remains pending.

TestFlight **1.14 (228)** is `VALID` and `IN_BETA_TESTING` in internal group `flyingrtx`. Explicit delivery, Apple build upload and processed build share ID `e38c2e61-63b2-47d8-bf49-efd045bd503f`. Apple and local IPA both contain **17,752,591 bytes**, MD5 **`5c5c777430881a87bb155abd02a89e22`**. All three localized release notes were verified by readback. No App Store release or external review was submitted.

The external-volume archive copy failed IPA verification with both fast and buffered copying. That directory is marked incomplete and its mismatched IPA was removed. The durable archive was instead saved in Mac mini's persistent Application Support directory (`durable-archive.json`): all 59 copied files were checked with SHA256 after buffered writes and fsync, the IPA matches the Apple-verified source, and the backup app's strict signature passes. The external failure's cause was not diagnosed as hardware failure. Source packages and published software were unaffected.
