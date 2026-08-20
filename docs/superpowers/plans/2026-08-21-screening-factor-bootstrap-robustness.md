# Screening Factor Bootstrap Robustness Implementation Plan

> **For agentic workers:** execute this plan with strict preregistration and TDD; do not inspect bootstrap performance before code and input manifests are committed.

**Goal:** Bootstrap-certify or reject the two locked screening winners F-BREADTH and F-HIGHBETA without changing their rules.

**Architecture:** A Python runner reads only the already-recorded candidate, matched-control, and V11 portfolio CSVs. It aligns returns, resamples identical circular 63-session blocks across the three paths for 20,000 fixed-seed replicates, applies preregistered probability/MDD gates mechanically, and writes all results.

**Spec:** `docs/superpowers/specs/2026-08-21-screening-factor-bootstrap-robustness-design.md`

## Task 1 — Freeze trial

- Create `tools/research-results/strategy-validation/preregistrations/ATM-SVP2-FACTOR-ROBUST-001.json` with two locked candidates, exact input paths, block size 63, 20,000 reps, seed 20260821, and exact gates.
- Append `PREREGISTER`, verify ledger, commit spec/plan/prereg/ledger.

## Task 2 — TDD statistical runner

- Create `scripts/test_screening_factor_bootstrap_robustness.py` first.
- RED must fail because runner does not exist.
- Create `scripts/run_screening_factor_bootstrap_robustness.py` implementing alignment, simple daily returns, common circular moving-block resampling, CAGR/Sharpe/MDD, and frozen gates.
- Unit tests use tiny deterministic synthetic data and verify same block indices are shared across series, output candidates are exactly F-BREADTH/F-HIGHBETA, and gate semantics.
- Commit runner/tests before formal input manifest/run.

## Task 3 — Freeze input manifest

- Create dataset artifact manifest for the six already-recorded portfolio CSVs used by the bootstrap.
- Commit manifest before formal execution.

## Task 4 — One formal run

- Verify clean worktree and ATM-SVP-2.
- Execute exactly once through `strategy_validation_formal_run.py`.
- Read results once; do not alter method/gates.
- Hash result artifacts, create RESULT, append ledger, verify and commit.

## Task 5 — Route evidence

- If a factor passes, only advance it to a separately preregistered execution/latency stress study.
- If it fails, keep its original screening PASS but label it not bootstrap-robust-certified.
