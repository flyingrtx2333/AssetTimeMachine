# Final Crisis-Filter Event Budget Family V6 Implementation Plan

> **For agentic workers:** strict preregistration + TDD; this is the final retrospective discovery batch in the campaign.

**Goal:** Evaluate F-VIXTERM, F-VVIX, and F-CREDITCASH under the frozen V5 event-budget completion architecture, then stop retrospective factor discovery.

**Spec:** `docs/superpowers/specs/2026-08-21-final-crisis-filter-family-v6-design.md`

## Task 1 — Freeze trial
- Create `tools/research-results/strategy-validation/preregistrations/ATM-SVP2-ORTHO-FACTOR-006.json` with exact sources, rules, matched controls, gates, and final search stop rule.
- Append PREREGISTER, verify ledger, commit before full data fetch.

## Task 2 — TDD fetcher/runner
- RED fetcher tests for exact Yahoo sources VIX9D/VIX/VVIX/HYG/SHY and adjusted-close parsing.
- RED runner tests for exact candidate/control mapping and frozen gates.
- Implement Swift event-budget runner reusing immutable V3 ratio/date logic and immutable V1 completedRiskBudget helper.
- Add VIXTERM structural `ratio <= 1.0`, VVIX 20-observation falling state, and HYG/SHY 20-observation rising state.
- Run no-performance synthetic smoke: identity=true, source events=166, underinvested events=129, constraints pass.
- Commit executable code before full source fetch.

## Task 3 — Freeze data
- Fetch five adjusted-close histories from 2001-01-01 through 2026-08-13.
- Inspect only coverage/provenance/SHA.
- Create and commit dataset manifest.

## Task 4 — One blind formal run
- Verify clean worktree and ATM-SVP-2.
- Execute exactly once through formal-run guard.
- Read result once; do not modify rules.
- Hash artifacts, create RESULT, append ledger, verify and commit.

## Task 5 — Stop retrospective discovery
- If any factor passes, route only to separately preregistered robustness.
- Regardless of outcome, create no further retrospective factor family in this campaign.
