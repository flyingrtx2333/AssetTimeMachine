# iOS Time Machine linked date selection · 2026-11-02

## Cause and fix

Build 221 kept the hero chart probe and daily calendar selection in separate private `@State` properties. Neither surface received the other selection.

`TimeMachineView` now owns one selected timeline date and passes the same binding to both surfaces. Chart/ruler gestures update the calendar selection; tapping a recorded calendar day supplies the closing snapshot timestamp to the chart probe. Unrecorded/future cells cannot move a record probe. Calendar highlight compares calendar days rather than exact timestamps, follows selection across years, and scrolls the selected week into view.

A day selected before the chart's visible range expands the chart range to All. Changing to a shorter range reconciles selection to a visible point after the projection refresh. Selected real points are retained alongside the 180-point drawing sample so a calendar choice cannot silently snap to a neighbouring sampled day. No financial records, persistence schemas, sync code or strategy logic changed.

## Verification

- `scripts/test_time_machine_linked_selection.py`: PASS. Executes the production binding, year-following and sampling method bodies with actual chart sampling/search helpers. Checks both view inputs use the parent binding, chart-to-calendar and calendar-to-chart updates, timestamp retention, visible/older dates, cross-year following, an omitted sample restored exactly, and clearing.
- `scripts/validate_xcode_build.sh ios`: full Release simulator build PASS.
- Localization audit: PASS (1549 keys, 766 direct calls, 1080 Chinese source literals).
- This focused check proves date-state propagation and sampling; it does not claim physical-device touch acceptance. Native Mac sources and the strategy engine were not modified.
