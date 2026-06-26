#!/usr/bin/env python3
"""Network and dynamic-speed momentum candidates.

No leverage, no financing, no >100% notional exposure.

This spike is intentionally structural rather than a parameter sweep:

- dynamic-speed momentum learns whether short/medium/long momentum has recently
  worked for each asset;
- network confirmation lets nearby assets reinforce or veto a signal;
- engine routing reuses the current defensive engine and offensive breadth
  engine from spike 022.
"""
from __future__ import annotations

from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "spikes" / "022-engine-selection-logic" / "engine_selection_logic.py"
SPEC = importlib.util.spec_from_file_location("engine_selection_logic_base", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"failed to load {MODULE_PATH}")
base = importlib.util.module_from_spec(SPEC)
sys.modules["engine_selection_logic_base"] = base
SPEC.loader.exec_module(base)

import atm_app_equivalent_backtest as app  # noqa: E402
import atm_new_logic_explorer as logic  # noqa: E402

Overlay = base.Overlay
ALL_SYMBOLS = ["gold_cny", "nasdaq", "sp500", "csi300", "shanghai_composite"]
EQUITIES = ["nasdaq", "sp500", "csi300", "shanghai_composite"]
US_EQUITIES = ["nasdaq", "sp500"]
HORIZONS = [20, 60, 120, 240]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(value, 0.0) for value in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(out)
    if total > max_total and total > 0:
        scale = max_total / total
        out = {symbol: weight * scale for symbol, weight in out.items() if weight * scale > 0.0001}
    return out


def blend(first: dict[str, float], second: dict[str, float], first_share: float) -> dict[str, float]:
    out: dict[str, float] = {}
    share = min(max(first_share, 0.0), 1.0)
    for symbol, weight in first.items():
        out[symbol] = out.get(symbol, 0.0) + weight * share
    for symbol, weight in second.items():
        out[symbol] = out.get(symbol, 0.0) + weight * (1 - share)
    return normalize(out)


def mom(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int) -> float | None:
    prices = prices_by_symbol[symbol]
    if index - lookback < 0 or prices[index - lookback] <= 0:
        return None
    return prices[index] / prices[index - lookback] - 1


def rolling_vol(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int = 60) -> float | None:
    prices = prices_by_symbol[symbol]
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if prices[cursor - 1] > 0 and prices[cursor] > 0:
            returns.append(math.log(prices[cursor] / prices[cursor - 1]))
    if len(returns) < 2:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def rolling_corr(
    prices_by_symbol: dict[str, list[float]],
    left: str,
    right: str,
    index: int,
    lookback: int = 120,
) -> float:
    if left == right or index - lookback + 1 < 1:
        return 0.0
    lp = prices_by_symbol[left]
    rp = prices_by_symbol[right]
    lx: list[float] = []
    rx: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if min(lp[cursor - 1], lp[cursor], rp[cursor - 1], rp[cursor]) <= 0:
            continue
        lx.append(math.log(lp[cursor] / lp[cursor - 1]))
        rx.append(math.log(rp[cursor] / rp[cursor - 1]))
    if len(lx) < 20:
        return 0.0
    lm = sum(lx) / len(lx)
    rm = sum(rx) / len(rx)
    cov = sum((a - lm) * (b - rm) for a, b in zip(lx, rx)) / len(lx)
    lv = sum((a - lm) ** 2 for a in lx) / len(lx)
    rv = sum((b - rm) ** 2 for b in rx) / len(rx)
    if lv <= 0 or rv <= 0:
        return 0.0
    return cov / math.sqrt(lv * rv)


def horizon_edge(
    prices_by_symbol: dict[str, list[float]],
    symbol: str,
    index: int,
    horizon: int,
    training: int = 240,
    forward: int = 20,
) -> float:
    """Recent sign accuracy of horizon momentum for the next rebalance month."""
    start = max(horizon, index - training)
    stop = index - forward
    if stop <= start:
        return 0.0
    scores: list[float] = []
    prices = prices_by_symbol[symbol]
    for cursor in range(start, stop + 1, forward):
        signal = mom(prices_by_symbol, symbol, cursor, horizon)
        if signal is None or prices[cursor] <= 0:
            continue
        future = prices[cursor + forward] / prices[cursor] - 1
        if abs(signal) < 0.001:
            continue
        scores.append(1.0 if (signal > 0) == (future > 0) else -1.0)
    if len(scores) < 4:
        return 0.0
    return sum(scores) / len(scores)


def dynamic_speed_score(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> float:
    weighted = 0.0
    edge_sum = 0.0
    for horizon in HORIZONS:
        signal = mom(prices_by_symbol, symbol, index, horizon)
        if signal is None:
            continue
        edge = horizon_edge(prices_by_symbol, symbol, index, horizon)
        # If a horizon has recently inverted, the score can deliberately turn
        # contrarian. Weak evidence keeps the horizon near zero.
        weighted += edge * signal
        edge_sum += abs(edge)
    if edge_sum <= 0:
        return 0.0
    vol = rolling_vol(prices_by_symbol, symbol, index) or 0.25
    return weighted / edge_sum / max(vol, 0.05)


def network_score(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> float:
    own = dynamic_speed_score(prices_by_symbol, symbol, index)
    support = 0.0
    corr_sum = 0.0
    for other in ALL_SYMBOLS:
        if other == symbol:
            continue
        corr = max(0.0, rolling_corr(prices_by_symbol, symbol, other, index))
        if corr <= 0:
            continue
        support += corr * dynamic_speed_score(prices_by_symbol, other, index)
        corr_sum += corr
    neighbor = support / corr_sum if corr_sum > 0 else 0.0
    return own + 0.35 * neighbor


def equity_network_ok(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    positive = [symbol for symbol in EQUITIES if network_score(prices_by_symbol, symbol, index) > 0]
    us_positive = [symbol for symbol in US_EQUITIES if network_score(prices_by_symbol, symbol, index) > 0]
    return len(positive) >= 2 and len(us_positive) >= 1


def equity_network_strong(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    positive = [symbol for symbol in EQUITIES if network_score(prices_by_symbol, symbol, index) > 0]
    return len(positive) >= 3 and all(network_score(prices_by_symbol, symbol, index) > 0 for symbol in US_EQUITIES)


def gold_network_ok(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    return network_score(prices_by_symbol, "gold_cny", index) > 0 and logic.above_ma(prices_by_symbol, "gold_cny", index, 120)


def network_target(prices_by_symbol: dict[str, list[float]], index: int, max_total: float = 0.95) -> dict[str, float]:
    scored: list[tuple[float, str]] = []
    for symbol in ALL_SYMBOLS:
        score = network_score(prices_by_symbol, symbol, index)
        if score <= 0:
            continue
        if symbol != "gold_cny" and not logic.above_ma(prices_by_symbol, symbol, index, 120):
            continue
        if symbol == "gold_cny" and not gold_network_ok(prices_by_symbol, index):
            continue
        scored.append((score, symbol))

    if not scored:
        return {}
    scored.sort(reverse=True)
    selected = scored[:3]
    total = sum(score for score, _symbol in selected)
    if total <= 0:
        return {}
    weights: dict[str, float] = {}
    for score, symbol in selected:
        weights[symbol] = max_total * score / total

    # Keep this implementable in the app: no single equity dominates the whole
    # book, and gold is still capped below all-in.
    for symbol in EQUITIES:
        if weights.get(symbol, 0.0) > 0.60:
            weights[symbol] = 0.60
    if weights.get("gold_cny", 0.0) > 0.75:
        weights["gold_cny"] = 0.75
    return normalize(weights, max_total)


def return_lead_blend_weights(
    context: base.EngineContext,
    current_weights: dict[str, float],
    breadth_weights: dict[str, float],
    signal_index: int,
) -> dict[str, float]:
    current_ret = base.trailing_return(context.current.values, signal_index, 240)
    breadth_ret = base.trailing_return(context.breadth.values, signal_index, 240)
    breadth_dd = base.trailing_drawdown(context.breadth.values, signal_index, 120)
    if breadth_ret is not None and current_ret is not None and breadth_ret > current_ret:
        if breadth_dd is not None and breadth_dd < -0.08:
            return blend(current_weights, breadth_weights, 0.7)
        return blend(breadth_weights, current_weights, 0.7)
    return current_weights


def network_overlay(mode: str, context: base.EngineContext | None = None) -> Callable[[Overlay], Overlay]:
    def factory(original: Overlay) -> Overlay:
        current_engine = base.current_overlay(original)
        breadth_engine = base.breadth_overlay(original)

        def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
            current_weights = current_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            breadth_weights = breadth_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            network_weights = network_target(prices_by_symbol, signal_index)
            free_budget = max(0.0, 1.0 - total_weight(current_weights))

            if mode == "network_speed_engine":
                return network_weights or current_weights

            if mode == "network_speed_core":
                return blend(current_weights, network_weights, 0.55) if network_weights else current_weights

            if mode == "network_speed_sleeve":
                target = dict(current_weights)
                sleeve = network_target(prices_by_symbol, signal_index, free_budget)
                for symbol, weight in sleeve.items():
                    target[symbol] = target.get(symbol, 0.0) + weight
                return normalize(target)

            if mode == "network_confirmed_return_lead":
                if context is None:
                    raise ValueError("context required")
                routed = return_lead_blend_weights(context, current_weights, breadth_weights, signal_index)
                if equity_network_ok(prices_by_symbol, signal_index):
                    return routed
                if gold_network_ok(prices_by_symbol, signal_index):
                    return current_weights
                return blend(current_weights, routed, 0.75)

            if mode == "network_strong_offense":
                if equity_network_strong(prices_by_symbol, signal_index):
                    return breadth_weights
                if equity_network_ok(prices_by_symbol, signal_index):
                    return blend(current_weights, breadth_weights, 0.45)
                return current_weights

            if mode == "network_transition_router":
                equity_ok = equity_network_ok(prices_by_symbol, signal_index)
                equity_strong = equity_network_strong(prices_by_symbol, signal_index)
                gold_ok = gold_network_ok(prices_by_symbol, signal_index)
                if equity_strong and not gold_ok:
                    return breadth_weights
                if equity_ok and gold_ok:
                    return blend(breadth_weights, current_weights, 0.55)
                if equity_ok:
                    return blend(current_weights, breadth_weights, 0.55)
                return current_weights

            raise ValueError(mode)

        return overlay

    return factory


def three_engine_router(context: dict[str, app.BacktestResult], mode: str) -> Callable[[Overlay], Overlay]:
    def factory(original: Overlay) -> Overlay:
        current_engine = base.current_overlay(original)
        breadth_engine = base.breadth_overlay(original)
        network_engine = network_overlay("network_speed_engine")(original)

        def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
            current_weights = current_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            breadth_weights = breadth_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            network_weights = network_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            candidates = {
                "current": current_weights,
                "breadth": breadth_weights,
                "network": network_weights,
            }
            scored: list[tuple[float, str]] = []
            for name, result in context.items():
                ret = base.trailing_return(result.values, signal_index, 240)
                dd = base.trailing_drawdown(result.values, signal_index, 120) or 0.0
                fast = base.trailing_return(result.values, signal_index, 60) or 0.0
                if ret is None:
                    continue
                score = ret + 0.35 * fast + 1.25 * min(dd, 0.0)
                if name == "breadth" and not equity_network_ok(prices_by_symbol, signal_index):
                    score -= 0.08
                if name == "network" and not candidates[name]:
                    score -= 1.0
                scored.append((score, name))
            if not scored:
                return current_weights
            scored.sort(reverse=True)
            leader = scored[0][1]

            if mode == "three_engine_winner":
                return candidates[leader] or current_weights

            if mode == "three_engine_blend":
                if leader == "current":
                    return blend(current_weights, candidates.get(scored[1][1], {}), 0.70)
                return blend(candidates[leader], current_weights, 0.65)

            raise ValueError(mode)

        return overlay

    return factory


def row_for(name: str, thesis: str, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": name,
        "thesis": thesis,
        "full": {
            "annualized": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "annual_volatility": result.annualized_volatility,
            "sharpe": result.sharpe_ratio,
            "total": result.total_return,
            "trades": len(result.trades),
        },
        "slices": {
            "post_2020": base.slice_metrics(result, "2020-01-01"),
            "last_10y": base.slice_metrics(result, "2016-06-19"),
            "post_2022": base.slice_metrics(result, "2022-01-01"),
            "post_2024": base.slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": base.max_drawdown_window(result),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-8:]],
    }


def main() -> None:
    original_fetch = app.fetch_public_history
    cache: dict[str | None, dict[str, list[tuple[date, float]]]] = {}

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        current = base.run_overlay_strategy("current_gold_handoff", base.current_overlay)
        breadth = base.run_overlay_strategy("equity_breadth", base.breadth_overlay)
        baseline_context = base.EngineContext(current=current, breadth=breadth)
        network = base.run_overlay_strategy("network_speed_engine", network_overlay("network_speed_engine"))

        rows = [
            row_for("current_gold_handoff", "Current defensive/balanced engine.", current),
            row_for("equity_breadth", "Offensive equity-breadth engine.", breadth),
            row_for("network_speed_engine", "Dynamic-speed momentum with network confirmation as a standalone engine.", network),
        ]

        specs: list[tuple[str, str, Callable[[Overlay], Overlay]]] = [
            ("network_speed_core", "Blend current engine with dynamic-speed network target.", network_overlay("network_speed_core")),
            ("network_speed_sleeve", "Keep current as core and fill unused budget with network-confirmed assets.", network_overlay("network_speed_sleeve")),
            (
                "network_confirmed_return_lead",
                "Use prior return-lead engine router only when equity network confirms the offensive state.",
                network_overlay("network_confirmed_return_lead", baseline_context),
            ),
            ("network_strong_offense", "Switch to breadth only when network breadth is strong.", network_overlay("network_strong_offense")),
            ("network_transition_router", "Route by transition state between equity network and gold network.", network_overlay("network_transition_router")),
            (
                "three_engine_winner",
                "Choose current, breadth, or network engine by recent engine trend after network veto.",
                three_engine_router({"current": current, "breadth": breadth, "network": network}, "three_engine_winner"),
            ),
            (
                "three_engine_blend",
                "Blend the recent engine-trend leader with current to avoid all-or-nothing switching.",
                three_engine_router({"current": current, "breadth": breadth, "network": network}, "three_engine_blend"),
            ),
        ]

        for name, thesis, factory in specs:
            result = base.run_overlay_strategy(name, factory)
            rows.append(row_for(name, thesis, result))
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("\nSUMMARY")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades | dd window")
    for row in rows:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
