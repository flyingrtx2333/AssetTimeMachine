#!/usr/bin/env python3
"""Sparse seasonal risk budget under 1% fee.

Spike 048 crossed 1.5 Sharpe with a seasonal-tier risk budget, but it traded on
month boundaries and was verified with lower fees. This spike keeps the same
return engine and tests execution structures that fit a 1% fee world:

- scheduled-only seasonal scaling;
- month-boundary sell-only cuts;
- tier changes that never buy until the normal strategy rebalance;
- wider no-trade bands.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
S048_PATH = ROOT / "spikes" / "048-sleeve-league-cash-gate" / "seasonal_tier_verify.py"
S064_PATH = ROOT / "spikes" / "064-low-turnover-daily-defense" / "low_turnover_daily_defense.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


s048 = load_module("seasonal_tier_verify_048_for_065", S048_PATH)
base064 = load_module("low_turnover_daily_defense_064_for_065", S064_PATH)

app = s048.app
t47 = s048.t47
replay = s048.replay
dyn = s048.dyn
s35 = s048.s35
s30 = s048.s30

MONTH_SCALE_048 = dict(s048.MONTH_SCALE)
MONTH_SCALE_WEAK_ONLY = {
    1: 1.00,
    2: 0.40,
    3: 1.00,
    4: 1.00,
    5: 1.00,
    6: 0.40,
    7: 1.00,
    8: 1.00,
    9: 0.40,
    10: 0.40,
    11: 1.00,
    12: 1.00,
}


@dataclass(frozen=True)
class SparseSeasonalSpec:
    name: str
    thesis: str
    month_scale: dict[int, float]
    boundary_mode: str
    rebalance_band: float
    fixed_selector_weight: float | None = None


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def scaled_targets(base_targets: dict[str, float], scale: float) -> dict[str, float]:
    if not base_targets:
        return {}
    return replay.normalize({symbol: weight * scale for symbol, weight in base_targets.items()})


def target_subset(current_targets: dict[str, float], desired_targets: dict[str, float]) -> dict[str, float]:
    """Sell-only target: cap existing target weights by desired weights."""
    out: dict[str, float] = {}
    for symbol in set(current_targets) | set(desired_targets):
        old = current_targets.get(symbol, 0.0)
        desired = desired_targets.get(symbol, 0.0)
        keep = min(old, desired)
        if keep > 0.0001:
            out[symbol] = keep
    return replay.normalize(out)


def run_spec(data: dict[str, Any], spec: SparseSeasonalSpec) -> dict[str, Any]:
    prices_by_symbol = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = data["tradable_symbols"]

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    values: list[float] = []
    trades: list[Any] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    month_scales: list[float] = []
    switches = 0
    base_targets: dict[str, float] = {}
    active_targets: dict[str, float] = {}
    max_target_sum = 0.0
    month_boundary_rebalances = 0
    boundary_sell_only_events = 0
    skipped_boundary_buys = 0
    last_month: int | None = None

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    for index, current_date in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest

        needs_rebalance = False
        can_buy = True
        boundary = last_month is not None and current_date.month != last_month
        signal_index = index - 1

        if index in targets_by_index:
            if signal_index >= 0:
                new_weight = (
                    spec.fixed_selector_weight
                    if spec.fixed_selector_weight is not None
                    else dyn.choose_weight(s048.SELECTOR, satellite_values, defensive_values, values, signal_index, selector_weight)
                )
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
            satellite_target, defensive_target = targets_by_index[index]
            base_targets = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            selector_weights.append(selector_weight)
            needs_rebalance = True

        if boundary:
            if spec.boundary_mode == "full":
                needs_rebalance = True
                month_boundary_rebalances += 1
            elif spec.boundary_mode == "sell_only":
                desired = scaled_targets(base_targets, spec.month_scale[current_date.month])
                sell_only_target = target_subset(active_targets, desired)
                if sell_only_target != active_targets:
                    active_targets = base064.fee_aware_rebalance(
                        index=index,
                        dates=dates,
                        prices_by_symbol=prices_by_symbol,
                        tradable_symbols=tradable_symbols,
                        targets=sell_only_target,
                        cash_box=cash_box,
                        units=units,
                        held=held,
                        trades=trades,
                        band=0.0,
                        buy=False,
                    )
                    boundary_sell_only_events += 1
                else:
                    skipped_boundary_buys += 1
            elif spec.boundary_mode == "none":
                pass
            else:
                raise ValueError(spec.boundary_mode)

        if needs_rebalance:
            scale = spec.month_scale[current_date.month]
            desired_targets = scaled_targets(base_targets, scale)
            if spec.boundary_mode == "scheduled_sell_only" and boundary:
                desired_targets = target_subset(active_targets, desired_targets)
                can_buy = False
            if base064.targets_changed(desired_targets, active_targets):
                active_targets = base064.fee_aware_rebalance(
                    index=index,
                    dates=dates,
                    prices_by_symbol=prices_by_symbol,
                    tradable_symbols=tradable_symbols,
                    targets=desired_targets,
                    cash_box=cash_box,
                    units=units,
                    held=held,
                    trades=trades,
                    band=spec.rebalance_band,
                    buy=can_buy,
                )
            month_scales.append(scale)
            max_target_sum = max(max_target_sum, sum(active_targets.values()))

        last_month = current_date.month
        values.append(portfolio_value(index))

    dates_out = dates
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates_out, values)
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": {
            "boundary_mode": spec.boundary_mode,
            "rebalance_band": spec.rebalance_band,
            "fixed_selector_weight": spec.fixed_selector_weight,
            "month_scale": spec.month_scale,
        },
        "full": {
            "annualized": annualized,
            "max_drawdown": max_dd,
            "annual_volatility": annual_vol,
            "sharpe": sharpe,
            "total": total,
            "trades": len(trades),
        },
        "slices": {
            "post_2020": s048.slice_metrics(dates_out, values, "2020-01-01"),
            "last_10y": s048.slice_metrics(dates_out, values, "2016-06-23"),
            "post_2022": s048.slice_metrics(dates_out, values, "2022-01-01"),
            "post_2024": s048.slice_metrics(dates_out, values, "2024-01-01"),
        },
        "drawdown_window": s048.max_drawdown_window(dates_out, values),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in trades[-10:]],
        "extra": {
            "switches": switches,
            "month_boundary_rebalances": month_boundary_rebalances,
            "boundary_sell_only_events": boundary_sell_only_events,
            "skipped_boundary_buys": skipped_boundary_buys,
            "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else selector_weight,
            "latest_selector_weight": selector_weights[-1] if selector_weights else selector_weight,
            "avg_month_scale": sum(month_scales) / len(month_scales) if month_scales else 1.0,
            "latest_month_scale": month_scales[-1] if month_scales else 1.0,
            "max_target_sum": max_target_sum,
            "symbols": tradable_symbols,
        },
    }


def specs() -> list[SparseSeasonalSpec]:
    out: list[SparseSeasonalSpec] = []
    for band in [0.0, 0.025, 0.05, 0.10]:
        out.append(
            SparseSeasonalSpec(
                name=f"original_full_monthly_048_band{int(band*1000)}",
                thesis="Original 048 seasonal tier, rerun with 1% fee.",
                month_scale=MONTH_SCALE_048,
                boundary_mode="full",
                rebalance_band=band,
            )
        )
        out.append(
            SparseSeasonalSpec(
                name=f"scheduled_only_048_band{int(band*1000)}",
                thesis="Apply 048 month scale only on normal strategy target dates; no month-boundary trades.",
                month_scale=MONTH_SCALE_048,
                boundary_mode="none",
                rebalance_band=band,
            )
        )
        out.append(
            SparseSeasonalSpec(
                name=f"sell_only_boundary_048_band{int(band*1000)}",
                thesis="At month boundaries, only sell to lower seasonal risk; never buy up until normal target dates.",
                month_scale=MONTH_SCALE_048,
                boundary_mode="sell_only",
                rebalance_band=band,
            )
        )
        out.append(
            SparseSeasonalSpec(
                name=f"weak_only_sell_boundary_band{int(band*1000)}",
                thesis="Only weak months cut exposure; month-boundary changes are sell-only.",
                month_scale=MONTH_SCALE_WEAK_ONLY,
                boundary_mode="sell_only",
                rebalance_band=band,
            )
        )
    for weight in [0.25, 0.50, 0.75, 0.95]:
        out.append(
            SparseSeasonalSpec(
                name=f"fixed_selector_{int(weight*100)}_sell_boundary_048",
                thesis="Remove selector churn, keep sparse seasonal sell-only boundary risk control.",
                month_scale=MONTH_SCALE_048,
                boundary_mode="sell_only",
                rebalance_band=0.05,
                fixed_selector_weight=weight,
            )
        )
    return out


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    patched_apps = [app, replay.app, s35.app, s30.app]
    for module_app in patched_apps:
        module_app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        rows = [run_spec(data, spec) for spec in specs()]
    finally:
        for module_app in patched_apps:
            module_app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Sparse seasonal dynamic sleeve tests with 1% fee, 0.05% slippage, no leverage, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | trades | dd window")
    for row in rows[:40]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        extra: dict[str, Any] = row["extra"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{extra['month_boundary_rebalances']}/{extra['boundary_sell_only_events']}/{extra['switches']} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
