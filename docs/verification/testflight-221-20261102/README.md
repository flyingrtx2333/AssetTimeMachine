# TestFlight 1.14 (221) · 2026-11-02

- Release source: `04ce967f9c56284ccd1db103ad3e94b9a61c975c` (calendar implementation `2cfe8b9`, preserved sync/settings fixes).
- Archive and IPA export succeeded on macmini from the clean isolated application checkout. Main app and Widget are both 1.14 (221); signing, bundle identity, encryption declaration and durable IPA checksum verified.
- App Store Connect validation and upload succeeded. Delivery/build ID: `a35e7aa3-6142-4a08-8129-59c3d545d408`.
- Apple processing: `VALID`. Existing internal group `flyingrtx`: `IN_BETA_TESTING`. Simplified Chinese, Traditional Chinese and English release notes written and read back successfully. No external beta review or App Store release submitted.
- Includes the iOS Time Machine daily net-asset change calendar, record navigation, regional/manual rise/fall colors and existing amount masking. Shared projection and UI evidence are in `../ios-daily-change-calendar-20261102/`.
- Prior full iOS Release simulator validation, shared calendar checks and localization audit passed for this source; the release helper skipped the redundant Debug simulator build. Strategy logic was unchanged; no additional strategy regression run.
- Physical-device update and taps remain pending user acceptance. API beta availability is verified separately from device acceptance.
- Signed archive, IPA, upload/processing logs and final receipts are preserved at the path in `durable-archive.json`. No credentials or personal financial data are included here.
