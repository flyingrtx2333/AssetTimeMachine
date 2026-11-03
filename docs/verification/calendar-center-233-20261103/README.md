# Centered calendar selection · 1.14 (233)

App source: `2b64ce2fae29e3990be3a9ce9d34b38f235cdea1`.

Both calendars previously scrolled the selected week to the trailing edge. They now use one shared calculation: count the complete visible week columns, choose the leading week that places the selected week closest to the center, and clamp only at the year boundaries. Even-width viewports use one of the two central columns so edge cells remain whole. Initial display, year changes and resizing use the same rule.

Probe changes within one week update the selected cell without scrolling again. Crossing a week scrolls to the new centered window. At a year edge, the leading week remains clamped until a different window is needed. No scroll animation or per-probe annual-data reconstruction was added.

The existing shared calendar check passed with phone five-column centering, Mac even-column centering, year-start/year-end clamping and a viewport wider than the entire dataset. Existing geometry, amount, contrast and accounting invariants remain covered; no strategy regression was expanded.

The native Release build and iPhone Debug build passed. The local signed native installation is 1.14 (233), source `2b64ce2`; signature, identity, entitlements and executable equality passed. `mac-calendar-dark.png` shows the actual native component with the selected July 18 week in the sixth of eleven visible columns. Its footer can reflect an independently hovered date. Both captures use synthetic records, without signed-in stores or user exports. Physical gesture acceptance remains pending.

`ios-calendar-center.png` shows the actual iOS component on a dedicated 375-point iPhone SE simulator, with October 27 in the third of five visible columns. The first cold launch hit a SpringBoard error; restarting only this dedicated simulator recovered it. TestFlight **1.14 (233)** is `VALID` and `IN_BETA_TESTING` in internal group `flyingrtx`. Apple and the local IPA match at **17,746,624 bytes**, MD5 **`729bbb77144c4cff60e42fe6740b67e0`**, with upload/build ID `4c169b4d-c268-46be-9d58-729b2401dfd3`. Three localized notes passed readback. Strict archive signature, archive/IPA executable UUID matching and per-file SHA256 backup checks passed. Artifacts are retained in Mac mini’s persistent Application Support directory. The dedicated simulator and completed release agent were removed. No App Store release or external beta review was submitted.
