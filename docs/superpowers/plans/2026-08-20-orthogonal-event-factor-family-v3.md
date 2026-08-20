# Orthogonal Event Factor Family V3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or subagent-driven-development. Steps use checkbox syntax.

**Goal:** Preregister, implement, fetch, and formally evaluate exactly three new event-retention factors: credit relative strength, cyclical/defensive relative strength, and equal-weight breadth.

**Architecture:** Frozen V11 supplies actual event dates and target paths. Each factor is computed from immutable adjusted-close source CSVs and can only decide whether to retain 50% of a frozen V11 de-risk reduction at that event. Each candidate is compared with a matched control that retains at every factor-available de-risk event.

**Tech Stack:** Swift, Python 3, Yahoo chart API, ATM-SVP-2 governance, Git.

**Spec:** `docs/superpowers/specs/2026-08-20-orthogonal-event-factor-family-v3-design.md`

## Global Constraints

- Formal candidates: `F-CREDIT`, `F-CYCLICAL`, `F-BREADTH` only.
- Matched controls: `C-CREDIT-ALWAYS`, `C-CYCLICAL-ALWAYS`, `C-BREADTH-ALWAYS`.
- Lookback 20 common observations, stale tolerance 7 days, retention fraction 50%, replay band 25%.
- Strict T-1; gross <=100%; no shorting, financing, leverage, or negative cash.
- Full source history fetch only after preregistration, pure logic, fetcher, and executable runner are committed.
- No rescue tuning or factor combination after results.

---

### Task 1: Freeze the research contract

**Files:**
- Create: `tools/research-results/strategy-validation/preregistrations/ATM-SVP2-ORTHO-FACTOR-003.json`
- Modify: `tools/research-results/strategy-validation/trial-ledger.jsonl`

- [ ] Create preregistration with exact factors `HYG/LQD`, `XLY/XLP`, `RSP/SPY`, matched controls, event definition, 50% retention, 20-observation direction, 7-day staleness and fixed gates.
- [ ] Append `PREREGISTER`, verify ledger.
- [ ] Commit spec, plan, preregistration and ledger before any full source history fetch.

### Task 2: Pure event-factor logic with TDD

**Files:**
- Create: `tools/orthogonal_event_factor_v3_logic.swift`
- Create: `tools/orthogonal_event_factor_v3_logic_test.swift`

- [ ] RED tests for adjusted-close ratio direction, stale lookup, 50% reduction retention, gross cap, and no unrelated new asset.
- [ ] Implement minimal pure logic.
- [ ] Require `ORTHOGONAL_EVENT_FACTOR_V3_LOGIC_TEST_OK`.
- [ ] Commit.

### Task 3: Fetcher + runner before full data

**Files:**
- Create: `scripts/fetch_orthogonal_event_factor_v3.py`
- Create: `scripts/test_fetch_orthogonal_event_factor_v3.py`
- Create: `tools/orthogonal_event_factor_v3.swiftpart`
- Create: `scripts/run_orthogonal_event_factor_v3.py`
- Create: `scripts/test_orthogonal_event_factor_v3.py`

- [ ] TDD Yahoo adjusted-close parser for exact tickers HYG/LQD/XLY/XLP/RSP/SPY.
- [ ] TDD gate evaluator against matched controls.
- [ ] Swift runner obtains frozen V11 target/trade dates, only updates targets on unique V11 trade dates, preserves pending retained target between events, and reports event counts.
- [ ] No-performance smoke using synthetic factor CSVs; output only ids, fingerprint, event counts and constraints.
- [ ] Commit executable code before full source fetch.

### Task 4: Fetch/freeze immutable data

- [ ] Fetch six adjusted-close histories from 2001-01-01 to frozen fixture end date.
- [ ] Verify metadata/coverage only.
- [ ] SHA dataset manifest includes base fixture + NFCI + six factor CSVs + fetch summary.
- [ ] Commit dataset.

### Task 5: One formal blind run

- [ ] Verify clean worktree + ATM-SVP-2 checker.
- [ ] Run once through `strategy_validation_formal_run.py`.
- [ ] Read all seven paths exactly once.
- [ ] Hash artifacts, create RESULT, append ledger, verify and commit.

### Task 6: Interpret

- [ ] Report V11, three matched controls and three candidates.
- [ ] If one admits, only authorize a separately preregistered robustness family.
- [ ] If none admits, retain negative evidence and move to a new factor family rather than tuning this one.
