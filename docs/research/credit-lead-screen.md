# LQD leads QQQ: bounded public-code research

`AssetTimeMachineResearch credit-lead-screen --prices FILE --history FILE --output NEW_DIR --source-commit SHA`

One frozen candidate plus four controls through `BacktestDailySimulator`, with no parameter search. Evidence is D0 and does not change product strategies, validation status, account data or sync.

Pinned MIT source: `45ck/llm-quant` commit `c82725c9a67e99fa2c83a536369c3fe2345d379d`, `LeadLagStrategy`, LQD-QQQ spec and robustness command. Original files, license and hashes are retained in the backend research study.

Code signal, not descriptive label: at review close k, `LQD[k-1]/LQD[k-5]-1`. The author's window5/lag1 is four return intervals. Entry at +0.5%, exit at -0.5%, review every five matched observations; original entry weight80%, remaining CNY demand deposits. Entry stop is fixed at95% of original QQQ USD signal close. Unlike the author's observed same-close execution, all stop and strategy exits execute at the next genuine open. No weight maintenance while held. Matched observed positive quotes ensure execution; saved desired/accepted targets and actual holdings must also pass the independent audit.

Funded QQQ and LQD signals are price-only, matching source raw close. Current-vintage data and author selection history prevent pristine OOS claims. A slice after the source commit is retrospective diagnostic only. All comparisons share strict prior-date FX, fee0.025% per fill, fractional shares, no leverage/shorts/crypto and settlement-v4.

Study and preregistration: `FlyingrtxFast/research/asset-time-machine/workspace/studies/credit-lead-open-2026-10-07/`.
