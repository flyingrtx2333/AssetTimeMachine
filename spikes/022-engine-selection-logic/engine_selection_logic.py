#!/usr/bin/env python3
"""Engine-selection logic candidates.

This spike treats strategies as engines:

- current_gold_handoff = defensive / balanced engine;
- equity_breadth = offensive high-return engine.

It then tests low-frequency engine switching using only historical engine state
available at each rebalance signal date.  This is different from asset-weight
optimization and from parameter sweeps.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import json
from pathlib import Path
import sys
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402
import atm_new_logic_explorer as logic  # noqa: E402
import atm_strategy_explorer as base_explorer  # noqa: E402

Overlay = Callable[[dict[str, float], int, date, dict[str, list[float]], list[float] | None, app.Config], dict[str, float]]


@dataclass(frozen=True)
class EngineContext:
    current: app.BacktestResult
    breadth: app.BacktestResult


@dataclass(frozen=True)
class Candidate:
    name: str
    thesis: str
    runner: Callable[[EngineContext], app.BacktestResult]


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


def confirmed(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> bool:
    mom60 = logic.mom(prices_by_symbol, symbol, index, 60)
    mom120 = logic.mom(prices_by_symbol, symbol, index, 120)
    return (
        mom60 is not None
        and mom120 is not None
        and mom60 > 0
        and mom120 > 0
        and logic.above_ma(prices_by_symbol, symbol, index, 120)
    )


def rolling_vol(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int = 60) -> float | None:
    values = prices_by_symbol[symbol]
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] > 0 and values[cursor] > 0:
            returns.append(app.math.log(values[cursor] / values[cursor - 1]))
    if len(returns) < 2:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return app.math.sqrt(variance) * app.math.sqrt(app.TRADING_DAYS_PER_YEAR)


def score(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> float:
    mom60 = logic.mom(prices_by_symbol, symbol, index, 60) or 0.0
    mom120 = logic.mom(prices_by_symbol, symbol, index, 120) or 0.0
    vol = rolling_vol(prices_by_symbol, symbol, index) or 9.0
    return max(0.0, (mom120 + 0.5 * mom60) / max(vol, 0.01))


def score_basket(symbols: list[str], prices_by_symbol: dict[str, list[float]], index: int, budget: float) -> dict[str, float]:
    scored = [(symbol, score(prices_by_symbol, symbol, index)) for symbol in symbols]
    scored = [(symbol, value) for symbol, value in scored if value > 0]
    total = sum(value for _symbol, value in scored)
    if total <= 0:
        return {}
    return {symbol: budget * value / total for symbol, value in scored}


def current_overlay(original: Overlay) -> Overlay:
    return logic.mechanism_gold_to_confirmed_us_handoff(original)


def breadth_overlay(original: Overlay) -> Overlay:
    base = current_overlay(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        equities = [symbol for symbol in app.EQUITY_SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
        if len(equities) < 2:
            return weights
        budget = 1.0 - total_weight(weights)
        if budget <= 0:
            return normalize(weights)
        addition = score_basket(equities, prices_by_symbol, signal_index, budget)
        for symbol, weight in addition.items():
            weights[symbol] = weights.get(symbol, 0.0) + weight
        return normalize(weights)

    return overlay


def blend(first: dict[str, float], second: dict[str, float], first_share: float) -> dict[str, float]:
    out: dict[str, float] = {}
    share = min(max(first_share, 0.0), 1.0)
    for symbol, weight in first.items():
        out[symbol] = out.get(symbol, 0.0) + weight * share
    for symbol, weight in second.items():
        out[symbol] = out.get(symbol, 0.0) + weight * (1 - share)
    return normalize(out)


def run_overlay_strategy(name: str, overlay_factory: Callable[[Overlay], Overlay]) -> app.BacktestResult:
    original_overlay = app.apply_gold_satellite_overlay
    gold_guard = base_explorer.make_gold_blowoff_rollover_overlay(
        cap=0.45,
        long_lookback=90,
        long_threshold=0.08,
        short_lookback=20,
    )
    app.apply_gold_satellite_overlay = overlay_factory(gold_guard)  # type: ignore[assignment]
    try:
        result = app.run_strategy("coreGoldSatelliteHeatCappedMomentum", end_date="2026-06-19")
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]
    return app.BacktestResult(
        strategy=name,
        coverage_start=result.coverage_start,
        coverage_end=result.coverage_end,
        point_count=result.point_count,
        annualized_return=result.annualized_return,
        max_drawdown=result.max_drawdown,
        total_return=result.total_return,
        annualized_volatility=result.annualized_volatility,
        sharpe_ratio=result.sharpe_ratio,
        final_value=result.final_value,
        trades=result.trades,
        dates=result.dates,
        values=result.values,
    )


def trailing_return(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def trailing_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    start = max(0, index - lookback + 1)
    window = values[start:index + 1]
    if not window:
        return None
    peak = max(window)
    if peak <= 0:
        return None
    return values[index] / peak - 1


def trailing_sharpe(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] > 0 and values[cursor] > 0:
            returns.append(values[cursor] / values[cursor - 1] - 1)
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / max(len(returns) - 1, 1)
    vol = app.math.sqrt(variance) * app.math.sqrt(app.TRADING_DAYS_PER_YEAR)
    if vol <= 0:
        return None
    return mean * app.TRADING_DAYS_PER_YEAR / vol


def switch_overlay(context: EngineContext, mode: str) -> Callable[[Overlay], Overlay]:
    current = current_overlay
    breadth = breadth_overlay

    def factory(original: Overlay) -> Overlay:
        current_engine = current(original)
        breadth_engine = breadth(original)

        def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
            current_weights = current_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            breadth_weights = breadth_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)

            if mode == "simple_ensemble":
                return blend(current_weights, breadth_weights, 0.5)

            current_ret = trailing_return(context.current.values, signal_index, 240)
            breadth_ret = trailing_return(context.breadth.values, signal_index, 240)
            current_sharpe = trailing_sharpe(context.current.values, signal_index, 240)
            breadth_sharpe = trailing_sharpe(context.breadth.values, signal_index, 240)
            breadth_dd = trailing_drawdown(context.breadth.values, signal_index, 120)

            if mode == "sharpe_switch":
                if breadth_sharpe is not None and current_sharpe is not None and breadth_sharpe > current_sharpe and breadth_sharpe > 0:
                    return breadth_weights
                return current_weights

            if mode == "return_switch_with_guard":
                if (
                    breadth_ret is not None
                    and current_ret is not None
                    and breadth_ret > current_ret
                    and (breadth_dd is None or breadth_dd > -0.08)
                ):
                    return breadth_weights
                return current_weights

            if mode == "consensus_switch":
                if (
                    breadth_ret is not None
                    and current_ret is not None
                    and breadth_sharpe is not None
                    and current_sharpe is not None
                    and breadth_ret > current_ret
                    and breadth_sharpe > current_sharpe
                    and (breadth_dd is None or breadth_dd > -0.08)
                ):
                    return breadth_weights
                return current_weights

            if mode == "hierarchical_router":
                if (
                    breadth_ret is not None
                    and current_ret is not None
                    and breadth_ret > current_ret
                    and (breadth_dd is None or breadth_dd > -0.08)
                ):
                    return breadth_weights
                if (
                    breadth_sharpe is not None
                    and current_sharpe is not None
                    and breadth_sharpe > current_sharpe
                    and (breadth_dd is None or breadth_dd > -0.12)
                ):
                    return blend(current_weights, breadth_weights, 0.5)
                return current_weights

            if mode == "return_lead_blend":
                if breadth_ret is not None and current_ret is not None and breadth_ret > current_ret:
                    if breadth_dd is not None and breadth_dd < -0.08:
                        return blend(current_weights, breadth_weights, 0.7)
                    return blend(breadth_weights, current_weights, 0.7)
                return current_weights

            if mode == "adaptive_blend":
                if breadth_sharpe is not None and current_sharpe is not None and breadth_sharpe > current_sharpe:
                    return blend(breadth_weights, current_weights, 0.70)
                return blend(current_weights, breadth_weights, 0.70)

            if mode == "drawdown_defensive":
                if breadth_dd is not None and breadth_dd < -0.06:
                    return current_weights
                return breadth_weights

            raise ValueError(mode)

        return overlay

    return factory


def candidate_specs() -> list[Candidate]:
    return [
        Candidate("current_gold_handoff", "Defensive balanced engine.", lambda _ctx: run_overlay_strategy("current_gold_handoff", current_overlay)),
        Candidate("equity_breadth", "Offensive breadth engine.", lambda _ctx: run_overlay_strategy("equity_breadth", breadth_overlay)),
        Candidate("simple_ensemble", "Static target-level 50/50 current plus breadth.", lambda ctx: run_overlay_strategy("simple_ensemble", switch_overlay(ctx, "simple_ensemble"))),
        Candidate("engine_sharpe_switch", "Choose the engine with better one-year trailing engine Sharpe.", lambda ctx: run_overlay_strategy("engine_sharpe_switch", switch_overlay(ctx, "sharpe_switch"))),
        Candidate("engine_return_switch_guard", "Choose breadth only when its one-year return leads and its recent drawdown is not stressed.", lambda ctx: run_overlay_strategy("engine_return_switch_guard", switch_overlay(ctx, "return_switch_with_guard"))),
        Candidate("engine_consensus_switch", "Choose breadth only when both trailing return and trailing Sharpe lead.", lambda ctx: run_overlay_strategy("engine_consensus_switch", switch_overlay(ctx, "consensus_switch"))),
        Candidate("engine_hierarchical_router", "Use breadth on clean return leadership, ensemble on noisy Sharpe leadership, otherwise current.", lambda ctx: run_overlay_strategy("engine_hierarchical_router", switch_overlay(ctx, "hierarchical_router"))),
        Candidate("engine_return_lead_blend", "Tilt toward breadth on return leadership, but blend defensively when breadth is in drawdown.", lambda ctx: run_overlay_strategy("engine_return_lead_blend", switch_overlay(ctx, "return_lead_blend"))),
        Candidate("engine_adaptive_blend", "Tilt 70/30 toward the engine with better one-year trailing Sharpe.", lambda ctx: run_overlay_strategy("engine_adaptive_blend", switch_overlay(ctx, "adaptive_blend"))),
        Candidate("engine_drawdown_defensive", "Run breadth until breadth itself enters a recent drawdown, then fall back to current.", lambda ctx: run_overlay_strategy("engine_drawdown_defensive", switch_overlay(ctx, "drawdown_defensive"))),
    ]


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


def max_drawdown_window(result: app.BacktestResult) -> dict[str, Any]:
    peak = result.values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for i, value in enumerate(result.values):
        if value > peak:
            peak = value
            peak_i = i
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = i
    return {
        "peak_date": result.dates[worst_peak].isoformat(),
        "trough_date": result.dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


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
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-19"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
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
        current = run_overlay_strategy("current_gold_handoff", current_overlay)
        breadth = run_overlay_strategy("equity_breadth", breadth_overlay)
        context = EngineContext(current=current, breadth=breadth)
        rows = []
        for spec in candidate_specs():
            if spec.name == "current_gold_handoff":
                result = current
            elif spec.name == "equity_breadth":
                result = breadth
            else:
                result = spec.runner(context)
            rows.append(row_for(spec.name, spec.thesis, result))
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
