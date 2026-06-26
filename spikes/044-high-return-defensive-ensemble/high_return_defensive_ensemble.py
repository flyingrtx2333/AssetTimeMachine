#!/usr/bin/env python3
"""Static sleeve screen for high-return satellite plus defensive budget.

No leverage, no shorting, no BTC. This is a screening step only: it blends two
already fee-adjusted strategy NAV curves. Any passing result needs a target
weight replay before product use.
"""
from __future__ import annotations

from datetime import date, datetime
import importlib.util
import json
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402

S30_PATH = ROOT / "spikes" / "030-smooth-risk-budget" / "smooth_risk_budget.py"
S42_PATH = ROOT / "spikes" / "042-confirmed-acceleration-satellite" / "confirmed_acceleration_satellite.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


s30 = load_module("smooth_risk_budget_for_ensemble", S30_PATH)
s42 = load_module("confirmed_acceleration_for_ensemble", S42_PATH)


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def run_confirmed_satellite() -> app.BacktestResult:
    spec = s42.s35.SatelliteSpec(
        "confirmed_satellite_best",
        "Best confirmed acceleration/compression/no-weak-month extra-equity satellite.",
        0.25,
        0.10,
        2,
        "risk_clean_confirmed_accel_compression_no_weak_months",
    )
    original_fetch = app.fetch_public_history
    original_add = s42.s35.add_satellite
    cache: dict[str | None, dict[str, list[tuple[date, float]]]] = {}

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s42.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s42.s35.add_satellite = s42.add_satellite  # type: ignore[assignment]
    try:
        env = s42.s35.build_env()
        return s42.s35.run_satellite_strategy(spec, env)
    finally:
        s42.s35.add_satellite = original_add  # type: ignore[assignment]
        s42.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        app.fetch_public_history = original_fetch  # type: ignore[assignment]


def run_profit_lock() -> app.BacktestResult:
    spec = s30.BudgetSpec("profit_lock_best", "Best defensive profit-lock risk budget.", 90, 0.012, 0.045, 0.50, "profit_lock")
    original_fetch = s30.app.fetch_public_history
    cache: dict[str | None, dict[str, list[tuple[date, float]]]] = {}

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        current = s30.s28.run_overlay_strategy("current_gold_handoff", s30.base.current_overlay, 60)
        breadth = s30.s28.run_overlay_strategy("equity_breadth", s30.base.breadth_overlay, 60)
        context = s30.base.EngineContext(current=current, breadth=breadth)
        env = s30.build_env(context)
        return s30.run_budget_strategy(spec, env)
    finally:
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]


def align_values(a: app.BacktestResult, b: app.BacktestResult, weight_a: float) -> tuple[list[date], list[float]]:
    by_a = {day: value for day, value in zip(a.dates, a.values)}
    by_b = {day: value for day, value in zip(b.dates, b.values)}
    dates = [day for day in a.dates if day in by_b]
    values = [weight_a * by_a[day] + (1.0 - weight_a) * by_b[day] for day in dates]
    return dates, values


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(dates) if day >= start_date), None)
    if idx is None or idx >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates[idx:], values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


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


def row(name: str, dates: list[date], values: list[float], weight_satellite: float | None = None) -> dict[str, Any]:
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": name,
        "weight_satellite": weight_satellite,
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


def main() -> None:
    satellite = run_confirmed_satellite()
    defensive = run_profit_lock()
    rows: list[dict[str, Any]] = [
        row("confirmed_satellite_best", satellite.dates, satellite.values, 1.0),
        row("profit_lock_best", defensive.dates, defensive.values, 0.0),
    ]
    for weight in [i / 20 for i in range(1, 20)]:
        dates, values = align_values(satellite, defensive, weight)
        rows.append(row(f"blend_satellite_{int(weight * 100)}", dates, values, weight))

    rows.sort(key=lambda item: (item["full"]["sharpe"] or 0.0, item["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Static NAV blend screen; target-weight replay required before app use.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | sat_weight | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | dd window")
    for item in rows:
        full: dict[str, Any] = item["full"]
        slices: dict[str, dict[str, Any]] = item["slices"]
        ddw: dict[str, Any] = item["drawdown_window"]
        print(
            f"{item['name']} | {item['weight_satellite']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
