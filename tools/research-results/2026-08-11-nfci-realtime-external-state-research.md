# 2026-08-11 NFCI realtime external-state research

## Scope

Research-only. Production App strategy is unchanged.

Constraints:
- production Swift App backtest engine / unified daily simulator;
- initial cash CNY100,000;
- fee 1.00%, slippage 0.05%;
- strict T-1;
- target gross <=100%;
- actual gross <=100%;
- no financed exposure / no negative cash;
- cash remains RMB demand deposit.

Pinned price fixture ends 2026-08-10.

## Production baseline

`riskContributionCashConfidenceLowNoise` / 无杠杆低噪增强:
- annualized 14.446908%
- max drawdown 7.931053%
- volatility 8.904863%
- Sharpe 1.508859
- 2020+ annualized 16.865344%, DD 7.584862%
- recent 10Y annualized 13.441569%, DD 7.584862%
- 2022+ annualized 20.390228%, DD 6.831549%
- trades 454
- average cash 42.5790%

All research replay control groups were required to reproduce 14.446908 / 7.931053 / 454 exactly before overlay results were accepted.

## Rejected external lines

### Active VIX panic-release reentry pulse
After fixing replay parity, all 10%/20% x 21/42-session active Nasdaq trial-position variants underperformed the baseline. Rejected.

### Real-yield + yield-curve US rerisk gate
63-session 10Y real-yield change plus 10Y-2Y curve change carried real predictive information in event studies, but suppressing champion US rerisk reduced full-history return. Attribution confirmed champion US rerisk was already positive even under macro-adverse states. Rejected as a trading gate.

### Public short-credit proxy
`DCPN3M - DTB3` did not reproduce the long-duration corporate-credit effect. Best result only about 14.48% and recent drawdown worsened. Rejected.

### BAA10Y
Strong corroborating research signal, but underlying Moody's licensing makes it unattractive as a bundled production dependency. Also publication timing required an extra one-session lag. Kept as corroborating evidence only.

## Key attribution discovery

Champion US de-risk events were frequently premature while financial conditions were already improving.

The external information was useful for **retaining part of an intended US reduction**, not for blocking rerisk or forcing new exposure.

## Realtime-vintage construction

Current revised Chicago Fed history was not used for accepted results.

ALFRED historical vintages were queried at each release date and the first-published value was reconstructed for every release.

Complete initial-release series built:
- `tools/research-results/NFCICREDIT_initial_release.csv`
- `tools/research-results/NFCILEVERAGE_initial_release.csv`

Both contain 732 releases from 2012-07-05 through 2026-08-05 with zero missing releases.

Thus the accepted signals are based on values actually available at the time, not today's revised historical path.

## Credit subindex rule

Definition:
- use latest NFCICREDIT initial-release value available on the strategy signal date;
- compare with 8 releases earlier;
- if 8-week change <= -0.03;
- and the champion proposes a true US de-risk (US reduction >=5pp and total gross reduction >=3pp);
- retain 50% of the intended US reduction using only the cash the base strategy was going to create.

Result:
- annualized 14.869645%
- max DD 7.931053%
- vol 9.020729%
- Sharpe 1.530136
- 2020+ 17.002042% / DD7.584862%
- recent10Y 13.563634% / DD7.584862%
- 2022+ unchanged 20.390228% / DD6.831549%
- 11 events
- trades449
- max target/actual gross1.0; financed0.

Robustness:
- raw threshold -0.03 vs -0.05 both work;
- 8-week and 10-week horizons both work, with 6/12 weeks still positive but weaker;
- rolling percentile rule was weaker, indicating absolute sustained easing contains more information than simple relative rank;
- leave-one-event-out: every exclusion remains above the 14.446908% baseline; minimum annualized 14.610931%; max DD always7.931053%.
- activating only from 2017+ / 2019+ / 2020+ remains positive; 2020+ annualized rises to about17.00%.

## Leverage subindex rule

Definition:
- use NFCILEVERAGE initial-release series;
- 4-week change <= -0.05;
- same true US de-risk gate;
- retain part of intended US reduction.

50% retention:
- annualized 14.848446%
- max DD7.931053%
- Sharpe1.527135
- 2020+17.135728% / DD7.672221%
- recent10Y13.624965%
- 2022+20.524631% / DD6.831549%
- 14 events
- no leverage / no financing.

75% retention:
- annualized14.857240%
- DD7.931053%
- 2020+17.255392%
- 2022+20.524631%.

Leverage therefore contributes more to recent periods than Credit, including a 2026 event.

## Combined Credit + Leverage

Rules are not added arithmetically. On a true US de-risk event, each component can request a retention fraction; the larger active retention is used, never exceeding the original reduction and never exceeding 100% gross exposure.

### High-return variant
Credit50 + Leverage75:
- annualized **14.897285%**
- max DD **7.931053%**
- Sharpe1.524821
- 2020+ **17.289051%** / DD7.672874%
- recent10Y **13.754323%**
- 2022+ **20.524631%** / DD6.831549%
- 20 union events
- no leverage / no financing.

However leave-one-event-out revealed one exclusion that raised max DD to8.335009%, so this variant is not the robust champion.

### Robust research champion
**Credit50 + Leverage50**:
- annualized **14.886386%**
- max DD **7.931053%**
- volatility9.038696%
- Sharpe **1.528832**
- 2020+ **17.169324%** / DD7.672221%
- recent10Y **13.680968%** / DD7.672221%
- 2022+ **20.524631%** / DD6.831549%
- 20 union events
- trades449
- average cash40.9855%
- max target gross1.000000000
- max actual gross1.000000000
- min cash ratio0
- financed days0.

### Combined jackknife
For Credit50+Leverage50, exclude each of the 20 union events one at a time:
- every annualized result remains above the production baseline14.446908%;
- worst leave-one-out annualized = **14.627631%**;
- every leave-one-out max DD remains exactly **7.931053%**.

### Time-out validation
Rules derived from early realtime-vintage events remain positive when enabled only later:
- only2017+ combo50: full14.517956%; 2020+17.169324%; 2022+20.524631%;
- only2019+ combo50: full14.531192%; 2020+17.169324%;
- only2020+ combo50: full14.528846%; 2020+17.176218%; 2022+20.524631%.

Credit50+Leverage75 also remains positive when activated only in 2017/2019/2020, but the full jackknife drawdown instability makes 50/50 preferable.

## Current conclusion

Current production remains 14.446908% / 7.931053%.

Current **research** champion is:

> NFCI realtime Credit50 + Leverage50 de-risk retention overlay

It improves return and Sharpe while preserving the full-history maximum drawdown and strict no-leverage audit, survives full realtime-vintage reconstruction, coarse threshold/horizon tests, time-out activation tests, and full leave-one-event-out testing.

Do not productionize without an explicit product decision and a production-quality weekly NFCI realtime data ingestion/update path.
