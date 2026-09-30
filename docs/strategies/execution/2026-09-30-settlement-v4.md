# Settlement v4 execution contract

Declared 2026-09-30 before any corrected historical replay. This is an engineering correction, not a new strategy trial, parameter search or formal execution-stress result. Engine identity: `atm-swift-settlement-v4-2026-09-30`.

## Observed defects

Clock-v3 suppresses decision callbacks while a target is pending. A change-only target during a market closure or sale settlement can disappear permanently. Its daily repeated overweight-sale check also postpones buys repeatedly despite already available cash. Preserved reproductions are in the research workspace's 2026-09-06 target-delivery and settlement-buy-phase audits.

## Execution rules

1. Evaluate the existing strategy's decision hook on every simulation session. It observes only the original prior-session signal context. A newer eligible target replaces the pending desired target. No changes to strategy signals, parameters, instruments, allocation weights or schedule.
2. Keep the existing requirement that all held and desired assets have real, positive observations before execution. Filled quotes remain valuation-only. Cancellation to cash still observes currently held assets.
3. Snapshot available cash after daily cash interest and before sales. Existing cash may fund purchases. Today's sale proceeds increase account cash/NAV but cannot fund purchases until a later fully observed session. Subsequent sales cannot repeatedly invalidate already settled cash.
4. Sales remain subject to the existing trading band, costs and sorted asset order. Purchases consume the pre-sale settled budget and cannot exceed account cash. No new financing or leverage.
5. Keep a target pending only when its otherwise executable purchases were constrained by today's unsettled sale proceeds. Fee/slippage residue with no cash does not create a permanent pending order. Completion callback fires only when no settlement-constrained purchases remain.
6. A new desired target is evaluated before execution; an obsolete queued buy must not execute after a newer liquidation/reallocation signal is available.
7. NAV equals cash plus marked holdings, cash must remain nonnegative in unfinanced runs, no execution on unobserved quotes, no same-session signal lookahead.

## Declared regression cases

- Existing cash funds a new asset while an existing asset rises and is sold down.
- Full rotation cannot buy with same-day sale proceeds; next observed session completes.
- A newer one-shot liquidation while a prior rotation waits supersedes the obsolete buy.
- New target during a closed market persists until a real observation.
- Further sales do not prevent using proceeds settled on an earlier session.
- Fees, slippage, zero trading band and band-boundary execution retain accounting invariants.
- App/core tests for signal causality, hypothetical sessions and holiday observations remain valid.
- Public price-only prewarm excludes macro-dependent forward strategies; frozen NFCI IDs remain in the separate macro-enabled forward API.

## Evidence boundary

Original protocols, trial ledger, frozen target hashes, OOS start dates and stored observations remain unchanged. Old metrics retain their original engine/cost/date labels. Corrected historical replays are POST_HOC_CURRENT_REPLAY, do not promote any strategy, and do not restart the forward clock. Current product defaults are read from source (0.025% fee / 0.05% slippage), separately from the original 1% / 0.05% historical baseline.
