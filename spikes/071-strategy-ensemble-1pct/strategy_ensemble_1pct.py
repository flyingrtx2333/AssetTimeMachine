#!/usr/bin/env python3
"""Strategy-level ensemble screen under the current 1% default fee.

This is deliberately not single-strategy parameter tuning.  It asks whether the
already app-equivalent strategy return streams contain enough independent
behavior to support a higher-Sharpe sleeve ensemble without leverage.

The curves blended here are already fee-adjusted by the app-equivalent engine.
Any attractive result is still an upper-bound screen: a product candidate must
later be replayed as combined target weights in the app engine.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import itertools
import json
import math
from pathlib import Path
import sys
from typing import Any, Literal

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402


STRATEGIES = [
    "coreGoldSatelliteHeatCappedMomentum",
    "coreGoldSatelliteGoldHandoffMomentum",
    "coreGoldSatelliteEquityBreadthMomentum",
    "coreGoldSatelliteOneWayVolManagedMomentum",
]


@dataclass(frozen=True)
class StrategySeries:
    name: str
    dates: list[date]
    values: list[float]
    returns: list[float]


@dataclass(frozen=True)
class SelectorSpec:
    name: str
    score: Literal["return", "sharpe", "calmar", "stability"]
    lookback: int
    rebalance: int
    top_count: int
    weak_to_cash: bool
    inverse_vol_weight: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def daily_returns(values: list[float]) -> list[float]:
    rows = [0.0]
    for index in range(1, len(values)):
        previous = values[index - 1]
        rows.append(values[index] / previous - 1 if previous > 0 else 0.0)
    return rows


def max_drawdown_window(dates: list[date], values: list[float]) -> dict[str, Any]:
    peak = values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for index, value in enumerate(values):
        if value > peak:
            peak = value
            peak_i = index
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = index
    return {
        "peak_date": dates[worst_peak].isoformat(),
        "trough_date": dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    start_index = next((index for index, day in enumerate(dates) if day >= start_date), None)
    if start_index is None or start_index >= len(dates) - 2:
        return {
            "annualized": None,
            "max_drawdown": None,
            "annual_volatility": None,
            "sharpe": None,
            "total": None,
        }
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates[start_index:], values[start_index:])
    return {
        "annualized": annualized,
        "max_drawdown": max_dd,
        "annual_volatility": annual_vol,
        "sharpe": sharpe,
        "total": total,
    }


def summarize(name: str, dates: list[date], values: list[float], kind: str, details: dict[str, Any]) -> dict[str, Any]:
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": name,
        "kind": kind,
        "details": details,
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


def align_strategy_series(results: list[app.BacktestResult]) -> tuple[list[date], dict[str, StrategySeries]]:
    common = set(results[0].dates)
    for result in results[1:]:
        common &= set(result.dates)
    dates = sorted(common)
    by_name: dict[str, StrategySeries] = {}
    for result in results:
        value_by_date = dict(zip(result.dates, result.values))
        values = [value_by_date[day] for day in dates]
        by_name[result.strategy] = StrategySeries(result.strategy, dates, values, daily_returns(values))
    return dates, by_name


def cash_returns(dates: list[date]) -> list[float]:
    return [0.0] + [app.cash_daily_return(day) for day in dates[:-1]]


def blended_values(dates: list[date], series: dict[str, StrategySeries], cash: list[float], weights: dict[str, float]) -> list[float]:
    value = 100_000.0
    values = [value]
    invested = sum(max(weight, 0.0) for weight in weights.values())
    cash_weight = max(0.0, 1.0 - invested)
    for index in range(1, len(dates)):
        day_return = cash_weight * cash[index]
        for name, weight in weights.items():
            day_return += max(weight, 0.0) * series[name].returns[index]
        value *= 1 + day_return
        values.append(value)
    return values


def compositions(total: int, parts: int, minimum: int = 1) -> list[list[int]]:
    if parts == 1:
        return [[total]] if total >= minimum else []
    rows: list[list[int]] = []
    max_head = total - minimum * (parts - 1)
    for head in range(minimum, max_head + 1):
        for tail in compositions(total - head, parts - 1, minimum):
            rows.append([head] + tail)
    return rows


def static_weight_grid(names: list[str], max_cash_units: int = 4, divisor: int = 20) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    min_units = divisor - max_cash_units
    for combo_size in range(1, min(4, len(names)) + 1):
        for combo in itertools.combinations(names, combo_size):
            for total_units in range(min_units, divisor + 1):
                for units in compositions(total_units, combo_size):
                    rows.append({name: unit / divisor for name, unit in zip(combo, units)})
    return rows


def trailing_stats(returns: list[float], index: int, lookback: int) -> tuple[float, float, float]:
    start = max(1, index - lookback + 1)
    window = returns[start : index + 1]
    if len(window) < max(20, lookback // 4):
        return 0.0, 9.0, 0.0
    compounded = 1.0
    peak = 1.0
    current = 1.0
    worst_dd = 0.0
    for item in window:
        current *= 1 + item
        compounded *= 1 + item
        peak = max(peak, current)
        worst_dd = min(worst_dd, current / peak - 1)
    mean = sum(window) / len(window)
    variance = sum((item - mean) ** 2 for item in window) / max(len(window) - 1, 1)
    annual_vol = math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)
    return compounded - 1, annual_vol, worst_dd


def score_series(returns: list[float], index: int, spec: SelectorSpec) -> tuple[float, float, float, float]:
    total_return, annual_vol, drawdown = trailing_stats(returns, index, spec.lookback)
    vol = max(annual_vol, 0.01)
    if spec.score == "return":
        score = total_return
    elif spec.score == "sharpe":
        score = total_return / vol
    elif spec.score == "calmar":
        score = total_return / max(abs(drawdown), 0.03)
    else:
        score = total_return / vol - max(abs(drawdown) - 0.04, 0.0) * 2.0
    return score, total_return, annual_vol, drawdown


def dynamic_selector_values(dates: list[date], series: dict[str, StrategySeries], cash: list[float], spec: SelectorSpec) -> tuple[list[float], list[dict[str, float]]]:
    value = 100_000.0
    values = [value]
    weights: dict[str, float] = {}
    trace = [dict(weights)]
    names = list(series)
    for index in range(1, len(dates)):
        if index == 1 or (index - 1) % max(spec.rebalance, 1) == 0:
            scored = []
            for name in names:
                score, total_return, annual_vol, drawdown = score_series(series[name].returns, index - 1, spec)
                scored.append((score, total_return, annual_vol, drawdown, name))
            scored.sort(key=lambda row: (-row[0], row[4]))
            selected = [row for row in scored[: max(spec.top_count, 1)] if not spec.weak_to_cash or row[1] > 0]
            if selected:
                if spec.inverse_vol_weight:
                    raw = [(row[4], 1.0 / max(row[2], 0.04)) for row in selected]
                    total = sum(weight for _, weight in raw)
                    weights = {name: weight / total for name, weight in raw if total > 0}
                else:
                    equal = 1.0 / len(selected)
                    weights = {row[4]: equal for row in selected}
            else:
                weights = {}

        invested = sum(weights.values())
        day_return = max(0.0, 1.0 - invested) * cash[index]
        for name, weight in weights.items():
            day_return += weight * series[name].returns[index]
        value *= 1 + day_return
        values.append(value)
        trace.append(dict(weights))
    return values, trace


def turnover_events(weight_trace: list[dict[str, float]]) -> int:
    changes = 0
    previous = weight_trace[0] if weight_trace else {}
    for weights in weight_trace[1:]:
        if weights != previous:
            changes += 1
            previous = weights
    return changes


def selector_specs() -> list[SelectorSpec]:
    specs: list[SelectorSpec] = []
    for score in ["return", "sharpe", "calmar", "stability"]:
        for lookback in [63, 126, 252, 378]:
            for rebalance in [21, 42, 63]:
                for top_count in [1, 2]:
                    specs.append(SelectorSpec(f"{score}_lb{lookback}_rb{rebalance}_top{top_count}", score, lookback, rebalance, top_count, True, False))
                    specs.append(SelectorSpec(f"{score}_lb{lookback}_rb{rebalance}_top{top_count}_ivol", score, lookback, rebalance, top_count, True, True))
    return specs


def main() -> None:
    raw_results = [app.run_strategy(name, fee_rate_pct=1.0, slippage_rate_pct=0.05, end_date="2026-06-23") for name in STRATEGIES]
    dates, series = align_strategy_series(raw_results)
    cash = cash_returns(dates)

    rows: list[dict[str, Any]] = []
    for result in raw_results:
        value_by_date = dict(zip(result.dates, result.values))
        values = [value_by_date[day] for day in dates]
        rows.append(summarize(result.strategy, dates, values, "single", {"trades": len(result.trades)}))

    for weights in static_weight_grid(list(series), max_cash_units=4, divisor=20):
        name = "+".join(f"{key}:{value:.2f}" for key, value in weights.items() if value > 0)
        rows.append(summarize(name, dates, blended_values(dates, series, cash, weights), "static", {"weights": weights}))

    for spec in selector_specs():
        values, trace = dynamic_selector_values(dates, series, cash, spec)
        rows.append(
            summarize(
                spec.name,
                dates,
                values,
                "selector",
                {
                    "score": spec.score,
                    "lookback": spec.lookback,
                    "rebalance": spec.rebalance,
                    "top_count": spec.top_count,
                    "weak_to_cash": spec.weak_to_cash,
                    "inverse_vol_weight": spec.inverse_vol_weight,
                    "turnover_events": turnover_events(trace),
                },
            )
        )

    rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)
    interesting = {
        "top_by_sharpe": rows[:40],
        "annual_ge_10": [row for row in rows if row["full"]["annualized"] >= 0.10][:30],
        "annual_ge_12": [row for row in rows if row["full"]["annualized"] >= 0.12][:30],
        "selectors": [row for row in rows if row["kind"] == "selector"][:30],
    }
    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "fee_rate_pct": 1.0,
        "slippage_rate_pct": 0.05,
        "coverage": {"start": dates[0].isoformat(), "end": dates[-1].isoformat(), "points": len(dates)},
        "rows": rows,
        "interesting": interesting,
    }
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("name | kind | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | details")
    for row in rows[:50]:
        full = row["full"]
        slices = row["slices"]
        details = row["details"]
        print(
            f"{row['name']} | {row['kind']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{(full['sharpe'] or 0):.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{details}"
        )


if __name__ == "__main__":
    main()
