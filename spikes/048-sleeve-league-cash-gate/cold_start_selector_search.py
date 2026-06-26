#!/usr/bin/env python3
"""Cold-start policies for the 047 dynamic sleeve selector.

The verified 047 selector defaults to an aggressive sleeve weight before the
315-session selector lookback is available. Its worst drawdown happens during
that early warmup period. This spike tests a different logic: when there is not
enough evidence to rank sleeves, start defensively or ramp exposure gradually.

No leverage, no shorting, no BTC. Uses the same target-weight replay mechanics
as 047.
"""
from __future__ import annotations

from dataclasses import dataclass
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

BEST_047 = dyn.SelectorSpec(
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


@dataclass(frozen=True)
class ColdStartSpec:
    name: str
    thesis: str
    warmup_mode: str
    initial_weight: float
    mature_weight: float
    warmup_scale: float
    ramp_sessions: int


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def clamp(value: float, low: float, high: float) -> float:
    return min(max(value, low), high)


def warmup_weight(spec: ColdStartSpec, signal_index: int) -> float:
    if spec.warmup_mode == "fixed_defensive":
        return spec.initial_weight
    if spec.warmup_mode == "linear_ramp":
        progress = clamp(signal_index / max(spec.ramp_sessions, 1), 0.0, 1.0)
        return spec.initial_weight + (spec.mature_weight - spec.initial_weight) * progress
    if spec.warmup_mode == "two_step":
        return spec.initial_weight if signal_index < spec.ramp_sessions else spec.mature_weight
    raise ValueError(spec.warmup_mode)


def simulate(data: dict[str, Any], spec: ColdStartSpec | None) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
    prices_by_symbol = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = data["tradable_symbols"]

    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []
    selector_weight = 0.80 if spec is None else spec.initial_weight
    selector_weights: list[float] = []
    target_scales: list[float] = []
    switches = 0
    warmup_rebalances = 0
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
            scale = 1.0
            if signal_index >= 0:
                if spec is not None and signal_index < BEST_047.lookback:
                    new_weight = warmup_weight(spec, signal_index)
                    scale = spec.warmup_scale
                    warmup_rebalances += 1
                else:
                    new_weight = dyn.choose_weight(BEST_047, satellite_values, defensive_values, points, signal_index, selector_weight)
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
            satellite_target, defensive_target = targets_by_index[index]
            targets = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            if scale < 0.999:
                targets = replay.normalize({symbol: weight * scale for symbol, weight in targets.items()})
            selector_weights.append(selector_weight)
            target_scales.append(scale)
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
        "warmup_rebalances": warmup_rebalances,
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else selector_weight,
        "latest_selector_weight": selector_weights[-1] if selector_weights else selector_weight,
        "avg_target_scale": sum(target_scales) / len(target_scales) if target_scales else 1.0,
        "max_target_sum": max_target_sum,
        "symbols": tradable_symbols,
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


def row_for(data: dict[str, Any], name: str, thesis: str, values: list[float], extra: dict[str, Any], trades: list[app.Trade], spec: ColdStartSpec | None) -> dict[str, Any]:
    dates: list[date] = data["dates"]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": name,
        "thesis": thesis,
        "spec": None if spec is None else spec.__dict__,
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


def specs() -> list[ColdStartSpec]:
    rows: list[ColdStartSpec] = []
    for warmup_mode in ["fixed_defensive", "linear_ramp", "two_step"]:
        for initial_weight in [0.0, 0.10, 0.25, 0.40]:
            for mature_weight in [0.25, 0.50, 0.80]:
                for warmup_scale in [0.65, 0.80, 1.00]:
                    for ramp_sessions in [126, 210, 315]:
                        if warmup_mode == "fixed_defensive" and mature_weight != 0.25:
                            continue
                        name = (
                            f"{warmup_mode}_iw{int(initial_weight*100)}_mw{int(mature_weight*100)}"
                            f"_sc{int(warmup_scale*100)}_r{ramp_sessions}"
                        )
                        rows.append(
                            ColdStartSpec(
                                name=name,
                                thesis=(
                                    "Cold-start the dynamic sleeve defensively until enough history exists to rank sleeves; "
                                    "this targets the early-2003 warmup drawdown without changing mature-period selection logic."
                                ),
                                warmup_mode=warmup_mode,
                                initial_weight=initial_weight,
                                mature_weight=mature_weight,
                                warmup_scale=warmup_scale,
                                ramp_sessions=ramp_sessions,
                            )
                        )
    return rows


def main() -> None:
    original_fetch = app.fetch_public_history
    cached_fetch = t47.cached_public_history_factory(original_fetch)
    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = t47.precompute_targets()
        rows: list[dict[str, Any]] = []
        base_values, base_extra, base_trades = simulate(data, None)
        rows.append(row_for(data, "dynamic_sleeve_047_reference", "Verified 047 dynamic sleeve without cold-start protection.", base_values, base_extra, base_trades, None))
        for spec in specs():
            values, extra, trades = simulate(data, spec)
            rows.append(row_for(data, spec.name, spec.thesis, values, extra, trades, spec))
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("cold_start_results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Target-weight cold-start search on top of 047. No leverage, no shorting, no BTC.",
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
