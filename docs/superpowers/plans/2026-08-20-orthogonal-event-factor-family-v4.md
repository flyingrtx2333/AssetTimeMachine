# Orthogonal Event Factor Family V4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or subagent-driven-development. Steps use checkbox syntax.

**Goal:** Preregister, implement, fetch, and formally evaluate exactly three new event-retention factors: SPHB/SPLV, XLI/XLU, and KRE/SPY.

**Architecture:** Reuse the already-tested generic V3 event-retention logic unchanged. Frozen V11 supplies actual trade dates and target paths. Each new factor uses adjusted-close ratio direction to decide whether to retain 50% of a V11 de-risk reduction and is compared with its own matched availability control.

**Tech Stack:** Swift, Python 3, Yahoo chart API, ATM-SVP-2 governance, Git.

**Spec:** `docs/superpowers/specs/2026-08-20-orthogonal-event-factor-family-v4-design.md`

## Global Constraints

- Formal candidates: `F-HIGHBETA`, `F-INDUTIL`, `F-BANKS` only.
- Matched controls: `C-HIGHBETA-ALWAYS`, `C-INDUTIL-ALWAYS`, `C-BANKS-ALWAYS`.
- Reuse `tools/orthogonal_event_factor_v3_logic.swift` unchanged for 20-observation ratio state, 7-day stale lookup, de-risk detection, 50% retention, and gross cap.
- Strict T-1; gross <=100%; no shorting, financing, leverage, or negative cash.
- Fee 1.00%, slippage 0.05%, replay band 25%.
- Full source histories are fetched only after preregistration, fetcher, tests, and executable runner are committed.
- No rescue tuning or factor combination after results.

---

### Task 1: Freeze the research contract

**Files:**
- Create: `tools/research-results/strategy-validation/preregistrations/ATM-SVP2-ORTHO-FACTOR-004.json`
- Modify: `tools/research-results/strategy-validation/trial-ledger.jsonl`

- [ ] Create preregistration with exact factors `SPHB/SPLV`, `XLI/XLU`, `KRE/SPY`; matched controls; event-only 50% retention; 20 common observations; 7-day stale tolerance; 25% band; exact gates.
- [ ] Append `PREREGISTER`, verify ledger.
- [ ] Commit spec, plan, preregistration and ledger before full source history fetch.

### Task 2: Fetcher and runner TDD

**Files:**
- Create: `scripts/test_fetch_orthogonal_event_factor_v4.py`
- Create: `scripts/fetch_orthogonal_event_factor_v4.py`
- Create: `scripts/test_orthogonal_event_factor_v4.py`
- Create: `scripts/run_orthogonal_event_factor_v4.py`
- Create: `tools/orthogonal_event_factor_v4.swiftpart`

- [ ] RED fetcher test freezes exact adjusted-close sources SPHB/SPLV/XLI/XLU/KRE/SPY.
- [ ] Implement adjusted-close fetcher; no performance calculations.
- [ ] RED runner tests freeze candidates/control mapping and matched-control gate semantics.
- [ ] Implement Swift runner by reusing the V3 event replay pattern and immutable `OrthogonalEventFactorV3Logic`; replace only factor inputs/ids.
- [ ] Implement Python orchestrator to parse seven paths and compare each candidate only with its matched control.
- [ ] Run no-performance smoke on synthetic data; require V11 fingerprint `ba67c8aa24bc7168`, identity replay true, 166 source event dates, 134 de-risk events, gross<=1 and nonnegative weights.
- [ ] Commit executable code before full source fetch.

### Task 3: Fetch and freeze immutable source data

- [ ] Fetch six adjusted-close histories from 2001-01-01 to frozen fixture end date 2026-08-13.
- [ ] Inspect only row counts, first/last dates, source ids and SHAs.
- [ ] Create SHA dataset manifest covering base fixture, NFCI initial-release CSVs, six factor CSVs and fetch summary.
- [ ] Commit dataset before formal run.

### Task 4: One blind formal run

- [ ] Verify clean worktree, ledger and ATM-SVP-2 checker.
- [ ] Execute once through `strategy_validation_formal_run.py`.
- [ ] Read all seven recorded paths once; do not modify factor definitions afterward.
- [ ] Generate result artifact SHA manifest.
- [ ] Create RESULT with all three candidates and matched controls, append ledger, verify protocol and commit.

### Task 5: Interpret and route

- [ ] If any factor reaches `STRONG_INCREMENTAL`, freeze it and start a separate robustness family without changing its rule.
- [ ] If only `ADMIT_FOR_ROBUSTNESS` passes, preserve it as a weak edge and continue new factor search.
- [ ] If all fail, retain negative evidence and open a genuinely different preregistered factor family rather than tuning V4.
