# Time Machine interaction performance · 2026-11-02

## Cause and change

- Mac: each selected/hovered day caused the calendar to build and format all 365 buttons, including their tooltips and accessibility values. The grid and individual cells now compare immutable input data; hovering only updates the footer, and selection rebuilds the previous/new cells. Calendar data follows history revisions rather than the curve range, with indexed date/snapshot lookup. Date-rail animation is scoped to the rail instead of the whole page.
- iOS: the date Binding eagerly read its value while the page constructed child views. That subscribed the page to every probe update, rerunning chart initialization, sorting, sampling, domains and series. Both views now share an observable selection reference; only readers of its date update. A stable chart child owns paths/axes; a separate lightweight overlay owns probe dots, rule and tooltip. Sampling stays fixed; the probe resolves full-resolution records, including unsampled dates. Exact asset values determine the domain. Calendar cells/month labels compare their inputs, and scrolling follows a changed week rather than every pointer event.
- Range expansion, cross-year following, amount masking, palette, record selection and accessibility selection are retained. No financial records, sync schemas or strategy calculations changed.

## Measurement

Actual production SwiftUI components, optimized `swiftc -O` harnesses, synthetic 300-day records, 100 selected-date changes. Each before/after pair uses the same fixture and drive cadence. Diagnostic counters are added only to temporary copied sources, never the installed app.

| Metric | Before | After |
| --- | ---: | ---: |
| Mac calendar cell bodies | 36,500 | 199 |
| Mac amount formatting calls | 73,100 | 299 |
| Mac update p95, ms | 26.32 | 7.07 |
| iOS calendar cell bodies | 36,500 | 199 |
| iOS amount formatting calls | 36,600 | 299 |
| iOS full chart preparations | 100 | 0 |
| iOS driven-step p95, ms, including the scheduled 17 ms sleep | 152.56 | 21.77 |
| iOS CADisplayLink interval p95, ms | 315.88 | 51.62 |

Mac uses an actual AppKit window with a 1 ms main-run-loop yield and layout/display barrier. Its harness supplies simplified localization and the actual native style source; this is a component timing, not whole-page or end-to-end device input latency. iOS uses actual chart/calendar, production theme, typography, formatters and localization, in a dedicated iPhone 17 / iOS 26.5 simulator on macmini. Display-link intervals include simulator/host scheduling and are not a physical-iPhone FPS claim. These are one focused before/after run, not a multi-device benchmark. No user data, credentials, cloud requests or account stores are used.

A previous whole-app fixture tour did not produce its completion marker within its 45 s bound; no whole-app timing is claimed from it. The scoped component runs above are the completed measurements.

## Proof and reproduction

- Shared calendar regression: PASS; includes indexed date/snapshot lookup and financial/day invariants.
- Linked selection regression: PASS; production observable selection, deduplication, older range expansion, cross-year following, exact unsampled probe, stable line sample and clearing.
- Full native Mac Release build and installed-app signature/identity verification: PASS. Local installed version 1.14 (223), source `f6a768b`; `desktop-install-223.json` records verification. Full iOS Release simulator build: PASS. Localization audit: PASS (1549 keys, 766 direct calls, 1080 Chinese source literals).
- `ios-probe-calendar-after.png`: actual optimized views; probe, date ruler, calendar highlight and tooltip all show 2026-07-18 using synthetic figures.
- `measure_mac_component.py`: run from the repository with a result label; writes temporary source/binary and JSON to `build/calendar-interaction-perf/`.
- `measure_ios_component.py`: run from the repository on macmini; builds an isolated simulator harness under that same build folder. Install/launch it only in a dedicated disposable iOS simulator; results are written to that harness's own `Documents/result.json`. The saved script is the optimized observable-reference driver; the before run used the corresponding build-222 Binding driver.
- Physical-device touch acceptance remains pending; signed release and installed Mac verification are recorded with the delivery receipt.
