# Build 224 release collision and corrected integration

The phone was on 1.14 (224), and restarting did not remove the legend. The footer-removal source and local archive were correct, but the published software asset came from a concurrent settings release.

- Footer-removal IPA: `a93ab1e`, 17,764,414 bytes, MD5 `acc82bcc983e3fe4ba33f0c326a8eb1c`; archive and exported Mach-O UUID `7491A3EA-EDBF-313F-8EED-FE0D421DA247`.
- Actual Apple 224 `ASSET`: 17,777,342 bytes, MD5 `9f3201cd508f7fbc978c6d36bd3758d2`. It exactly matches the IPA from `codex/settings-ledger-testflight-224`, source `0c5530d`, which still contains the legend. ContentDelivery upload logs at 17:37 name that worktree. Both jobs shared buildUpload `0e15eb8d-1502-47b5-ac49-56c5ba7dbb8b`.
- Previous verification only matched the local package to its backup, then attributed an Apple `VALID` build with the same version to it. That source attribution was incorrect. The old README is explicitly corrected; its original client-assigned source value is not Apple binary proof.
- The settings branch is merged, retaining its settings UI and this branch's footer deletion and performance work.
- The release helper now serializes cooperating worktrees on the same host, freezes the archive source revision, and requires Apple software-asset size/MD5 to match the local signed IPA. A validate-on-upload option avoids the separate validator's failed metadata transaction for this recovery; Apple's upload processing still must become VALID.
- The new guard was exercised against the real mismatched 224 asset and correctly rejected it. No new business/strategy regression was added.

Build 225 is now verified and available to the existing internal group:

- Source: `3a7c7cbe4f68fa5d7c2d85af1fb96be3cf44dca4`. Settings changes from `af0c477` were merged without restoring the calendar footer.
- The uploader explicitly returned `UPLOAD SUCCEEDED with no errors`. Delivery, Apple build upload and processed build all share ID `db171141-d39e-4541-81e9-9f4b2195fecc`.
- Apple and local IPA both contain **17,771,070 bytes**, MD5 **`a3a09666cf83000d2a64e32af3565f55`**. `artifact-match.json` records the authoritative Apple asset comparison; this is independent of the source revision supplied by the client.
- IPA SHA256: `96cd427c061b766d36526571747be24c0f0863f32482d0ed351ac12df02b3df8`. Exported and archived executable UUID: `6969B016-57C2-3117-BC4B-F4C280DD25A9`. The dSYM contains the new SettingsLedger views and no calendar legend symbols.
- App and Widget: **1.14 (225)**. Simulator Debug build, signed Release archive, strict archive signature, localization audit, Apple processing `VALID`, and CLI `ASC_VALID`: PASS. No business or strategy regression was added; native sources are unchanged from the verified Mac installation.
- Internal group `flyingrtx`: **`IN_BETA_TESTING`**. English, Simplified Chinese and Traditional Chinese release notes were verified by readback. No App Store release or external beta review was submitted.
- Archive, IPA, actual upload/build logs and final receipts are preserved at the path in `durable-archive.json`; the backup IPA SHA256 was checked.
- The existing component screenshots in `../calendar-legend-removal-20261102/` show the same unchanged footer-removal source. They are isolated native component captures, not full-app signed-in acceptance. A dedicated full-app simulator was attempted with synthetic imported records, but its chart remained empty; it is not claimed as a populated-screen verification. No production records or account were used. Physical-device acceptance of 225 remains pending.
