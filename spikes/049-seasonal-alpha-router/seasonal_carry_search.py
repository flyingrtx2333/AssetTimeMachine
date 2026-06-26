#!/usr/bin/env python3
"""Idle-cash carry sleeve on top of the seasonal-tier dynamic sleeve.

The 048 candidate has strong Sharpe but low annualized return because a large
part of the portfolio sits in cash during weak/mid months. This spike tests
whether that idle budget can be put into low-volatility Treasury total-return
funds without reopening equity drawdowns.

No leverage, no shorting, no BTC. This uses external long-history Yahoo adjusted
close data for Treasury mutual funds, converted to CNY with the app FX series.
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
SPIKE041 = ROOT / "spikes" / "041-carry-total-return-assets" / "carry_total_return_assets.py"
sys.path.insert(0, str(SPIKE047))

import dynamic_sleeve_selector as dyn  # noqa: E402
import target_replay_search as t47  # noqa: E402
import target_weight_replay as replay  # noqa: E402

spec041 = importlib.util.spec_from_file_location("carry_total_return_assets_049", SPIKE041)
if spec041 is None or spec041.loader is None:
    raise RuntimeError(f"failed to load {SPIKE041}")
carry = importlib.util.module_from_spec(spec041)
sys.modules["carry_total_return_assets_049"] = carry
spec041.loader.exec_module(carry)

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


@dataclass(frozen=True)
class CarryOverlaySpec:
    name: str
    thesis: str
    mode: str
    cap: float
    per_asset_cap: float
    use_only_weak_mid_months: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(value, 0.0) for value in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    return replay.normalize(weights, max_total)


def month_is_weak_or_mid(month: int) -> bool:
    return month in {1, 2, 3, 6, 8, 9, 10}


def add_carry(
    base_target: dict[str, float],
    spec: CarryOverlaySpec,
    prices_by_symbol: dict[str, list[float]],
    month: int,
    signal_index: int,
    portfolio_values: list[float],
) -> dict[str, float]:
    if spec.cap <= 0:
        return base_target
    if spec.use_only_weak_mid_months and not month_is_weak_or_mid(month):
        return base_target
    available = min(max(0.0, 1.0 - total_weight(base_target)), spec.cap)
    if available <= 0:
        return base_target

    risk_off = carry.equity_stress(prices_by_symbol, signal_index)
    clean = [value for value in portfolio_values if value > 0]
    if clean:
        peak = max(clean[-90:])
        risk_off = risk_off or (clean[-1] / peak - 1 if peak > 0 else 0.0) < -0.02

    if spec.mode == "short_only":
        symbols = ["vfisx"]
    elif spec.mode == "balanced_carry":
        symbols = ["vfisx", "vfitx", "vustx"]
    elif spec.mode == "risk_off_duration":
        if not risk_off:
            return base_target
        symbols = ["vfitx", "vustx", "vfisx"]
    elif spec.mode == "curve_or_month":
        symbols = ["vfitx", "vfisx", "vustx"] if risk_off or month_is_weak_or_mid(month) else ["vfisx"]
    else:
        raise ValueError(spec.mode)

    scored: list[tuple[float, str]] = []
    for symbol in symbols:
        score = carry.fund_score(prices_by_symbol, symbol, signal_index, risk_off)
        if score is not None:
            scored.append((score, symbol))
    if not scored:
        return base_target
    scored.sort(reverse=True)
    selected = scored[:2 if spec.mode in {"balanced_carry", "curve_or_month"} else 1]
    score_total = sum(score for score, _symbol in selected)
    if score_total <= 0:
        return base_target
    out = dict(base_target)
    for score, symbol in selected:
        addition = min(spec.per_asset_cap, available * score / score_total)
        out[symbol] = out.get(symbol, 0.0) + addition
    return normalize(out)


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


def simulate(data: dict[str, Any], spec: CarryOverlaySpec) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
    core_prices = data["prices_by_symbol"]
    dates: list[date] = data["dates"]
    raw_public = data["raw_public"]
    fund_prices = carry.align_extra_cny_series(dates, raw_public)
    prices_by_symbol = {**core_prices, **fund_prices}
    satellite_values: list[float] = data["satellite_values"]
    defensive_values: list[float] = data["defensive_values"]
    targets_by_index = data["targets_by_index"]
    tradable_symbols: list[str] = sorted(set(data["tradable_symbols"] + carry.FUND_SYMBOLS))

    cash_box = {"cash": 100_000.0}
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []
    selector_weight = 0.80
    selector_weights: list[float] = []
    carry_hits = 0
    switches = 0
    base_targets: dict[str, float] = {}
    active_targets: dict[str, float] = {}
    max_target_sum = 0.0
    last_month: int | None = None

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    for index, current_date in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest

        needs_rebalance = False
        signal_index = index - 1
        if index in targets_by_index:
            if signal_index >= 0:
                new_weight = dyn.choose_weight(SELECTOR, satellite_values, defensive_values, points, signal_index, selector_weight)
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
            satellite_target, defensive_target = targets_by_index[index]
            raw_target = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            scale = MONTH_SCALE[current_date.month]
            base_targets = normalize({symbol: weight * scale for symbol, weight in raw_target.items()})
            selector_weights.append(selector_weight)
            needs_rebalance = True

        if last_month is not None and current_date.month != last_month:
            scale = MONTH_SCALE[current_date.month]
            base_targets = normalize({symbol: weight / max(MONTH_SCALE[last_month], 0.0001) * scale for symbol, weight in base_targets.items() if symbol not in carry.FUND_SYMBOLS})
            needs_rebalance = True

        if needs_rebalance:
            targets = base_targets
            if signal_index >= 0:
                targets = add_carry(targets, spec, prices_by_symbol, current_date.month, signal_index, points)
            if any(symbol in targets for symbol in carry.FUND_SYMBOLS):
                carry_hits += 1
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
                max_target_sum = max(max_target_sum, total_weight(active_targets))

        last_month = current_date.month
        points.append(portfolio_value(index))

    extra = {
        "switches": switches,
        "carry_hits": carry_hits,
        "avg_selector_weight": sum(selector_weights) / len(selector_weights) if selector_weights else selector_weight,
        "latest_selector_weight": selector_weights[-1] if selector_weights else selector_weight,
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


def row_for(data: dict[str, Any], spec: CarryOverlaySpec, values: list[float], extra: dict[str, Any], trades: list[app.Trade]) -> dict[str, Any]:
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


def specs() -> list[CarryOverlaySpec]:
    out: list[CarryOverlaySpec] = []
    for mode in ["short_only", "balanced_carry", "risk_off_duration", "curve_or_month"]:
        for cap in [0.15, 0.25, 0.35, 0.50]:
            for per_asset_cap in [0.15, 0.25, 0.35]:
                if per_asset_cap > cap:
                    continue
                for weak_mid_only in [True, False]:
                    out.append(
                        CarryOverlaySpec(
                            name=f"seasonal_tier_{mode}_cap{int(cap*100)}_per{int(per_asset_cap*100)}_{'weakmid' if weak_mid_only else 'all'}",
                            thesis="Use seasonal-tier dynamic sleeve and put idle cash into Treasury carry assets.",
                            mode=mode,
                            cap=cap,
                            per_asset_cap=per_asset_cap,
                            use_only_weak_mid_months=weak_mid_only,
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
    try:
        data = t47.precompute_targets()
        data["raw_public"] = cached_fetch(end_date=None)
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
    out_path = Path(__file__).with_name("seasonal_carry_results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Target-weight seasonal carry search on top of 048. No leverage, no shorting, no BTC.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | extra | trades | dd window")
    for row in rows[:60]:
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
