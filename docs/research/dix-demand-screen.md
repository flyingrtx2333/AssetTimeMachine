# DIX demand: dated-aggregate diagnostic

`AssetTimeMachineResearch dix-demand-screen --prices FILE --history FILE --output NEW_DIR --source-commit SHA`

SqueezeMetrics, *Short is Long*, March2018 p5, describes elevated DIX at45% and conditional60-market-day returns. This research uses one independently frozen flat-only capital-account interpretation: DIX dated two matched sessions before execution, enter100% QQQ at a genuine open, hold60 open-to-open intervals, mandatory exit, no same-open reentry. Signals while holding are ignored. Four fixed controls cover low-DIX QQQ, source-asset SPY, QQQ buyhold and CNY demand cash. All accounts use the shared settlement-v4 simulator, fee0.025%, no leverage, no short, no crypto, no maintenance while held.

This is not an author complete-strategy replication or product result. The current DIX CSV lacks immutable historical publication timestamps and vintage/composition metadata. The two-session lag is a timing assumption; formal eligibility is blocked, and 2011+ data exclude the2008 crisis. No GEX/ML component or missing pre2011 factors are fabricated. Price-only funded accounts omit distributions. All controls and negative results remain in the persistent research master.

Evidence: `FlyingrtxFast/research/asset-time-machine/workspace/studies/dix-demand-open-2026-10-07/`.
