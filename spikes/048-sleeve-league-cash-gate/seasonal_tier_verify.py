#!/usr/bin/env python3
"""Verify the seasonal-tier risk budget candidate from spike 048.

Logic:
- Use the verified 047 dynamic sleeve selector as the return engine.
- Add a calendar risk budget derived from month-level behavior:
  - Weak months 2/6/9/10: 40% target exposure.
  - Middling months 1/3/8: 55% target exposure.
  - Good but not strongest months 4/5/7: 90% target exposure.
  - Strong months 11/12: 100% target exposure.
- Rebalance only on normal target changes or month boundaries.

No leverage, no shorting, no BTC. This is target-weight replay with fees,
slippage, cash interest, and real app-equivalent price alignment.
"""
from __future__ import annotations

from datetime import date, datetime
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

SELECTOR = dyn.SelectorSpec(
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
MONTH_SCALE = {
    1: 0.55,
    2: 0.40,
    3: 0.55,
    4: 0.90,
    5: 0.90,
    6: 0.40,
    7: 0.90,
    8: 0.55,
    9: 0.40,
    10: 0.40,
    11: 1.00,
    12: 1.00,
}


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


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
    targets = replay.normalize(targets)
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


def run_candidate(data: dict[str, Any]) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
    prices_by_symbol = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = data["tradable_symbols"]

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    month_scales: list[float] = []
    switches = 0
    base_targets: dict[str, float] = {}
    active_targets: dict[str, float] = {}
    max_target_sum = 0.0
    month_boundary_rebalances = 0
    last_month: int | None = None

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    for index, current_date in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest

        needs_rebalance = False
        if index in targets_by_index:
            signal_index = index - 1
            if signal_index >= 0:
                new_weight = dyn.choose_weight(SELECTOR, satellite_values, defensive_values, points, signal_index, selector_weight)
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
            satellite_target, defensive_target = targets_by_index[index]
            base_targets = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            selector_weights.append(selector_weight)
            needs_rebalance = True

        if last_month is not None and current_date.month != last_month:
            needs_rebalance = True
            month_boundary_rebalances += 1

        if needs_rebalance:
            scale = MONTH_SCALE[current_date.month]
            targets = replay.normalize({symbol: weight * scale for symbol, weight in base_targets.items()}) if base_targets else {}
            if targets != active_targets:
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
            month_scales.append(scale)
            max_target_sum = max(max_target_sum, sum(active_targets.values()))

        last_month = current_date.month
        points.append(portfolio_value(index))

    extra = {
        "switches": switches,
        "month_boundary_rebalances": month_boundary_rebalances,
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else selector_weight,
        "latest_selector_weight": selector_weights[-1] if selector_weights else selector_weight,
        "avg_month_scale": sum(month_scales) / len(month_scales) if month_scales else 1.0,
        "latest_month_scale": month_scales[-1] if month_scales else 1.0,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
        "month_scale": MONTH_SCALE,
    }
    return points, extra, trades


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


def row_for(data: dict[str, Any], values: list[float], extra: dict[str, Any], trades: list[app.Trade]) -> dict[str, Any]:
    dates: list[date] = data["dates"]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": "seasonal_tier_dynamic_sleeve",
        "thesis": "Use 047 dynamic sleeve as engine, then apply month-tier target exposure based on persistent seasonal risk/reward.",
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
        "checks": {
            "no_btc": not any("btc" in symbol.lower() or "bitcoin" in symbol.lower() for symbol in extra["symbols"]),
            "no_leverage": extra["max_target_sum"] <= 1.000001,
            "sharpe_above_1_5": sharpe is not None and sharpe > 1.5,
        },
    }


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        values, extra, trades = run_candidate(data)
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    row = row_for(data, values, extra, trades)
    out_path = Path(__file__).with_name("seasonal_tier_verify.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Independent single-candidate target-weight verification for seasonal tier dynamic sleeve.",
                "row": row,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    full: dict[str, Any] = row["full"]
    slices: dict[str, dict[str, Any]] = row["slices"]
    ddw: dict[str, Any] = row["drawdown_window"]
    print(f"WROTE {out_path}")
    print(
        f"{row['name']} | annualized={pct(full['annualized'])} "
        f"dd={pct(full['max_drawdown'])} vol={pct(full['annual_volatility'])} "
        f"sharpe={full['sharpe']:.4f} trades={full['trades']}"
    )
    print(
        "slices="
        f"post2020 {pct(slices['post_2020']['annualized'])}/{slices['post_2020']['sharpe']:.4f}, "
        f"last10 {pct(slices['last_10y']['annualized'])}/{slices['last_10y']['sharpe']:.4f}, "
        f"post2022 {pct(slices['post_2022']['annualized'])}/{slices['post_2022']['sharpe']:.4f}, "
        f"post2024 {pct(slices['post_2024']['annualized'])}/{slices['post_2024']['sharpe']:.4f}"
    )
    print(f"checks={row['checks']}")
    print(f"extra={row['extra']}")
    print(f"drawdown_window={ddw['peak_date']}->{ddw['trough_date']}")


if __name__ == "__main__":
    main()
