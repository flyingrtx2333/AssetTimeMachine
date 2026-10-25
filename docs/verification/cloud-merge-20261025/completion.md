# Sync mechanism completion audit · 2026-10-25

The previous merge patch fixed derived-quote conflicts, but was not a complete end-to-end fix. Focused independent review reproduced additional normal-use failures: cross-day inherited balances compared as edits, canonical deletion aliases resurrected by an offline peer, missing automatic reconnect, and accepted uploads losing their common ancestor on a later auxiliary failure or lost response.

## Implemented behavior

- A copied entry retains an optional source UUID. Reconciliation accepts inheritance only when the same payload contains its actual earlier source with matching user values. Manual confirmation clears provenance, including confirmation of unchanged values. Automatic quote refresh preserves provenance and does not commit quantity drafts. Old rows without proof remain protected.
- Snapshot and entry deletions retain optional logical day/account identity. This identity survives tombstone merging, import/export and multiple sync cycles. Newly introduced opaque legacy deletions are hydrated from authenticated history; already acknowledged opaque tombstones do not require expired history. A deleted-and-recreated live record is never blindly deleted by day matching.
- Offline requests keep their intent with 2–60 second backoff. iOS checks on foreground activation and periodically while active; both platforms stop automatic timers while inactive. Unchanged local/baseline content polls lightweight authenticated head metadata, downloading the full payload only if needed.
- Acknowledged uploads save their accepted baseline before ancillary history listing or checking later local edits. A private per-account pending-upload journal survives an unknown response and application restart. Recovery requires an exact authenticated latest/history fingerprint; it never infers acceptance from clocks.
- Recovered deletion identity is written back to the actual cloud head using the existing compare-and-swap upload. Matching an enriched in-memory copy alone is not treated as a completed server update.
- Existing ownership, mutation/draft barriers, deletion-versus-edit protection and true conflicting user-value protection remain enforced.

## Compatibility and proof

Three optional SwiftData fields were added. The migration check compiles the actual old `6e7eadc` model schema and the current schema under the same module identity, creates an isolated on-disk store, verifies original data unchanged after migration, and verifies persistence of the new fields across reopening. The backend stores the complete dictionary payload unchanged, so it retains these optional properties without a server schema change.

- Shared merge (41), logical-deletion (5), and inheritance (4) focused checks passed.
- Actual old-store migration and reopen passed.
- Localization audit passed.
- Native Release and final iOS Simulator arm64 Release builds passed. The final isolated cloud transport probe passed all 42 checks, including automatic reconnect, lost-response recovery, concurrent save, provenance persistence and legacy-deletion healing without repeat full downloads. Receipt: `completion-sync-probe.json`.

## Deployment boundary

This document records source and isolated transport validation. It does not claim that the user's iPhone has installed this version or that real iPhone/Mac data has completed a two-device acceptance run. Production records are not restored, replaced or deleted by these checks. Real simultaneous edits to the same user value still require preserving both values rather than guessing a winner.
