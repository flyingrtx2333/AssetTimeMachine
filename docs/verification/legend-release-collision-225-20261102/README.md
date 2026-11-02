# Build 224 release collision and corrected integration

The phone was on 1.14 (224), and restarting did not remove the legend. The footer-removal source and local archive were correct, but the published software asset came from a concurrent settings release.

- Footer-removal IPA: `a93ab1e`, 17,764,414 bytes, MD5 `acc82bcc983e3fe4ba33f0c326a8eb1c`; archive and exported Mach-O UUID `7491A3EA-EDBF-313F-8EED-FE0D421DA247`.
- Actual Apple 224 `ASSET`: 17,777,342 bytes, MD5 `9f3201cd508f7fbc978c6d36bd3758d2`. It exactly matches the IPA from `codex/settings-ledger-testflight-224`, source `0c5530d`, which still contains the legend. ContentDelivery upload logs at 17:37 name that worktree. Both jobs shared buildUpload `0e15eb8d-1502-47b5-ac49-56c5ba7dbb8b`.
- Previous verification only matched the local package to its backup, then attributed an Apple `VALID` build with the same version to it. That source attribution was incorrect. The old README is explicitly corrected; its original client-assigned source value is not Apple binary proof.
- The settings branch is merged, retaining its settings UI and this branch's footer deletion and performance work.
- The release helper now serializes cooperating worktrees on the same host, freezes the archive source revision, and requires Apple software-asset size/MD5 to match the local signed IPA. A validate-on-upload option avoids the separate validator's failed metadata transaction for this recovery; Apple's upload processing still must become VALID.
- The new guard was exercised against the real mismatched 224 asset and correctly rejected it. No new business/strategy regression was added.

Build 225 will be attributed only after an explicit upload receipt, a matching remote software-asset receipt, and internal-group availability are verified. Device acceptance remains a separate user check.
