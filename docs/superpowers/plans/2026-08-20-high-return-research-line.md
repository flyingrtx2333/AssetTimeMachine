# High-Return Research Line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and formally execute one preregistered three-candidate research family (`HR-A`, `HR-B`, `HR-C`) that tests whether modestly faster multi-timescale trend information and fuller use of the existing 100% risk budget can lift net CAGR toward the 18–22% region without leverage, shorting, or changing frozen V11.

**Architecture:** Keep frozen V11 as a control/sub-engine only. Put deterministic target math in a small pure Swift logic file, exercise it with standalone Swift tests, then use a research fragment that feeds those targets through the existing `BacktestEngine.runResearchTargetProviderStrategyWithTrace` / shared `BacktestDailySimulator`. A Python orchestrator only compiles, runs, parses, and mechanically applies preregistered gates; it never simulates portfolio returns.

**Tech Stack:** Swift + existing AssetTimeMachine backtest engine, Python 3 governance/orchestration, ATM-SVP-2 ledger/artifact tooling, Git.

**Spec:** `docs/superpowers/specs/2026-08-20-high-return-research-line-design.md`

## Global Constraints

- Frozen V11 `nfci-dual-core-v11 / dualcore-v11-2026-08-15` is never modified.
- Formal family contains exactly `HR-A`, `HR-B`, `HR-C`; no grid and no replacement candidates after results.
- Assets remain `gold_cny`, `nasdaq`, `sp500`, `csi300`, `shanghai_composite` plus RMB cash.
- Fee is 1.00%; slippage is 0.05%; max gross is 100%; negative cash, leverage and shorting are forbidden.
- Signals use T-1 data.
- Fixed time folds are the same seven V11 folds: `2012-07-05..2014-12-31`, `2015-01-01..2016-12-31`, `2017-01-01..2018-12-31`, `2019-01-01..2020-12-31`, `2021-01-01..2022-12-31`, `2023-01-01..2024-12-31`, `2025-01-01..latest`.
- Round-1 admission requires CAGR >=16%, Sharpe >=1.40, MDD <=12%, CAGR improvement >=1.5pp vs frozen V11, >=5/7 folds Sharpe >1, worst-fold Sharpe >0, and all portfolio constraints.
- `TARGET_REGION` additionally requires CAGR >=18% and Sharpe >=1.45.
- A failed round 1 is retained; no cadence/parameter sweep is allowed to rescue it.

---

### Task 1: Freeze the Round-1 Research Contract

**Files:**
- Modify: `docs/superpowers/specs/2026-08-20-high-return-research-line-design.md`
- Create: `tools/research-results/strategy-validation/preregistrations/ATM-SVP2-HR-ARCH-001.json`
- Create: `tools/research-results/strategy-validation/datasets/ATM-SVP2-HR-ARCH-001.json`
- Modify: `tools/research-results/strategy-validation/trial-ledger.jsonl`

**Interfaces:**
- Consumes: existing ATM-SVP-2 policy/ledger rules and `generalization_public_history.json` plus point-in-time NFCI CSVs.
- Produces: immutable trial id `ATM-SVP2-HR-ARCH-001`, exact three candidate ids, exact gate definitions and dataset hashes used by Tasks 3–5.

- [ ] **Step 1: Add exact seven fold ranges to the design spec**

Insert the fixed ranges from Global Constraints immediately under the Evaluation section. No date may be selected after seeing HR-A/B/C results.

- [ ] **Step 2: Create the dataset SHA manifest**

Run:

```bash
python3 scripts/strategy_validation_artifact_manifest.py \
  --trial-id ATM-SVP2-HR-ARCH-001 --kind dataset \
  --output tools/research-results/strategy-validation/datasets/ATM-SVP2-HR-ARCH-001.json \
  --file tools/fixtures/backtest-history/generalization_public_history.json \
  --file tools/research-results/NFCICREDIT_initial_release.csv \
  --file tools/research-results/NFCILEVERAGE_initial_release.csv \
  --metadata-json '{"evidence_class":"R1_RETROSPECTIVE","lineage":"high-return-architecture-v1","formal_candidates":["HR-A","HR-B","HR-C"],"cost":"1.00% fee + 0.05% slippage"}'
```

Expected: `ARTIFACT_MANIFEST_WRITTEN ... files=3`.

- [ ] **Step 3: Create the preregistration payload**

The JSON must contain:

```json
{
  "trial_id": "ATM-SVP2-HR-ARCH-001",
  "protocol_id": "ATM-SVP-2",
  "strategy_lineage": "high-return-architecture-v1; frozen control nfci-dual-core-v11 / dualcore-v11-2026-08-15",
  "hypothesis": "At least one of three low-complexity architectures can improve frozen V11 net CAGR by >=1.5pp while preserving Sharpe >=1.40, MDD <=12%, >=5/7 folds Sharpe >1, worst-fold Sharpe >0 and 100% gross/no-short constraints under 1.00% fee + 0.05% slippage.",
  "evidence_class": "R1_RETROSPECTIVE",
  "dataset_manifest": "tools/research-results/strategy-validation/datasets/ATM-SVP2-HR-ARCH-001.json",
  "allowed_changes": [
    "HR-A exact multi-timescale trend allocator from the frozen spec",
    "HR-B exact V11 state-conditioned risk-budget completion from the frozen spec",
    "HR-C exact 50/50 HR-A/HR-B blend from the frozen spec"
  ],
  "candidate_ids": ["HR-A", "HR-B", "HR-C"],
  "candidate_count": 3,
  "selection_metric": "No winner optimization. Mechanically report admission and TARGET_REGION flags for all three candidates.",
  "pass_fail_gates": [
    "CAGR >=16%",
    "Sharpe >=1.40",
    "MDD <=12%",
    "CAGR >= frozen V11 CAGR +1.5pp",
    ">=5/7 fixed folds Sharpe >1",
    "worst fixed-fold Sharpe >0",
    "max gross <=100%, min target weight >=0, no financing/negative cash",
    "TARGET_REGION only if admitted plus CAGR >=18% and Sharpe >=1.45"
  ],
  "formal_run_budget": 3,
  "follow_up_policy": "No parameter, cadence, band, trend-window, breadth-threshold or blend-weight search is allowed after results. Any new idea is a new preregistered family and all HR-A/B/C outcomes remain in trial accounting.",
  "swift_engine_entrypoint": "scripts/run_high_return_architecture_v1.py -> tools/high_return_architecture_v1.swiftpart -> BacktestEngine shared simulator",
  "expected_outputs": [
    "V11 control metrics",
    "all HR-A/HR-B/HR-C full metrics",
    "all seven fold metrics",
    "2020+ and 2022+ slices",
    "trade count and average cash",
    "target fingerprint and constraints",
    "all portfolio CSVs",
    "mechanical admission and TARGET_REGION flags",
    "run receipt and SHA-256 result artifact manifest"
  ]
}
```

- [ ] **Step 4: Append PREREGISTER and verify it before touching candidate code**

Run:

```bash
python3 scripts/strategy_validation_ledger.py append \
  --event PREREGISTER \
  --payload-file tools/research-results/strategy-validation/preregistrations/ATM-SVP2-HR-ARCH-001.json
python3 scripts/strategy_validation_ledger.py verify
```

Expected: one new valid `PREREGISTER` record and `LEDGER_VALID`.

- [ ] **Step 5: Commit the research contract**

```bash
git add docs/superpowers/specs/2026-08-20-high-return-research-line-design.md \
  tools/research-results/strategy-validation/preregistrations/ATM-SVP2-HR-ARCH-001.json \
  tools/research-results/strategy-validation/datasets/ATM-SVP2-HR-ARCH-001.json \
  tools/research-results/strategy-validation/trial-ledger.jsonl
git commit -m "research(strategy): preregister high-return architecture round 1"
```

---

### Task 2: Build Pure Swift Target Logic with TDD

**Files:**
- Create: `tools/high_return_architecture_v1_logic.swift`
- Create: `tools/high_return_architecture_v1_logic_test.swift`

**Interfaces:**
- Produces: `HighReturnArchitectureV1Logic.trendTarget`, `.riskBudgetTarget`, `.blendedTarget`, and `.annualizedVolatility` used by Task 3.
- All functions are pure and depend only on Foundation plus arrays/dictionaries.

- [ ] **Step 1: Write the failing Swift test first**

`tools/high_return_architecture_v1_logic_test.swift` must construct deterministic price histories and assert:

```swift
@main
struct HighReturnArchitectureV1LogicTest {
    static func main() {
        let roles = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
        let rising = Array(1...300).map(Double.init)
        let falling = Array((1...300).reversed()).map(Double.init)
        let prices = [
            "gold_cny": rising,
            "nasdaq": rising,
            "sp500": rising,
            "csi300": falling,
            "shanghai_composite": falling
        ]
        let trend = HighReturnArchitectureV1Logic.trendTarget(pricesBySymbol: prices, signalIndex: 299)
        precondition(Set(trend.keys).isSubset(of: Set(roles)))
        precondition((trend.values.reduce(0,+)) <= 1.000000001)
        precondition((trend["csi300"] ?? 0) == 0)
        precondition((trend["shanghai_composite"] ?? 0) == 0)

        let base = ["gold_cny":0.20, "nasdaq":0.20, "sp500":0.20]
        let budget = HighReturnArchitectureV1Logic.riskBudgetTarget(baseTarget: base, pricesBySymbol: prices, signalIndex: 299)
        precondition(abs(budget.values.reduce(0,+) - 1.0) < 1e-9)
        precondition((budget["csi300"] ?? 0) == 0)

        let blend = HighReturnArchitectureV1Logic.blendedTarget(trend: trend, budget: budget)
        precondition(blend.values.allSatisfy { $0 >= 0 })
        precondition(blend.values.reduce(0,+) <= 1.000000001)
        print("HIGH_RETURN_LOGIC_TEST_OK")
    }
}
```

- [ ] **Step 2: Run the test to verify RED**

Run:

```bash
xcrun swiftc tools/high_return_architecture_v1_logic_test.swift -o /private/tmp/high_return_logic_test
```

Expected: FAIL because `HighReturnArchitectureV1Logic` does not exist.

- [ ] **Step 3: Implement minimal pure logic**

`tools/high_return_architecture_v1_logic.swift` must expose:

```swift
nonisolated enum HighReturnArchitectureV1Logic {
    static let roleSymbols = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
    static let trendHorizons = [20, 60, 120, 252]

    static func trailingReturn(_ prices: [Double], signalIndex: Int, horizon: Int) -> Double?
    static func annualizedVolatility(_ prices: [Double], signalIndex: Int, sessions: Int = 60) -> Double?
    static func trendTarget(pricesBySymbol: [String:[Double]], signalIndex: Int) -> [String:Double]
    static func riskBudgetTarget(baseTarget: [String:Double], pricesBySymbol: [String:[Double]], signalIndex: Int) -> [String:Double]
    static func blendedTarget(trend: [String:Double], budget: [String:Double]) -> [String:Double]
}
```

`trendTarget` must implement exactly the spec: four sign votes, score >=0.75, rank by `score/max(vol,0.08)`, top two, normalized to gross 1.0 when eligible assets exist.

`riskBudgetTarget` must count roles whose 60- and 120-session returns are both positive; when breadth >=4 and base gross is in `(0,1)`, rescale only existing positive base holdings to gross 1.0. Otherwise return the nonnegative base target unchanged.

`blendedTarget` must use exact 50/50 role weights and normalize only if gross >1.

- [ ] **Step 4: Compile and run GREEN**

```bash
xcrun swiftc tools/high_return_architecture_v1_logic.swift \
  tools/high_return_architecture_v1_logic_test.swift \
  -o /private/tmp/high_return_logic_test
/private/tmp/high_return_logic_test
```

Expected: `HIGH_RETURN_LOGIC_TEST_OK`.

- [ ] **Step 5: Commit pure logic and test**

```bash
git add tools/high_return_architecture_v1_logic.swift tools/high_return_architecture_v1_logic_test.swift
git commit -m "research(strategy): add high-return architecture target logic"
```

---

### Task 3: Integrate All Three Candidates with the Shared Swift Simulator

**Files:**
- Create: `tools/high_return_architecture_v1.swiftpart`
- Create: `scripts/run_high_return_architecture_v1.py`
- Create: `scripts/test_high_return_architecture_v1.py`

**Interfaces:**
- Consumes: Task 2 pure target functions, frozen V11 daily target states, existing research target provider simulator.
- Produces: one control plus exactly three candidate reports and portfolio CSVs in a single formal command.

- [ ] **Step 1: Write failing Python parser/gate tests**

The test imports from the not-yet-created runner:

```python
from run_high_return_architecture_v1 import evaluate_candidate, FORMAL_CANDIDATES

assert FORMAL_CANDIDATES == ["HR-A", "HR-B", "HR-C"]

passing = {
    "cagr_percent": 18.2,
    "sharpe": 1.50,
    "mdd_percent": 9.5,
    "max_gross": 1.0,
    "min_weight": 0.0,
    "fold_sharpes": [1.2,1.1,1.3,1.4,1.05,0.8,1.2]
}
flags = evaluate_candidate(passing, frozen_v11_cagr_percent=14.345615)
assert flags["admit_for_robustness"] is True
assert flags["target_region"] is True
```

Also include a case with CAGR 19% but 4/7 folds >1 and assert admission is false.

- [ ] **Step 2: Verify RED**

```bash
python3 scripts/test_high_return_architecture_v1.py
```

Expected: FAIL because runner module/functions do not exist.

- [ ] **Step 3: Implement the Swift fragment**

The branch `ATM_HIGH_RETURN_ARCH_V1=1` must:

1. Load the same point-in-time NFCI CSVs used by formal V11.
2. Run exact `.nfciDualCoreSimplifiedV11` with 1.00%/0.05% settings to obtain `base.dailyStates` and control metrics.
3. Build `pricesBySymbol` through the same prepared market data frame / research provider inputs.
4. Run three `ResearchTargetStrategyConfig` cases:
   - HR-A: `rebalanceSessions=10`, `rebalanceBand=0.15`, target = `trendTarget(...)`.
   - HR-B: `rebalanceSessions=10`, `rebalanceBand=0.25`, target = `riskBudgetTarget(baseTarget: baseTargetForSignalDate, ...)`.
   - HR-C: `rebalanceSessions=10`, `rebalanceBand=0.20`, target = exact blend of HR-A and HR-B targets.
5. Use `BacktestEngine.runResearchTargetProviderStrategyWithTrace` for every candidate.
6. Print for control and all candidates: CAGR, MDD, vol, Sharpe, trades, average cash, max gross, min weight, fingerprint, 2020+/2022+ metrics, seven fixed fold metrics.
7. Write one portfolio CSV per control/candidate when `ATM_HIGH_RETURN_OUTPUT_DIR` is set.

No candidate may condition behavior on another candidate’s realized return or metric.

- [ ] **Step 4: Implement the Python orchestrator minimally**

`run_high_return_architecture_v1.py` must:

- compile `tools/high_return_architecture_v1_logic.swift` alongside the assembled strategy dump and normal engine files;
- execute one Swift binary with all three candidates;
- parse exact ids `V11-CONTROL`, `HR-A`, `HR-B`, `HR-C`;
- export `candidate-metrics.json` and `candidate-metrics.csv`;
- apply `evaluate_candidate` mechanically;
- label V11 control separately, never as candidate 4;
- exit 0 whether candidates pass or fail, unless execution/evidence is invalid. A research FAIL is a valid result, not a process error.

- [ ] **Step 5: Run GREEN unit tests**

```bash
python3 scripts/test_high_return_architecture_v1.py
```

Expected: PASS.

- [ ] **Step 6: Run a development smoke test on exposed history**

```bash
python3 scripts/run_high_return_architecture_v1.py \
  --fixture tools/fixtures/backtest-history/generalization_public_history.json \
  --output-dir /private/tmp/atm-high-return-v1-dev
```

Expected: control fingerprint `ba67c8aa24bc7168`; exactly three candidate rows; no missing/negative/gross constraint errors. Do **not** use this development output as the formal result if the code changes afterward.

- [ ] **Step 7: Commit the final executable research code**

```bash
git add tools/high_return_architecture_v1.swiftpart \
  scripts/run_high_return_architecture_v1.py \
  scripts/test_high_return_architecture_v1.py
git commit -m "research(strategy): implement high-return architecture round 1"
```

---

### Task 4: Execute the One Formal Round-1 Run

**Files:**
- Create: `tools/research-results/strategy-validation/runs/ATM-SVP2-HR-ARCH-001/**`
- Create: `tools/research-results/strategy-validation/results/ATM-SVP2-HR-ARCH-001.json`
- Modify: `tools/research-results/strategy-validation/trial-ledger.jsonl`

**Interfaces:**
- Consumes: committed preregistration + committed executable candidate code.
- Produces: immutable HR-A/B/C round-1 result and evidence bundle.

- [ ] **Step 1: Verify the worktree is clean and protocol is valid**

```bash
python3 scripts/validate_strategy_protocol.py \
  --manifest tools/research-results/strategy-validation/v11-protocol-manifest-v2.json
git diff --check
```

Expected: `PROTOCOL_VALID ATM-SVP-2`, G3 remains PARTIAL, and no diff errors.

- [ ] **Step 2: Execute through the formal-run wrapper**

```bash
python3 scripts/strategy_validation_formal_run.py \
  --trial-id ATM-SVP2-HR-ARCH-001 \
  --output-dir tools/research-results/strategy-validation/runs/ATM-SVP2-HR-ARCH-001 \
  -- python3 scripts/run_high_return_architecture_v1.py \
       --fixture tools/fixtures/backtest-history/generalization_public_history.json \
       --output-dir tools/research-results/strategy-validation/runs/ATM-SVP2-HR-ARCH-001/candidates
```

Expected: one authorization receipt binding the current Git commit, followed by exactly one full family result containing HR-A/B/C together.

- [ ] **Step 3: Inspect only the already-recorded formal metrics**

Read `candidates/candidate-metrics.json`. Report every candidate, including failures. Do not edit candidate code, gates, cadence, windows, breadth threshold or bands after this step.

- [ ] **Step 4: Hash every formal result artifact**

Generate `artifact-manifest.json` covering:

```text
run-authorization.json
execution.json
stdout.txt
stderr.txt
candidates/candidate-metrics.json
candidates/candidate-metrics.csv
candidates/V11-CONTROL-portfolio.csv
candidates/HR-A-portfolio.csv
candidates/HR-B-portfolio.csv
candidates/HR-C-portfolio.csv
```

Use `scripts/strategy_validation_artifact_manifest.py --kind result`.

- [ ] **Step 5: Create and append the RESULT**

`results/ATM-SVP2-HR-ARCH-001.json` must contain all three candidate metrics and flags, the execution commit, preregistration hash, dataset manifest, result manifest, and a decision string that explicitly says either:

- which candidates are `ADMIT_FOR_ROBUSTNESS` / `TARGET_REGION`, or
- `NO_CANDIDATE_ADMITTED`.

Append with:

```bash
python3 scripts/strategy_validation_ledger.py append \
  --event RESULT \
  --payload-file tools/research-results/strategy-validation/results/ATM-SVP2-HR-ARCH-001.json
```

- [ ] **Step 6: Verify evidence and commit the result**

```bash
python3 scripts/strategy_validation_ledger.py verify
python3 scripts/validate_strategy_protocol.py \
  --manifest tools/research-results/strategy-validation/v11-protocol-manifest-v2.json
git diff --check
```

Then commit:

```bash
git add tools/research-results/strategy-validation/runs/ATM-SVP2-HR-ARCH-001 \
  tools/research-results/strategy-validation/results/ATM-SVP2-HR-ARCH-001.json \
  tools/research-results/strategy-validation/trial-ledger.jsonl
git commit -m "research(strategy): record high-return architecture round 1"
```

---

### Task 5: Interpret Without Post-Hoc Tuning

**Files:**
- Create: `docs/strategies/high-return-architecture-round1-2026-08-20.md`

**Interfaces:**
- Consumes: immutable Task 4 formal result only.
- Produces: human-readable conclusion and next allowed action.

- [ ] **Step 1: Write the full result table**

Include V11 control plus all HR-A/B/C metrics, seven fold Sharpes, admission flag and target-region flag.

- [ ] **Step 2: Answer the frequency question directly**

Classify the evidence as one of:

```text
HIGHER_FREQUENCY_HELPED_NET
HIGHER_FREQUENCY_DID_NOT_HELP_NET
MIXED_ARCHITECTURE_EFFECT
```

The classification must follow HR-A’s net result and comparisons; do not infer from gross/pre-cost values.

- [ ] **Step 3: State the next permissible research action**

- If at least one candidate is admitted: create a **new** robustness preregistration; do not modify the admitted candidate.
- If none is admitted: record the negative result. Any new architecture is a new preregistered lineage/family, not “HR-D rescue tuning.”

- [ ] **Step 4: Commit and push**

```bash
git add docs/strategies/high-return-architecture-round1-2026-08-20.md
git commit -m "docs(strategy): summarize high-return architecture round 1"
git push origin HEAD:main
```
