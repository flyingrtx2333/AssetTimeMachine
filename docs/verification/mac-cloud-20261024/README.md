# Native Mac cloud refresh and sheet — 2026-10-24

Signed and installed native source: `4df733c`. App: `/Applications/资产时光机.app`, version `1.14 (215)` with `ATMSourceRevision=4df733c`.

## Cause and changes

- The installed executable predated the shared build-211 legacy sync recovery/export fix. Updating Git and publishing iOS had not replaced the installed native binary.
- Native Home routed the cloud control to Settings. Home and Settings now open the same dedicated cloud sheet, preserving the current page.
- Native refresh previously depended on startup/scene changes. Application activation now triggers an immediate check; an active, signed-in foreground session checks every 60 seconds. Losing application focus or scene activity cancels the polling task. The store still owns any in-flight synchronization.
- During a shared cloud import, model-backed page views are unmounted and rebuilt on the committed data revision. History summaries reload from the store after an import.
- The sheet shows applied-backup time, recent backups, refresh, export, account association and confirmation-protected restore. Its restored-session height is explicit so controls remain usable after session hydration.
- Native builds now embed the app version/build and source revision, before development signing. Existing application, app-group and keychain identities are preserved.

## Verification

- Final native Release build and development-signature verification: passed.
- Compared application identifier, team, app group and keychain groups with the installed app: identical.
- Existing isolated cloud suite: all 30 checks passed, including unchanged-local pulls, legacy baseline recovery, conflict preservation, expired-token handling and export without upload. Synthetic transport only; no personal account used for this suite.
- Dark/light app-owned sheet captures: passed; opening the sheet retained the existing page. Samples are local at `evidence/mac-cloud-20261024/` and visibly use a synthetic account.
- The installed app then ran normal synchronization using its existing account. Its own import/history-refresh event confirmed that newer cloud records were applied. Personal counts, dates, values, account identity and raw runtime logs are excluded from this public verification record.
- The final installed binary has the expected source revision. The live sheet window was confirmed at 480 × 560 points. Operating-system window pixel capture was unavailable; visual comparison used the isolated app-owned captures.
- Localization audit: passed (1,478 keys). Shell syntax and whitespace checks: passed.

No manual restore, account reassociation or forced cloud replacement was performed. This is a local native Mac update; TestFlight 215 was not republished.
