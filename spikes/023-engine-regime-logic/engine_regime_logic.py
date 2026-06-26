#!/usr/bin/env python3
"""Engine-regime routing candidates.

This spike builds on spike 022.  It keeps the same two engines:

- current_gold_handoff: defensive/balanced;
- equity_breadth: offensive/high-return.

The new logic is a regime state machine over engine equity curves, not a search
over asset-signal parameters.
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

Overlay = base.Overlay


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def moving_average(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0:
        return None
    window = values[index - lookback + 1:index + 1]
    if not window:
        return None
    return sum(window) / len(window)


def above_engine_ma(values: list[float], index: int, lookback: int) -> bool:
    ma = moving_average(values, index, lookback)
    return ma is not None and values[index] >= ma


def positive_engine_momentum(values: list[float], index: int, lookback: int) -> bool:
    ret = base.trailing_return(values, index, lookback)
    return ret is not None and ret > 0


def engine_regime_overlay(context: base.EngineContext, mode: str) -> Callable[[Overlay], Overlay]:
    def factory(original: Overlay) -> Overlay:
        current_engine = base.current_overlay(original)
        breadth_engine = base.breadth_overlay(original)

        def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
            current_weights = current_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            breadth_weights = breadth_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)

            current_fast = base.trailing_return(context.current.values, signal_index, 60)
            breadth_fast = base.trailing_return(context.breadth.values, signal_index, 60)
            current_slow = base.trailing_return(context.current.values, signal_index, 240)
            breadth_slow = base.trailing_return(context.breadth.values, signal_index, 240)
            current_sharpe = base.trailing_sharpe(context.current.values, signal_index, 240)
            breadth_sharpe = base.trailing_sharpe(context.breadth.values, signal_index, 240)
            breadth_dd = base.trailing_drawdown(context.breadth.values, signal_index, 120)
            breadth_clean = (breadth_dd is None or breadth_dd > -0.08) and above_engine_ma(context.breadth.values, signal_index, 120)
            breadth_recovered = above_engine_ma(context.breadth.values, signal_index, 60) and positive_engine_momentum(context.breadth.values, signal_index, 60)

            if mode == "breadth_equity_curve_gate":
                if breadth_clean and positive_engine_momentum(context.breadth.values, signal_index, 120):
                    return breadth_weights
                return current_weights

            if mode == "fast_slow_consensus":
                fast_win = breadth_fast is not None and current_fast is not None and breadth_fast > current_fast
                slow_win = breadth_slow is not None and current_slow is not None and breadth_slow > current_slow
                if fast_win and slow_win and breadth_clean:
                    return breadth_weights
                if (fast_win or slow_win) and breadth_recovered:
                    return base.blend(current_weights, breadth_weights, 0.5)
                return current_weights

            if mode == "sharpe_return_ladder":
                ret_win = breadth_slow is not None and current_slow is not None and breadth_slow > current_slow
                sharpe_win = breadth_sharpe is not None and current_sharpe is not None and breadth_sharpe > current_sharpe
                if ret_win and sharpe_win and breadth_clean:
                    return breadth_weights
                if ret_win and breadth_recovered:
                    return base.blend(breadth_weights, current_weights, 0.65)
                if sharpe_win:
                    return base.blend(current_weights, breadth_weights, 0.6)
                return current_weights

            if mode == "offense_after_recovery":
                if breadth_slow is not None and current_slow is not None and breadth_slow > current_slow and breadth_recovered:
                    return breadth_weights
                if breadth_recovered:
                    return base.blend(current_weights, breadth_weights, 0.6)
                return current_weights

            if mode == "drawdown_aware_ladder":
                if breadth_dd is not None and breadth_dd < -0.08:
                    return current_weights
                if breadth_dd is not None and breadth_dd < -0.03:
                    return base.blend(current_weights, breadth_weights, 0.7)
                if breadth_slow is not None and current_slow is not None and breadth_slow > current_slow:
                    return breadth_weights
                return base.blend(current_weights, breadth_weights, 0.5)

            if mode == "cash_buffer_offense":
                if breadth_slow is not None and current_slow is not None and breadth_slow > current_slow and breadth_clean:
                    # Structural cash ballast: deploy offense but leave part of
                    # the budget in cash to improve realized return/vol ratio.
                    return {symbol: weight * 0.85 for symbol, weight in breadth_weights.items()}
                return current_weights

            raise ValueError(mode)

        return overlay

    return factory


def candidate_specs() -> list[tuple[str, str, str]]:
    return [
        ("breadth_equity_curve_gate", "Use offense only when its own equity curve is above trend and recent drawdown is clean.", "breadth_equity_curve_gate"),
        ("fast_slow_consensus", "Use offense when it beats defense on both fast and slow engine returns; blend on partial agreement.", "fast_slow_consensus"),
        ("sharpe_return_ladder", "Route by return and Sharpe agreement; partial wins get partial offense.", "sharpe_return_ladder"),
        ("offense_after_recovery", "Use offense after it regains short-term trend, otherwise fall back to current.", "offense_after_recovery"),
        ("drawdown_aware_ladder", "Scale offense by its own recent drawdown state.", "drawdown_aware_ladder"),
        ("cash_buffer_offense", "When offense leads cleanly, run it with a structural cash ballast.", "cash_buffer_offense"),
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
            row_for("current_gold_handoff", "Defensive balanced engine.", current),
            row_for("equity_breadth", "Offensive high-return engine.", breadth),
            row_for("engine_return_lead_blend", "Best from spike 022.", base.run_overlay_strategy("engine_return_lead_blend", base.switch_overlay(context, "return_lead_blend"))),
        ]
        for name, thesis, mode in candidate_specs():
            result = base.run_overlay_strategy(name, engine_regime_overlay(context, mode))
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
