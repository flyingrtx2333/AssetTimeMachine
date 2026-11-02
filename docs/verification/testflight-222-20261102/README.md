# TestFlight 1.14 (222) · 2026-11-02

- Signed release source: `8c821e4bebb5934d7b63a8513f1b4f76deab6b96`; linked-selection fix: `d410178`.
- Fixes the separate date states introduced with the daily calendar in 221: chart probe/ruler and calendar now share one selection. Cross-year selections follow the calendar year; older selections expand the curve range, and a selected day survives line downsampling.
- Focused selection regression and full iOS Release simulator build passed. Localization audit passed. See `../ios-linked-selection-20261102/` for scope and proof limits. Financial data, cloud sync and strategy calculations are unchanged.
- Main app and Widget: 1.14 (222). Strict archive signature, bundle/team identity, encryption declaration and durable IPA checksum verified.
- App Store Connect validation/upload: succeeded. Delivery/build ID `33dc4c26-c6a0-4969-8a12-80ad5011a1fa`.
- Apple processing: `VALID`; existing internal group `flyingrtx`: `IN_BETA_TESTING`. English, Simplified Chinese and Traditional Chinese notes written and read back. No external beta review or App Store release submitted.
- Archive/IPA/logs/final receipts preserved at the path in `durable-archive.json`. Physical-device update and touch acceptance remain pending user acceptance.
