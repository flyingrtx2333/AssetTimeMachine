# Screening Factor Bootstrap Robustness Design

## Goal

Test whether the two previously preregistered screening winners, F-BREADTH and F-HIGHBETA, have statistically stable incremental value without changing any factor rule, lookback, retention fraction, band, or source data.

## Governance

- Protocol: `ATM-SVP-2`.
- Trial: `ATM-SVP2-FACTOR-ROBUST-001`.
- Evidence class: `R1_RETROSPECTIVE`.
- Locked candidates: `F-BREADTH` from `ATM-SVP2-ORTHO-FACTOR-003` and `F-HIGHBETA` from `ATM-SVP2-ORTHO-FACTOR-004`.
- No new strategy run, parameter change, factor combination, or winner replacement is allowed in this trial.
- The exact already-recorded candidate, matched-control, and V11 portfolio CSVs are the only performance inputs.

## Statistical method

For each locked candidate independently:

1. Align daily portfolio-value series by common date for candidate, its matched control, and V11.
2. Convert each aligned series to simple daily returns.
3. Preserve cross-series dependence by resampling the same block indices for candidate, matched control, and V11.
4. Use circular moving blocks of exactly 63 trading sessions.
5. Each bootstrap path has the same number of daily returns as the observed aligned sample.
6. Number of bootstrap replicates: exactly 20,000.
7. RNG seed: exactly `20260821`.
8. For each replicate compute compounded annualized return (252 sessions/year), annualized Sharpe with zero risk-free rate, and maximum drawdown.

## Inputs

### F-BREADTH

- Candidate: `tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-003/candidates/F-BREADTH-portfolio.csv`
- Matched control: `tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-003/candidates/C-BREADTH-ALWAYS-portfolio.csv`
- V11: `tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-003/candidates/V11-CONTROL-portfolio.csv`

### F-HIGHBETA

- Candidate: `tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-004/candidates/F-HIGHBETA-portfolio.csv`
- Matched control: `tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-004/candidates/C-HIGHBETA-ALWAYS-portfolio.csv`
- V11: `tools/research-results/strategy-validation/runs/ATM-SVP2-ORTHO-FACTOR-004/candidates/V11-CONTROL-portfolio.csv`

## Robustness certification gate

A locked factor receives `BOOTSTRAP_ROBUST_PASS` only if all are true:

- `P(CAGR_candidate > CAGR_V11) >= 0.90`;
- `P(Sharpe_candidate > Sharpe_matched_control) >= 0.90`;
- bootstrap median candidate-minus-V11 CAGR delta > 0;
- bootstrap median candidate-minus-matched-control Sharpe delta > 0;
- candidate bootstrap MDD P97.5 <= 15%.

These gates are deliberately stronger than the original screening admission. A failure does not erase the historical screening PASS; it means the factor is not bootstrap-robust enough to advance.

## Failure semantics

- Do not change block size, seed, replicate count, probability threshold, MDD threshold, or metric definitions after results.
- Do not bootstrap only a favorable subperiod after viewing the full result.
- Do not combine the two factors in this trial.
- If both fail, neither may be described as robust-certified.
- If one passes, it may proceed only to a separately preregistered execution/latency stress study.
