#!/usr/bin/env python3
"""Event-driven asset-level handbrake on top of the dynamic sleeve.

The 047 dynamic sleeve only changes target weights on its normal rebalance
schedule. This spike tests a different source of edge: between scheduled
rebalances, cut only the held asset that breaks down, leaving the rest of the
portfolio intact. No leverage, no shorting, no BTC.
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

ROOT = Path(__file__).resolve().parents[2]
SPIKE047 = ROOT / "spikes" / "047-dynamic-sleeve-selector"
sys.path.insert(0, str(SPIKE047))

import dynamic_sleeve_selector as dyn  # noqa: E402
import target_replay_search as t47  # noqa: E402
import target_weight_replay as replay  # noqa: E402

app = dyn.app
s35 = replay.s35
s30 = replay.s30

BASE_SELECTOR = dyn.SelectorSpec(
    name="target_hysteresis_selector_lb315_h95_l25_m125_d35",
    thesis="047 verified dynamic sleeve selector.",
    mode="hysteresis_selector",
    lookback=315,
    satellite_high=0.95,
    satellite_low=0.25,
    ret_margin=0.0125,
    dd_limit=0.035,
    portfolio_dd_limit=0.030,
)

EQUITY_SYMBOLS = {
    "nasdaq",
    "sp500",
    "dowjones",
    "csi300",
    "shanghai_composite",
    "shenzhen_component",
    "chinext",
}


@dataclass(frozen=True)
class HandbrakeSpec:
    name: str
    thesis: str
    trigger_mode: str
    cut_fraction: float
    reentry_mode: str
    cooldown_sessions: int
    equity_group_cut: bool
    use_contribution_loss: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    return replay.normalize(weights, max_total)


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(value, 0.0) for value in weights.values())


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
    for index, value in enumerate(values):
        if value > peak:
            peak = value
            peak_i = index
        drawdown = (peak - value) / peak if peak > 0 else 0.0
        if drawdown > worst:
            worst = drawdown
            worst_peak = peak_i
            worst_trough = index
    return {"peak_date": dates[worst_peak].isoformat(), "trough_date": dates[worst_trough].isoformat(), "max_drawdown": worst}


def next_rebalance_index(index: int, rebalance_sessions: int, count: int) -> int:
    step = max(rebalance_sessions, 1)
    return min(((index // step) + 1) * step, count - 1)


def build_indicators(prices_by_symbol: dict[str, list[float]]) -> dict[str, dict[str, list[float | None]]]:
    out: dict[str, dict[str, list[float | None]]] = {}
    for symbol, prices in prices_by_symbol.items():
        out[symbol] = {
            "ma20": app.moving_average(prices, 20),
            "ma40": app.moving_average(prices, 40),
            "ma80": app.moving_average(prices, 80),
        }
    return out


def safe_momentum(prices: list[float], index: int, lookback: int) -> float | None:
    value = app.price_momentum(prices, index, lookback)
    return value if value is not None and math.isfinite(value) else None


def safe_drawdown(prices: list[float], index: int, lookback: int) -> float | None:
    value = app.rolling_drawdown_from_high(prices, index, lookback)
    return value if value is not None and math.isfinite(value) else None


def is_breaking_down(
    symbol: str,
    index: int,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[str, list[float | None]]],
    mode: str,
) -> bool:
    prices = prices_by_symbol[symbol]
    if index <= 0 or index >= len(prices):
        return False

    mom5 = safe_momentum(prices, index, 5)
    mom10 = safe_momentum(prices, index, 10)
    mom20 = safe_momentum(prices, index, 20)
    mom60 = safe_momentum(prices, index, 60)
    dd20 = safe_drawdown(prices, index, 20)
    dd40 = safe_drawdown(prices, index, 40)
    ma20 = indicators[symbol]["ma20"][index]
    ma40 = indicators[symbol]["ma40"][index]
    ma80 = indicators[symbol]["ma80"][index]
    price = prices[index]

    if None in (mom10, mom20, dd20, ma20, ma40):
        return False
    assert mom10 is not None and mom20 is not None and dd20 is not None and ma20 is not None and ma40 is not None

    if symbol == "gold_cny":
        soft_break = price < ma20 and mom10 < -0.010
        hard_break = dd20 < -0.045 and mom20 < -0.005
        trend_break = ma80 is not None and price < ma80 and mom20 < -0.020
    else:
        soft_break = price < ma20 and mom10 < -0.020
        hard_break = dd20 < -0.060 and mom20 < -0.015
        trend_break = price < ma40 and mom20 < -0.030

    if mode == "soft_or_hard":
        return soft_break or hard_break
    if mode == "confirmed_trend":
        return hard_break or trend_break
    if mode == "fast_source_loss":
        return (mom5 is not None and mom5 < (-0.030 if symbol != "gold_cny" else -0.018)) or hard_break
    if mode == "late_cycle_decay":
        hot = mom60 is not None and mom60 > (0.10 if symbol == "gold_cny" else 0.16)
        return hard_break or (hot and soft_break and dd40 is not None and dd40 < -0.045)
    raise ValueError(mode)


def repair_confirmed(
    symbol: str,
    index: int,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[str, list[float | None]]],
) -> bool:
    prices = prices_by_symbol[symbol]
    mom10 = safe_momentum(prices, index, 10)
    mom20 = safe_momentum(prices, index, 20)
    ma20 = indicators[symbol]["ma20"][index]
    if None in (mom10, mom20, ma20):
        return False
    assert mom10 is not None and mom20 is not None and ma20 is not None
    return prices[index] > ma20 and mom10 > 0 and mom20 > (-0.005 if symbol == "gold_cny" else 0.0)


def equity_breadth_broken(
    index: int,
    prices_by_symbol: dict[str, list[float]],
    indicators: dict[str, dict[str, list[float | None]]],
) -> bool:
    checked = 0
    weak = 0
    for symbol in ["nasdaq", "sp500", "csi300", "shanghai_composite"]:
        if symbol not in prices_by_symbol:
            continue
        prices = prices_by_symbol[symbol]
        mom20 = safe_momentum(prices, index, 20)
        ma40 = indicators[symbol]["ma40"][index]
        if mom20 is None or ma40 is None:
            continue
        checked += 1
        if prices[index] < ma40 or mom20 < -0.02:
            weak += 1
    return checked >= 3 and weak >= 3


def contribution_loss_broken(
    symbol: str,
    active_targets: dict[str, float],
    prices_by_symbol: dict[str, list[float]],
    index: int,
    lookback: int = 10,
) -> bool:
    weight = active_targets.get(symbol, 0.0)
    if weight <= 0 or index - lookback < 0:
        return False
    momentum = safe_momentum(prices_by_symbol[symbol], index, lookback)
    if momentum is None:
        return False
    return weight * momentum < (-0.018 if symbol == "gold_cny" else -0.024)


def apply_quarantine(
    base_targets: dict[str, float],
    quarantined_until: dict[str, int],
    spec: HandbrakeSpec,
    index: int,
) -> dict[str, float]:
    out = dict(base_targets)
    for symbol, until in list(quarantined_until.items()):
        if until < index:
            continue
        if symbol not in out:
            continue
        out[symbol] = out[symbol] * spec.cut_fraction
    return normalize(out)


def targets_changed(first: dict[str, float], second: dict[str, float], tolerance: float = 0.0005) -> bool:
    symbols = set(first) | set(second)
    return any(abs(first.get(symbol, 0.0) - second.get(symbol, 0.0)) > tolerance for symbol in symbols)


def rebalance_portfolio(
    *,
    index: int,
    dates: list[date],
    prices_by_symbol: dict[str, list[float]],
    tradable_symbols: list[str],
    targets: dict[str, float],
    cash_box: dict[str, float],
    units: dict[str, float],
    held: set[str],
    trades: list[app.Trade],
) -> dict[str, float]:
    cash = cash_box["cash"]
    fee_rate = 0.001
    slippage_rate = 0.0005
    targets = normalize(targets)
    target_symbols = set(targets.keys())

    def portfolio_value() -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    pre_value = portfolio_value()
    for symbol in sorted(held - target_symbols):
        current_units = units.get(symbol, 0.0)
        if current_units <= 0:
            continue
        price = prices_by_symbol[symbol][index]
        execution_price = max(price * (1 - slippage_rate), 0.0)
        cash_amount = current_units * execution_price * (1 - fee_rate)
        cash += cash_amount
        units[symbol] = 0.0
        trades.append(app.Trade(dates[index].isoformat(), "sell", symbol, execution_price, cash_amount, current_units))
    held &= target_symbols

    for symbol in sorted(target_symbols):
        current_units = units.get(symbol, 0.0)
        if current_units <= 0:
            continue
        price = prices_by_symbol[symbol][index]
        current_value = current_units * price
        target_value = pre_value * targets[symbol]
        gross_to_sell = max(current_value - target_value, 0.0)
        if gross_to_sell <= 0:
            continue
        units_to_sell = min(current_units, gross_to_sell / price)
        execution_price = max(price * (1 - slippage_rate), 0.0)
        cash_amount = units_to_sell * execution_price * (1 - fee_rate)
        cash += cash_amount
        units[symbol] = max(current_units - units_to_sell, 0.0)
        trades.append(app.Trade(dates[index].isoformat(), "sell", symbol, execution_price, cash_amount, units_to_sell))
        if units[symbol] <= sys.float_info.min:
            held.discard(symbol)

    total_value = portfolio_value()
    for symbol in sorted(target_symbols):
        price = prices_by_symbol[symbol][index]
        if price <= 0:
            continue
        current_value = units.get(symbol, 0.0) * price
        target_value = total_value * targets[symbol]
        amount = min(cash, max(target_value - current_value, 0.0))
        if amount <= 0:
            continue
        execution_price = price * (1 + slippage_rate)
        bought_units = amount * (1 - fee_rate) / execution_price if execution_price > 0 else 0.0
        units[symbol] = units.get(symbol, 0.0) + bought_units
        cash -= amount
        held.add(symbol)
        trades.append(app.Trade(dates[index].isoformat(), "buy", symbol, execution_price, amount, bought_units))

    cash_box["cash"] = cash
    return targets


def simulate(data: dict[str, Any], spec: HandbrakeSpec) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
    env = data["env"]
    prices_by_symbol = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = data["tradable_symbols"]
    indicators = build_indicators(prices_by_symbol)

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    switches = 0
    handbrake_hits = 0
    repair_reentries = 0
    max_target_sum = 0.0
    base_targets: dict[str, float] = {}
    active_targets: dict[str, float] = {}
    quarantined_until: dict[str, int] = {}
    min_reentry_index: dict[str, int] = {}

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def quarantine(symbol: str, index: int) -> None:
        nonlocal handbrake_hits
        targets_to_cut = [symbol]
        if spec.equity_group_cut and symbol in EQUITY_SYMBOLS and equity_breadth_broken(index, prices_by_symbol, indicators):
            targets_to_cut = [candidate for candidate in base_targets if candidate in EQUITY_SYMBOLS]
        until = next_rebalance_index(index, env.config.rebalance_sessions, len(dates))
        if spec.reentry_mode == "cooldown":
            until = min(until, index + spec.cooldown_sessions)
        elif spec.reentry_mode == "repair":
            until = next_rebalance_index(index, env.config.rebalance_sessions, len(dates))
        for candidate in targets_to_cut:
            if base_targets.get(candidate, 0.0) <= 0:
                continue
            if quarantined_until.get(candidate, -1) < index:
                handbrake_hits += 1
            quarantined_until[candidate] = max(quarantined_until.get(candidate, -1), until)
            min_reentry_index[candidate] = index + spec.cooldown_sessions

    for index, current_date in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest

        needs_rebalance = False
        signal_index = index - 1

        if index in targets_by_index:
            if signal_index >= 0:
                new_weight = dyn.choose_weight(BASE_SELECTOR, satellite_values, defensive_values, points, signal_index, selector_weight)
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
            satellite_target, defensive_target = targets_by_index[index]
            base_targets = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            selector_weights.append(selector_weight)
            for symbol in list(quarantined_until):
                if quarantined_until[symbol] < index or spec.reentry_mode == "next_rebalance":
                    quarantined_until.pop(symbol, None)
                    min_reentry_index.pop(symbol, None)
            if signal_index >= 0:
                for symbol in list(base_targets):
                    if is_breaking_down(symbol, signal_index, prices_by_symbol, indicators, spec.trigger_mode):
                        quarantine(symbol, index)
            needs_rebalance = True

        if points:
            signal_for_today = index - 1
            if signal_for_today >= 0:
                for symbol in list(held):
                    if base_targets.get(symbol, 0.0) <= 0:
                        continue
                    broken = is_breaking_down(symbol, signal_for_today, prices_by_symbol, indicators, spec.trigger_mode)
                    if spec.use_contribution_loss:
                        broken = broken or contribution_loss_broken(symbol, active_targets, prices_by_symbol, signal_for_today)
                    if broken:
                        quarantine(symbol, index)
                        needs_rebalance = True

                if spec.reentry_mode == "repair":
                    for symbol in list(quarantined_until):
                        if quarantined_until[symbol] < index:
                            continue
                        if index < min_reentry_index.get(symbol, index):
                            continue
                        if base_targets.get(symbol, 0.0) > 0 and repair_confirmed(symbol, signal_for_today, prices_by_symbol, indicators):
                            quarantined_until.pop(symbol, None)
                            min_reentry_index.pop(symbol, None)
                            repair_reentries += 1
                            needs_rebalance = True

        if needs_rebalance:
            targets = apply_quarantine(base_targets, quarantined_until, spec, index)
            max_target_sum = max(max_target_sum, total_weight(targets))
            if targets_changed(targets, active_targets):
                active_targets = rebalance_portfolio(
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

        points.append(portfolio_value(index))

    extra = {
        "switches": switches,
        "handbrake_hits": handbrake_hits,
        "repair_reentries": repair_reentries,
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else selector_weight,
        "latest_selector_weight": selector_weights[-1] if selector_weights else selector_weight,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
    }
    return points, extra, trades


def row_for(data: dict[str, Any], spec: HandbrakeSpec, values: list[float], extra: dict[str, Any], trades: list[app.Trade]) -> dict[str, Any]:
    dates: list[date] = data["dates"]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
        "thesis": spec.thesis,
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
        "drawdown_window": max_drawdown_window(dates, values),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in trades[-10:]],
        "extra": extra,
    }


def specs() -> list[HandbrakeSpec]:
    out: list[HandbrakeSpec] = []
    for trigger in ["soft_or_hard", "confirmed_trend", "fast_source_loss", "late_cycle_decay"]:
        for cut_fraction in [0.0, 0.25, 0.40]:
            for reentry_mode, cooldown in [("next_rebalance", 0), ("cooldown", 15), ("repair", 10)]:
                for equity_group_cut in [False, True]:
                    for contribution in [False, True]:
                        if trigger == "fast_source_loss" and contribution:
                            continue
                        out.append(
                            HandbrakeSpec(
                                name=(
                                    f"handbrake_{trigger}_cut{int(cut_fraction * 100)}_"
                                    f"{reentry_mode}{cooldown if cooldown else ''}_"
                                    f"{'group' if equity_group_cut else 'single'}_"
                                    f"{'contrib' if contribution else 'price'}"
                                ),
                                thesis="Cut only the breaking held asset between scheduled dynamic-sleeve rebalances.",
                                trigger_mode=trigger,
                                cut_fraction=cut_fraction,
                                reentry_mode=reentry_mode,
                                cooldown_sessions=cooldown,
                                equity_group_cut=equity_group_cut,
                                use_contribution_loss=contribution,
                            )
                        )
    return out


def baseline_row(data: dict[str, Any]) -> dict[str, Any]:
    values, extra, trades = t47.simulate(data, BASE_SELECTOR)
    spec = HandbrakeSpec(
        name="baseline_047_dynamic_sleeve",
        thesis="047 verified dynamic sleeve without event-driven handbrake.",
        trigger_mode="none",
        cut_fraction=1.0,
        reentry_mode="scheduled",
        cooldown_sessions=0,
        equity_group_cut=False,
        use_contribution_loss=False,
    )
    return row_for(data, spec, values, extra, trades)


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        rows = [baseline_row(data)]
        for spec in specs():
            values, extra, trades = simulate(data, spec)
            rows.append(row_for(data, spec, values, extra, trades))
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Target-weight replay. Event-driven asset-level handbrake. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | trades | dd window")
    for row in rows[:50]:
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
