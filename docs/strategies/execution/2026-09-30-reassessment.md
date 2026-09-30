# Settlement-v4 execution adjudication (2026-09-30)

Evidence class: **POST_HOC_CURRENT_REPLAY**, not independent alpha, prospective validation or full G0–G6 acceptance. Execution contract remains separately frozen in `2026-09-30-settlement-v4.md`.

## Scope and disposition

- Legacy production performance (`da851256`, preceding clock-v3) is withdrawn from the public backtest API. Unknown/old engine results fail closed.
- The two reproduced defects (lost target callbacks during pending settlement and repeated sale phases deferring buys despite settled cash) are fixed in commit `aca9916f660366200c10423412b92203c9fbc1e9`.
- Synthetic defect tests failed before correction and passed afterward. Relevant existing clock/accounting/closure regressions passed. Public catalog prewarms five price-only strategies; macro-dependent NFCI remains outside that path.
- Production amd64 image was built from that commit's Git archive, tested independently, then deployed. Its registry digest is `sha256:d34c3eb123bdca8b1e1f2b9b61e7c6a04eab1b7310b019b7b63295585df99532`.
- All five live public catalog results match the independent full-precision replay within `1.5e-15`; a live 2020+ run also matches its continuous-state slice. iOS Release simulator build succeeds; no application was installed/uploaded as part of this audit.

## Current fixed product-cost replay

CNY 100,000 initial capital; fee **0.025%**, slippage **0.05%** per fill; no financing. Dataset cutoff **2026-09-29**. Sharpe uses the existing engine's **Rf=0** definition. Full-history dates differ by strategy inception/warmup.

| Strategy | Annualized return | Maximum drawdown | Sharpe |
|---|---:|---:|---:|
| Gold/Nasdaq dual trend | 10.31% | 17.39% | 0.923 |
| Balanced | 7.83% | 14.56% | 0.892 |
| Risk budget | 9.19% | 18.74% | 0.948 |
| Profit lock | 6.65% | 11.86% | 0.842 |
| Low noise | 8.65% | 13.85% | 0.946 |
| NFCI V11 (separate macro replay) | 8.70% | 14.43% | 0.974 |

All six miss the requested full-history Sharpe 1.2 threshold even under Rf=0. These observations do not constitute a new formal objective-gate result. NFCI initial-release coverage begins 2012-07-05; earlier history uses existing missing-macro rules and is not complete macro-coverage validation.

## Matched execution control

On original pinned prices ending 2026-08-31, with original **1% fee / 0.05% slippage**, five original clock-v3 baselines were reproduced within `1e-6`. Only engine execution changed for the v4 comparison. Low-noise CAGR moved **5.8597% → 6.0281%**; V11 **6.0377% → 6.3104%**. V11 has no entry in that pinned five-product baseline; its comparison is a separately retained matched previous-engine control, not reproduction of its original 14.35% freeze claim.

Do not attribute the legacy-versus-current gap to a few weeks of post-freeze market performance. It includes earlier execution-clock/observed-quote changes, the two phase defects, and (for the current replay) different costs/data vintage. Corrections have not restored the old advertised figures.

## Frozen lineage preservation

Original freezes, trial ledger, OOS start and accumulated observations remain unchanged. The original host-mounted forward binary remains SHA-256 `b16a922f5c0b4182e0ef48af178cebf7bfa4cf99e1e0a15000e7e706b358fb32`. Its observations are historical audit evidence. Corrected worker output is blocked from being relabeled as the original frozen forward lineage; a corrected prospective arm requires separate governance registration. Existing G3/G4/G6 blockers and incomplete statuses are not cleared by these engineering tests.

## Evidence location

Full before/after traces, input/source hashes, preserved original baseline hashes, negative test output, invalid preliminary exporter-date evidence, live receipts and rollback details:

`FlyingrtxFast/research/asset-time-machine/workspace/studies/execution-reassessment-2026-09-30/`

The same persistent Notion strategy table has six new versioned rows and three historical-vintage audit notes, all read back. Prior numeric results and formal verdicts remain preserved. Twenty unrelated older pending Notion additions remain pending.
