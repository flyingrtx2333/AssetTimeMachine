# Final Crisis-Filter Event Budget Family V6 Design

## Goal

Run the final preregistered retrospective factor-discovery batch. Test whether three crisis/stress filters can decide when frozen V11 event-level risk-budget completion to 100% gross is safe enough to improve return without the 19% drawdowns observed in V5.

After this trial, no additional retrospective factor-discovery family is allowed under the current research campaign regardless of outcome. Any further evidence must come from robustness tests of a locked winner, G4 pristine holdout work, G6 prospective OOS, or genuinely new future data.

## Governance

- Protocol: `ATM-SVP-2`.
- Trial: `ATM-SVP2-ORTHO-FACTOR-006`.
- Lineage: `final-crisis-filter-event-budget-v6`.
- Formal candidates: `F-VIXTERM`, `F-VVIX`, `F-CREDITCASH`.
- Matched controls: `C-VIXTERM-ALWAYS`, `C-VVIX-ALWAYS`, `C-CREDITCASH-ALWAYS`.
- Candidate count 3; formal run budget 3.
- V11 remains frozen.
- V1–V5 and robustness-audit results remain permanent trial history.

## Frozen event-budget architecture

Reuse V5 architecture unchanged:

- Fee 1.00%; slippage 0.05%.
- Strict T-1.
- Max gross 100%; no shorting, financing, leverage, or negative cash.
- Replay band 25%.
- Factor logic is evaluated only on unique execution dates on which frozen V11 actually trades.
- If current V11 positive target gross is in `(0,1)` and completion is enabled, scale only current already-positive V11 holdings proportionally to exactly 100% gross.
- Do not introduce zero-target assets.
- Factor changes between V11 events cannot create trades.
- Identity replay with completion disabled must match frozen V11 within established replay tolerances.

## Factor rules

All Yahoo histories use adjusted close. Latest usable observation must be no more than 7 calendar days stale.

### F-VIXTERM — short-end volatility term inversion filter

- Yahoo `^VIX9D` and `^VIX`.
- On common dates compute `vixterm = VIX9D / VIX`.
- Risk-on iff latest usable `vixterm <= 1.0`.
- The threshold 1.0 is structural: short-horizon implied volatility is not above 30-day VIX. It is not searched.
- Metadata-only inception: VIX9D 2011-01-03; VIX 1990-01-02.

### F-VVIX — volatility-of-volatility easing

- Yahoo `^VVIX`.
- Risk-on iff latest usable VVIX adjusted close <= its value 20 source observations earlier.
- Lookback fixed at 20 observations.
- Metadata-only inception: 2007-01-03.

### F-CREDITCASH — high-yield credit versus short Treasury cash proxy

- Yahoo `HYG` and `SHY`.
- On common dates compute `creditcash = HYG / SHY` from adjusted close.
- Risk-on iff latest usable ratio >= ratio 20 common observations earlier.
- Lookback fixed at 20 observations.
- Metadata-only inception: HYG 2007-04-11; SHY 2002-07-30.

`HYG` appeared previously in the distinct HYG/LQD retention factor and `SHY` appeared in older unrelated research. HYG/SHY under event-budget completion is a separately preregistered mechanism and counts as a new candidate; it does not overwrite prior failures.

## Matched controls

For each factor independently:

- Candidate: complete to 100% gross only when the factor is available and risk-on.
- Matched control: complete to 100% gross whenever the factor is available, regardless of state.
- When unavailable, both preserve exact V11 target.

## Evaluation and gates

Report full-history CAGR, Sharpe, MDD, vol, trades, average cash, fingerprint, constraints, 2020+, 2022+, same seven V11 folds, source events, underinvested events, available underinvested events, and completed events.

`ADMIT_FOR_ROBUSTNESS` requires all:

- CAGR > V11 CAGR;
- Sharpe > own matched control Sharpe;
- MDD <=12%;
- >=4/7 folds candidate Sharpe >= matched-control Sharpe;
- worst-fold Sharpe >0;
- max gross <=1 and min target weight >=0.

`STRONG_INCREMENTAL` additionally requires:

- CAGR >= V11 CAGR +1.0 percentage point;
- Sharpe >= V11 Sharpe.

## Final retrospective-search stop rule

After the formal result is opened:

- Do not change the VIXTERM threshold, VVIX/credit lookbacks, stale rule, band, gross target, or candidate set.
- Do not add another retrospective factor family under this campaign, even if all three fail.
- Do not combine winners from earlier rounds on the same historical sample.
- A passing factor may only enter a separately preregistered robustness trial.
- If no factor is strong and robust, the correct conclusion is that the current historical evidence does not support a stable ~20% CAGR strategy under the frozen constraints.
