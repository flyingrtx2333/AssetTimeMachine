#!/usr/bin/env python3
"""Static sleeve ensembles of existing no-leverage strategy engines.

This is a structural test, not single-strategy parameter tuning.  The question:
can fixed capital sleeves assigned to behaviorally different strategies improve
full-history Sharpe without relying on leverage, shorts, or BTC?

The first pass blends already fee-adjusted strategy NAV curves.  Any promising
candidate must later be replayed as a combined target-weight app strategy.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import itertools
import json
import math
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

S28_PATH = ROOT / "spikes" / "028-calendar-invariant-sharpe14" / "sharpe14_logic.py"
SPEC28 = importlib.util.spec_from_file_location("sharpe14_logic_base", S28_PATH)
if SPEC28 is None or SPEC28.loader is None:
    raise RuntimeError(f"failed to load {S28_PATH}")
s28 = importlib.util.module_from_spec(SPEC28)
sys.modules["sharpe14_logic_base"] = s28
SPEC28.loader.exec_module(s28)

S30_PATH = ROOT / "spikes" / "030-smooth-risk-budget" / "smooth_risk_budget.py"
SPEC30 = importlib.util.spec_from_file_location("smooth_risk_budget_base", S30_PATH)
if SPEC30 is None or SPEC30.loader is None:
    raise RuntimeError(f"failed to load {S30_PATH}")
s30 = importlib.util.module_from_spec(SPEC30)
sys.modules["smooth_risk_budget_base"] = s30
SPEC30.loader.exec_module(s30)

app = s28.app
base = s28.base


@dataclass(frozen=True)
class SeriesResult:
    name: str
    result: app.BacktestResult


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def max_drawdown_window(dates: list[date], values: list[float]) -> dict[str, Any]:
    peak = values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for i, value in enumerate(values):
        if value > peak:
            peak = value
            peak_i = i
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = i
    return {"peak_date": dates[worst_peak].isoformat(), "trough_date": dates[worst_trough].isoformat(), "max_drawdown": worst}


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(dates) if day >= start_date), None)
    if idx is None or idx >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates[idx:], values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


def run_s28_candidates() -> list[SeriesResult]:
    current = s28.run_overlay_strategy("current_gold_handoff", base.current_overlay, 60)
    breadth = s28.run_overlay_strategy("equity_breadth", base.breadth_overlay, 60)
    context = base.EngineContext(current=current, breadth=breadth)
    wanted = {
        "baseline_return_lead_blend",
        "baseline_one_way_vol",
        "one_way_portfolio_ladder",
        "one_way_plus_basket_vol9",
        "one_way_plus_basket_vol10",
        "one_way_profit_lock",
        "one_way_us_breakdown_cash",
        "one_way_full_stack",
        "quality_gate_one_way",
    }
    specs = {candidate.name: candidate for candidate in s28.candidate_specs()}
    out = [
        SeriesResult("current_gold_handoff", current),
        SeriesResult("equity_breadth", breadth),
    ]
    for name in sorted(wanted):
        candidate = specs[name]
        result = s28.run_overlay_strategy(name, s28.overlay_factory(context, candidate), candidate.rebalance_sessions)
        out.append(SeriesResult(name, result))
    return out


def run_s30_candidates() -> list[SeriesResult]:
    current = s30.s28.run_overlay_strategy("current_gold_handoff", base.current_overlay, 60)
    breadth = s30.s28.run_overlay_strategy("equity_breadth", base.breadth_overlay, 60)
    env = s30.build_env(base.EngineContext(current=current, breadth=breadth))
    specs = [
        s30.BudgetSpec("smooth_profit_lock", "Smooth profit-lock risk budget.", 90, 0.012, 0.045, 0.50, "profit_lock"),
        s30.BudgetSpec("smooth_two_speed", "Two-speed drawdown risk budget.", 90, 0.012, 0.045, 0.50, "two_speed"),
        s30.BudgetSpec("smooth_convex", "Convex drawdown risk budget.", 90, 0.012, 0.045, 0.50, "convex"),
    ]
    return [SeriesResult(spec.name, s30.run_budget_strategy(spec, env)) for spec in specs]


def aligned_returns(series: list[SeriesResult]) -> tuple[list[date], dict[str, list[float]]]:
    common = set(series[0].result.dates)
    for item in series[1:]:
        common &= set(item.result.dates)
    dates = sorted(common)
    by_name: dict[str, list[float]] = {}
    for item in series:
        value_by_date = dict(zip(item.result.dates, item.result.values))
        values = [value_by_date[day] for day in dates]
        returns = [0.0]
        for index in range(1, len(values)):
            returns.append(values[index] / values[index - 1] - 1 if values[index - 1] > 0 else 0.0)
        by_name[item.name] = returns
    return dates, by_name


def blended_curve(dates: list[date], returns_by_name: dict[str, list[float]], cash_returns: list[float], weights: dict[str, float]) -> list[float]:
    value = 100_000.0
    values = [value]
    cash_weight = max(0.0, 1.0 - sum(max(weight, 0.0) for weight in weights.values()))
    for index in range(1, len(dates)):
        daily = cash_weight * cash_returns[index]
        for name, weight in weights.items():
            daily += weight * returns_by_name[name][index]
        value *= 1 + daily
        values.append(value)
    return values


def blend_row(dates: list[date], returns_by_name: dict[str, list[float]], cash_returns: list[float], weights: dict[str, float]) -> dict[str, Any]:
    values = blended_curve(dates, returns_by_name, cash_returns, weights)
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": "+".join(f"{name}:{weight:.2f}" for name, weight in weights.items() if weight > 0),
        "weights": weights,
        "full": {
            "annualized": annualized,
            "max_drawdown": max_dd,
            "annual_volatility": annual_vol,
            "sharpe": sharpe,
            "total": total,
        },
        "slices": {
            "post_2020": slice_metrics(dates, values, "2020-01-01"),
            "last_10y": slice_metrics(dates, values, "2016-06-23"),
            "post_2022": slice_metrics(dates, values, "2022-01-01"),
            "post_2024": slice_metrics(dates, values, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(dates, values),
    }


def compositions(total: int, parts: int, minimum: int = 1) -> list[list[int]]:
    if parts == 1:
        return [[total]] if total >= minimum else []
    rows: list[list[int]] = []
    max_head = total - minimum * (parts - 1)
    for head in range(minimum, max_head + 1):
        for tail in compositions(total - head, parts - 1, minimum):
            rows.append([head] + tail)
    return rows


def grid_weights(names: list[str], max_cash: float = 0.10, divisor: int = 10) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    min_units = math.ceil((1 - max_cash) * divisor)
    for combo_size in [2, 3]:
        for combo in itertools.combinations(names, combo_size):
            for total_units in range(min_units, divisor + 1):
                for units in compositions(total_units, combo_size):
                    rows.append({name: unit / divisor for name, unit in zip(combo, units)})
    return rows


def selected_search_names(base_rows: list[dict[str, Any]]) -> list[str]:
    by_sharpe = sorted(base_rows, key=lambda row: (row["full"]["sharpe"] or 0.0), reverse=True)
    by_return = sorted(base_rows, key=lambda row: row["full"]["annualized"], reverse=True)
    preferred = [
        "baseline_one_way_vol",
        "one_way_portfolio_ladder",
        "one_way_plus_basket_vol9",
        "smooth_profit_lock",
        "baseline_return_lead_blend",
        "current_gold_handoff",
        "equity_breadth",
    ]
    names: list[str] = []
    for name in preferred + [row["weights"].keys().__iter__().__next__() for row in by_sharpe[:6]] + [row["weights"].keys().__iter__().__next__() for row in by_return[:3]]:
        if name not in names:
            names.append(name)
    return names[:8]


def main() -> None:
    series = run_s28_candidates() + run_s30_candidates()
    dates, returns_by_name = aligned_returns(series)
    cash_returns = [0.0] + [app.cash_daily_return(day) for day in dates[:-1]]
    base_rows = [blend_row(dates, returns_by_name, cash_returns, {item.name: 1.0}) for item in series]
    names = selected_search_names(base_rows)
    rows = base_rows + [blend_row(dates, returns_by_name, cash_returns, weights) for weights in grid_weights(names)]
    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]

    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | dd window")
    for row in rows[:40]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
