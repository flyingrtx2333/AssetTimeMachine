# Calendar readability · 1.14 (230)

App source: `949bb4e824cebcf7038c52672650466c4d9e0ae1`.

- Chinese amounts below 10,000 use ordinary grouped integers (`+310`, `−620`, `+7,600`); larger amounts use 万/亿/兆. English uses ordinary integers followed by K/M/B/T (`+310`, `−620`, `+7.6K`, `+12K`). Changes below one yuan retain cents; zero is `0`. The selected-day detail and Mac tooltip retain the exact currency amount to cents.
- The dark palettes were reversed. Higher absolute-change levels now have lower luminance in both appearances and both hues. Text changes between dark and white to retain at least 4.5:1 contrast. Region defaults, explicit rise/fall preferences and the existing intensity thresholds are preserved.
- Each viewport fits whole week columns, scrolls to a complete selected column and snaps to week boundaries. A year has at most 54 columns: fixed stacks avoid the estimated-offset adjustment observed with lazy stacks (a 4-point drift that clipped the trailing cell). Cell equality and cached annual calculations remain in place. Resizing realigns the selection.
- No persisted schema, sync, account, net-change calculation, strategy code or existing settings were changed.

## Focused verification

- The new luminance assertion first failed against the old palette. The existing calendar check then passed with the fix: readable signed amounts, rounding boundaries, whole-column widths, decreasing luminance and existing contrast/accounting/preference checks. No strategy regression was added.
- Localization audit passed: 1,552 keys, 764 direct calls, 1,078 Chinese source literals. No new translation keys.
- Native Release build passed. Installed `/Applications/资产时光机.app` is 1.14 (230), source `949bb4e`; strict signature, identity, entitlements and executable equality passed. The fixed previous-app backup was retained.
- The actual native component redrew four cell bodies and formatted six full amounts across two successive selection changes. This is a focused redraw check, not an end-to-end chart gesture or physical-device benchmark.
- iPhone Debug compilation passed in the release helper. The actual calendar component was inspected on a dedicated iPhone SE simulator (375×667 points), in Chinese light/dark and with English amount units. Each capture waited eight seconds after launch. Sample records are synthetic; no signed-in account or private user export was used. Regional date formatting remains controlled by the device locale.

## Screenshots and comparison

| Surface | Before | After |
| --- | --- | --- |
| Native component, 752×420 points, dark | [228](../calendar-cells-228-20261102/mac-calendar-dark.png) | [230](mac-calendar-dark.png) |
| Native component, light | [228](../calendar-cells-228-20261102/mac-calendar-light.png) | [230](mac-calendar-light.png) |
| iPhone SE, Chinese dark | [228](../calendar-cells-228-20261102/ios-dark.png) | [230](ios-small-dark.png) |

Additional captures: [iPhone light](ios-small-light.png), [English amounts](ios-small-english.png), native full fixture at [820×660 dark](mac-dark.png) / [light](mac-light.png), and [800×620 dark](mac-small-dark.png). The main page scrolls vertically to the matrix footer.

The full native bitmap capture retains the previously observed missing selected-toolbar-label capture artifact. The 800×620 synthetic chart also exposes an existing overlap between the total/net-assets point labels; this calendar-only patch does not change chart annotations. The calendar screenshots above show complete signs, labels and selected-cell borders.

TestFlight **1.14 (230)** is `VALID` and `IN_BETA_TESTING` in internal group `flyingrtx`. The explicit delivery, Apple build upload and processed build share ID `2e6a3ff4-db52-480f-8822-aed7083f7dc6`. Apple and the local IPA both contain **17,758,129 bytes**, MD5 **`e42644dae6444128c599ac8c529d6a1d`**. All three release notes were verified by readback. The signed archive, exported IPA and release receipts are retained in Mac mini’s persistent Application Support directory; every copied artifact was checked after buffered writes and fsync. Physical-device acceptance remains pending. No App Store release or external beta review was submitted.
