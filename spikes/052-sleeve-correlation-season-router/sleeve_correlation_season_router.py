#!/usr/bin/env python3
"""Correlation and seasonal sleeve-router screens.

This spike checks two ideas after 051 failed:

1. Whether blending the high-return 047 sleeve with the high-Sharpe 049
   seasonal/carry sleeve creates enough diversification to reach Sharpe 1.6.
2. Whether month-specific routing between the 047 satellite and defensive
   sleeves improves the full-history frontier without cutting total exposure to
   cash.

The static blend is a NAV-level screen only. The seasonal sleeve-router replay
is target-weight-level and includes fees/slippage. No leverage, no shorting, no
BTC.
"""
from __future__ import annotations

from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import statistics
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SPIKE047 = ROOT / "spikes" / "047-dynamic-sleeve-selector"
SPIKE049 = ROOT / "spikes" / "049-seasonal-alpha-router"
sys.path.insert(0, str(SPIKE047))

import dynamic_sleeve_selector as dyn  # noqa: E402
import target_replay_search as t47  # noqa: E402
import target_weight_replay as replay  # noqa: E402

spec049 = importlib.util.spec_from_file_location("seasonal_carry_search_052", SPIKE049 / "seasonal_carry_search.py")
if spec049 is None or spec049.loader is None:
    raise RuntimeError(f"failed to load {SPIKE049 / 'seasonal_carry_search.py'}")
seasonal_carry = importlib.util.module_from_spec(spec049)
sys.modules["seasonal_carry_search_052"] = seasonal_carry
spec049.loader.exec_module(seasonal_carry)

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


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def performance_row(name: str, dates: list[date], values: list[float], extra: dict[str, Any] | None = None) -> dict[str, Any]:
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
        "extra": extra or {},
    }


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(dates) if day >= start_date), None)
    if idx is None or idx >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates[idx:], values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


def daily_returns(values: list[float]) -> list[float]:
    return [values[index] / values[index - 1] - 1 for index in range(1, len(values)) if values[index - 1] > 0]


def correlation(a: list[float], b: list[float]) -> float | None:
    if len(a) != len(b) or len(a) < 3:
        return None
    mean_a = statistics.fmean(a)
    mean_b = statistics.fmean(b)
    numerator = sum((left - mean_a) * (right - mean_b) for left, right in zip(a, b))
    denom_a = sum((item - mean_a) ** 2 for item in a)
    denom_b = sum((item - mean_b) ** 2 for item in b)
    if denom_a <= 0 or denom_b <= 0:
        return None
    return numerator / math.sqrt(denom_a * denom_b)


def nav_blend_rows(dates: list[date], high_values: list[float], low_values: list[float]) -> list[dict[str, Any]]:
    high_returns = daily_returns(high_values)
    low_returns = daily_returns(low_values)
    rows: list[dict[str, Any]] = []
    for step in range(21):
        high_weight = step / 20
        values = [100_000.0]
        for high_return, low_return in zip(high_returns, low_returns):
            blended_return = high_weight * high_return + (1 - high_weight) * low_return
            values.append(values[-1] * (1 + blended_return))
        rows.append(
            performance_row(
                f"nav_blend_047_{int(high_weight * 100)}_049_{int((1 - high_weight) * 100)}",
                dates,
                values,
                {"high_weight": high_weight},
            )
        )
    return rows


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
) -> None:
    cash = cash_box["cash"]
    fee_rate = 0.001
    slippage_rate = 0.0005
    targets = replay.normalize(targets)
    target_symbols = set(targets)

    def portfolio_value() -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    pre_value = portfolio_value()
    for symbol in sorted(held - target_symbols):
        current_units = units.get(symbol, 0.0)
        if current_units <= 0:
            continue
        execution_price = max(prices_by_symbol[symbol][index] * (1 - slippage_rate), 0.0)
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


def seasonal_selector_weight(
    month: int,
    base_weight: float,
    mode: str,
    strong_months: set[int],
    weak_months: set[int],
    high: float,
    mid: float,
    low: float,
) -> float:
    if mode == "replace":
        if month in strong_months:
            return high
        if month in weak_months:
            return low
        return mid
    if mode == "clamp":
        if month in strong_months:
            return max(base_weight, high)
        if month in weak_months:
            return min(base_weight, low)
        return min(max(base_weight, low), mid)
    if mode == "tilt":
        if month in strong_months:
            return min(0.95, base_weight + high)
        if month in weak_months:
            return max(0.25, base_weight - low)
        return base_weight
    raise ValueError(mode)


def simulate_seasonal_router(
    data: dict[str, Any],
    *,
    mode: str,
    strong_months: set[int],
    weak_months: set[int],
    high: float,
    mid: float,
    low: float,
) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
    env = data["env"]
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
    trades: list[app.Trade] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    switches = 0
    max_target_sum = 0.0

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    for index, current_date in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest

        if index in targets_by_index:
            signal_index = index - 1
            if signal_index >= 0:
                base_weight = dyn.choose_weight(BASE_SELECTOR, satellite_values, defensive_values, values, signal_index, selector_weight)
                next_weight = seasonal_selector_weight(current_date.month, base_weight, mode, strong_months, weak_months, high, mid, low)
                if abs(next_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = next_weight
            satellite_target, defensive_target = targets_by_index[index]
            target = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            max_target_sum = max(max_target_sum, sum(target.values()))
            selector_weights.append(selector_weight)
            rebalance_portfolio(
                index=index,
                dates=dates,
                prices_by_symbol=prices_by_symbol,
                tradable_symbols=tradable_symbols,
                targets=target,
                cash_box=cash_box,
                units=units,
                held=held,
                trades=trades,
            )

        values.append(portfolio_value(index))

    return values, {
        "mode": mode,
        "strong_months": sorted(strong_months),
        "weak_months": sorted(weak_months),
        "high": high,
        "mid": mid,
        "low": low,
        "switches": switches,
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else selector_weight,
        "latest_selector_weight": selector_weights[-1] if selector_weights else selector_weight,
        "max_target_sum": max_target_sum,
    }, trades


def seasonal_router_rows(data: dict[str, Any]) -> list[dict[str, Any]]:
    strong_sets = [
        {10, 11, 12},
        {3, 5, 10, 11, 12},
        {4, 5, 7, 11, 12},
        {1, 4, 5, 7, 11, 12},
    ]
    weak_sets = [
        {2, 6, 9, 10},
        {2, 6, 8, 9},
        {1, 2, 6, 8, 9, 10},
        {2, 8, 9},
    ]
    rows: list[dict[str, Any]] = []
    for strong_months in strong_sets:
        for weak_months in weak_sets:
            for mode in ["tilt", "clamp", "replace"]:
                if mode == "tilt":
                    candidates = [(0.10, 0.0, 0.15), (0.15, 0.0, 0.20), (0.20, 0.0, 0.25)]
                else:
                    candidates = [(0.80, 0.55, 0.25), (0.90, 0.55, 0.35), (0.95, 0.65, 0.35)]
                for high, mid, low in candidates:
                    values, extra, trades = simulate_seasonal_router(
                        data,
                        mode=mode,
                        strong_months=strong_months,
                        weak_months=weak_months,
                        high=high,
                        mid=mid,
                        low=low,
                    )
                    name = (
                        f"seasonal_sleeve_{mode}_"
                        f"s{''.join(str(item) for item in sorted(strong_months))}_"
                        f"w{''.join(str(item) for item in sorted(weak_months))}_"
                        f"h{int(high * 100)}_m{int(mid * 100)}_l{int(low * 100)}"
                    )
                    row = performance_row(name, data["dates"], values, {**extra, "trades": len(trades)})
                    rows.append(row)
    return rows


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    seasonal_carry.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    seasonal_carry.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    seasonal_carry.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    seasonal_carry.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        data["raw_public"] = cached_fetch(end_date=None)
        high_values, high_extra, high_trades = t47.simulate(data, BASE_SELECTOR)
        carry_spec = seasonal_carry.CarryOverlaySpec(
            name="seasonal_tier_short_only_cap50_per35_all",
            thesis="049 high-Sharpe seasonal/carry sleeve.",
            mode="short_only",
            cap=0.50,
            per_asset_cap=0.35,
            use_only_weak_mid_months=False,
        )
        low_values, low_extra, low_trades = seasonal_carry.simulate(data, carry_spec)
        nav_rows = nav_blend_rows(data["dates"], high_values, low_values)
        router_rows = seasonal_router_rows(data)
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    high_row = performance_row("baseline_047_dynamic_sleeve", data["dates"], high_values, {**high_extra, "trades": len(high_trades)})
    low_row = performance_row("baseline_049_seasonal_carry", data["dates"], low_values, {**low_extra, "trades": len(low_trades)})
    daily_corr = correlation(daily_returns(high_values), daily_returns(low_values))
    nav_rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    router_rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]

    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "note": "NAV blend is a screen only; seasonal router is target-weight replay. No leverage, no shorting, no BTC.",
        "daily_return_correlation_047_049": daily_corr,
        "baselines": [high_row, low_row],
        "nav_blend_rows": nav_rows,
        "seasonal_router_rows": router_rows,
    }
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print(f"daily_return_correlation_047_049={daily_corr:.4f}" if daily_corr is not None else "daily_return_correlation_047_049=n/a")
    print("baselines")
    for row in [high_row, low_row]:
        full = row["full"]
        print(f"{row['name']} | {pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])}")
    print("top NAV blends")
    for row in nav_rows[:12]:
        full = row["full"]
        print(f"{row['name']} | {pct(full['annualized'])}/{pct(full['max_drawdown'])}/{full['sharpe']:.4f}/{pct(full['annual_volatility'])}")
    print("top seasonal routers")
    for row in router_rows[:20]:
        full = row["full"]
        extra = row["extra"]
        print(
            f"{row['name']} | {pct(full['annualized'])}/{pct(full['max_drawdown'])}/"
            f"{full['sharpe']:.4f}/{pct(full['annual_volatility'])} | avgw={extra['avg_selector_weight']:.3f}"
        )


if __name__ == "__main__":
    main()
