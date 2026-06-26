#!/usr/bin/env python3
"""Target-weight replay for the dynamic sleeve selector.

This verifies the NAV-level candidate by generating both sleeve target
portfolios at each rebalance, then trading one combined target portfolio.
No leverage, no shorting, no BTC.
"""
from __future__ import annotations

from datetime import date, datetime
import json
import math
from pathlib import Path
import sys
from typing import Any

import dynamic_sleeve_selector as dyn

app = dyn.app
s44 = dyn.s44
s42 = s44.s42
s35 = s42.s35
s30 = s44.s30


BEST_SELECTOR = dyn.SelectorSpec(
    name="target_replay_hysteresis_lb231_h90_l32_m150_d45",
    thesis="Target-weight replay of the best NAV-level long-lookback hysteresis sleeve selector.",
    mode="hysteresis_selector",
    lookback=231,
    satellite_high=0.90,
    satellite_low=0.32,
    ret_margin=0.015,
    dd_limit=0.045,
    portfolio_dd_limit=0.035,
)
SHARED_DATA: dict[str, Any] | None = None


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    clean = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = sum(clean.values())
    if total > max_total and total > 0:
        factor = max_total / total
        clean = {symbol: weight * factor for symbol, weight in clean.items() if weight * factor > 0.0001}
    return clean


def blend_weights(a: dict[str, float], b: dict[str, float], a_weight: float) -> dict[str, float]:
    out: dict[str, float] = {}
    for symbol in set(a) | set(b):
        value = a_weight * a.get(symbol, 0.0) + (1.0 - a_weight) * b.get(symbol, 0.0)
        if value > 0.0001:
            out[symbol] = value
    return normalize(out)


def build_env_and_prices():
    original_fetch = app.fetch_public_history
    original_fetch_extra = s35.fetch_extra_raw
    cache: dict[str | None, dict[str, list[tuple[date, float]]]] = {}
    extra_cache: dict[str, dict[str, list[tuple[date, float]]]] = {}

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    def cached_fetch_extra(end_date: date):
        key = end_date.isoformat()
        if key not in extra_cache:
            extra_cache[key] = original_fetch_extra(end_date)
        return extra_cache[key]

    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.fetch_extra_raw = cached_fetch_extra  # type: ignore[assignment]
    try:
        env = s35.build_env()
        prices_by_symbol = s35.add_extra_series(env)
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.fetch_extra_raw = original_fetch_extra  # type: ignore[assignment]
    return env, prices_by_symbol


def values_by_env_date(env_dates: list[date], result: app.BacktestResult) -> list[float]:
    lookup = {day: value for day, value in zip(result.dates, result.values)}
    missing = [day for day in env_dates if day not in lookup]
    if missing:
        raise RuntimeError(f"standalone result missing {len(missing)} env dates, first={missing[0]}")
    return [lookup[day] for day in env_dates]


def load_shared_data() -> dict[str, Any]:
    global SHARED_DATA
    if SHARED_DATA is None:
        satellite_result = s44.run_confirmed_satellite()
        defensive_result = s44.run_profit_lock()
        env, prices_by_symbol = build_env_and_prices()
        SHARED_DATA = {
            "satellite_result": satellite_result,
            "defensive_result": defensive_result,
            "env": env,
            "prices_by_symbol": prices_by_symbol,
            "satellite_values": values_by_env_date(env.dates, satellite_result),
            "defensive_values": values_by_env_date(env.dates, defensive_result),
        }
    return SHARED_DATA


def raw_meta_weights(env: Any, signal_index: int, trace_index: int) -> dict[str, float]:
    if env.config.meta_switch is None:
        return app.advanced_rotation_target_weights(
            env.symbols,
            env.prices_by_symbol,
            env.ma_by_symbol,
            env.vol_by_symbol,
            signal_index,
            env.dates[signal_index],
            env.config,
        )
    return app.meta_rotation_target_weights(env.config.meta_switch, signal_index, trace_index, env.meta_traces) or {}


def run_replay(
    name: str,
    selector: dyn.SelectorSpec | None,
    fixed_satellite_weight: float | None = None,
) -> tuple[app.BacktestResult, dict[str, Any]]:
    shared = load_shared_data()
    env = shared["env"]
    prices_by_symbol = shared["prices_by_symbol"]
    dates = env.dates
    satellite_values = shared["satellite_values"]
    defensive_values = shared["defensive_values"]

    satellite_spec = s35.SatelliteSpec(
        "confirmed_satellite_target",
        "Confirmed acceleration/compression/no-weak-month extra-equity satellite.",
        0.25,
        0.10,
        2,
        "risk_clean_confirmed_accel_compression_no_weak_months",
    )
    defensive_spec = s30.BudgetSpec("profit_lock_target", "Profit-lock defensive budget.", 90, 0.012, 0.045, 0.50, "profit_lock")

    tradable_symbols = [symbol for symbol in env.symbols if symbol not in env.config.signal_only_symbols]
    tradable_symbols += [symbol for symbol in s35.EXTRA_SYMBOLS if symbol in prices_by_symbol]
    tradable_symbols = sorted(set(tradable_symbols))

    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []
    selector_weight = 0.80 if fixed_satellite_weight is None else fixed_satellite_weight
    selector_weights: list[float] = []
    switches = 0
    max_target_sum = 0.0

    signal_months = [day.month for day in dates]
    original_signal_month = s35.current_signal_month

    def runtime_signal_month(_prices_by_symbol: dict[str, list[float]], signal_index: int) -> int:
        if signal_index < 0 or signal_index >= len(signal_months):
            return 1
        return signal_months[signal_index]

    s35.current_signal_month = runtime_signal_month

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def sleeve_targets(signal_index: int, trace_index: int) -> tuple[dict[str, float], dict[str, float]]:
        raw = raw_meta_weights(env, signal_index, trace_index)
        satellite_champion = env.champion_overlay(raw, signal_index, dates[signal_index], prices_by_symbol, satellite_values, env.config)
        satellite_target = s42.add_satellite(satellite_champion, satellite_spec, prices_by_symbol, signal_index)

        defensive_champion = env.champion_overlay(raw, signal_index, dates[signal_index], prices_by_symbol, defensive_values, env.config)
        defensive_target = s30.apply_budget(defensive_champion, defensive_spec, signal_index, defensive_values)
        return normalize(satellite_target), normalize(defensive_target)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        nonlocal selector_weight, switches, max_target_sum
        sat_target, def_target = sleeve_targets(signal_index, trace_index)
        if fixed_satellite_weight is None:
            new_weight = dyn.choose_weight(BEST_SELECTOR if selector is None else selector, satellite_values, defensive_values, points, signal_index, selector_weight)
            if abs(new_weight - selector_weight) > 0.05:
                switches += 1
            selector_weight = new_weight
        target = blend_weights(sat_target, def_target, selector_weight)
        max_target_sum = max(max_target_sum, sum(target.values()))
        selector_weights.append(selector_weight)
        return target

    try:
        for index in range(len(dates)):
            if index > 0 and cash > 0:
                interest = cash * app.cash_daily_return(dates[index - 1])
                if math.isfinite(interest) and interest > 0:
                    cash += interest

            if index == 0 or index % max(env.config.rebalance_sessions, 1) == 0:
                signal_index = index - 1
                targets = normalize(target_weights(signal_index, index) if signal_index >= 0 else {})
                target_symbols = set(targets.keys())
                pre_value = portfolio_value(index)

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

                total_value = portfolio_value(index)
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

            value = portfolio_value(index)
            points.append(value)
            values_by_index[index] = value
    finally:
        s35.current_signal_month = original_signal_month

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, points)
    result = app.BacktestResult(
        strategy=name,
        coverage_start=dates[0].isoformat(),
        coverage_end=dates[-1].isoformat(),
        point_count=len(points),
        annualized_return=annualized,
        max_drawdown=max_dd,
        total_return=total,
        annualized_volatility=annual_vol,
        sharpe_ratio=sharpe,
        final_value=points[-1],
        trades=trades,
        dates=dates,
        values=points,
    )
    extra = {
        "switches": switches,
        "avg_satellite_weight": sum(selector_weights) / len(selector_weights) if selector_weights else selector_weight,
        "latest_satellite_weight": selector_weights[-1] if selector_weights else selector_weight,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
    }
    return result, extra


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


def max_drawdown_window(result: app.BacktestResult) -> dict[str, Any]:
    peak = result.values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for i, value in enumerate(result.values):
        if value > peak:
            peak = value
            peak_i = i
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = i
    return {"peak_date": result.dates[worst_peak].isoformat(), "trough_date": result.dates[worst_trough].isoformat(), "max_drawdown": worst}


def row_for(result: app.BacktestResult, extra: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": result.strategy,
        "full": {
            "annualized": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "annual_volatility": result.annualized_volatility,
            "sharpe": result.sharpe_ratio,
            "total": result.total_return,
            "trades": len(result.trades),
        },
        "slices": {
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-23"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-10:]],
        "extra": extra,
    }


def main() -> None:
    runs = [
        run_replay("target_replay_satellite_100", BEST_SELECTOR, fixed_satellite_weight=1.0),
        run_replay("target_replay_defensive_100", BEST_SELECTOR, fixed_satellite_weight=0.0),
        run_replay("target_replay_static_80", BEST_SELECTOR, fixed_satellite_weight=0.80),
        run_replay(BEST_SELECTOR.name, BEST_SELECTOR),
    ]
    rows = [row_for(result, extra) for result, extra in runs]
    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("target_replay_results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "selector": BEST_SELECTOR.__dict__,
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | trades | dd window")
    for row in rows:
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
