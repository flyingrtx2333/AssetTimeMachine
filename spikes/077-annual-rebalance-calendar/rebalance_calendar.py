#!/usr/bin/env python3
"""Calendar timing test for annual quality/core baskets.

This keeps the asset logic from spike 074 unchanged and tests whether the
rebalance calendar itself is a better structural rule than "first trading day of
the calendar year".
"""
from __future__ import annotations

from datetime import datetime
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


frontier073 = load_module("atm_spike073_for_077", ROOT / "spikes/073-static-quality-income-frontier/static_quality_income_frontier.py")
app = frontier073.app


BASKETS = [
    (
        "max_sharpe_074",
        {"OSTIX": 0.50, "CORE": 0.30, "IAU": 0.05, "AAPL": 0.05, "LLY": 0.05, "ORLY": 0.05},
    ),
    (
        "annual_12_sharpe_156",
        {"OSTIX": 0.40, "CORE": 0.35, "IAU": 0.05, "AAPL": 0.10, "LLY": 0.05, "ORLY": 0.05},
    ),
    (
        "annual_1230_sharpe_1549",
        {"OSTIX": 0.40, "CORE": 0.30, "IAU": 0.05, "AAPL": 0.10, "COST": 0.05, "LLY": 0.05, "ORLY": 0.05},
    ),
    (
        "middle_1168_sharpe_1573",
        {"OSTIX": 0.45, "CORE": 0.30, "IAU": 0.05, "AAPL": 0.10, "LLY": 0.05, "ORLY": 0.05},
    ),
]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def replay_months(dates: list[Any], series: dict[str, list[float | None]], basket: frontier073.Basket, months: set[int]) -> tuple[list[Any], list[float], int] | None:
    symbols = list(basket.weights)
    indices = frontier073.aligned_indices(dates, series, symbols)
    if not indices:
        return None
    cash = frontier073.INITIAL_CASH
    units = {symbol: 0.0 for symbol in symbols}
    out_dates: list[Any] = []
    values: list[float] = []
    trades = 0
    rebalanced_periods: set[tuple[int, int]] = set()

    def value_at(index: int) -> float:
        total = cash
        for symbol, qty in units.items():
            price = float(series[symbol][index] or 0.0)
            if qty > 0 and price > 0:
                total += qty * price
        return total

    for index in indices:
        day = dates[index]
        period_key = (day.year, day.month)
        should_rebalance = day.month in months and period_key not in rebalanced_periods
        if not out_dates:
            should_rebalance = True
        if should_rebalance:
            current_value = value_at(index)
            for symbol in symbols:
                price = float(series[symbol][index] or 0.0)
                if price <= 0:
                    continue
                current_symbol_value = units[symbol] * price
                desired = current_value * basket.weights[symbol]
                if current_symbol_value > desired:
                    qty = min(units[symbol], (current_symbol_value - desired) / price)
                    if qty > 0:
                        fee = 0.0 if symbol == "CORE" else frontier073.FEE_RATE
                        cash += qty * price * (1 - frontier073.SLIPPAGE_RATE) * (1 - fee)
                        units[symbol] -= qty
                        trades += 1
            current_value = value_at(index)
            for symbol in symbols:
                price = float(series[symbol][index] or 0.0)
                if price <= 0:
                    continue
                current_symbol_value = units[symbol] * price
                desired = current_value * basket.weights[symbol]
                if current_symbol_value < desired:
                    gross = desired - current_symbol_value
                    fee = 0.0 if symbol == "CORE" else frontier073.FEE_RATE
                    spend = min(cash, gross * (1 + frontier073.SLIPPAGE_RATE) * (1 + fee))
                    if spend > 0:
                        units[symbol] += spend / ((1 + frontier073.SLIPPAGE_RATE) * (1 + fee) * price)
                        cash -= spend
                        trades += 1
            rebalanced_periods.add(period_key)
        out_dates.append(day)
        values.append(value_at(index))
    return out_dates, values, trades


def row_for(dates: list[Any], series: dict[str, list[float | None]], name: str, weights: dict[str, float], months: set[int], label: str) -> dict[str, Any] | None:
    basket = frontier073.Basket(dict(sorted(weights.items())))
    replay = replay_months(dates, series, basket, months)
    if replay is None:
        return None
    replay_dates, values, trades = replay
    row = frontier073.metric_row(f"{name}:{label}", "calendar_rebalance", replay_dates, values, basket, trades)
    row["basket_name"] = name
    row["months"] = sorted(months)
    return row


def main() -> None:
    dates, series, errors = frontier073.load_series()
    rows: list[dict[str, Any]] = []
    month_sets: list[tuple[str, set[int]]] = []
    month_sets.extend((f"annual_m{month:02d}", {month}) for month in range(1, 13))
    month_sets.extend(
        [
            ("semi_01_07", {1, 7}),
            ("semi_02_08", {2, 8}),
            ("semi_03_09", {3, 9}),
            ("semi_04_10", {4, 10}),
            ("semi_05_11", {5, 11}),
            ("semi_06_12", {6, 12}),
        ]
    )
    for name, weights in BASKETS:
        for label, months in month_sets:
            row = row_for(dates, series, name, weights, months, label)
            if row is not None:
                rows.append(row)
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)
    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "errors": errors,
        "rows": rows,
        "interesting": {
            "top_by_sharpe": rows[:60],
            "annual_ge_12": [row for row in rows if row["full"]["annualized"] >= 0.12][:60],
            "sharpe_ge_16": [row for row in rows if (row["full"]["sharpe"] or 0.0) >= 1.6][:60],
        },
    }
    out_path = HERE / "results.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    for row in rows[:60]:
        full = row["full"]
        post = row["slices"]["post_2020"]
        last10 = row["slices"]["last_10y"]
        print(
            f"{row['name']} | months={row['months']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{(full['sharpe'] or 0):.4f}/{pct(full['annual_volatility'])} | "
            f"post2020 {pct(post['annualized'])}/{(post['sharpe'] or 0):.4f} | "
            f"last10 {pct(last10['annualized'])}/{(last10['sharpe'] or 0):.4f} | trades={row['trades']}"
        )


if __name__ == "__main__":
    main()
