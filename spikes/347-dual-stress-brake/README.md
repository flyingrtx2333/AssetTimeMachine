# Spike 347 - Dual stress brake

## Verdict

No promotion as a new logic.

## Hypothesis

If gold is broken and equities are also stressed, do not force gold's freed weight into Nasdaq/S&P. Cap equity and let the rest remain cash.

## Benchmark

Spike 345:

- Full: 8.72% / -10.53%, Sharpe 1.003
- 2020+: 13.82% / -9.71%
- 10y: 11.29% / -9.71%

## Result

Some candidates looked numerically strong, for example:

- Full: 8.82% / -10.27%, Sharpe 1.013
- 2020+: 14.23% / -8.81%
- 10y: 11.81% / -8.81%

However, the new dual-stress brake only fired 1-2 days in the top candidates. That means the better-looking output was mostly due to nearby gold-repair parameter changes, not the new dual-stress logic doing real work.

The promotion gate required at least 5 brake days to prove the new mechanism mattered. Hits under that stricter gate: 0.

## Decision

Do not promote. Keep spike 345 as current research champion. Continue searching for a better mechanism that materially changes behavior and survives cluster/robustness checks.
