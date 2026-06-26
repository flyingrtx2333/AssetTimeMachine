#!/usr/bin/env python3
"""Contagion-controlled global repair candidate.

This spike starts from the 059 high-return lead and adds a narrow 2015-style
equity contagion control. It is not a broad stop-loss shell: the control only
activates after China/HK bubble rollover or China/HK plus global equity
breakdown, then temporarily scales equity/global-repair exposure until US/global
breadth repairs.

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
GLOBAL_PATH = ROOT / "spikes" / "059-global-repair-opportunity" / "global_repair_opportunity.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


g59 = load_module("global_repair_opportunity_059", GLOBAL_PATH)

app = g59.app
repair = g59.repair
phase = g59.phase
dyn = g59.dyn
replay = g59.replay
t47 = g59.t47
s35 = g59.s35
s30 = g59.s30

EQUITY_SYMBOLS = {
    "nasdaq",
    "sp500",
    "dowjones",
    "csi300",
    "shanghai_composite",
    "shenzhen_component",
    "chinext",
    "hsi",
    "nikkei",
}
CHINA_HK_SYMBOLS = ["csi300", "shanghai_composite", "shenzhen_component", "chinext", "hsi"]
GLOBAL_CHECK_SYMBOLS = ["nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "hsi", "nikkei"]


@dataclass(frozen=True)
class ContagionSpec:
    name: str
    cooldown_sessions: int
    equity_scale: float
    global_overlay_scale: float
    redeploy_gold_ratio: float
    release_mode: str
    trigger_mode: str


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


BASE_SPEC = g59.GlobalRepairSpec(
    name="global_eq_cap8_per6_top1_oil4_phase1_repair1",
    repair_top_count=1,
    base_overlay_cap=0.35,
    base_per_asset_cap=0.15,
    global_symbols=("hsi", "nikkei"),
    global_overlay_cap=0.08,
    global_per_asset_cap=0.06,
    global_top_count=1,
    commodity_cap=0.04,
    use_phase_lock=True,
)


def safe_momentum(values: list[float], index: int, lookback: int) -> float | None:
    return g59.safe_momentum(values, index, lookback)


def moving_average(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    window = values[index - period + 1:index + 1]
    if any(value <= 0 for value in window):
        return None
    return sum(window) / period


def rolling_dd(values: list[float], index: int, lookback: int) -> float | None:
    return repair.rolling_high_drawdown(values, index, lookback)


def bubble_rollover_symbol(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> bool:
    prices = prices_by_symbol.get(symbol)
    if not prices or index <= 0 or prices[index] <= 0:
        return False
    mom20 = safe_momentum(prices, index, 20)
    mom60 = safe_momentum(prices, index, 60)
    mom120 = safe_momentum(prices, index, 120)
    dd20 = rolling_dd(prices, index, 20)
    dd60 = rolling_dd(prices, index, 60)
    ma40 = moving_average(prices, index, 40)
    ma120 = moving_average(prices, index, 120)
    if None in (mom20, mom60, mom120, dd20, dd60, ma40, ma120):
        return False
    assert mom20 is not None and mom60 is not None and mom120 is not None
    assert dd20 is not None and dd60 is not None and ma40 is not None and ma120 is not None
    hot = mom120 > 0.30 or mom60 > 0.18 or prices[index] > ma120 * 1.18
    rollover = mom20 < -0.025 or dd20 < -0.055 or dd60 < -0.10 or prices[index] < ma40
    return hot and rollover


def weak_symbol(prices_by_symbol: dict[str, list[float]], symbol: str, indicators: dict[str, dict[int, list[float | None]]], index: int) -> bool:
    prices = prices_by_symbol.get(symbol)
    if not prices or index <= 0 or prices[index] <= 0:
        return False
    ma60 = indicators[symbol][60][index]
    mom20 = safe_momentum(prices, index, 20)
    mom60 = safe_momentum(prices, index, 60)
    dd60 = rolling_dd(prices, index, 60)
    if ma60 is None or mom20 is None or mom60 is None or dd60 is None:
        return False
    return prices[index] < ma60 or mom20 < -0.035 or mom60 < -0.055 or dd60 < -0.105


def global_breadth(prices_by_symbol: dict[str, list[float]], indicators: dict[str, dict[int, list[float | None]]], index: int) -> tuple[int, int]:
    checked = 0
    healthy = 0
    for symbol in GLOBAL_CHECK_SYMBOLS:
        prices = prices_by_symbol.get(symbol)
        if not prices:
            continue
        ma60 = indicators[symbol][60][index]
        mom20 = safe_momentum(prices, index, 20)
        if ma60 is None or mom20 is None:
            continue
        checked += 1
        if prices[index] > ma60 and mom20 > -0.015:
            healthy += 1
    return checked, healthy


def contagion_trigger(
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    index: int,
    spec: ContagionSpec,
) -> tuple[bool, str]:
    bubble_symbols = [symbol for symbol in CHINA_HK_SYMBOLS if bubble_rollover_symbol(prices_by_symbol, symbol, index)]
    weak_china_hk = [symbol for symbol in CHINA_HK_SYMBOLS if weak_symbol(prices_by_symbol, symbol, indicators, index)]
    checked, healthy = global_breadth(prices_by_symbol, indicators, index)
    global_weak = checked >= 5 and healthy <= 2

    if spec.trigger_mode == "bubble_only":
        active = len(bubble_symbols) >= 1
    elif spec.trigger_mode == "bubble_or_breadth":
        active = len(bubble_symbols) >= 1 or (len(weak_china_hk) >= 2 and global_weak)
    elif spec.trigger_mode == "cluster":
        active = len(bubble_symbols) >= 1 and (len(weak_china_hk) >= 2 or global_weak)
    else:
        raise ValueError(spec.trigger_mode)

    reason = f"bubble={','.join(bubble_symbols) or '-'} weak={len(weak_china_hk)} breadth={healthy}/{checked}"
    return active, reason


def release_ok(
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    index: int,
    spec: ContagionSpec,
) -> bool:
    checked, healthy = global_breadth(prices_by_symbol, indicators, index)
    us_good = 0
    for symbol in ["nasdaq", "sp500"]:
        prices = prices_by_symbol[symbol]
        ma60 = indicators[symbol][60][index]
        mom20 = safe_momentum(prices, index, 20)
        mom60 = safe_momentum(prices, index, 60)
        if ma60 is not None and mom20 is not None and mom60 is not None and prices[index] > ma60 and mom20 > 0 and mom60 > -0.01:
            us_good += 1
    if spec.release_mode == "time_only":
        return False
    if spec.release_mode == "us_repair":
        return us_good >= 2
    if spec.release_mode == "global_repair":
        return us_good >= 2 and checked >= 5 and healthy >= 4
    raise ValueError(spec.release_mode)


def gold_ok(prices_by_symbol: dict[str, list[float]], indicators: dict[str, dict[int, list[float | None]]], index: int) -> bool:
    prices = prices_by_symbol["gold_cny"]
    ma60 = indicators["gold_cny"][60][index]
    ma120 = indicators["gold_cny"][120][index]
    mom20 = safe_momentum(prices, index, 20)
    return ma60 is not None and ma120 is not None and mom20 is not None and prices[index] > ma60 and prices[index] > ma120 and mom20 > -0.02


def apply_contagion_control(
    targets: dict[str, float],
    spec: ContagionSpec,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[int, list[float | None]]],
    signal_index: int,
    state: dict[str, Any],
) -> dict[str, float]:
    if signal_index < 0:
        return repair.normalize(targets)

    triggered, reason = contagion_trigger(prices_by_symbol, indicators, signal_index, spec)
    if triggered:
        state["until"] = max(int(state.get("until", -1)), signal_index + spec.cooldown_sessions)
        state["events"] = int(state.get("events", 0)) + 1
        state["last_reason"] = reason

    active = int(state.get("until", -1)) >= signal_index
    if active and release_ok(prices_by_symbol, indicators, signal_index, spec):
        active = False
        state["released"] = int(state.get("released", 0)) + 1
        state["until"] = signal_index - 1

    if not active:
        return repair.normalize(targets)

    state["active_days"] = int(state.get("active_days", 0)) + 1
    out = dict(targets)
    removed = 0.0
    for symbol in list(out):
        if symbol not in EQUITY_SYMBOLS:
            continue
        scale = spec.global_overlay_scale if symbol in {"hsi", "nikkei"} else spec.equity_scale
        old = out.get(symbol, 0.0)
        new = old * scale
        out[symbol] = new
        removed += max(old - new, 0.0)
    if removed > 0 and spec.redeploy_gold_ratio > 0 and gold_ok(prices_by_symbol, indicators, signal_index):
        out["gold_cny"] = out.get("gold_cny", 0.0) + removed * spec.redeploy_gold_ratio
    return repair.normalize(out)


def targets_changed(first: dict[str, float], second: dict[str, float], tolerance: float = 0.0005) -> bool:
    symbols = set(first) | set(second)
    return any(abs(first.get(symbol, 0.0) - second.get(symbol, 0.0)) > tolerance for symbol in symbols)


def simulate(data: dict[str, Any], spec: ContagionSpec) -> tuple[list[float], dict[str, Any], list[Any], list[dict[str, Any]]]:
    prices_by_symbol: dict[str, list[float]] = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = data["tradable_symbols"]
    indicators = repair.build_indicators(prices_by_symbol)
    repair_spec = g59.make_repair_spec(BASE_SPEC)
    phase_spec = g59.make_phase_spec(True, BASE_SPEC.repair_top_count)

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    values: list[float] = []
    trades: list[Any] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    switches = 0
    repair_hits = 0
    global_hits = 0
    phase_lock_events = 0
    phase_lock_days = 0
    locked: dict[str, int] = {}
    contagion_state: dict[str, Any] = {"until": -1, "events": 0, "active_days": 0, "released": 0}
    active_targets: dict[str, float] = {}
    base_targets: dict[str, float] = {}
    repair_overlay: dict[str, float] = {}
    global_overlay: dict[str, float] = {}
    max_target_sum = 0.0
    target_log: list[dict[str, Any]] = []

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    for index, current_date in enumerate(dates):
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
            base_budget = min(repair_spec.overlay_cap, max(0.0, 1.0 - repair.total_weight(base_targets)))
            active_repair_symbols = set(repair_overlay)
            repair_overlay = repair.repair_targets(
                spec=repair_spec,
                prices_by_symbol=prices_by_symbol,
                indicators=indicators,
                tradable_symbols=[symbol for symbol in tradable_symbols if symbol not in set(BASE_SPEC.global_symbols)],
                signal_index=signal_index,
                budget=base_budget,
                active_repair_symbols=active_repair_symbols,
            )
            if repair_overlay:
                repair_hits += 1
            remaining_budget = min(
                BASE_SPEC.global_overlay_cap,
                max(0.0, 1.0 - repair.total_weight(base_targets) - repair.total_weight(repair_overlay)),
            )
            global_overlay = g59.global_targets(BASE_SPEC, prices_by_symbol, indicators, signal_index, remaining_budget)
            if global_overlay:
                global_hits += 1
            needs_rebalance = True

        if len(locked) > previous_lock_count:
            phase_lock_events += len(locked) - previous_lock_count
        if locked:
            phase_lock_days += 1

        if needs_rebalance:
            targets = dict(base_targets)
            for overlay in [repair_overlay, global_overlay]:
                for symbol, weight in overlay.items():
                    targets[symbol] = targets.get(symbol, 0.0) + weight
            targets = repair.normalize(targets)
            targets = phase.apply_phase_locks(targets, locked, phase_spec)
            targets = apply_contagion_control(targets, spec, prices_by_symbol, indicators, signal_index, contagion_state)
            max_target_sum = max(max_target_sum, repair.total_weight(targets))
            if app.parse_date("2015-04-01") <= current_date <= app.parse_date("2015-10-31"):
                target_log.append(
                    {
                        "date": current_date.isoformat(),
                        "signal_date": dates[signal_index].isoformat() if signal_index >= 0 else None,
                        "targets": {symbol: round(weight, 4) for symbol, weight in sorted(targets.items()) if weight > 0.0001},
                        "selector_weight": selector_weight,
                        "contagion_until": contagion_state.get("until", -1),
                        "contagion_active": int(contagion_state.get("until", -1)) >= signal_index,
                        "reason": contagion_state.get("last_reason"),
                    }
                )
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
        "global_hits": global_hits,
        "phase_lock_events": phase_lock_events,
        "phase_lock_days": phase_lock_days,
        "contagion_events": contagion_state.get("events", 0),
        "contagion_active_days": contagion_state.get("active_days", 0),
        "contagion_releases": contagion_state.get("released", 0),
        "last_contagion_reason": contagion_state.get("last_reason"),
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else None,
        "latest_selector_weight": selector_weights[-1] if selector_weights else None,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
    }
    return values, extra, trades, target_log


def row_for(
    data: dict[str, Any],
    spec: ContagionSpec,
    values: list[float],
    extra: dict[str, Any],
    trades: list[Any],
    target_log: list[dict[str, Any]],
) -> dict[str, Any]:
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
        "target_log_2015": target_log[:20],
        "extra": extra,
    }


def baseline_row(data: dict[str, Any]) -> dict[str, Any]:
    values, extra, trades = g59.simulate(data, BASE_SPEC)
    spec = ContagionSpec(
        name="baseline_059_global_repair",
        cooldown_sessions=0,
        equity_scale=1.0,
        global_overlay_scale=1.0,
        redeploy_gold_ratio=0.0,
        release_mode="time_only",
        trigger_mode="bubble_only",
    )
    return row_for(data, spec, values, extra, trades, [])


def specs() -> list[ContagionSpec]:
    out: list[ContagionSpec] = []
    for trigger_mode in ["bubble_only", "cluster", "bubble_or_breadth"]:
        for cooldown_sessions in [42, 63, 84, 126]:
            for equity_scale, global_overlay_scale in [(0.35, 0.0), (0.45, 0.0), (0.55, 0.25), (0.65, 0.35)]:
                for redeploy_gold_ratio in [0.0, 0.50, 0.80]:
                    for release_mode in ["us_repair", "global_repair", "time_only"]:
                        out.append(
                            ContagionSpec(
                                name=(
                                    f"contagion_{trigger_mode}_cd{cooldown_sessions}_"
                                    f"eq{int(equity_scale*100)}_glob{int(global_overlay_scale*100)}_"
                                    f"gold{int(redeploy_gold_ratio*100)}_{release_mode}"
                                ),
                                cooldown_sessions=cooldown_sessions,
                                equity_scale=equity_scale,
                                global_overlay_scale=global_overlay_scale,
                                redeploy_gold_ratio=redeploy_gold_ratio,
                                release_mode=release_mode,
                                trigger_mode=trigger_mode,
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
    g59.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    g59.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    g59.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    g59.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        data = g59.add_extra_series(data, ["hang_seng", "nikkei225", "oil_wti_cny"])
        rows = [baseline_row(data)]
        for spec in specs():
            values, extra, trades, target_log = simulate(data, spec)
            rows.append(row_for(data, spec, values, extra, trades, target_log))
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
        g59.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        g59.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        g59.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        g59.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "059 global repair plus narrow China/HK equity contagion control. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | contagion | trades | dd window")
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
            f"{extra.get('contagion_events', 0)}/{extra.get('contagion_active_days', 0)}/{extra.get('contagion_releases', 0)} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
