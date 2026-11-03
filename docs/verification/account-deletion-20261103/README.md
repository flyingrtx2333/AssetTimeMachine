# Account deletion review repair

Continues chat `01a171ac-3b82-7872-8341-39c581a34d6e`, where the user chose to implement deletion before resubmitting and to preserve website/other-product data. Source baseline is the current 233 release branch at `61226ee`. No new build number or release has been assigned yet.

The iOS Settings data section and native Mac cloud-account surface expose Delete Account. The shared view shows the exact irreversible scope, supports cancellation, asks for final confirmation and uses native Apple reauthentication when required. Necessary consequence/error text is retained; no extra section subtitles were added. The deletion view scrolls for long text and larger type.

The client uses the new product-specific login endpoints. A completed deletion cancels pending sync, clears local credentials and old sync metadata, and keeps the device's offline records. Recreated accounts use a different identity and require explicit association of old local records before upload. Normal upgrades keep their existing baseline. An account switch preserves the existing cross-user ownership barrier. A failed metadata cleanup remains gated across restarts.

The backend counterpart is branch `codex/atm-account-deletion-20261103` in FlyingrtxFast; its `docs/verification/atm-account-deletion-20261103/` contains real HTTP/MySQL/COS lifecycle proof and rollout constraints. The temporary validation API did not replace production. Apple token revocation still requires a dedicated service key and real reauthentication. The user plans to connect an iPhone to Mac mini for the requested physical-device recording. Neither that recording nor visual acceptance of this new flow has occurred. The previous browser connection was unavailable, so no developer-portal key was created.

Mac/iOS compiler results and localization checks are recorded in `build-checks.json`. These are compilation evidence, not a claim of physical-device or Apple authorization acceptance. No upload or App Store resubmission has been made for this repair.
