#!/usr/bin/env python3
"""Asset phase-lock plus portfolio risk-budget search.

This spike starts from the current 053 repair-overlay candidate, then adds a
new state-machine layer: an asset that had a strong run and then rolls over is
temporarily treated as its own risk source, so its target weight is clipped and
the freed budget stays in cash.

No leverage, no shorting, no BTC. Fees, slippage, and cash yield are included.
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
REPAIR_PATH = ROOT / "spikes" / "053-drawdown-repair-reentry" / "drawdown_repair_reentry.py"

spec_module = importlib.util.spec_from_file_location("drawdown_repair_reentry_053", REPAIR_PATH)
if spec_module is None or spec_module.loader is None:
    raise RuntimeError(f"failed to load {REPAIR_PATH}")
repair = importlib.util.module_from_spec(spec_module)
sys.modules["drawdown_repair_reentry_053"] = repair
spec_module.loader.exec_module(repair)

app = repair.app
dyn = repair.dyn
replay = repair.replay
t47 = repair.t47
s35 = repair.s35
s30 = repair.s30

RISK_ASSETS = {
    "gold_cny",
    "nasdaq",
    "sp500",
    "dowjones",
    "csi300",
    "shanghai_composite",
    "shenzhen_component",
    "chinext",
}
CHINA_ASSETS = {"csi300", "shanghai_composite", "shenzhen_component", "chinext"}


@dataclass(frozen=True)
class PhaseLockSpec:
    name: str
    repair_top_count: int
    repair_overlay_cap: float
    repair_per_asset_cap: float
    lock_universe: str
    hot_lookback: int
    hot_threshold: float
    crack_lookback: int
    crack_threshold: float
    rollover_drawdown: float
    lock_scale: float
    max_lock_days: int
    portfolio_dd_limit: float
    stress_budget: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def allowed_symbols(spec: PhaseLockSpec) -> set[str]:
    if spec.lock_universe == "gold":
        return {"gold_cny"}
    if spec.lock_universe == "gold_china":
        return {"gold_cny", *CHINA_ASSETS}
    return set(RISK_ASSETS)


def simple_return(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0:
        return None
    previous = values[index - lookback]
    current = values[index]
    if previous <= 0 or current <= 0:
        return None
    return current / previous - 1


def rolling_high_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0:
        return None
    window = [item for item in values[index - lookback + 1:index + 1] if item > 0]
    if not window:
        return None
    high = max(window)
    return values[index] / high - 1 if high > 0 else None


def portfolio_drawdown(values: list[float], lookback: int) -> float | None:
    if len(values) < lookback + 1:
        return None
    window = values[-lookback:]
    high = max(window)
    current = window[-1]
    return current / high - 1 if high > 0 else None


def should_lock_asset(
    symbol: str,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    index: int,
    spec: PhaseLockSpec,
) -> bool:
    if symbol not in allowed_symbols(spec):
        return False
    prices = prices_by_symbol[symbol]
    hot_return = simple_return(prices, index, spec.hot_lookback)
    crack_return = simple_return(prices, index, spec.crack_lookback)
    drawdown = rolling_high_drawdown(prices, index, spec.hot_lookback)
    ma20 = indicators[symbol][20][index]
    ma40 = indicators[symbol][40][index]
    ma120 = indicators[symbol][120][index]
    if None in (hot_return, crack_return, drawdown, ma20, ma40, ma120):
        return False
    assert hot_return is not None and crack_return is not None and drawdown is not None
    assert ma20 is not None and ma40 is not None and ma120 is not None

    hot = hot_return >= spec.hot_threshold or prices[index] > ma120 * (1 + spec.hot_threshold * 0.45)
    rollover = crack_return <= spec.crack_threshold or drawdown <= -spec.rollover_drawdown
    broken = prices[index] < ma20 or prices[index] < ma40
    return hot and rollover and broken


def recovered_asset(
    symbol: str,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    index: int,
    lock_start: int,
    spec: PhaseLockSpec,
) -> bool:
    prices = prices_by_symbol[symbol]
    ma40 = indicators[symbol][40][index]
    momentum20 = simple_return(prices, index, 20)
    if index - lock_start >= spec.max_lock_days and momentum20 is not None and momentum20 > 0:
        return True
    if ma40 is None or momentum20 is None:
        return False
    return prices[index] > ma40 and momentum20 > 0.025


def update_locks(
    *,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    tradable_symbols: list[str],
    signal_index: int,
    spec: PhaseLockSpec,
    locked: dict[str, int],
) -> None:
    if signal_index < 0:
        return
    for symbol in tradable_symbols:
        if symbol not in RISK_ASSETS or symbol not in prices_by_symbol:
            continue
        if symbol in locked:
            if recovered_asset(symbol, prices_by_symbol, indicators, signal_index, locked[symbol], spec):
                del locked[symbol]
            continue
        if should_lock_asset(symbol, prices_by_symbol, indicators, signal_index, spec):
            locked[symbol] = signal_index


def apply_phase_locks(targets: dict[str, float], locked: dict[str, int], spec: PhaseLockSpec) -> dict[str, float]:
    if not locked:
        return repair.normalize(targets)
    clipped: dict[str, float] = {}
    for symbol, weight in targets.items():
        if symbol in locked:
            clipped[symbol] = max(0.0, weight * spec.lock_scale)
        else:
            clipped[symbol] = max(0.0, weight)
    return repair.normalize(clipped)


def apply_portfolio_budget(targets: dict[str, float], values: list[float], spec: PhaseLockSpec) -> dict[str, float]:
    if spec.portfolio_dd_limit <= 0 or spec.stress_budget >= 0.999:
        return targets
    drawdown = portfolio_drawdown(values, 63)
    if drawdown is None or drawdown > -spec.portfolio_dd_limit:
        return targets
    return repair.normalize({symbol: weight * spec.stress_budget for symbol, weight in targets.items()})


def repair_spec(spec: PhaseLockSpec) -> Any:
    return repair.RepairSpec(
        name=f"repair_top{spec.repair_top_count}_cap{int(spec.repair_overlay_cap*100)}",
        mode="overlay",
        drawdown_lookback=105,
        drawdown_threshold=0.10,
        rebound_lookback=30,
        rebound_threshold=0.055,
        confirmation_ma=40,
        momentum_lookback=20,
        top_count=spec.repair_top_count,
        overlay_cap=spec.repair_overlay_cap,
        per_asset_cap=spec.repair_per_asset_cap,
        require_breadth=True,
        exit_weakness=True,
    )


def targets_changed(first: dict[str, float], second: dict[str, float], tolerance: float = 0.0005) -> bool:
    symbols = set(first) | set(second)
    return any(abs(first.get(symbol, 0.0) - second.get(symbol, 0.0)) > tolerance for symbol in symbols)


def simulate(data: dict[str, Any], spec: PhaseLockSpec) -> tuple[list[float], dict[str, Any], list[Any]]:
    prices_by_symbol: dict[str, list[float]] = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = data["tradable_symbols"]
    indicators = repair.build_indicators(prices_by_symbol)
    phase_repair_spec = repair_spec(spec)

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    values: list[float] = []
    trades: list[Any] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    switches = 0
    repair_hits = 0
    lock_days = 0
    lock_events = 0
    max_locked_count = 0
    locked: dict[str, int] = {}
    active_targets: dict[str, float] = {}
    base_targets: dict[str, float] = {}
    repair_overlay: dict[str, float] = {}
    max_target_sum = 0.0

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    for index, _current_date in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest

        needs_rebalance = False
        signal_index = index - 1
        previous_lock_count = len(locked)

        if index in targets_by_index:
            if signal_index >= 0:
                new_weight = dyn.choose_weight(
                    repair.BASE_SELECTOR,
                    satellite_values,
                    defensive_values,
                    values,
                    signal_index,
                    selector_weight,
                )
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
                update_locks(
                    prices_by_symbol=prices_by_symbol,
                    indicators=indicators,
                    tradable_symbols=tradable_symbols,
                    signal_index=signal_index,
                    spec=spec,
                    locked=locked,
                )
            satellite_target, defensive_target = targets_by_index[index]
            base_targets = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            selector_weights.append(selector_weight)
            needs_rebalance = True

        if index == 0 or index % 21 == 0:
            budget = min(phase_repair_spec.overlay_cap, max(0.0, 1.0 - repair.total_weight(base_targets)))
            active_repair_symbols = set(repair_overlay)
            repair_overlay = repair.repair_targets(
                spec=phase_repair_spec,
                prices_by_symbol=prices_by_symbol,
                indicators=indicators,
                tradable_symbols=tradable_symbols,
                signal_index=signal_index,
                budget=budget,
                active_repair_symbols=active_repair_symbols,
            )
            if repair_overlay:
                repair_hits += 1
            needs_rebalance = True

        if len(locked) > previous_lock_count:
            lock_events += len(locked) - previous_lock_count
        if locked:
            lock_days += 1
            max_locked_count = max(max_locked_count, len(locked))

        if needs_rebalance:
            targets = dict(base_targets)
            for symbol, weight in repair_overlay.items():
                targets[symbol] = targets.get(symbol, 0.0) + weight
            targets = apply_phase_locks(targets, locked, spec)
            targets = apply_portfolio_budget(targets, values, spec)
            max_target_sum = max(max_target_sum, repair.total_weight(targets))
            if targets_changed(targets, active_targets):
                active_targets = repair.rebalance_portfolio(
                    index=index,
                    dates=dates,
                    prices_by_symbol=prices_by_symbol,
                    tradable_symbols=tradable_symbols,
                    targets=targets,
                    cash_box=cash_box,
                    units=units,
                    held=held,
                    trades=trades,
                )

        values.append(portfolio_value(index))

    extra = {
        "switches": switches,
        "repair_hits": repair_hits,
        "lock_events": lock_events,
        "lock_days": lock_days,
        "max_locked_count": max_locked_count,
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else None,
        "latest_selector_weight": selector_weights[-1] if selector_weights else None,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
    }
    return values, extra, trades


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    return repair.slice_metrics(dates, values, start)


def row_for(data: dict[str, Any], spec: PhaseLockSpec, values: list[float], extra: dict[str, Any], trades: list[Any]) -> dict[str, Any]:
    dates: list[date] = data["dates"]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
        "spec": spec.__dict__,
        "full": {
            "annualized": annualized,
            "max_drawdown": max_dd,
            "annual_volatility": annual_vol,
            "sharpe": sharpe,
            "total": total,
            "trades": len(trades),
        },
        "slices": {
            "post_2020": slice_metrics(dates, values, "2020-01-01"),
            "last_10y": slice_metrics(dates, values, "2016-06-23"),
            "post_2022": slice_metrics(dates, values, "2022-01-01"),
            "post_2024": slice_metrics(dates, values, "2024-01-01"),
        },
        "drawdown_window": repair.max_drawdown_window(dates, values),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in trades[-10:]],
        "extra": extra,
    }


def baseline_rows(data: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for top_count, overlay_cap, per_asset_cap in [(1, 0.35, 0.15), (2, 0.35, 0.15)]:
        spec = PhaseLockSpec(
            name=f"baseline_053_repair_top{top_count}",
            repair_top_count=top_count,
            repair_overlay_cap=overlay_cap,
            repair_per_asset_cap=per_asset_cap,
            lock_universe="none",
            hot_lookback=126,
            hot_threshold=99,
            crack_lookback=20,
            crack_threshold=-99,
            rollover_drawdown=99,
            lock_scale=1,
            max_lock_days=1,
            portfolio_dd_limit=0,
            stress_budget=1,
        )
        values, extra, trades = repair.simulate(data, repair_spec(spec))
        rows.append(row_for(data, spec, values, extra, trades))
    return rows


def specs() -> list[PhaseLockSpec]:
    out: list[PhaseLockSpec] = []
    lock_shapes = [
        ("fast", 84, 0.16, 15, -0.015, 0.06),
        ("middle", 126, 0.22, 20, -0.020, 0.08),
        ("slow", 189, 0.32, 30, -0.030, 0.10),
    ]
    portfolio_modes = [
        ("no_pf", 0.0, 1.0),
        ("pf4_b75", 0.04, 0.75),
        ("pf6_b85", 0.06, 0.85),
    ]
    for repair_top_count, overlay_cap, per_asset_cap in [(1, 0.35, 0.15), (2, 0.35, 0.15)]:
        for universe in ["gold", "gold_china", "all"]:
            for shape_name, hot_lb, hot_threshold, crack_lb, crack_threshold, rollover_dd in lock_shapes:
                for lock_scale in [0.25, 0.45, 0.65]:
                    for max_lock_days in [63, 126, 252]:
                        for pf_name, pf_dd, stress_budget in portfolio_modes:
                            out.append(
                                PhaseLockSpec(
                                    name=(
                                        f"phase_{universe}_{shape_name}_scale{int(lock_scale*100)}_"
                                        f"max{max_lock_days}_{pf_name}_repair{repair_top_count}"
                                    ),
                                    repair_top_count=repair_top_count,
                                    repair_overlay_cap=overlay_cap,
                                    repair_per_asset_cap=per_asset_cap,
                                    lock_universe=universe,
                                    hot_lookback=hot_lb,
                                    hot_threshold=hot_threshold,
                                    crack_lookback=crack_lb,
                                    crack_threshold=crack_threshold,
                                    rollover_drawdown=rollover_dd,
                                    lock_scale=lock_scale,
                                    max_lock_days=max_lock_days,
                                    portfolio_dd_limit=pf_dd,
                                    stress_budget=stress_budget,
                                )
                            )
    return out


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
    try:
        data = t47.precompute_targets()
        rows = baseline_rows(data)
        for spec in specs():
            values, extra, trades = simulate(data, spec)
            rows.append(row_for(data, spec, values, extra, trades))
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        repair.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "053 repair overlay plus asset phase-lock/risk-budget state machine. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | locks | target | trades | dd window")
    for row in rows[:80]:
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
            f"{extra.get('lock_events', 0)}/{extra.get('lock_days', 0)}/{extra.get('max_locked_count', 0)} | "
            f"{extra.get('max_target_sum', 0):.3f} | {full['trades']} | "
            f"{ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
