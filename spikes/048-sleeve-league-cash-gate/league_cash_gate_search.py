#!/usr/bin/env python3
"""Target-weight search for a sleeve league plus cash gate.

This spike is deliberately not another parameter tweak of the 047 selector.
It adds a third portfolio behavior: when neither sleeve has enough recent edge,
the strategy can shrink total target exposure and hold cash.

No leverage, no shorting, no BTC. Uses the 047 target-weight precomputation so
fees, slippage, cash interest, and trade mechanics remain app-equivalent.
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


@dataclass(frozen=True)
class LeagueSpec:
    name: str
    thesis: str
    selector_mode: str
    gate_mode: str
    lookback: int
    short_lookback: int
    vol_lookback: int
    high_weight: float
    low_weight: float
    ret_margin: float
    score_margin: float
    min_edge: float
    dd_limit: float
    pf_dd_limit: float
    high_scale: float
    mid_scale: float
    low_scale: float
    target_vol: float
    stress_scale: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def clamp(value: float, low: float, high: float) -> float:
    return min(max(value, low), high)


def trailing_return(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0:
        return None
    start = values[index - lookback]
    end = values[index]
    if start <= 0 or end <= 0:
        return None
    return end / start - 1.0


def trailing_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0:
        return None
    window = values[index - lookback + 1:index + 1]
    peak = max(window)
    return values[index] / peak - 1.0 if peak > 0 else None


def trailing_vol(values: list[float], index: int, lookback: int) -> float | None:
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


def sleeve_score(values: list[float], index: int, lookback: int, vol_lookback: int) -> float | None:
    ret = trailing_return(values, index, lookback)
    vol = trailing_vol(values, index, vol_lookback)
    dd = trailing_drawdown(values, index, max(60, lookback // 2))
    if ret is None or vol is None or vol <= 0 or dd is None:
        return None
    # Return per volatility, with a direct penalty for fresh drawdown.
    return ret / vol + dd * 1.6


def recent_asset_stress(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    risk_assets = ["nasdaq", "sp500", "csi300", "shanghai_composite", "shenzhen_component", "chinext"]
    broken = 0
    checked = 0
    for symbol in risk_assets:
        values = prices_by_symbol.get(symbol)
        if not values or index >= len(values):
            continue
        r20 = trailing_return(values, index, 20)
        r60 = trailing_return(values, index, 60)
        dd60 = trailing_drawdown(values, index, 60)
        if r20 is None or r60 is None or dd60 is None:
            continue
        checked += 1
        if r20 < -0.035 or r60 < -0.08 or dd60 < -0.10:
            broken += 1
    return checked >= 3 and broken >= 2


def choose_sleeve_weight(
    spec: LeagueSpec,
    satellite_values: list[float],
    defensive_values: list[float],
    signal_index: int,
    previous_weight: float,
) -> float:
    sat_ret = trailing_return(satellite_values, signal_index, spec.lookback)
    def_ret = trailing_return(defensive_values, signal_index, spec.lookback)
    sat_score = sleeve_score(satellite_values, signal_index, spec.lookback, spec.vol_lookback)
    def_score = sleeve_score(defensive_values, signal_index, spec.lookback, spec.vol_lookback)
    if sat_ret is None or def_ret is None or sat_score is None or def_score is None:
        return previous_weight

    midpoint = (spec.high_weight + spec.low_weight) / 2.0
    if spec.selector_mode == "league_hysteresis":
        spread = sat_score - def_score
        if previous_weight >= midpoint:
            return spec.low_weight if spread < -spec.score_margin else spec.high_weight
        return spec.high_weight if spread > spec.score_margin else spec.low_weight

    if spec.selector_mode == "return_score_vote":
        spread = (sat_ret - def_ret - spec.ret_margin) + 0.18 * (sat_score - def_score)
        if previous_weight >= midpoint:
            return spec.low_weight if spread < -spec.ret_margin else spec.high_weight
        return spec.high_weight if spread > spec.ret_margin else spec.low_weight

    if spec.selector_mode == "soft_league":
        spread = sat_score - def_score
        raw = 1.0 / (1.0 + math.exp(-4.0 * spread))
        return clamp(spec.low_weight + (spec.high_weight - spec.low_weight) * raw, spec.low_weight, spec.high_weight)

    raise ValueError(spec.selector_mode)


def choose_gate_scale(
    spec: LeagueSpec,
    satellite_values: list[float],
    defensive_values: list[float],
    strategy_values: list[float],
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
    sleeve_weight: float,
) -> float:
    sat_ret = trailing_return(satellite_values, signal_index, spec.short_lookback)
    def_ret = trailing_return(defensive_values, signal_index, spec.short_lookback)
    sat_dd = trailing_drawdown(satellite_values, signal_index, max(60, spec.lookback // 2))
    def_dd = trailing_drawdown(defensive_values, signal_index, max(60, spec.lookback // 2))
    pf_dd = trailing_drawdown(strategy_values, len(strategy_values) - 1, max(60, spec.lookback // 2)) if len(strategy_values) > 1 else 0.0
    blended_vol = None
    sat_vol = trailing_vol(satellite_values, signal_index, spec.vol_lookback)
    def_vol = trailing_vol(defensive_values, signal_index, spec.vol_lookback)
    if sat_vol is not None and def_vol is not None:
        blended_vol = sleeve_weight * sat_vol + (1.0 - sleeve_weight) * def_vol

    if sat_ret is None or def_ret is None or sat_dd is None or def_dd is None:
        return spec.mid_scale

    best_ret = max(sat_ret, def_ret)
    best_dd = max(sat_dd, def_dd)
    worst_dd = min(sat_dd, def_dd)
    pf_dd = pf_dd or 0.0
    scale = spec.high_scale

    if spec.gate_mode == "edge_cash_gate":
        if pf_dd < -spec.pf_dd_limit or best_dd < -spec.dd_limit:
            scale = spec.low_scale
        elif best_ret < spec.min_edge:
            scale = spec.mid_scale

    elif spec.gate_mode == "dual_confirm_cash_gate":
        if pf_dd < -spec.pf_dd_limit:
            scale = spec.low_scale
        elif sat_ret < spec.min_edge and def_ret < spec.min_edge:
            scale = spec.low_scale
        elif best_ret < spec.min_edge or worst_dd < -spec.dd_limit:
            scale = spec.mid_scale

    elif spec.gate_mode == "vol_target_gate":
        if blended_vol is not None and blended_vol > 0:
            scale = min(scale, spec.target_vol / blended_vol)
        if pf_dd < -spec.pf_dd_limit or best_dd < -spec.dd_limit:
            scale = min(scale, spec.mid_scale)
        if best_ret < spec.min_edge:
            scale = min(scale, spec.mid_scale)

    elif spec.gate_mode == "stress_quarantine":
        if recent_asset_stress(prices_by_symbol, signal_index):
            scale = spec.stress_scale
        if pf_dd < -spec.pf_dd_limit:
            scale = min(scale, spec.low_scale)
        elif best_ret < spec.min_edge:
            scale = min(scale, spec.mid_scale)

    elif spec.gate_mode == "profit_lock_gate":
        pf_ret = trailing_return(strategy_values, len(strategy_values) - 1, 63) if len(strategy_values) > 64 else 0.0
        if pf_ret is not None and pf_ret > 0.075 and pf_dd < -0.012:
            scale = min(scale, spec.mid_scale)
        if pf_dd < -spec.pf_dd_limit or best_dd < -spec.dd_limit:
            scale = spec.low_scale
        elif best_ret < spec.min_edge:
            scale = min(scale, spec.mid_scale)

    else:
        raise ValueError(spec.gate_mode)

    return clamp(scale, spec.low_scale, spec.high_scale)


def scale_targets(targets: dict[str, float], factor: float) -> dict[str, float]:
    return replay.normalize({symbol: weight * factor for symbol, weight in targets.items()})


def simulate(data: dict[str, Any], spec: LeagueSpec) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
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
    sleeve_weight = 0.55
    weights: list[float] = []
    scales: list[float] = []
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
                new_weight = choose_sleeve_weight(spec, satellite_values, defensive_values, signal_index, sleeve_weight)
                if abs(new_weight - sleeve_weight) > 0.05:
                    switches += 1
                sleeve_weight = new_weight
            satellite_target, defensive_target = targets_by_index[index]
            raw_targets = replay.blend_weights(satellite_target, defensive_target, sleeve_weight)
            scale = choose_gate_scale(
                spec,
                satellite_values,
                defensive_values,
                points,
                prices_by_symbol,
                signal_index,
                sleeve_weight,
            ) if signal_index >= 0 else 0.0
            targets = scale_targets(raw_targets, scale)
            weights.append(sleeve_weight)
            scales.append(scale)
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
        "avg_sleeve_weight": sum(weights) / len(weights) if weights else sleeve_weight,
        "latest_sleeve_weight": weights[-1] if weights else sleeve_weight,
        "avg_scale": sum(scales) / len(scales) if scales else 0.0,
        "latest_scale": scales[-1] if scales else 0.0,
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


def row_for(data: dict[str, Any], spec: LeagueSpec, values: list[float], extra: dict[str, Any], trades: list[app.Trade]) -> dict[str, Any]:
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


def specs() -> list[LeagueSpec]:
    rows: list[LeagueSpec] = []
    selector_modes = ["league_hysteresis", "return_score_vote"]
    gate_modes = ["edge_cash_gate", "dual_confirm_cash_gate", "vol_target_gate", "stress_quarantine", "profit_lock_gate"]
    for selector_mode in selector_modes:
        for gate_mode in gate_modes:
            for lookback in [168, 252, 315]:
                for short_lookback in [42, 63]:
                    vol_lookback = max(63, short_lookback)
                    for high_weight, low_weight in [(0.95, 0.15), (0.90, 0.20), (0.85, 0.25)]:
                        for score_margin in [0.00, 0.12]:
                            for min_edge in [0.00, 0.01]:
                                for dd_limit, pf_dd_limit in [(0.035, 0.030), (0.050, 0.035)]:
                                    for high_scale, mid_scale, low_scale, target_vol in [
                                        (1.00, 0.75, 0.35, 0.105),
                                    ]:
                                        name = (
                                            f"{selector_mode}_{gate_mode}_lb{lookback}_s{short_lookback}"
                                            f"_h{int(high_weight*100)}_l{int(low_weight*100)}"
                                            f"_e{int(min_edge*1000)}_d{int(dd_limit*1000)}"
                                            f"_sc{int(high_scale*100)}{int(mid_scale*100)}{int(low_scale*100)}"
                                        )
                                        rows.append(
                                            LeagueSpec(
                                                name=name,
                                                thesis=(
                                                    "Target-weight sleeve league: rank the high-return and defensive sleeves, "
                                                    "then shrink exposure to cash when edge, drawdown, volatility, or market stress weakens."
                                                ),
                                                selector_mode=selector_mode,
                                                gate_mode=gate_mode,
                                                lookback=lookback,
                                                short_lookback=short_lookback,
                                                vol_lookback=vol_lookback,
                                                high_weight=high_weight,
                                                low_weight=low_weight,
                                                ret_margin=0.0125,
                                                score_margin=score_margin,
                                                min_edge=min_edge,
                                                dd_limit=dd_limit,
                                                pf_dd_limit=pf_dd_limit,
                                                high_scale=high_scale,
                                                mid_scale=mid_scale,
                                                low_scale=low_scale,
                                                target_vol=target_vol,
                                                stress_scale=low_scale,
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
                "note": "Target-weight-level search. No leverage, no shorting, no BTC. Reuses 047 sleeve target streams.",
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
