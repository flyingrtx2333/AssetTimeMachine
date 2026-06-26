#!/usr/bin/env python3
"""Target-volatility budget on top of the 053 repair-overlay engine.

The new logic here is portfolio construction rather than asset timing: build
the candidate target portfolio first, estimate its recent realized volatility,
and clip total exposure only when the target portfolio is too hot.

No leverage, no shorting, no BTC. Fees, slippage, and cash yield are included.
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
PHASE_PATH = ROOT / "spikes" / "055-phase-lock-risk-budget" / "phase_lock_risk_budget.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


repair = load_module("drawdown_repair_reentry_053", REPAIR_PATH)
phase = load_module("phase_lock_risk_budget_055", PHASE_PATH)

app = repair.app
dyn = repair.dyn
replay = repair.replay
t47 = repair.t47
s35 = repair.s35
s30 = repair.s30


@dataclass(frozen=True)
class VolSpec:
    name: str
    repair_top_count: int
    lookback: int
    target_vol: float
    floor_scale: float
    shock_scale: float
    use_phase_lock: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def make_repair_spec(spec: VolSpec) -> Any:
    return repair.RepairSpec(
        name=f"vol_repair_top{spec.repair_top_count}",
        mode="overlay",
        drawdown_lookback=105,
        drawdown_threshold=0.10,
        rebound_lookback=30,
        rebound_threshold=0.055,
        confirmation_ma=40,
        momentum_lookback=20,
        top_count=spec.repair_top_count,
        overlay_cap=0.35,
        per_asset_cap=0.15,
        require_breadth=True,
        exit_weakness=True,
    )


def make_phase_spec(enabled: bool, repair_top_count: int) -> Any:
    return phase.PhaseLockSpec(
        name="gold_phase_middle_scale25" if enabled else "phase_off",
        repair_top_count=repair_top_count,
        repair_overlay_cap=0.35,
        repair_per_asset_cap=0.15,
        lock_universe="gold" if enabled else "none",
        hot_lookback=126,
        hot_threshold=0.22,
        crack_lookback=20,
        crack_threshold=-0.020,
        rollover_drawdown=0.08,
        lock_scale=0.25 if enabled else 1.0,
        max_lock_days=126,
        portfolio_dd_limit=0.0,
        stress_budget=1.0,
    )


def target_volatility(
    prices_by_symbol: dict[str, list[float]],
    targets: dict[str, float],
    signal_index: int,
    lookback: int,
) -> float | None:
    if signal_index - lookback + 1 < 1 or not targets:
        return None
    returns: list[float] = []
    for index in range(signal_index - lookback + 1, signal_index + 1):
        basket_return = 0.0
        valid = True
        for symbol, weight in targets.items():
            prices = prices_by_symbol.get(symbol)
            if not prices or index <= 0 or index >= len(prices):
                valid = False
                break
            previous = prices[index - 1]
            current = prices[index]
            if previous <= 0 or current <= 0:
                valid = False
                break
            basket_return += weight * (current / previous - 1.0)
        if valid:
            returns.append(basket_return)
    if len(returns) < max(20, lookback // 2):
        return None
    return statistics.stdev(returns) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def recent_target_shock(
    prices_by_symbol: dict[str, list[float]],
    targets: dict[str, float],
    signal_index: int,
) -> float | None:
    if signal_index - 5 < 0 or not targets:
        return None
    value = 1.0
    for index in range(signal_index - 4, signal_index + 1):
        daily_return = 0.0
        valid = True
        for symbol, weight in targets.items():
            prices = prices_by_symbol.get(symbol)
            if not prices or index <= 0 or index >= len(prices):
                valid = False
                break
            previous = prices[index - 1]
            current = prices[index]
            if previous <= 0 or current <= 0:
                valid = False
                break
            daily_return += weight * (current / previous - 1.0)
        if not valid:
            return None
        value *= 1 + daily_return
    return value - 1


def apply_vol_budget(
    prices_by_symbol: dict[str, list[float]],
    targets: dict[str, float],
    signal_index: int,
    spec: VolSpec,
) -> tuple[dict[str, float], float | None, float]:
    vol = target_volatility(prices_by_symbol, targets, signal_index, spec.lookback)
    if vol is None or vol <= spec.target_vol:
        return repair.normalize(targets), vol, 1.0
    scale = max(spec.floor_scale, min(1.0, spec.target_vol / max(vol, 0.0001)))
    shock = recent_target_shock(prices_by_symbol, targets, signal_index)
    if shock is not None and shock < -0.025:
        scale = min(scale, spec.shock_scale)
    return repair.normalize({symbol: weight * scale for symbol, weight in targets.items()}), vol, scale


def targets_changed(first: dict[str, float], second: dict[str, float], tolerance: float = 0.0005) -> bool:
    symbols = set(first) | set(second)
    return any(abs(first.get(symbol, 0.0) - second.get(symbol, 0.0)) > tolerance for symbol in symbols)


def simulate(data: dict[str, Any], spec: VolSpec) -> tuple[list[float], dict[str, Any], list[Any]]:
    prices_by_symbol: dict[str, list[float]] = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = data["tradable_symbols"]
    repair_spec = make_repair_spec(spec)
    phase_spec = make_phase_spec(spec.use_phase_lock, spec.repair_top_count)
    indicators = repair.build_indicators(prices_by_symbol)

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    values: list[float] = []
    trades: list[Any] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    switches = 0
    repair_hits = 0
    vol_cuts = 0
    shock_cuts = 0
    phase_lock_events = 0
    phase_lock_days = 0
    locked: dict[str, int] = {}
    active_targets: dict[str, float] = {}
    base_targets: dict[str, float] = {}
    repair_overlay: dict[str, float] = {}
    vol_observations: list[float] = []
    scale_observations: list[float] = []
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
                if spec.use_phase_lock:
                    phase.update_locks(
                        prices_by_symbol=prices_by_symbol,
                        indicators=indicators,
                        tradable_symbols=tradable_symbols,
                        signal_index=signal_index,
                        spec=phase_spec,
                        locked=locked,
                    )
            satellite_target, defensive_target = targets_by_index[index]
            base_targets = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            selector_weights.append(selector_weight)
            needs_rebalance = True

        if index == 0 or index % 21 == 0:
            budget = min(repair_spec.overlay_cap, max(0.0, 1.0 - repair.total_weight(base_targets)))
            active_repair_symbols = set(repair_overlay)
            repair_overlay = repair.repair_targets(
                spec=repair_spec,
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
            phase_lock_events += len(locked) - previous_lock_count
        if locked:
            phase_lock_days += 1

        if needs_rebalance:
            targets = dict(base_targets)
            for symbol, weight in repair_overlay.items():
                targets[symbol] = targets.get(symbol, 0.0) + weight
            targets = repair.normalize(targets)
            if spec.use_phase_lock:
                targets = phase.apply_phase_locks(targets, locked, phase_spec)
            targets, estimated_vol, scale = apply_vol_budget(prices_by_symbol, targets, signal_index, spec)
            if estimated_vol is not None:
                vol_observations.append(estimated_vol)
            scale_observations.append(scale)
            if scale < 0.999:
                vol_cuts += 1
                if scale <= spec.shock_scale + 0.0001:
                    shock_cuts += 1
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
        "vol_cuts": vol_cuts,
        "shock_cuts": shock_cuts,
        "phase_lock_events": phase_lock_events,
        "phase_lock_days": phase_lock_days,
        "avg_estimated_target_vol": sum(vol_observations) / len(vol_observations) if vol_observations else None,
        "avg_scale": sum(scale_observations) / len(scale_observations) if scale_observations else None,
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else None,
        "latest_selector_weight": selector_weights[-1] if selector_weights else None,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
    }
    return values, extra, trades


def row_for(data: dict[str, Any], spec: VolSpec, values: list[float], extra: dict[str, Any], trades: list[Any]) -> dict[str, Any]:
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
            "post_2020": repair.slice_metrics(dates, values, "2020-01-01"),
            "last_10y": repair.slice_metrics(dates, values, "2016-06-23"),
            "post_2022": repair.slice_metrics(dates, values, "2022-01-01"),
            "post_2024": repair.slice_metrics(dates, values, "2024-01-01"),
        },
        "drawdown_window": repair.max_drawdown_window(dates, values),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in trades[-10:]],
        "extra": extra,
    }


def specs() -> list[VolSpec]:
    out: list[VolSpec] = []
    for repair_top_count in [1, 2]:
        for lookback in [42, 63, 84, 126]:
            for target_vol in [0.075, 0.085, 0.095, 0.105]:
                for floor_scale in [0.50, 0.65, 0.75, 0.85]:
                    for shock_scale in [0.55, 0.70]:
                        for use_phase_lock in [False, True]:
                            if shock_scale < floor_scale:
                                continue
                            out.append(
                                VolSpec(
                                    name=(
                                        f"target_vol_lb{lookback}_tv{int(target_vol*1000)}_"
                                        f"floor{int(floor_scale*100)}_shock{int(shock_scale*100)}_"
                                        f"phase{int(use_phase_lock)}_repair{repair_top_count}"
                                    ),
                                    repair_top_count=repair_top_count,
                                    lookback=lookback,
                                    target_vol=target_vol,
                                    floor_scale=floor_scale,
                                    shock_scale=shock_scale,
                                    use_phase_lock=use_phase_lock,
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
    phase.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    phase.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    phase.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    phase.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        rows: list[dict[str, Any]] = []
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
        phase.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        phase.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        phase.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        phase.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "053 repair overlay plus target-volatility budget. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | trades | dd window")
    for row in rows[:80]:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{row['extra']} | {full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
