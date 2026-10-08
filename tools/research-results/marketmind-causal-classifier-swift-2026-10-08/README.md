# Native causal MII classifier and input readiness

See [REPORT.md](REPORT.md), [HANDOFF.md](HANDOFF.md), and the adjacent full-estimator audit.
The executable classifier is under the verified AssetTimeMachine checkout's `tools/`.
Its audit driver takes a decompressed `FIXTURE.json` and an output path, and accepts only
the synthetic fixture schema. A passed classifier is not a completed full-MII feature port,
market-PIT contract, shared-engine trading candidate, performance result or product change.

`prepare_fixture.py` runs the author's fixed252 classification only; `verify_saved.py` reads
saved states without estimator/account execution. Both source and output are frozen and
archived; lossless gzip retains bulky JSON. Master append is guarded and one-time.
`SOURCE_PROFILE.json` records the limited base-catalog/source mapping investigation.
No full market histories or licensed vendor files were acquired.
