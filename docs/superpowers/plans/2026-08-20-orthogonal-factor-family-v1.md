# Orthogonal Factor Family V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preregister, implement, and formally evaluate exactly three new orthogonal factor gates—term spread, dollar direction, and small-cap/large-cap relative strength—using one standardized V11 risk-budget completion overlay and an ALWAYS-FILL control.

**Architecture:** Keep V11 frozen and obtain its daily target path from the existing Swift engine. External factor series are fetched and hashed as immutable input artifacts after preregistration and code freeze. A small pure Swift factor-state module computes T-1 risk-on states; all candidate portfolios then replay through the same `runResearchTargetProviderStrategyWithTrace` simulator and identical 25% band.

**Tech Stack:** Swift, Python 3, FRED CSV, Yahoo chart API, ATM-SVP-2 ledger/artifact tooling, Git.

**Spec:** `docs/superpowers/specs/2026-08-20-orthogonal-factor-family-v1-design.md`

## Global Constraints

- Formal candidates are exactly `F-CURVE`, `F-USD`, `F-SIZE`.
- `V11-CONTROL` and `ALWAYS-FILL` are controls, not candidates.
- No candidate transform, 20-observation horizon, stale tolerance, sign rule, 25% band, or overlay semantics may change after preregistration.
- Full candidate factor histories are not fetched until the design, preregistration, and executable code are committed.
- Strict T-1, max gross 100%, no shorting, no leverage, no negative cash.
- All strategy results include 1.00% fee + 0.05% slippage.

---

### Task 1: Freeze the factor family contract

**Files:**
- Create: `tools/research-results/strategy-validation/preregistrations/ATM-SVP2-ORTHO-FACTOR-001.json`
- Modify: `tools/research-results/strategy-validation/trial-ledger.jsonl`
- Commit: design spec + preregistration + ledger before candidate data fetch.

**Interfaces:**
- Produces trial id `ATM-SVP2-ORTHO-FACTOR-001` and exact candidate/source definitions consumed by later tasks.

- [ ] **Step 1: Create preregistration JSON** with candidate ids `F-CURVE`, `F-USD`, `F-SIZE`, source ids `T10Y3M`, `DX-Y.NYB`, `^RUT`, `^RUI`, exact risk-on rules, factor-screening gates from the spec, formal_run_budget=3, and a follow-up policy forbidding rescue transforms/grids.
- [ ] **Step 2: Append `PREREGISTER`** using `scripts/strategy_validation_ledger.py` and verify the ledger.
- [ ] **Step 3: Commit** the spec, plan, preregistration, and ledger with message `research(factor): preregister orthogonal factor family v1`.

---

### Task 2: Implement factor-state logic with TDD

**Files:**
- Create: `tools/orthogonal_factor_family_v1_logic.swift`
- Create: `tools/orthogonal_factor_family_v1_logic_test.swift`

**Interfaces:**
- Produces pure functions for latest T-1 lookup with seven-calendar-day staleness, 20-observation direction, size-ratio direction, and V11 positive-weight fill-to-100% target transformation.

- [ ] **Step 1: Write failing Swift tests** asserting:
  - stale observations older than 7 calendar days return unavailable;
  - curve risk-on only when latest spread >0;
  - dollar risk-on when latest <= observation 20 positions earlier;
  - size risk-on when latest RUT/RUI ratio >= ratio 20 common observations earlier;
  - fill target never creates a symbol not already positive in V11 and never exceeds 100% gross.
- [ ] **Step 2: Run `swiftc -parse-as-library` and verify RED** because the logic type does not exist.
- [ ] **Step 3: Implement minimal pure Swift logic** exactly matching the frozen rules.
- [ ] **Step 4: Compile/run and verify `ORTHOGONAL_FACTOR_LOGIC_TEST_OK`**.
- [ ] **Step 5: Commit** logic and tests.

---

### Task 3: Implement factor data fetcher and runner before fetching full candidate histories

**Files:**
- Create: `scripts/fetch_orthogonal_factor_family_v1.py`
- Create: `scripts/test_fetch_orthogonal_factor_family_v1.py`
- Create: `tools/orthogonal_factor_family_v1.swiftpart`
- Create: `scripts/run_orthogonal_factor_family_v1.py`
- Create: `scripts/test_orthogonal_factor_family_v1.py`

**Interfaces:**
- Fetcher outputs four immutable raw CSVs with `date,value`: T10Y3M, DXY, Russell 2000, Russell 1000.
- Runner consumes the four CSVs plus the existing V11 market/NFCI fixtures and outputs V11-CONTROL, ALWAYS-FILL, F-CURVE, F-USD, F-SIZE.

- [ ] **Step 1: Write fetcher tests first** for FRED CSV/Yahoo JSON parsing using synthetic fixtures; verify RED.
- [ ] **Step 2: Implement fetcher** without any return/performance calculations. FRED uses `fredgraph.csv`; Yahoo uses chart v8. It must save exact source/provenance metadata and refuse unknown source ids.
- [ ] **Step 3: Write runner gate/parser tests first** asserting exactly three formal candidates and the spec gate semantics; verify RED.
- [ ] **Step 4: Implement Swift fragment**:
  - direct frozen V11 control with point-in-time NFCI;
  - same target path replay as ALWAYS-FILL;
  - same standardized overlay gated by each factor;
  - same 25% band for all overlays;
  - T-1 factor lookup only;
  - print full metrics/folds/constraints only when formal mode is enabled.
- [ ] **Step 5: Implement Python runner** to compile Swift, parse controls/candidates, compare candidate fold Sharpes against ALWAYS-FILL, and mechanically assign `ADMIT_FOR_ROBUSTNESS` / `STRONG_INCREMENTAL`.
- [ ] **Step 6: Run a no-performance smoke** that only verifies V11 fingerprint, ids, factor file parsing, and portfolio constraints; no candidate CAGR/Sharpe is printed.
- [ ] **Step 7: Commit** fetcher, logic integration, runner, and tests before any full factor-history fetch.

---

### Task 4: Fetch and freeze the formal factor dataset

**Files:**
- Create: `tools/research-results/strategy-validation/factor-data/ATM-SVP2-ORTHO-FACTOR-001/*.csv`
- Create: `tools/research-results/strategy-validation/factor-data/ATM-SVP2-ORTHO-FACTOR-001/fetch-summary.json`
- Create: `tools/research-results/strategy-validation/datasets/ATM-SVP2-ORTHO-FACTOR-001.json`

**Interfaces:**
- Produces immutable factor inputs for the formal run.

- [ ] **Step 1: Run fetcher once** for `T10Y3M`, `DX-Y.NYB`, `^RUT`, `^RUI`, using start `2001-01-01` and end matching the current base fixture end date.
- [ ] **Step 2: Do not inspect charts or factor-conditioned returns.** Only verify row counts, first/last dates, monotonic dates, positive index prices for market series, and nonempty T10Y3M values.
- [ ] **Step 3: Generate SHA dataset manifest** covering the four factor CSVs, base history fixture, and the two point-in-time NFCI CSVs.
- [ ] **Step 4: Commit** factor data + dataset manifest before the formal strategy run.

---

### Task 5: Execute exactly one formal factor-family run

**Files:**
- Create: `tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-001/**`
- Create: `tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-001.json`
- Modify: `tools/research-results/strategy-validation/trial-ledger.jsonl`

**Interfaces:**
- Produces immutable controls and all three factor results.

- [ ] **Step 1: Verify clean worktree and `ATM-SVP-2` checker.**
- [ ] **Step 2: Run through `strategy_validation_formal_run.py`** with the committed dataset and executable code.
- [ ] **Step 3: Read the already-recorded metrics once.** No candidate code or factor rule may change after this step.
- [ ] **Step 4: Generate result artifact SHA manifest** covering receipts, logs, metrics, and all five portfolio CSVs.
- [ ] **Step 5: Create RESULT** reporting all three factor candidates even if all fail, append to ledger, verify ledger/protocol, and commit.

---

### Task 6: Interpret the factor evidence

**Files:**
- Create: `docs/strategies/orthogonal-factor-family-v1-2026-08-20.md`

**Interfaces:**
- Consumes only the immutable formal result.

- [ ] **Step 1: Report controls and all three candidates** with full metrics and fold comparison against ALWAYS-FILL.
- [ ] **Step 2: Explain whether any factor shows timing value beyond simply taking more risk.**
- [ ] **Step 3: If admitted, only authorize a new robustness family; do not integrate or tune immediately. If none admit, preserve the negative result and choose any future factor as a new preregistered family.**
- [ ] **Step 4: Commit the summary.**
