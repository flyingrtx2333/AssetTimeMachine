# Account deletion review repair — TestFlight 1.14 (234)

Continues chat `01a171ac-3b82-7872-8341-39c581a34d6e` and the user-approved repair for the 1.14 (233) rejection. Signed release source is `cbc89927283cce355b4facfe882f0bd18892dba9`; later evidence-only commits do not change that binary.

The iOS Settings data section and native Mac cloud-account surface expose Delete Account. The shared scrolling view states the irreversible scope, supports cancellation and confirmation, and uses native Apple reauthentication when required. Completed deletion clears sync credentials and old sync metadata while preserving offline records. A recreated account gets a new identity and requires explicit association before uploading old local records. Normal upgrades keep their baseline; account switches retain the existing ownership barrier.

The immutable backend runtime `5c7d36fe6acf3dfeb51093a3d82b06ff53488cf5` is deployed. The production API passed seven real HTTP/MySQL/COS lifecycle checks using disposable accounts, including credential revocation, cloud object deletion, retained website identity, untouched control data and concurrent upload/deletion. Fixtures were removed. The Apple Sign in with Apple service key was created with explicit user approval and configured privately on the server. Live Apple credential preflight passed for iOS/Mac, but real Apple reauthentication and grant revocation remain unverified.

Archive and export succeeded. Apple accepted delivery `4a1f2f94-3c8a-4674-a92f-0a66c6e7d0ab`; processing is `VALID`, internal state is `IN_BETA_TESTING`, and membership in the existing `flyingrtx` internal group plus en-US/zh-Hans/zh-Hant notes were read back. The exact uploaded software asset matches the IPA checksum and release source. Codesign and archive/IPA executable UUID verification passed. See the JSON receipts alongside this file.

The archive and IPA are retained under `/Users/xiangjunsheng/Library/Application Support/AssetTimeMachineReleases/TestFlight-1.14-234`. Every original file and symlink was checked after copying; source artifacts were retained. The private service key is outside the repository and app bundle.

Mac and iOS compiler/localization evidence is in `build-checks.json`; the native installed Mac application was not updated by this continuation. No physical iPhone is currently detected. Physical-device visual acceptance, real Apple reauthentication/deletion, and Apple's requested recording remain pending. No App Store resubmission or reviewer response has been sent.
