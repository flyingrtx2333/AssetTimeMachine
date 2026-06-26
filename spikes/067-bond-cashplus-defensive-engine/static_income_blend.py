#!/usr/bin/env python3
"""Static current-core + income-fund blend search under 1% entry fee.

This is a ceiling check: if low-turnover income ballast cannot improve the
Sharpe enough even with static weights, dynamic sleeves are unlikely to solve
the 1% fee problem without a new return source.
"""
from __future__ import annotations

from datetime import date, datetime
import importlib.util
import json
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


engine = load_module("atm_spike067_engine", HERE / "bond_cashplus_defensive_engine.py")
app = engine.app
carry = engine.carry

FUNDS = ["OSTIX", "DODIX", "PTTRX", "VWINX", "PRWCX", "FPACX"]
ASSETS = ["CORE", *FUNDS]
MIN_CORE_WEIGHT = 0.20
FUND_ENTRY_FEE = 0.01
END_DATE = "2026-06-23"


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def fetch_fund(symbol: str) -> list[tuple[date, float]]:
    lower = symbol.lower()
    if lower not in engine.YAHOO_SYMBOLS:
        engine.YAHOO_SYMBOLS[lower] = symbol
    return engine.fetch_yahoo_adjusted(lower)


def fund_series(symbol: str, dates: list[date], fx_points: list[tuple[date, float]]) -> list[float | None]:
    points = carry.convert_usd_points_to_cny(fetch_fund(symbol), fx_points)
    out: list[float | None] = []
    first_price: float | None = None
    for day in dates:
        price = carry.price_on_or_before(points, day, app.MAX_FORWARD_FILL_CALENDAR_DAYS)
        if price is None:
            out.append(None)
            continue
        if first_price is None:
            first_price = price
        out.append(100_000.0 * (1 - FUND_ENTRY_FEE) * price / first_price)
    return out


def performance(dates: list[date], values: list[float]) -> dict[str, float | None]:
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "annualized": annualized,
        "max_drawdown": max_dd,
        "annual_volatility": annual_vol,
        "sharpe": sharpe,
        "total": total,
    }


def slice_performance(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    index = next((i for i, day in enumerate(dates) if day >= start_date), None)
    if index is None or index >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "annual_volatility": None, "sharpe": None, "total": None}
    return performance(dates[index:], values[index:])


def weight_vectors(asset_count: int, total_steps: int = 10, prefix: tuple[float, ...] = ()) -> list[tuple[float, ...]]:
    if asset_count == 1:
        return [prefix + (total_steps / 10,)]
    out: list[tuple[float, ...]] = []
    for step in range(total_steps + 1):
        out.extend(weight_vectors(asset_count - 1, total_steps - step, prefix + (step / 10,)))
    return out


def main() -> None:
    base = app.run_strategy("coreGoldSatelliteOneWayVolManagedMomentum", end_date=END_DATE)
    raw = app.fetch_public_history(end_date=app.parse_date(END_DATE))
    matrix: dict[str, list[float | None]] = {"CORE": [float(value) for value in base.values]}
    for fund in FUNDS:
        matrix[fund] = fund_series(fund, base.dates, raw[app.USD_FX_SYMBOL])

    valid_indices = [
        index
        for index, _day in enumerate(base.dates)
        if all(matrix[asset][index] is not None for asset in ASSETS)
    ]
    dates = [base.dates[index] for index in valid_indices]
    aligned = {asset: [float(matrix[asset][index] or 0.0) for index in valid_indices] for asset in ASSETS}

    rows: list[dict[str, Any]] = []
    for weights in weight_vectors(len(ASSETS)):
        if weights[0] < MIN_CORE_WEIGHT:
            continue
        values = [
            sum(weights[index] * aligned[asset][cursor] for index, asset in enumerate(ASSETS))
            for cursor in range(len(dates))
        ]
        row = {
            "weights": {asset: weights[index] for index, asset in enumerate(ASSETS) if weights[index] > 0},
            "full": performance(dates, values),
            "slices": {
                "post_2020": slice_performance(dates, values, "2020-01-01"),
                "last_10y": slice_performance(dates, values, "2016-06-23"),
                "post_2024": slice_performance(dates, values, "2024-01-01"),
            },
        }
        rows.append(row)

    rows.sort(key=lambda row: (row["full"]["sharpe"] or -9.0, row["full"]["annualized"] or -9.0), reverse=True)
    out_path = HERE / "static_blend_results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "coverage": {"start": dates[0].isoformat(), "end": dates[-1].isoformat(), "count": len(dates)},
                "min_core_weight": MIN_CORE_WEIGHT,
                "fund_entry_fee": FUND_ENTRY_FEE,
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("weights | ann/dd/sharpe/vol | post2020 ann/sh | last10 ann/sh | post2024 ann/sh")
    for row in rows[:25]:
        full = row["full"]
        slices = row["slices"]
        print(
            f"{row['weights']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f}"
        )


if __name__ == "__main__":
    main()
