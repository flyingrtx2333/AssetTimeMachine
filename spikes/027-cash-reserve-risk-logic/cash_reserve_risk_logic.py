#!/usr/bin/env python3
"""Cash-reserve and no-leverage volatility-management candidates.

No leverage, no financing, no >100% notional exposure.

The prior best engine router is close to Sharpe 1.3. This spike tests whether a
structural cash reserve and one-way volatility management can improve realized
return per unit of volatility without changing the asset universe or borrowing.
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

Overlay = base.Overlay


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


def scale(weights: dict[str, float], factor: float) -> dict[str, float]:
    return {symbol: weight * factor for symbol, weight in weights.items() if weight * factor > 0.0001}


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


def return_lead_weights(
    context: base.EngineContext,
    current_weights: dict[str, float],
    breadth_weights: dict[str, float],
    signal_index: int,
) -> tuple[dict[str, float], str]:
    current_ret = base.trailing_return(context.current.values, signal_index, 240)
    breadth_ret = base.trailing_return(context.breadth.values, signal_index, 240)
    breadth_dd = base.trailing_drawdown(context.breadth.values, signal_index, 120)
    if breadth_ret is not None and current_ret is not None and breadth_ret > current_ret:
        if breadth_dd is not None and breadth_dd < -0.08:
            return blend(current_weights, breadth_weights, 0.7), "defensive_blend"
        return blend(breadth_weights, current_weights, 0.7), "offensive_blend"
    return current_weights, "current"


def risk_parity_engine_weights(
    context: base.EngineContext,
    current_weights: dict[str, float],
    breadth_weights: dict[str, float],
    signal_index: int,
) -> dict[str, float]:
    current_ret = base.trailing_return(context.current.values, signal_index, 240)
    breadth_ret = base.trailing_return(context.breadth.values, signal_index, 240)
    current_vol = trailing_vol(context.current.values, signal_index, 240)
    breadth_vol = trailing_vol(context.breadth.values, signal_index, 240)
    if current_ret is None or breadth_ret is None or current_vol is None or breadth_vol is None:
        return current_weights
    current_quality = max(current_ret, 0.0) / max(current_vol, 0.01)
    breadth_quality = max(breadth_ret, 0.0) / max(breadth_vol, 0.01)
    if current_quality <= 0 and breadth_quality <= 0:
        return current_weights
    breadth_share = breadth_quality / (current_quality + breadth_quality)
    if breadth_ret > current_ret:
        breadth_share = max(breadth_share, 0.55)
    else:
        breadth_share = min(breadth_share, 0.35)
    return blend(breadth_weights, current_weights, breadth_share)


def overlay_factory(context: base.EngineContext, mode: str) -> Callable[[Overlay], Overlay]:
    def factory(original: Overlay) -> Overlay:
        current_engine = base.current_overlay(original)
        breadth_engine = base.breadth_overlay(original)

        def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
            current_weights = current_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            breadth_weights = breadth_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            routed, state = return_lead_weights(context, current_weights, breadth_weights, signal_index)

            if mode == "baseline_return_lead_blend":
                return routed

            if mode == "permanent_cash_reserve":
                # Structural no-leverage margin of safety: keep 10% dry powder
                # in the app's cash yield instead of forcing full deployment.
                return scale(routed, 0.90)

            if mode == "offense_cash_reserve":
                if state == "offensive_blend":
                    return scale(routed, 0.88)
                return routed

            if mode == "defensive_cash_reserve":
                if state != "offensive_blend":
                    return scale(routed, 0.90)
                return routed

            if mode == "engine_quality_risk_parity":
                return risk_parity_engine_weights(context, current_weights, breadth_weights, signal_index)

            if mode == "risk_parity_cash_reserve":
                return scale(risk_parity_engine_weights(context, current_weights, breadth_weights, signal_index), 0.92)

            if mode == "one_way_vol_managed":
                # Use current engine's own realized volatility as the risk
                # budget; if the routed engine is hotter, cut exposure, never
                # borrow to raise exposure.
                current_vol = trailing_vol(context.current.values, signal_index, 240)
                breadth_vol = trailing_vol(context.breadth.values, signal_index, 240)
                routed_vol = breadth_vol if state == "offensive_blend" else current_vol
                if current_vol is None or routed_vol is None or routed_vol <= current_vol:
                    return routed
                return scale(routed, min(1.0, current_vol / routed_vol))

            if mode == "profit_lock_after_fast_offense":
                breadth_fast = base.trailing_return(context.breadth.values, signal_index, 60)
                breadth_dd = base.trailing_drawdown(context.breadth.values, signal_index, 60)
                if state == "offensive_blend" and breadth_fast is not None and breadth_fast > 0.08 and (breadth_dd is None or breadth_dd > -0.02):
                    return scale(routed, 0.88)
                return routed

            if mode == "cash_buffer_offense_retest":
                breadth_slow = base.trailing_return(context.breadth.values, signal_index, 240)
                current_slow = base.trailing_return(context.current.values, signal_index, 240)
                breadth_dd = base.trailing_drawdown(context.breadth.values, signal_index, 120)
                breadth_clean = breadth_dd is None or breadth_dd > -0.08
                if breadth_slow is not None and current_slow is not None and breadth_slow > current_slow and breadth_clean:
                    return scale(breadth_weights, 0.85)
                return current_weights

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
        context = base.EngineContext(current=current, breadth=breadth)
        rows = [
            row_for("current_gold_handoff", "Current defensive/balanced engine.", current),
            row_for("equity_breadth", "Offensive equity-breadth engine.", breadth),
        ]
        specs: list[tuple[str, str]] = [
            ("baseline_return_lead_blend", "Prior best return-lead engine blend."),
            ("permanent_cash_reserve", "Run prior best with a permanent 10% cash reserve."),
            ("offense_cash_reserve", "Reserve cash only when the router is in offensive blend state."),
            ("defensive_cash_reserve", "Reserve cash outside offensive state only."),
            ("engine_quality_risk_parity", "Blend engines by trailing return per unit of engine volatility."),
            ("risk_parity_cash_reserve", "Engine-quality risk parity with a small cash reserve."),
            ("one_way_vol_managed", "Scale down only when routed engine volatility exceeds current engine volatility."),
            ("profit_lock_after_fast_offense", "Reserve cash after fast offensive gains while breadth is near highs."),
            ("cash_buffer_offense_retest", "Retest the prior cash-buffer offense rule in this spike."),
        ]
        for name, thesis in specs:
            result = base.run_overlay_strategy(name, overlay_factory(context, name))
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
