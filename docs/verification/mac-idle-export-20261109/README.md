# Native Mac periodic export CPU

Live 1.15 (238), source cc843fd, was profiled on the local Mac with its existing records. Foreground stationary sampling across an automatic-refresh interval found about 2.05 CPU seconds per minute-long poll. Most busy samples were in CloudExportProjectionStore materializing the full SwiftData graph; persisted baseline ISO8601 decoding was independently measured at 0.061 seconds, so changing that decoder would not address the hotspot. Background idle samples stayed at 0% CPU. The reported 1111.7 Energy Impact was not reproduced; a direct read of the existing Activity Monitor row before this patch was 0.2. CPU time and Energy Impact are different measures.

The shared cooperative exporter now retains one validated value snapshot, keyed by the exact ModelContainer and the synchronous global save revision. Every context save invalidates it; unsaved caller changes and cancellation still fail before a cache hit. A cache hit updates exportedAt, preserving export-time semantics. Network head checks, conflict reconciliation, ownership and pending-upload protections remain in place.

Native Mac Release, iOS simulator Release and localization passed. Focused cloud checks passed 42/42, including other-context save invalidation, dirty drafts, distinct containers, cancellation and a fresh export date. Verification ran only against isolated synthetic stores. Raw live stack samples and private record benchmarks remain outside Git.

Installation and repeat live measurements are pending.
