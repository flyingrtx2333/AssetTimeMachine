# Fixed MarketMind Light research screen

`mii-light-screen --spy RAW_YAHOO --sectors NINE_SECTOR_INPUT --history HISTORY --output FRESH_DIRECTORY --source-commit SHA` runs one candidate and five frozen controls. It is an exploratory price-account adaptation, not a public strategy.

The causal features and nine indicator rules are ported from MarketMind0.1.0 sourcead1b13d. MII-Light uses the software normalCDF of the252-session slope zscore, close-difference volatility percentile, and EMA5 breadth. Breadth is explicitly the fixed nine-sector fraction aboveSMA50, not point-in-time stock-constituent breadth. Paper AppendixB uses a rawzscore example and actualATR; these differences prevent exact-replication claims. Thresholds remain the paper's fixed0.3/0.7, independent of final dataset length.

Each selected family averages its three binary signals into a0..1 SPY target. Controls use the equal nine-signal mean,21-session lagged state, cyclic wrong-family mapping, SPY buyhold, and a native gold/Nasdaq reference. Changes are delivered after an already-known close to the shared funded simulator at the next real open, preserving settled cash and latest-target delivery. First evaluation session is the baseline close. No financing, leverage, crypto or cash enhancement.

Costs are0.025% perfill, no base slippage, CashYieldCNY. SPY and sector snapshots are historical Yahoo price observations; dividends are excluded. FX is strictly prior calendar-date, max14days. The2008–2026-08-20 window is historical and already exposed. The native reference has a different instrument/fill/FX clock; its comparison is diagnostic.

Three focused Release tests cover independent author feature/signal vectors, exact history-prefix/future-disturbance equality, and invalid or undefined inputs. They do not establish investment effectiveness. All six outcomes, raw targets, features and funded account states must be retained; no parameter rescue is authorized after returns.

The separate source audit demonstrates that full-MII0.1.0 `fit_transform` varies regime warmup with final dataset length. Its synthetic downstream counterexample leaves raw estimates and MII identical but changes131 prefix classifications. Fixed minimum history resolves that isolated downstream dependence; full-MII estimators and author strategy returns were not replicated. The Light screen does not call that classifier.

Source attribution: MarketMind 0.1.0, copyright (c) 2026 Layan Oraidi; the preserved [BSD 3-Clause notice](MarketMind-BSD-3-Clause.txt) accompanies this research port.

The six-account frozen run completed on 2026-10-06. The candidate's full-period CAGR was 5.1634%, drawdown22.3902%, and CashYieldCNY-excess Sharpe0.47538. The unconditional nine-signal control had lower drawdown16.7129% and higher excess Sharpe0.58391. Neither reaches the1.2 screen. All4474 SPY fills, T-1 targets and cash/unit ledgers were verified against saved inputs; this does not establish total-return or prospective effectiveness. The native barbell control is only diagnostic: the API replays earlier history and rebases existing holdings at the range start, rather than beginning a fresh SPY account. No public strategy or validation status changes.
