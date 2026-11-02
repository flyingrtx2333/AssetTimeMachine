# iOS daily net-asset change calendar · 2026-11-02

Implemented over SSH on macmini in the isolated application checkout, based on the native Mac calendar commit `781041a`. Existing account, sync, settings and strategy work is preserved.

## Behavior

- Time Machine displays a horizontally scrollable year grid below the main trend chart, initially positioned at the latest recorded day in the selected year. Year selection covers recorded years and the current year.
- Selecting a day displays the signed CNY change and actual comparison date. The Record action resolves the closing snapshot by UUID. Amount masking follows the existing Time Machine visibility control, including accessibility values.
- Palette menu and Settings → Preferences → Change colors use the same stored preference. Follow Region defaults to red up in CN, green up elsewhere; explicit red-up and green-up overrides persist.
- iOS and native Mac now use `AssetChangeCalendarData.swift` for the exact same daily closing/net-balance projection and color preference. The original preference key is retained. Chart date range and live market movements do not alter recorded daily changes.
- Missing dates are blank; first observations have no comparison; future records are excluded. A gap compares to the previous recorded date, which remains visible. This is net-asset change, including deposits/withdrawals and liabilities, not investment return.

## Evidence

- Full iOS Release simulator build: PASS (`scripts/validate_xcode_build.sh ios`, macmini).
- Shared calculation/persistence check: PASS (`scripts/test_native_change_calendar.py`, macmini). Covers duplicate daily snapshots, liabilities, gaps, cross-year baseline, leap year/DST, invalid/future values, rounding, regional defaults and override persistence.
- Localization audit: PASS, 1549 keys, 766 direct calls, 1080 Chinese source literals.
- Screenshots: actual `TimeMachineChangeCalendar` SwiftUI source with actual production color tokens, running in a dedicated iPhone 17 / iOS 26.5 simulator. All financial figures are synthetic. The harness supplies snapshot projections and the outer page heading; these are component evidence, not captures of a signed-in application.
- `red-rise-light.png`, `green-rise-dark.png`: opposing palettes/light-dark appearance.
- `empty-dark.png`: missing records remain neutral, without invented zero changes.
- `hidden-dark.png`: signed amount masked.
- `large-type.png`: accessibility text size, wrapping header/date and stable calendar axes.

Device taps, full-app navigation to a saved record, and TestFlight installation have not been manually exercised for this iOS change. No TestFlight upload or production data writes were performed.
