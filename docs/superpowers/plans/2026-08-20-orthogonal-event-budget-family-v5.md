# Orthogonal Event Budget Family V5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or subagent-driven-development. Steps use checkbox syntax.

**Goal:** Preregister, implement, fetch, and formally evaluate exactly three event-only 100% risk-budget completion factors: QQQ/TLT, XBI/XLV, and IYT/IEF.

**Architecture:** Frozen V11 supplies actual trade dates and target paths. Each factor uses an adjusted-close ratio state and, only on a frozen V11 event date, may scale the existing positive V11 target weights to 100% gross. Each factor is compared with its own matched availability control that always completes the budget when data are available.

**Tech Stack:** Swift, Python 3, Yahoo chart API, ATM-SVP-2 governance, Git.

**Spec:** `docs/superpowers/specs/2026-08-20-orthogonal-event-budget-family-v5-design.md`

## Global Constraints

- Formal candidates: `F-GROWTHBOND`, `F-BIOTECH`, `F-TRANSPORT` only.
- Matched controls: `C-GROWTHBOND-ALWAYS`, `C-BIOTECH-ALWAYS`, `C-TRANSPORT-ALWAYS`.
- Lookback 20 common observations, stale tolerance 7 days, event-only execution, replay band 25%, max gross exactly 100% when completion is enabled.
- Strict T-1; no shorting, financing, leverage, or negative cash.
- Fee 1.00%, slippage 0.05%.
- Full source histories are fetched only after preregistration, tests, fetcher, and executable runner are committed.
- No rescue tuning or factor combination after results.

---

### Task 1: Freeze the research contract

- Create `tools/research-results/strategy-validation/preregistrations/ATM-SVP2-ORTHO-FACTOR-005.json` with exact sources/rules/gates.
- Append `PREREGISTER`, verify ledger.
- Commit spec, plan, preregistration and ledger before full source history fetch.

### Task 2: TDD fetcher and event-budget runner

**Files:**
- `scripts/test_fetch_orthogonal_event_budget_v5.py`
- `scripts/fetch_orthogonal_event_budget_v5.py`
- `scripts/test_orthogonal_event_budget_v5.py`
- `scripts/run_orthogonal_event_budget_v5.py`
- `tools/orthogonal_event_budget_v5.swiftpart`

- RED fetcher test freezes exact adjusted-close sources QQQ/TLT/XBI/XLV/IYT/IEF.
- Implement fetcher with no performance calculations.
- RED runner test freezes candidate/control mapping and matched-control gate semantics.
- Swift runner reuses immutable `OrthogonalEventFactorV3Logic` for ratio state and uses a pure fill-to-100% helper with tests or an already-tested identical helper.
- Identity replay with completion disabled must match V11.
- No-performance smoke on synthetic data may print ids, fingerprint, source event count, underinvested event count, availability/completion counts, and constraints only.
- Commit executable code before full source fetch.

### Task 3: Fetch/freeze immutable source data

- Fetch six adjusted-close histories from 2001-01-01 through 2026-08-13.
- Inspect only row counts, first/last dates, source ids and SHAs.
- Generate dataset SHA manifest covering base fixture, NFCI initial-release CSVs, six factor CSVs and fetch summary.
- Commit dataset before formal run.

### Task 4: One blind formal run

- Verify clean worktree, ledger and ATM-SVP-2 checker.
- Execute once through `strategy_validation_formal_run.py`.
- Read all seven recorded paths once and freeze the result.
- Generate result artifact SHA manifest.
- Create RESULT, append ledger, verify protocol and commit.

### Task 5: Route evidence

- If `STRONG_INCREMENTAL` appears, freeze that exact factor/architecture and start a separate robustness family.
- If only screening PASS appears, retain it as a weak edge and continue new factors.
- If all fail, retain negative evidence and do not alter V5 parameters.
