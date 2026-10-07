# Stock/bond rebalancing pressure: frozen long-only research screen

Primary source: Harvey, Mazzoleni, Melone, *The Unintended Consequences of
Rebalancing*, December15,2025, sections1.2/4 and appendixB:
<https://afajof.org/management/viewp.php?n=144452>.

This is a D0 economic-mechanism adaptation, not a replication of the author's
stock/bond futures spread. It is research-only and changes no product strategy.

## Fixed rule

Twenty-six virtual SPY/IEF portfolios start with equity weight0.6. For each
completed USD session, update each weight using the stock and bond gross total
return: `w*stockGrowth / (w*stockGrowth + (1-w)*bondGrowth)`. Average its
pre-reset deviation from0.6. After observing the close, reset virtual weights
whose absolute deviation reaches their threshold (`0,0.001,...,0.025`) to0.6
for the next session. The reset convention is explicitly our ETF adaptation;
it is not presented as a literal appendixB recursion.

At the next genuine open, target QQQ weight is
`clip(-meanDeviation/0.015,0,1)`. The1.5pp scale is the pinned December2025
paper's scale, not a locally fitted value. IEF is only a signal input. There
is no calendar component, funded bond sleeve, futures, short, or leverage.

The six frozen accounts are: QQQ candidate; reversed QQQ signal; QQQ50%
rebalanced daily; QQQ buy and hold; SPY candidate as a transfer diagnostic;
RMB demand-deposit cash. Full2005-01-03..2026-10-02 and2020+/2022+/2025+
are all reported. Each slice includes the preceding actual account state;
the full window includes100k seed NAV one calendar day before the first fill.

## Execution and evidence

Use shared `BacktestDailySimulator` settlement-v4 only. All fills cost0.025%,
slippage0, no borrowing, prior calendar-day FX at most14days old. The same
known FX marks that session's open and close. Latest desired targets are
submitted when changed; the fixed50% account also rebalances every session.
After-sale cash remains subject to the existing shared settlement convention.

ETF signals use `(close+ex-date distribution)/previousClose`, validated against
raw dividend events. Funded accounts are price-only: distributions are omitted
from NAV, not silently included through adjusted opening prices. This limits
economic claims, particularly cross-ETF comparisons. No pristine OOS is claimed;
the paper's calibration and vendor snapshot are historically exposed.

`rebalancing-pressure-screen --prices FILE --history FILE --output NEW_DIR
--source-commit SHA` writes immutable result, desired targets, signal features
and hashes. Six funded accounts, zero parameter search; no result-driven rescue.
The primary screen objective is full CashYieldCNY-excess Sharpe>=1.2. RF0
Sharpe is separate; cash-control Sharpe is not economically informative.
