#!/usr/bin/env python3
"""Higher-Sharpe risk-budget routing candidates.

No leverage, no financing, no >100% notional exposure.

This spike extends the engine-router idea with portfolio-state and market-state
risk budgets.  The aim is to improve Sharpe without turning the strategy into a
cash-only artifact.
"""
from __future__ import annotations

from datetime import date, datetime
import importlib.util
import json
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


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(value, 0.0) for value in weights.values())


def scale(weights: dict[str, float], factor: float) -> dict[str, float]:
    return {symbol: weight * factor for symbol, weight in weights.items() if weight * factor > 0.0001}


def recent_drawdown(values: list[float] | None, lookback: int) -> float:
    if not values:
        return 0.0
    window = values[-lookback:]
    if not window:
        return 0.0
    peak = max(window)
    if peak <= 0:
        return 0.0
    return values[-1] / peak - 1


def market_stress(prices_by_symbol: dict[str, list[float]], signal_index: int) -> bool:
    sp_bad = (
        (logic.mom(prices_by_symbol, "sp500", signal_index, 20) or 0.0) < -0.03
        or not logic.above_ma(prices_by_symbol, "sp500", signal_index, 120)
    )
    nd_bad = (
        (logic.mom(prices_by_symbol, "nasdaq", signal_index, 20) or 0.0) < -0.04
        or not logic.above_ma(prices_by_symbol, "nasdaq", signal_index, 120)
    )
    return sp_bad and nd_bad


def weak_season(signal_date: date) -> bool:
    # Calendar rule, not fitted to this search: late-summer/autumn risk windows
    # plus February, which the app already treats as a weak equity month.
    return signal_date.month in {2, 8, 9, 10}


def route_overlay(context: base.EngineContext, mode: str) -> Callable[[Overlay], Overlay]:
    def factory(original: Overlay) -> Overlay:
        current_engine = base.current_overlay(original)
        breadth_engine = base.breadth_overlay(original)

        def base_return_lead(
            raw_weights,
            signal_index,
            signal_date,
            prices_by_symbol,
            portfolio_values,
            config,
        ) -> dict[str, float]:
            current_weights = current_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            breadth_weights = breadth_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            current_ret = base.trailing_return(context.current.values, signal_index, 240)
            breadth_ret = base.trailing_return(context.breadth.values, signal_index, 240)
            breadth_dd = base.trailing_drawdown(context.breadth.values, signal_index, 120)
            if breadth_ret is not None and current_ret is not None and breadth_ret > current_ret:
                if breadth_dd is not None and breadth_dd < -0.08:
                    return base.blend(current_weights, breadth_weights, 0.7)
                return base.blend(breadth_weights, current_weights, 0.7)
            return current_weights

        def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
            current_weights = current_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            breadth_weights = breadth_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            routed = base_return_lead(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)

            if mode == "baseline_return_lead_blend":
                return routed

            if mode == "portfolio_drawdown_budget":
                dd = recent_drawdown(portfolio_values, 60)
                if dd < -0.06:
                    return current_weights
                if dd < -0.03:
                    return base.blend(current_weights, routed, 0.7)
                return routed

            if mode == "market_stress_budget":
                if market_stress(prices_by_symbol, signal_index):
                    return current_weights
                return routed

            if mode == "seasonal_defensive_router":
                if weak_season(signal_date):
                    return base.blend(current_weights, routed, 0.75)
                return routed

            if mode == "stress_or_season_budget":
                if market_stress(prices_by_symbol, signal_index):
                    return current_weights
                if weak_season(signal_date):
                    return base.blend(current_weights, routed, 0.65)
                return routed

            if mode == "drawdown_scale_not_switch":
                dd = recent_drawdown(portfolio_values, 60)
                if dd < -0.06:
                    return scale(routed, 0.55)
                if dd < -0.03:
                    return scale(routed, 0.75)
                return routed

            if mode == "offense_only_after_engine_recovery":
                current_ret = base.trailing_return(context.current.values, signal_index, 240)
                breadth_ret = base.trailing_return(context.breadth.values, signal_index, 240)
                breadth_fast = base.trailing_return(context.breadth.values, signal_index, 60)
                breadth_dd = base.trailing_drawdown(context.breadth.values, signal_index, 120)
                recovered = breadth_fast is not None and breadth_fast > 0 and (breadth_dd is None or breadth_dd > -0.06)
                if breadth_ret is not None and current_ret is not None and breadth_ret > current_ret and recovered:
                    return base.blend(breadth_weights, current_weights, 0.7)
                return current_weights

            if mode == "risk_sleeve_router":
                # Split the target into stable core plus offensive sleeve when
                # breadth leads; this avoids replacing the whole portfolio with
                # the offensive engine.
                current_ret = base.trailing_return(context.current.values, signal_index, 240)
                breadth_ret = base.trailing_return(context.breadth.values, signal_index, 240)
                if breadth_ret is not None and current_ret is not None and breadth_ret > current_ret and not market_stress(prices_by_symbol, signal_index):
                    return base.blend(current_weights, breadth_weights, 0.55)
                return current_weights

            raise ValueError(mode)

        return overlay

    return factory


def candidate_specs() -> list[tuple[str, str]]:
    return [
        ("baseline_return_lead_blend", "Prior best engine return lead blend."),
        ("portfolio_drawdown_budget", "When this strategy itself enters drawdown, step back to the defensive engine."),
        ("market_stress_budget", "Use defensive engine during broad US stress, otherwise use return-lead blend."),
        ("seasonal_defensive_router", "Use defensive blend during weak calendar risk windows, otherwise use return-lead blend."),
        ("stress_or_season_budget", "Combine broad-market stress and weak-season defensive routing."),
        ("drawdown_scale_not_switch", "Scale exposure down during strategy drawdown instead of switching engines."),
        ("offense_only_after_engine_recovery", "Use offense only after its own fast recovery confirms."),
        ("risk_sleeve_router", "Keep current as core and add an offensive breadth sleeve only when breadth leads."),
    ]


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
        context = base.EngineContext(current=current, breadth=breadth)
        rows = [
            row_for("current_gold_handoff", "Current defensive/balanced engine.", current),
            row_for("equity_breadth", "Offensive equity-breadth engine.", breadth),
        ]
        for name, thesis in candidate_specs():
            result = base.run_overlay_strategy(name, route_overlay(context, name))
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
