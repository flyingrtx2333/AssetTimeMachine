# Orthogonal Factor Family V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preregister, implement, fetch, and formally evaluate exactly three new V11 risk-budget timing factors: funding-spread compression, copper/gold relative strength, and Cboe SKEW direction.

**Architecture:** Frozen V11 supplies the base target path. A small pure Swift module computes T-1 factor states from immutable source CSVs; a common overlay either preserves V11 or proportionally fills only existing positive V11 holdings to 100% gross. All candidates and ALWAYS-FILL use the same 25% band and the same shared `BacktestDailySimulator` path.

**Tech Stack:** Swift, Python 3, FRED graph CSV, Yahoo chart API, ATM-SVP-2 ledger/artifact tooling, Git.

**Spec:** `docs/superpowers/specs/2026-08-20-orthogonal-factor-family-v2-design.md`

## Global Constraints

- Formal candidates are exactly `F-FUNDING`, `F-COPGOLD`, `F-SKEW`.
- `V11-CONTROL` and `ALWAYS-FILL` are controls only.
- No parameter grid, factor transformation search, combination search, or rescue tuning is allowed.
- Full candidate histories are fetched only after preregistration, pure logic, fetcher, and formal runner are committed.
- Strict T-1; max gross 100%; no shorting, leverage, financing, or negative cash.
- Fee 1.00%, slippage 0.05%, band 25%, stale tolerance 7 calendar days.
- Direction horizon is exactly 20 source/common observations for all three factors.

---

### Task 1: Freeze the formal research contract

**Files:**
- Create: `tools/research-results/strategy-validation/preregistrations/ATM-SVP2-ORTHO-FACTOR-002.json`
- Modify: `tools/research-results/strategy-validation/trial-ledger.jsonl`

**Interfaces:**
- Produces trial id `ATM-SVP2-ORTHO-FACTOR-002`, exact factor source ids, candidate count, gates, and forbidden follow-ups.

- [ ] **Step 1: Create preregistration JSON** containing exact candidates `F-FUNDING`, `F-COPGOLD`, `F-SKEW`; source ids `DCPF3M`, `DFF`, `HG=F`, `GC=F`, `^SKEW`; exact 20-observation and 7-day rules; candidate_count=3; formal_run_budget=3; and the gates from the spec.
- [ ] **Step 2: Append `PREREGISTER`** with `scripts/strategy_validation_ledger.py` and verify the ledger.
- [ ] **Step 3: Commit** spec, plan, preregistration, and ledger before any full factor history is fetched.

---

### Task 2: Build pure factor-state logic with TDD

**Files:**
- Create: `tools/orthogonal_factor_family_v2_logic.swift`
- Create: `tools/orthogonal_factor_family_v2_logic_test.swift`

**Interfaces:**
- Produces `Point`, latest usable T-1 lookup, common-date difference/ratio builders, funding/copper-gold/SKEW risk-on functions, and the standardized fill-to-100% target transform.

- [ ] **Step 1: Write failing Swift tests first** for: 7-day staleness; funding spread falling over 20 common observations; copper/gold ratio rising over 20 common observations; SKEW falling over 20 observations; and fill target never adding zero-V11 assets or exceeding 100% gross.
- [ ] **Step 2: Compile test alone and verify RED** because `OrthogonalFactorFamilyV2Logic` does not exist.
- [ ] **Step 3: Implement the minimal pure Swift functions** exactly matching the spec.
- [ ] **Step 4: Compile/run and require `ORTHOGONAL_FACTOR_V2_LOGIC_TEST_OK`.**
- [ ] **Step 5: Commit** pure logic + tests.

---

### Task 3: Implement fetcher and formal runner before full data fetch

**Files:**
- Create: `scripts/fetch_orthogonal_factor_family_v2.py`
- Create: `scripts/test_fetch_orthogonal_factor_family_v2.py`
- Create: `tools/orthogonal_factor_family_v2.swiftpart`
- Create: `scripts/run_orthogonal_factor_family_v2.py`
- Create: `scripts/test_orthogonal_factor_family_v2.py`

**Interfaces:**
- Fetcher writes raw `date,value` CSVs for DCPF3M, DFF, HG, GC, and SKEW plus provenance.
- Runner outputs `V11-CONTROL`, `ALWAYS-FILL`, and exactly the three formal candidates through the shared Swift simulator.

- [ ] **Step 1: Write synthetic FRED/Yahoo parser tests and verify RED.**
- [ ] **Step 2: Implement fetcher** using only preregistered source ids; no strategy performance calculations are allowed.
- [ ] **Step 3: Write runner gate/parser tests and verify RED.** Gate logic must require candidate CAGR > V11, candidate Sharpe > ALWAYS-FILL, MDD <=12%, >=4/7 fold Sharpe wins/ties vs ALWAYS-FILL, worst-fold Sharpe >0, and portfolio constraints.
- [ ] **Step 4: Implement Swift runner** with exact frozen V11, ALWAYS-FILL, F-FUNDING, F-COPGOLD, F-SKEW; same 25% band; T-1 source lookup only.
- [ ] **Step 5: Implement Python orchestrator** to compile Swift, parse controls/candidates, apply gates mechanically, and write candidate metrics.
- [ ] **Step 6: Run no-performance smoke** using synthetic factor CSVs; output may contain ids, V11 fingerprint, factor counts, and constraints only—no candidate CAGR/Sharpe/MDD.
- [ ] **Step 7: Commit** all executable research code before full factor data fetch.

---

### Task 4: Fetch and freeze the immutable factor dataset

**Files:**
- Create: `tools/research-results/strategy-validation/factor-data/ATM-SVP2-ORTHO-FACTOR-002/*.csv`
- Create: `tools/research-results/strategy-validation/factor-data/ATM-SVP2-ORTHO-FACTOR-002/fetch-summary.json`
- Create: `tools/research-results/strategy-validation/datasets/ATM-SVP2-ORTHO-FACTOR-002.json`

**Interfaces:**
- Produces immutable full-history factor inputs for the formal run.

- [ ] **Step 1: Read base fixture end date mechanically.** Use start `2001-01-01` and that exact end date.
- [ ] **Step 2: Fetch all five raw source series once.** Do not inspect factor-conditioned strategy returns.
- [ ] **Step 3: Verify only rows, first/last dates, monotonic dates, positive market prices, and source ids.**
- [ ] **Step 4: Generate SHA dataset manifest** covering base fixture, NFCI point-in-time CSVs, five factor CSVs, and fetch summary.
- [ ] **Step 5: Commit** the dataset before formal execution.

---

### Task 5: Execute exactly one formal family run

**Files:**
- Create: `tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-002/**`
- Create: `tools/research-results/strategy-validation/results/ATM-SVP2-ORTHO-FACTOR-002.json`
- Modify: `tools/research-results/strategy-validation/trial-ledger.jsonl`

**Interfaces:**
- Produces the immutable round result for all three factor candidates.

- [ ] **Step 1: Verify clean worktree and ATM-SVP-2 protocol.**
- [ ] **Step 2: Execute once through `strategy_validation_formal_run.py`.**
- [ ] **Step 3: Read the already-recorded formal result once.** No candidate logic, factor rule, threshold, horizon, stale rule, band, or overlay may change afterward.
- [ ] **Step 4: Generate result artifact SHA manifest** covering receipts, logs, metrics, controls, and all candidate portfolio CSVs.
- [ ] **Step 5: Create RESULT** with all three candidate results, append to ledger, verify ledger/protocol, and commit.

---

### Task 6: Interpret without post-hoc tuning

**Files:**
- Create: `docs/strategies/orthogonal-factor-family-v2-2026-08-20.md`

**Interfaces:**
- Consumes only the immutable formal result.

- [ ] **Step 1: Report V11, ALWAYS-FILL, and all three factors.**
- [ ] **Step 2: State whether any factor adds timing value beyond simply taking more risk.**
- [ ] **Step 3: If admitted, authorize only a new robustness family. If none admit, preserve the negative result and move to a genuinely different factor family.**
- [ ] **Step 4: Commit the human-readable summary.**
