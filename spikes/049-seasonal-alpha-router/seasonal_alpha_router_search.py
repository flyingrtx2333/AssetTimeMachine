#!/usr/bin/env python3
"""Seasonal alpha router on top of the 047 dynamic sleeve.

The 048 seasonal-tier candidate crossed Sharpe 1.5 but cut annualized return too
much. This spike tests a richer mechanism: in months where the 047 engine has
weak seasonal risk/reward, route part of the target budget into month-specific
assets that historically have better behavior, subject to trend confirmation.

No leverage, no shorting, no BTC. Target-weight replay with fees, slippage, and
cash interest.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import json
import math
from pathlib import Path
import statistics
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


@dataclass(frozen=True)
class RouterSpec:
    name: str
    thesis: str
    basket_mode: str
    transform_mode: str
    weak_base_scale: float
    mid_base_scale: float
    good_base_scale: float
    weak_alpha: float
    mid_alpha: float
    trend_mode: str
    top_count: int
    per_asset_cap: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    return replay.normalize(weights, max_total)


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(value, 0.0) for value in weights.values())


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0 or values[index] <= 0:
        return None
    return values[index] / values[index - lookback] - 1.0


def moving_average(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    window = values[index - period + 1:index + 1]
    if any(value <= 0 for value in window):
        return None
    return sum(window) / period


def annual_vol(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        prev = values[cursor - 1]
        current = values[cursor]
        if prev <= 0 or current <= 0:
            return None
        returns.append(current / prev - 1.0)
    if len(returns) < 20:
        return None
    return statistics.stdev(returns) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def drawdown(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0 or values[index] <= 0:
        return None
    window = values[index - lookback + 1:index + 1]
    if any(value <= 0 for value in window):
        return None
    peak = max(window)
    return values[index] / peak - 1.0 if peak > 0 else None


def month_tier(month: int) -> str:
    if month in {2, 6, 9, 10}:
        return "weak"
    if month in {1, 3, 8}:
        return "mid"
    return "good"


def basket_for(mode: str, month: int) -> list[str]:
    if mode == "seasonal_single":
        return {
            1: ["gold_cny"],
            2: ["chinext"],
            3: [],
            4: [],
            5: [],
            6: ["chinext"],
            7: [],
            8: ["gold_cny"],
            9: ["chinext", "shenzhen_component"],
            10: ["nasdaq", "dowjones", "chinext"],
            11: [],
            12: ["csi300", "shenzhen_component"],
        }.get(month, [])

    if mode == "seasonal_basket":
        return {
            1: ["gold_cny"],
            2: ["csi300", "shanghai_composite", "shenzhen_component", "chinext"],
            3: [],
            4: [],
            5: [],
            6: ["chinext"],
            7: [],
            8: ["gold_cny"],
            9: ["csi300", "shenzhen_component", "chinext"],
            10: ["nasdaq", "sp500", "dowjones", "chinext"],
            11: [],
            12: ["csi300", "shanghai_composite", "shenzhen_component"],
        }.get(month, [])

    if mode == "seasonal_gold_china_us":
        return {
            1: ["gold_cny"],
            2: ["shenzhen_component", "chinext"],
            3: ["nasdaq", "sp500"],
            4: [],
            5: [],
            6: ["gold_cny", "chinext"],
            7: [],
            8: ["gold_cny"],
            9: ["shenzhen_component", "chinext"],
            10: ["nasdaq", "sp500", "dowjones"],
            11: [],
            12: ["csi300", "shenzhen_component"],
        }.get(month, [])

    raise ValueError(mode)


def asset_score(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, trend_mode: str) -> float | None:
    values = prices_by_symbol.get(symbol)
    if not values or index >= len(values) or values[index] <= 0:
        return None
    mom20 = momentum(values, index, 20)
    mom60 = momentum(values, index, 60)
    mom120 = momentum(values, index, 120)
    ma60 = moving_average(values, index, 60)
    ma120 = moving_average(values, index, 120)
    vol60 = annual_vol(values, index, 60)
    dd60 = drawdown(values, index, 60)
    if None in (mom20, mom60, mom120, ma60, ma120, vol60, dd60):
        return None
    assert mom20 is not None and mom60 is not None and mom120 is not None
    assert ma60 is not None and ma120 is not None and vol60 is not None and dd60 is not None

    if trend_mode == "loose":
        if mom60 < -0.015 or values[index] < ma120 or dd60 < -0.10:
            return None
    elif trend_mode == "confirmed":
        if mom60 <= 0 or mom120 <= -0.015 or values[index] < ma120 or dd60 < -0.08:
            return None
    elif trend_mode == "accel":
        if mom20 <= -0.005 or mom60 <= 0 or values[index] < ma60 or dd60 < -0.07:
            return None
    else:
        raise ValueError(trend_mode)

    return (0.45 * mom20 + 0.75 * mom60 + mom120 + 0.35 * max(dd60, -0.30)) / max(vol60, 0.04)


def seasonal_alpha_target(
    spec: RouterSpec,
    prices_by_symbol: dict[str, list[float]],
    month: int,
    signal_index: int,
) -> dict[str, float]:
    symbols = basket_for(spec.basket_mode, month)
    scored: list[tuple[float, str]] = []
    for symbol in symbols:
        score = asset_score(prices_by_symbol, symbol, signal_index, spec.trend_mode)
        if score is not None and score > 0:
            scored.append((score, symbol))
    scored.sort(reverse=True)
    selected = scored[: spec.top_count]
    if not selected:
        return {}
    total = sum(score for score, _symbol in selected)
    if total <= 0:
        return {}
    out: dict[str, float] = {}
    for score, symbol in selected:
        out[symbol] = min(spec.per_asset_cap, score / total)
    return normalize(out)


def scaled_base(spec: RouterSpec, month: int, base_target: dict[str, float]) -> dict[str, float]:
    tier = month_tier(month)
    scale = spec.weak_base_scale if tier == "weak" else spec.mid_base_scale if tier == "mid" else spec.good_base_scale
    return normalize({symbol: weight * scale for symbol, weight in base_target.items()})


def alpha_weight(spec: RouterSpec, month: int) -> float:
    tier = month_tier(month)
    if tier == "weak":
        return spec.weak_alpha
    if tier == "mid":
        return spec.mid_alpha
    return 0.0


def combine_targets(
    spec: RouterSpec,
    base_target: dict[str, float],
    alpha_target: dict[str, float],
    month: int,
) -> dict[str, float]:
    base = scaled_base(spec, month, base_target)
    alpha = alpha_weight(spec, month)
    if not alpha_target or alpha <= 0:
        return base

    if spec.transform_mode == "overlay_idle":
        available = min(alpha, max(0.0, 1.0 - total_weight(base)))
        out = dict(base)
        for symbol, weight in alpha_target.items():
            out[symbol] = out.get(symbol, 0.0) + available * weight
        return normalize(out)

    if spec.transform_mode == "blend":
        out: dict[str, float] = {}
        for symbol in set(base) | set(alpha_target):
            out[symbol] = (1.0 - alpha) * base.get(symbol, 0.0) + alpha * alpha_target.get(symbol, 0.0)
        return normalize(out)

    if spec.transform_mode == "replace_weak":
        tier = month_tier(month)
        replace = alpha if tier in {"weak", "mid"} else 0.0
        out: dict[str, float] = {}
        for symbol in set(base) | set(alpha_target):
            out[symbol] = (1.0 - replace) * base.get(symbol, 0.0) + replace * alpha_target.get(symbol, 0.0)
        return normalize(out)

    raise ValueError(spec.transform_mode)


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


def simulate(data: dict[str, Any], spec: RouterSpec) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
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
    alpha_hits = 0
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
        signal_index = index - 1
        if index in targets_by_index:
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
            if signal_index >= 0:
                alpha_target = seasonal_alpha_target(spec, prices_by_symbol, current_date.month, signal_index)
            else:
                alpha_target = {}
            if alpha_target:
                alpha_hits += 1
            targets = combine_targets(spec, base_targets, alpha_target, current_date.month) if base_targets else {}
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
        "month_boundary_rebalances": month_boundary_rebalances,
        "alpha_hits": alpha_hits,
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


def row_for(data: dict[str, Any], spec: RouterSpec, values: list[float], extra: dict[str, Any], trades: list[app.Trade]) -> dict[str, Any]:
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


def specs() -> list[RouterSpec]:
    out: list[RouterSpec] = []
    for basket_mode in ["seasonal_single", "seasonal_basket", "seasonal_gold_china_us"]:
        for transform_mode in ["overlay_idle", "blend"]:
            for weak_base_scale in [0.40, 0.45, 0.50]:
                for mid_base_scale in [0.55, 0.65]:
                    for good_base_scale in [0.90, 1.00]:
                        for weak_alpha in [0.10, 0.20, 0.30]:
                            for mid_alpha in [0.00, 0.10, 0.20]:
                                for trend_mode in ["loose", "confirmed"]:
                                    for top_count in [1]:
                                        for per_asset_cap in [0.50, 0.70]:
                                            name = (
                                                f"{basket_mode}_{transform_mode}_wb{int(weak_base_scale*100)}"
                                                f"_mb{int(mid_base_scale*100)}_gb{int(good_base_scale*100)}"
                                                f"_wa{int(weak_alpha*100)}_ma{int(mid_alpha*100)}"
                                                f"_{trend_mode}_top{top_count}_cap{int(per_asset_cap*100)}"
                                            )
                                            out.append(
                                                RouterSpec(
                                                    name=name,
                                                    thesis=(
                                                        "Keep the 047 dynamic sleeve as core, but route weak/mid-season "
                                                        "risk budget into month-specific assets with trend confirmation."
                                                    ),
                                                    basket_mode=basket_mode,
                                                    transform_mode=transform_mode,
                                                    weak_base_scale=weak_base_scale,
                                                    mid_base_scale=mid_base_scale,
                                                    good_base_scale=good_base_scale,
                                                    weak_alpha=weak_alpha,
                                                    mid_alpha=mid_alpha,
                                                    trend_mode=trend_mode,
                                                    top_count=top_count,
                                                    per_asset_cap=per_asset_cap,
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
    out_path = Path(__file__).with_name("seasonal_alpha_router_results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Target-weight seasonal alpha router search on top of 047. No leverage, no shorting, no BTC.",
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
