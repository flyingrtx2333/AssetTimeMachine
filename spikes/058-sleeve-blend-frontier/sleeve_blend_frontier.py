#!/usr/bin/env python3
"""NAV-level sleeve blend frontier.

This is a screening spike, not product truth. It replays the strongest current
sleeves with their own trade costs, then blends their daily NAV returns to test
whether the sleeves are complementary enough to justify a target-weight-level
implementation.

No leverage and no BTC. External Treasury fund sleeves appear only in the 049
carry candidate and are explicitly marked as a product-data-source caveat.
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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
REPAIR_PATH = ROOT / "spikes" / "053-drawdown-repair-reentry" / "drawdown_repair_reentry.py"
SEASONAL_PATH = ROOT / "spikes" / "056-seasonal-repair-torque" / "seasonal_repair_torque.py"
CARRY_PATH = ROOT / "spikes" / "049-seasonal-alpha-router" / "seasonal_carry_search.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


repair = load_module("drawdown_repair_reentry_053", REPAIR_PATH)
seasonal = load_module("seasonal_repair_torque_056", SEASONAL_PATH)
carry049 = load_module("seasonal_carry_search_049", CARRY_PATH)

app = repair.app
t47 = repair.t47
replay = repair.replay
s35 = repair.s35
s30 = repair.s30


@dataclass(frozen=True)
class SleeveResult:
    name: str
    values: list[float]
    row: dict[str, Any]
    caveat: str


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def repair_spec(top_count: int = 1) -> Any:
    return repair.RepairSpec(
        name=f"repair_053_top{top_count}",
        mode="overlay",
        drawdown_lookback=105,
        drawdown_threshold=0.10,
        rebound_lookback=30,
        rebound_threshold=0.055,
        confirmation_ma=40,
        momentum_lookback=20,
        top_count=top_count,
        overlay_cap=0.35,
        per_asset_cap=0.15,
        require_breadth=True,
        exit_weakness=True,
    )


def seasonal_spec() -> Any:
    return seasonal.TorqueSpec(
        name="seasonal_056_torque_best",
        repair_top_count=1,
        weak_scale=0.65,
        mid_scale=0.70,
        good_scale=1.00,
        scale_mode="whole_target",
        repair_month_mode="all",
        use_phase_lock=True,
    )


def carry_spec() -> Any:
    return carry049.CarryOverlaySpec(
        name="seasonal_049_carry_best",
        thesis="Highest-Sharpe seasonal carry sleeve from spike 049.",
        mode="short_only",
        cap=0.50,
        per_asset_cap=0.35,
        use_only_weak_mid_months=False,
    )


def returns(values: list[float]) -> list[float]:
    out: list[float] = []
    for previous, current in zip(values, values[1:]):
        if previous <= 0 or current <= 0:
            out.append(0.0)
        else:
            out.append(current / previous - 1.0)
    return out


def values_from_returns(weighted_returns: list[float], initial: float = 100_000.0) -> list[float]:
    values = [initial]
    current = initial
    for daily_return in weighted_returns:
        current *= 1.0 + daily_return
        values.append(current)
    return values


def corr(first: list[float], second: list[float]) -> float | None:
    if len(first) != len(second) or len(first) < 3:
        return None
    mean_first = statistics.mean(first)
    mean_second = statistics.mean(second)
    numerator = sum((a - mean_first) * (b - mean_second) for a, b in zip(first, second))
    den_first = math.sqrt(sum((a - mean_first) ** 2 for a in first))
    den_second = math.sqrt(sum((b - mean_second) ** 2 for b in second))
    if den_first <= 0 or den_second <= 0:
        return None
    return numerator / den_first / den_second


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    return repair.slice_metrics(dates, values, start)


def row_for(dates: list[date], name: str, values: list[float], extra: dict[str, Any]) -> dict[str, Any]:
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": name,
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
        "drawdown_window": repair.max_drawdown_window(dates, values),
        "extra": extra,
    }


def static_blend_rows(dates: list[date], sleeves: list[SleeveResult]) -> list[dict[str, Any]]:
    sleeve_returns = {sleeve.name: returns(sleeve.values) for sleeve in sleeves}
    rows: list[dict[str, Any]] = []
    step = 0.05
    count = int(1 / step)
    for a in range(count + 1):
        for b in range(count + 1 - a):
            c = count - a - b
            weights = {
                sleeves[0].name: a * step,
                sleeves[1].name: b * step,
                sleeves[2].name: c * step,
            }
            daily_returns: list[float] = []
            for index in range(len(dates) - 1):
                daily_returns.append(sum(weight * sleeve_returns[name][index] for name, weight in weights.items()))
            values = values_from_returns(daily_returns)
            label = "_".join(f"{name}:{int(weight*100)}" for name, weight in weights.items() if weight > 0)
            rows.append(row_for(dates, f"static_{label}", values, {"weights": weights, "method": "static_daily_nav_rebalanced"}))
    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    return rows


def trailing_stats(series: list[float], end: int, lookback: int) -> tuple[float, float, float] | None:
    start = end - lookback
    if start < 0 or end > len(series):
        return None
    sample = series[start:end]
    if len(sample) < max(20, lookback // 2):
        return None
    avg = statistics.mean(sample)
    vol = statistics.stdev(sample) if len(sample) > 1 else 0.0
    score = avg / vol if vol > 0 else -999
    drawdown = 0.0
    value = 1.0
    peak = 1.0
    for item in sample:
        value *= 1 + item
        peak = max(peak, value)
        drawdown = min(drawdown, value / peak - 1 if peak > 0 else 0.0)
    return score, sum(sample), drawdown


def dynamic_router_rows(dates: list[date], sleeves: list[SleeveResult]) -> list[dict[str, Any]]:
    sleeve_returns = {sleeve.name: returns(sleeve.values) for sleeve in sleeves}
    rows: list[dict[str, Any]] = []
    rebalance_days = [21, 42, 63]
    lookbacks = [63, 126, 189, 252]
    methods = ["sharpe", "return_dd", "return_if_clean"]

    for rebalance_every in rebalance_days:
        for lookback in lookbacks:
            for method in methods:
                current = sleeves[0].name
                switches = 0
                chosen: list[str] = []
                blended_returns: list[float] = []
                for index in range(len(dates) - 1):
                    if index == 0 or index % rebalance_every == 0:
                        scores: list[tuple[float, str]] = []
                        for sleeve in sleeves:
                            stats = trailing_stats(sleeve_returns[sleeve.name], index, lookback)
                            if stats is None:
                                continue
                            trailing_sharpe, trailing_return, trailing_dd = stats
                            if method == "sharpe":
                                score = trailing_sharpe
                            elif method == "return_dd":
                                score = trailing_return + trailing_dd * 0.45
                            elif method == "return_if_clean":
                                score = trailing_return if trailing_dd > -0.045 else trailing_return + trailing_dd
                            else:
                                raise ValueError(method)
                            scores.append((score, sleeve.name))
                        if scores:
                            scores.sort(reverse=True)
                            next_name = scores[0][1]
                            if next_name != current:
                                switches += 1
                            current = next_name
                    chosen.append(current)
                    blended_returns.append(sleeve_returns[current][index])
                values = values_from_returns(blended_returns)
                rows.append(
                    row_for(
                        dates,
                        f"router_{method}_lb{lookback}_rb{rebalance_every}",
                        values,
                        {
                            "method": method,
                            "lookback": lookback,
                            "rebalance_every": rebalance_every,
                            "switches": switches,
                            "latest_sleeve": chosen[-1] if chosen else current,
                            "sleeve_counts": {name: chosen.count(name) for name in sorted(sleeve_returns)},
                        },
                    )
                )
    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    return rows


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    repair.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    seasonal.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    seasonal.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    seasonal.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    seasonal.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    carry049.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    carry049.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    carry049.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    carry049.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        data["raw_public"] = cached_fetch(end_date=None)

        repair_values, repair_extra, repair_trades = repair.simulate(data, repair_spec(1))
        repair_row = repair.row_for(data, repair_spec(1), repair_values, repair_extra, repair_trades)
        seasonal_values, seasonal_extra, seasonal_trades = seasonal.simulate(data, seasonal_spec())
        seasonal_row = seasonal.row_for(data, seasonal_spec(), seasonal_values, seasonal_extra, seasonal_trades)
        carry_values, carry_extra, carry_trades = carry049.simulate(data, carry_spec())
        carry_row = carry049.row_for(data, carry_spec(), carry_values, carry_extra, carry_trades)
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        seasonal.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        seasonal.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        seasonal.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        seasonal.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        carry049.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        carry049.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        carry049.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        carry049.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    dates: list[date] = data["dates"]
    sleeves = [
        SleeveResult("repair_053", repair_values, repair_row, "app-native"),
        SleeveResult("seasonal_056", seasonal_values, seasonal_row, "app-native"),
        SleeveResult("carry_049", carry_values, carry_row, "uses external Treasury fund data"),
    ]

    correlations: dict[str, float | None] = {}
    for i, first in enumerate(sleeves):
        for second in sleeves[i + 1:]:
            correlations[f"{first.name}__{second.name}"] = corr(returns(first.values), returns(second.values))

    static_rows = static_blend_rows(dates, sleeves)
    router_rows = dynamic_router_rows(dates, sleeves)
    rows = sorted(static_rows[:30] + router_rows[:30], key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "NAV-level screening only; target-weight replay required before app use.",
                "sleeves": {sleeve.name: {"row": sleeve.row, "caveat": sleeve.caveat} for sleeve in sleeves},
                "correlations": correlations,
                "top_static": static_rows[:30],
                "top_router": router_rows[:30],
                "top_combined": rows[:40],
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("correlations", correlations)
    print("top combined | ann/dd/sharpe/vol | 2020 ann/sharpe | last10 ann/sharpe | extra")
    for row in rows[:40]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{row['extra']}"
        )


if __name__ == "__main__":
    main()
