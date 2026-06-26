#!/usr/bin/env python3
"""Target-weight-level search for dynamic sleeve selection.

This searches selector logic only. The two sleeve target portfolios are
precomputed once for every rebalance date, then each candidate trades a combined
target portfolio with fees/slippage.
"""
from __future__ import annotations

from datetime import date, datetime
import json
import math
from pathlib import Path
import sys
from typing import Any

import dynamic_sleeve_selector as dyn
import target_weight_replay as replay

app = dyn.app
s35 = replay.s35
s30 = replay.s30
s42 = replay.s42
CACHE_PATH = Path(__file__).with_name("public_history_cache.json")


def cached_public_history_factory(original_fetch):
    memory: dict[str | None, dict[str, list[tuple[date, float]]]] = {}

    def load_full() -> dict[str, list[tuple[date, float]]]:
        if CACHE_PATH.exists():
            raw = json.loads(CACHE_PATH.read_text())
            return {
                symbol: [(date.fromisoformat(day), float(price)) for day, price in rows]
                for symbol, rows in raw.items()
            }
        last_error: Exception | None = None
        for _attempt in range(4):
            try:
                data = original_fetch(end_date=None)
                CACHE_PATH.write_text(
                    json.dumps(
                        {symbol: [(day.isoformat(), price) for day, price in rows] for symbol, rows in data.items()},
                        ensure_ascii=False,
                    )
                )
                return data
            except Exception as exc:  # retry transient network/API timeouts
                last_error = exc
        raise RuntimeError(f"failed to fetch public history for cache: {last_error!r}")

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key in memory:
            return memory[key]
        full = load_full()
        if end_date is None:
            memory[key] = full
        else:
            memory[key] = {
                symbol: [(day, price) for day, price in rows if day <= end_date]
                for symbol, rows in full.items()
            }
        return memory[key]

    return cached_fetch


def precompute_targets() -> dict[str, Any]:
    shared = replay.load_shared_data()
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

    signal_months = [day.month for day in dates]
    original_signal_month = s35.current_signal_month

    def runtime_signal_month(_prices_by_symbol: dict[str, list[float]], signal_index: int) -> int:
        if signal_index < 0 or signal_index >= len(signal_months):
            return 1
        return signal_months[signal_index]

    s35.current_signal_month = runtime_signal_month
    targets_by_index: dict[int, tuple[dict[str, float], dict[str, float]]] = {}
    try:
        for index in range(len(dates)):
            if index == 0 or index % max(env.config.rebalance_sessions, 1) == 0:
                signal_index = index - 1
                if signal_index < 0:
                    targets_by_index[index] = ({}, {})
                    continue
                raw = replay.raw_meta_weights(env, signal_index, index)
                satellite_champion = env.champion_overlay(raw, signal_index, dates[signal_index], prices_by_symbol, satellite_values, env.config)
                satellite_target = s42.add_satellite(satellite_champion, satellite_spec, prices_by_symbol, signal_index)
                defensive_champion = env.champion_overlay(raw, signal_index, dates[signal_index], prices_by_symbol, defensive_values, env.config)
                defensive_target = s30.apply_budget(defensive_champion, defensive_spec, signal_index, defensive_values)
                targets_by_index[index] = (replay.normalize(satellite_target), replay.normalize(defensive_target))
    finally:
        s35.current_signal_month = original_signal_month

    tradable_symbols = [symbol for symbol in env.symbols if symbol not in env.config.signal_only_symbols]
    tradable_symbols += [symbol for symbol in s35.EXTRA_SYMBOLS if symbol in prices_by_symbol]
    return {
        "env": env,
        "prices_by_symbol": prices_by_symbol,
        "dates": dates,
        "satellite_values": satellite_values,
        "defensive_values": defensive_values,
        "targets_by_index": targets_by_index,
        "tradable_symbols": sorted(set(tradable_symbols)),
    }


def simulate(data: dict[str, Any], spec: dyn.SelectorSpec) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
    env = data["env"]
    prices_by_symbol = data["prices_by_symbol"]
    dates = data["dates"]
    satellite_values = data["satellite_values"]
    defensive_values = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols = data["tradable_symbols"]

    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    switches = 0
    max_target_sum = 0.0

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    for index in range(len(dates)):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index in targets_by_index:
            signal_index = index - 1
            if signal_index >= 0:
                new_weight = dyn.choose_weight(spec, satellite_values, defensive_values, points, signal_index, selector_weight)
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
            satellite_target, defensive_target = targets_by_index[index]
            targets = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            selector_weights.append(selector_weight)
            max_target_sum = max(max_target_sum, sum(targets.values()))
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

        points.append(portfolio_value(index))

    extra = {
        "switches": switches,
        "avg_satellite_weight": sum(selector_weights) / len(selector_weights) if selector_weights else selector_weight,
        "latest_satellite_weight": selector_weights[-1] if selector_weights else selector_weight,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
    }
    return points, extra, trades


def specs() -> list[dyn.SelectorSpec]:
    out: list[dyn.SelectorSpec] = []
    for mode in ["hysteresis_selector", "return_selector", "momentum_gradient", "drawdown_guard"]:
        for lookback in [168, 189, 210, 231, 252, 273, 294, 315]:
            for high, low in [(0.95, 0.25), (0.92, 0.30), (0.90, 0.32), (0.90, 0.35), (0.88, 0.35), (0.86, 0.40), (0.84, 0.45), (0.80, 0.55)]:
                for ret_margin in [0.0, 0.01, 0.0125, 0.015, 0.02, 0.025, 0.03]:
                    for dd_limit, pf_limit in [(0.035, 0.030), (0.040, 0.030), (0.045, 0.035), (0.055, 0.040), (0.065, 0.045), (0.085, 0.060)]:
                        out.append(
                            dyn.SelectorSpec(
                                name=f"target_{mode}_lb{lookback}_h{int(high*100)}_l{int(low*100)}_m{int(ret_margin*10000)}_d{int(dd_limit*1000)}",
                                thesis="Target-level selector search over precomputed sleeve target weights.",
                                mode=mode,
                                lookback=lookback,
                                satellite_high=high,
                                satellite_low=low,
                                ret_margin=ret_margin,
                                dd_limit=dd_limit,
                                portfolio_dd_limit=pf_limit,
                            )
                        )
    return out


def row_for(data: dict[str, Any], spec: dyn.SelectorSpec, values: list[float], extra: dict[str, Any], trades: list[app.Trade]) -> dict[str, Any]:
    dates = data["dates"]
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
            "post_2020": replay.slice_metrics(app.BacktestResult(spec.name, dates[0].isoformat(), dates[-1].isoformat(), len(values), annualized, max_dd, total, annual_vol, sharpe, values[-1], trades, dates, values), "2020-01-01"),
            "last_10y": replay.slice_metrics(app.BacktestResult(spec.name, dates[0].isoformat(), dates[-1].isoformat(), len(values), annualized, max_dd, total, annual_vol, sharpe, values[-1], trades, dates, values), "2016-06-23"),
            "post_2022": replay.slice_metrics(app.BacktestResult(spec.name, dates[0].isoformat(), dates[-1].isoformat(), len(values), annualized, max_dd, total, annual_vol, sharpe, values[-1], trades, dates, values), "2022-01-01"),
            "post_2024": replay.slice_metrics(app.BacktestResult(spec.name, dates[0].isoformat(), dates[-1].isoformat(), len(values), annualized, max_dd, total, annual_vol, sharpe, values[-1], trades, dates, values), "2024-01-01"),
        },
        "drawdown_window": replay.max_drawdown_window(app.BacktestResult(spec.name, dates[0].isoformat(), dates[-1].isoformat(), len(values), annualized, max_dd, total, annual_vol, sharpe, values[-1], trades, dates, values)),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in trades[-10:]],
        "extra": extra,
    }


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = cached_public_history_factory(original_fetch)
    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = precompute_targets()
        rows: list[dict[str, Any]] = []
        for spec in specs():
            values, extra, trades = simulate(data, spec)
            rows.append(row_for(data, spec, values, extra, trades))
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("target_search_results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Target-weight-level search using precomputed satellite/defensive sleeve targets.",
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
            f"{replay.pct(full['annualized'])}/{replay.pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{replay.pct(full['annual_volatility'])} | "
            f"{replay.pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{replay.pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{replay.pct(slices['post_2024']['annualized'])}/{(slices['post_2024']['sharpe'] or 0):.4f} | "
            f"{row['extra']} | {full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
