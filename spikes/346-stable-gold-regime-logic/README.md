# Spike 346 - Stable gold regime logic cluster

## Verdict

No promotion.

This spike was created because single-point parameter picks are not good enough. The benchmark is spike 345, not the old incumbent:

- Spike 345: Full 8.72% / -10.53%, Sharpe 1.003
- 2020+: 13.82% / -9.71%
- 10y: 11.29% / -9.71%

## Method

Instead of ranking individual parameter peaks, this spike defined coarse economic logic centers and tested local perturbation clusters. A new logic would only promote if the cluster itself was robust, not if one lucky parameter tuple looked good.

## Result

No stable cluster beat spike 345.

Best individual outlier:

- Full: 8.84% / -10.30%
- 2020+: 14.06% / -9.68%
- 10y: 11.46% / -9.68%

But its cluster hit rate was only 2.1% and median behavior was weaker than spike 345:

- medium_gold_break_rounded hit rate: 3/140 = 2.1%
- cluster median CAGR: 8.65%
- cluster median DD: -11.17%

## Decision

Do not promote the 8.84% outlier. It is likely a parameter peak, not a better logic family.
