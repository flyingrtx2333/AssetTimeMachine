# Automatic market refresh and cloud reconciliation · 2026-10-25

## Reproduced causes

The shared reconciliation preflight compared complete snapshot headers and complete entry records. Header fields included independently updated market-anchor prices and `marketAnchorsUpdatedAt`. Automatic `entry.unitPrice` changes were also compared as user edits. Synthetic payloads executed against the actual merge implementation reproduced a conflict even when both devices only refreshed an identical anchor at different times.

The iOS market lifecycle and native Record Today action can independently create the same calendar day and account entries with different UUIDs. The old duplicate guard rejected these equivalent logical records. iOS record-view automatic rate refresh could also update a historical snapshot with a current quote.

This investigation identifies reproducible code mechanisms; it does not assert which individual field differed in the user's iPhone payload. No production cloud backup was restored, replaced or deleted during verification.

## Changes

- Three-way reconciliation merges independent user fields using the retained common ancestor. Conflicting changes to the same amount, quantity or manual unit price still stop without uploading or discarding either value.
- Bound automatic prices merge separately from user quantities; snapshot anchor prices and source dates remain paired. Derived refresh differences do not block user deletion.
- A unique snapshot/day and entry/account/day are aligned across replicas. A deterministic total UUID order converges even when devices have different prior baselines. Existing within-device duplicates are preserved; delete-and-recreate ambiguity stops rather than applying an old tombstone to a new user record.
- Reconciliation retains a matching replica's metadata instead of combining it with a stale clock. Nested entries are compared in canonical order, so a pure pull or refresh timestamp alone does not become a new upload.
- Historical snapshots are excluded from the record view's automatic live-rate writer.
- Account ownership validation, upload compare-and-swap, local mutation barriers, safety backups and corrupt/missing-baseline protection remain in force. No persisted schema, endpoint or strategy behavior changed.

## Verification

- `python3 scripts/test_cloud_merge.py`: 41 focused synthetic checks passed, including the pre-fix failing cases, manual conflicts, deletion/recreation and identity convergence.
- Localization audit passed.
- Native Release build passed. The isolated full cloud-store transport probe passed all 31 checks, including pure pulls without uploads, upload CAS retries, ownership barriers, draft protection, corrupt baselines and preservation of true conflicts.
- iOS Simulator Release build passed. The final source also passed a separate arm64 Simulator Release build; disposable products were removed.

## Availability

This verified source is included in the Git synchronization. Installing it over the running Mac app and uploading it to TestFlight are separate steps; neither is part of this source synchronization.
