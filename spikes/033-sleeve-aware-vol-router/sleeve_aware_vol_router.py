#!/usr/bin/env python3
"""Sleeve-aware volatility routing candidates.

The current champion scales the whole routed portfolio down when the offensive
engine is more volatile than the current defensive engine.  This spike tests a
more structural idea: treat the current engine as the core sleeve and the
offensive breadth engine as a satellite sleeve, then scale or redeploy only the
offensive sleeve.

No leverage, no shorting, no total notional above 100%.
"""
from __future__ import annotations

from dataclasses import dataclass
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

Overlay = base.Overlay


@dataclass(frozen=True)
class Candidate:
    name: str
    thesis: str
    mode: str


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(out)
    if total > max_total and total > 0:
        scale = max_total / total
        out = {symbol: weight * scale for symbol, weight in out.items() if weight * scale > 0.0001}
    return out


def scale(weights: dict[str, float], factor: float) -> dict[str, float]:
    factor = min(max(factor, 0.0), 1.0)
    return normalize({symbol: weight * factor for symbol, weight in weights.items()})


def blend(first: dict[str, float], second: dict[str, float], first_share: float) -> dict[str, float]:
    out: dict[str, float] = {}
    share = min(max(first_share, 0.0), 1.0)
    for symbol, weight in first.items():
        out[symbol] = out.get(symbol, 0.0) + weight * share
    for symbol, weight in second.items():
        out[symbol] = out.get(symbol, 0.0) + weight * (1 - share)
    return normalize(out)


def trailing_vol(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] > 0 and values[cursor] > 0:
            returns.append(math.log(values[cursor] / values[cursor - 1]))
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


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
    return values[index] / peak - 1 if peak > 0 else None


def vol_ratio(context: base.EngineContext, signal_index: int) -> float:
    current_vol = trailing_vol(context.current.values, signal_index, 240)
    breadth_vol = trailing_vol(context.breadth.values, signal_index, 240)
    if current_vol is None or breadth_vol is None or breadth_vol <= current_vol or breadth_vol <= 0:
        return 1.0
    return min(max(current_vol / breadth_vol, 0.0), 1.0)


def positive_delta(from_weights: dict[str, float], to_weights: dict[str, float]) -> dict[str, float]:
    out: dict[str, float] = {}
    for symbol, target in to_weights.items():
        extra = target - from_weights.get(symbol, 0.0)
        if extra > 0.0001:
            out[symbol] = extra
    return out


def add_weights(first: dict[str, float], second: dict[str, float], second_scale: float = 1.0) -> dict[str, float]:
    out = dict(first)
    for symbol, weight in second.items():
        out[symbol] = out.get(symbol, 0.0) + weight * second_scale
    return normalize(out)


def route_state(context: base.EngineContext, signal_index: int) -> str:
    current_ret = trailing_return(context.current.values, signal_index, 240)
    breadth_ret = trailing_return(context.breadth.values, signal_index, 240)
    breadth_dd = trailing_drawdown(context.breadth.values, signal_index, 120)
    if current_ret is not None and breadth_ret is not None and breadth_ret > current_ret:
        if breadth_dd is not None and breadth_dd < -0.08:
            return "defensive_blend"
        return "offensive_blend"
    return "current"


def route_weights(
    context: base.EngineContext,
    current_weights: dict[str, float],
    breadth_weights: dict[str, float],
    signal_index: int,
    mode: str,
) -> dict[str, float]:
    state = route_state(context, signal_index)
    ratio = vol_ratio(context, signal_index)

    if state == "current":
        return current_weights

    if state == "defensive_blend":
        return blend(current_weights, breadth_weights, 0.7)

    if mode == "baseline_one_way":
        return scale(blend(breadth_weights, current_weights, 0.7), ratio)

    if mode == "scale_breadth_sleeve_only":
        out: dict[str, float] = {}
        for symbol, weight in current_weights.items():
            out[symbol] = out.get(symbol, 0.0) + weight * 0.30
        for symbol, weight in breadth_weights.items():
            out[symbol] = out.get(symbol, 0.0) + weight * 0.70 * ratio
        return normalize(out)

    if mode == "redeploy_to_current":
        breadth_share = 0.70 * ratio
        current_share = 1.0 - breadth_share
        return blend(breadth_weights, current_weights, breadth_share)

    if mode == "core_plus_scaled_extra":
        extra = positive_delta(current_weights, breadth_weights)
        return add_weights(current_weights, extra, ratio)

    if mode == "core_plus_half_scaled_extra":
        extra = positive_delta(current_weights, breadth_weights)
        return add_weights(current_weights, extra, 0.5 * ratio)

    if mode == "core_plus_quality_extra":
        current_ret = trailing_return(context.current.values, signal_index, 120) or 0.0
        breadth_ret = trailing_return(context.breadth.values, signal_index, 120) or 0.0
        quality_boost = 1.0 if breadth_ret > current_ret else 0.5
        extra = positive_delta(current_weights, breadth_weights)
        return add_weights(current_weights, extra, ratio * quality_boost)

    if mode == "current_floor_scaled_route":
        routed = scale(blend(breadth_weights, current_weights, 0.7), ratio)
        # Keep at least half of the current engine's core if the full-portfolio
        # scale would have cut it below that level.
        floor = scale(current_weights, 0.50)
        out = dict(routed)
        for symbol, weight in floor.items():
            out[symbol] = max(out.get(symbol, 0.0), weight)
        return normalize(out)

    raise ValueError(mode)


def overlay_factory(context: base.EngineContext, candidate: Candidate) -> Callable[[Overlay], Overlay]:
    def factory(original: Overlay) -> Overlay:
        current_engine = base.current_overlay(original)
        breadth_engine = base.breadth_overlay(original)

        def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
            current_weights = current_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            breadth_weights = breadth_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            return route_weights(context, current_weights, breadth_weights, signal_index, candidate.mode)

        return overlay

    return factory


def run_overlay_strategy(name: str, overlay_builder: Callable[[Overlay], Overlay]) -> app.BacktestResult:
    original_overlay = app.apply_gold_satellite_overlay
    gold_guard = base.base_explorer.make_gold_blowoff_rollover_overlay(
        cap=0.45,
        long_lookback=90,
        long_threshold=0.08,
        short_lookback=20,
    )
    app.apply_gold_satellite_overlay = overlay_builder(gold_guard)  # type: ignore[assignment]
    try:
        result = app.run_strategy("coreGoldSatelliteHeatCappedMomentum", end_date="2026-06-23")
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


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
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
    return {"peak_date": result.dates[worst_peak].isoformat(), "trough_date": result.dates[worst_trough].isoformat(), "max_drawdown": worst}


def row_for(candidate: Candidate, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": candidate.name,
        "thesis": candidate.thesis,
        "mode": candidate.mode,
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
            "last_10y": slice_metrics(result, "2016-06-23"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-8:]],
    }


def candidate_specs() -> list[Candidate]:
    return [
        Candidate("baseline_one_way", "Current champion logic: scale the whole routed target when offensive engine is hotter.", "baseline_one_way"),
        Candidate("scale_breadth_sleeve_only", "Scale only the offensive sleeve; preserve the current-engine sleeve.", "scale_breadth_sleeve_only"),
        Candidate("redeploy_to_current", "Move clipped offensive budget back to the current defensive engine instead of cash.", "redeploy_to_current"),
        Candidate("core_plus_scaled_extra", "Use current engine as core and add only volatility-scaled positive breadth extras.", "core_plus_scaled_extra"),
        Candidate("core_plus_half_scaled_extra", "Use current engine as core and add a smaller scaled breadth satellite.", "core_plus_half_scaled_extra"),
        Candidate("core_plus_quality_extra", "Add scaled breadth extras only when recent breadth quality still leads.", "core_plus_quality_extra"),
        Candidate("current_floor_scaled_route", "Whole-route volatility scale with a floor on the current core sleeve.", "current_floor_scaled_route"),
    ]


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
        current = run_overlay_strategy("current_gold_handoff", base.current_overlay)
        breadth = run_overlay_strategy("equity_breadth", base.breadth_overlay)
        context = base.EngineContext(current=current, breadth=breadth)
        rows = [row_for(candidate, run_overlay_strategy(candidate.name, overlay_factory(context, candidate))) for candidate in candidate_specs()]
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
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
