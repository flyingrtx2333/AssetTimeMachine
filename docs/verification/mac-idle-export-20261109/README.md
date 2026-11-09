# Native Mac periodic export CPU

Live 1.15 (238), source cc843fd, was profiled on the local Mac with its existing records. Foreground stationary sampling across an automatic-refresh interval found about 2.05 CPU seconds per minute-long poll. Most busy samples were in CloudExportProjectionStore materializing the full SwiftData graph; persisted baseline ISO8601 decoding was independently measured at 0.061 seconds, so changing that decoder would not address the hotspot. Background idle samples stayed at 0% CPU. The reported 1111.7 Energy Impact was not reproduced; a direct read of the existing Activity Monitor row before this patch was 0.2. CPU time and Energy Impact are different measures.

The shared cooperative exporter now retains one validated value snapshot, keyed by the exact ModelContainer and the synchronous global save revision. Every context save invalidates it; unsaved caller changes and cancellation still fail before a cache hit. A cache hit updates exportedAt, preserving export-time semantics. Network head checks, conflict reconciliation, ownership and pending-upload protections remain in place.

Native Mac Release, iOS simulator Release and localization passed. Focused cloud checks passed 42/42, including other-context save invalidation, dirty drafts, distinct containers, cancellation and a fresh export date. Verification ran only against isolated synthetic stores. Raw live stack samples and private record benchmarks remain outside Git.

Both installed native Mac apps were updated to source `d2176dc` (native version 1.15 / build 238); see install receipts. TestFlight 1.15 (238) remains the previously verified `cc843fd` iOS artifact; this follow-up does not claim a new phone release.

The repeat foreground stationary measurement, after initial sync, used 0.24 CPU seconds across an 80.3-second window containing one periodic poll, versus about 2.05 CPU seconds for the prior poll (88.3% lower). Every foreground-state sample remained active. The new stack sample contained no CloudExportProjectionStore.exportPayload frames; authenticated head checks still ran. Activity Monitor Energy Impact read 0.0 throughout sampled steady intervals. These observations do not establish the cause of the original 1111.7 peak, which remains unreproduced. See `performance.json`. No user financial records or raw stack samples were committed. The Mac mini one-time updater was unloaded after completion.


## Records and Time Machine follow-up

After the user identified these two pages, both were checked using the same installed user store on source `d2176dc`. Time Machine remained foreground for 80.565 seconds and consumed 0.33 CPU seconds; Records remained foreground for 87.068 seconds and consumed 0.38 CPU seconds. Each run crossed an automatic refresh, with no full database export or repeating editor-reload frames in the stationary sample. Only fully foreground runs are included; interrupted attempts were excluded. See `page-checks.json`.

Time Machine Energy Impact settled to 0.0 after the initial page-entry period. During the valid Records CPU run, Activity Monitor was showing Memory, so no Records Energy Impact claim is made. The original 1111.7 energy peak remains unreproduced. No additional app code changes, build or TestFlight upload were needed.
