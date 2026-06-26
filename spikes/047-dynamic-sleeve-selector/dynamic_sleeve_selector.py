#!/usr/bin/env python3
"""Dynamic sleeve selector between high-return and defensive engines.

No leverage, no shorting, no BTC. This is a NAV-level screen: it combines two
already fee-adjusted strategy curves using only information available up to the
previous session. Any passing candidate needs target-weight replay before app
promotion.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import statistics
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402

S44_PATH = ROOT / "spikes" / "044-high-return-defensive-ensemble" / "high_return_defensive_ensemble.py"
SPEC44 = importlib.util.spec_from_file_location("high_return_defensive_ensemble_base", S44_PATH)
if SPEC44 is None or SPEC44.loader is None:
    raise RuntimeError(f"failed to load {S44_PATH}")
s44 = importlib.util.module_from_spec(SPEC44)
sys.modules["high_return_defensive_ensemble_base"] = s44
SPEC44.loader.exec_module(s44)


@dataclass(frozen=True)
class SelectorSpec:
    name: str
    thesis: str
    mode: str
    lookback: int
    satellite_high: float
    satellite_low: float
    ret_margin: float
    dd_limit: float
    portfolio_dd_limit: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def common_series(*results: app.BacktestResult) -> tuple[list[date], list[list[float]]]:
    maps = [{day: value for day, value in zip(result.dates, result.values)} for result in results]
    dates = [day for day in results[0].dates if all(day in item for item in maps)]
    return dates, [[item[day] for day in dates] for item in maps]


def trailing_return(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def trailing_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0:
        return None
    window = values[index - lookback + 1:index + 1]
    peak = max(window)
    return values[index] / peak - 1 if peak > 0 else None


def trailing_vol(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] <= 0 or values[cursor] <= 0:
            return None
        returns.append(values[cursor] / values[cursor - 1] - 1)
    if len(returns) < 20:
        return None
    return statistics.stdev(returns) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def clamp(value: float, low: float, high: float) -> float:
    return min(max(value, low), high)


def choose_weight(
    spec: SelectorSpec,
    satellite: list[float],
    defensive: list[float],
    strategy_values: list[float],
    signal_index: int,
    previous_weight: float,
) -> float:
    sat_ret = trailing_return(satellite, signal_index, spec.lookback)
    def_ret = trailing_return(defensive, signal_index, spec.lookback)
    sat_dd = trailing_drawdown(satellite, signal_index, max(60, spec.lookback // 2))
    pf_dd = trailing_drawdown(strategy_values, len(strategy_values) - 1, max(60, spec.lookback // 2)) if len(strategy_values) > 1 else 0.0
    sat_vol = trailing_vol(satellite, signal_index, max(60, spec.lookback // 2))
    def_vol = trailing_vol(defensive, signal_index, max(60, spec.lookback // 2))

    if None in (sat_ret, def_ret, sat_dd):
        return previous_weight
    assert sat_ret is not None and def_ret is not None and sat_dd is not None
    pf_dd = pf_dd or 0.0

    if spec.mode == "return_selector":
        if pf_dd < -spec.portfolio_dd_limit or sat_dd < -spec.dd_limit:
            return spec.satellite_low
        return spec.satellite_high if sat_ret > def_ret + spec.ret_margin else spec.satellite_low

    if spec.mode == "hysteresis_selector":
        if pf_dd < -spec.portfolio_dd_limit or sat_dd < -spec.dd_limit:
            return spec.satellite_low
        if previous_weight >= (spec.satellite_high + spec.satellite_low) / 2:
            return spec.satellite_low if sat_ret < def_ret - spec.ret_margin else spec.satellite_high
        return spec.satellite_high if sat_ret > def_ret + spec.ret_margin else spec.satellite_low

    if spec.mode == "drawdown_guard":
        if pf_dd < -spec.portfolio_dd_limit or sat_dd < -spec.dd_limit:
            return spec.satellite_low
        return spec.satellite_high

    if spec.mode == "vol_balanced":
        if sat_vol is None or def_vol is None or sat_vol <= 0 or def_vol <= 0:
            return previous_weight
        inv_sat = 1.0 / sat_vol
        inv_def = 1.0 / def_vol
        base_weight = inv_sat / (inv_sat + inv_def)
        if sat_ret < def_ret - spec.ret_margin or sat_dd < -spec.dd_limit:
            base_weight *= 0.65
        elif sat_ret > def_ret + spec.ret_margin:
            base_weight = min(spec.satellite_high, base_weight * 1.35)
        return clamp(base_weight, spec.satellite_low, spec.satellite_high)

    if spec.mode == "momentum_gradient":
        spread = sat_ret - def_ret - spec.ret_margin
        midpoint = (spec.satellite_high + spec.satellite_low) / 2
        span = (spec.satellite_high - spec.satellite_low) / 2
        score = math.tanh(spread * 8.0)
        weight = midpoint + span * score
        if pf_dd < -spec.portfolio_dd_limit or sat_dd < -spec.dd_limit:
            weight = min(weight, spec.satellite_low + 0.10)
        return clamp(weight, spec.satellite_low, spec.satellite_high)

    raise ValueError(spec.mode)


def run_selector(
    spec: SelectorSpec,
    dates: list[date],
    satellite: list[float],
    defensive: list[float],
    rebalance_sessions: int = 21,
) -> tuple[list[float], dict[str, Any]]:
    values = [100_000.0]
    weight = 0.80
    weights = [weight]
    switches = 0
    for index in range(1, len(dates)):
        if index > 1 and index % rebalance_sessions == 0:
            signal_index = index - 1
            new_weight = choose_weight(spec, satellite, defensive, values, signal_index, weight)
            if abs(new_weight - weight) > 0.05:
                switches += 1
            weight = new_weight
        sat_ret = satellite[index] / satellite[index - 1] - 1
        def_ret = defensive[index] / defensive[index - 1] - 1
        values.append(values[-1] * (1 + weight * sat_ret + (1.0 - weight) * def_ret))
        weights.append(weight)
    return values, {
        "switches": switches,
        "avg_satellite_weight": sum(weights) / len(weights),
        "latest_satellite_weight": weights[-1],
    }


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


def row_for(name: str, dates: list[date], values: list[float], spec: SelectorSpec | None, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": name,
        "thesis": spec.thesis if spec else "Reference curve.",
        "spec": None if spec is None else spec.__dict__,
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
        "extra": extra or {},
    }


def specs() -> list[SelectorSpec]:
    out: list[SelectorSpec] = []
    families = [
        ("return_selector", "Switch to high-return satellite only when its trailing return beats defensive engine."),
        ("hysteresis_selector", "Use hysteresis so the sleeve does not flip on tiny return spreads."),
        ("drawdown_guard", "Default to satellite but fall back to defensive sleeve after satellite or portfolio drawdown."),
        ("vol_balanced", "Dynamic inverse-vol sleeve with return and drawdown permission layer."),
        ("momentum_gradient", "Smoothly vary satellite weight from the return spread instead of hard switching."),
    ]
    for mode, thesis in families:
        for lookback in [63, 126, 189, 252]:
            for high, low in [(0.90, 0.35), (0.85, 0.45), (0.80, 0.55)]:
                for ret_margin in [0.00, 0.015, 0.03]:
                    for dd_limit, pf_limit in [(0.045, 0.035), (0.065, 0.045), (0.085, 0.060)]:
                        name = f"{mode}_lb{lookback}_h{int(high*100)}_l{int(low*100)}_m{int(ret_margin*1000)}_d{int(dd_limit*1000)}"
                        out.append(SelectorSpec(name, thesis, mode, lookback, high, low, ret_margin, dd_limit, pf_limit))
    return out


def main() -> None:
    satellite_result = s44.run_confirmed_satellite()
    defensive_result = s44.run_profit_lock()
    dates, series = common_series(satellite_result, defensive_result)
    satellite, defensive = series

    rows: list[dict[str, Any]] = [
        row_for("confirmed_satellite_best", dates, satellite, None, {"satellite_weight": 1.0}),
        row_for("profit_lock_best", dates, defensive, None, {"satellite_weight": 0.0}),
    ]
    for weight in [0.7, 0.75, 0.8, 0.85, 0.9]:
        values = [weight * sat + (1.0 - weight) * defensive[i] for i, sat in enumerate(satellite)]
        rows.append(row_for(f"static_blend_{int(weight * 100)}", dates, values, None, {"satellite_weight": weight}))

    for spec in specs():
        values, extra = run_selector(spec, dates, satellite, defensive)
        rows.append(row_for(spec.name, dates, values, spec, extra))

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "NAV-level screen only; target-weight replay required before app use.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | dd window")
    for row in rows[:40]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        extra = row["extra"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{extra} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
