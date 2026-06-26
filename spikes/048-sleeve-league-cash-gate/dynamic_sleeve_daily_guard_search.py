#!/usr/bin/env python3
"""Daily risk-guard search on top of the verified 047 dynamic sleeve.

The 047 selector only changes target weights on scheduled rebalance days. This
spike tests a different mechanism: keep the 047 return engine, but allow a
daily circuit breaker to reduce equity exposure between scheduled rebalances
when portfolio weakness and market stress agree.

No leverage, no shorting, no BTC. All candidates use target-weight replay with
fees, slippage, and cash interest.
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

EQUITY_SYMBOLS = {"nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext"}
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
class GuardSpec:
    name: str
    thesis: str
    trigger_mode: str
    transform_mode: str
    min_hold_days: int
    repair_lookback: int
    portfolio_dd: float
    shock_lookback: int
    shock_threshold: float
    equity_scale: float
    gold_cap: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


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


def equity_exposure(weights: dict[str, float]) -> float:
    return sum(weight for symbol, weight in weights.items() if symbol in EQUITY_SYMBOLS)


def market_shock_count(prices_by_symbol: dict[str, list[float]], index: int, lookback: int, threshold: float) -> int:
    count = 0
    for symbol in ["nasdaq", "sp500", "csi300", "shanghai_composite", "shenzhen_component", "chinext"]:
        values = prices_by_symbol.get(symbol)
        if not values or index >= len(values):
            continue
        ret = trailing_return(values, index, lookback)
        dd = trailing_drawdown(values, index, max(lookback, 40))
        if ret is None or dd is None:
            continue
        if ret < threshold or dd < threshold * 1.45:
            count += 1
    return count


def gold_trend_ok(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    values = prices_by_symbol.get("gold_cny")
    if not values or index >= len(values):
        return False
    r20 = trailing_return(values, index, 20)
    r60 = trailing_return(values, index, 60)
    dd60 = trailing_drawdown(values, index, 60)
    return r20 is not None and r60 is not None and dd60 is not None and r20 > -0.025 and r60 > 0 and dd60 > -0.06


def should_trigger(
    spec: GuardSpec,
    prices_by_symbol: dict[str, list[float]],
    base_targets: dict[str, float],
    strategy_values: list[float],
    index: int,
) -> bool:
    if equity_exposure(base_targets) < 0.25:
        return False
    shock_count = market_shock_count(prices_by_symbol, index, spec.shock_lookback, spec.shock_threshold)
    pf_dd = trailing_drawdown(strategy_values, len(strategy_values) - 1, max(20, spec.shock_lookback)) if len(strategy_values) > 20 else 0.0
    pf_dd = pf_dd or 0.0

    if spec.trigger_mode == "broad_market_shock":
        return shock_count >= 2

    if spec.trigger_mode == "portfolio_confirmed_shock":
        return pf_dd < -spec.portfolio_dd and shock_count >= 1

    if spec.trigger_mode == "triple_confirmed_shock":
        nd = prices_by_symbol.get("nasdaq", [])
        sp = prices_by_symbol.get("sp500", [])
        gold = prices_by_symbol.get("gold_cny", [])
        nd_ret = trailing_return(nd, index, spec.shock_lookback) if nd else None
        sp_ret = trailing_return(sp, index, spec.shock_lookback) if sp else None
        gold_ret = trailing_return(gold, index, 20) if gold else None
        return (
            pf_dd < -spec.portfolio_dd
            and nd_ret is not None and sp_ret is not None and nd_ret < spec.shock_threshold
            and sp_ret < spec.shock_threshold * 0.70
            and (gold_ret is None or gold_ret < 0.03)
        )

    raise ValueError(spec.trigger_mode)


def should_repair(spec: GuardSpec, prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    shock_count = market_shock_count(prices_by_symbol, index, spec.repair_lookback, spec.shock_threshold * 0.45)
    nd = prices_by_symbol.get("nasdaq", [])
    sp = prices_by_symbol.get("sp500", [])
    nd_repair = trailing_return(nd, index, spec.repair_lookback) if nd else None
    sp_repair = trailing_return(sp, index, spec.repair_lookback) if sp else None
    return shock_count == 0 and nd_repair is not None and sp_repair is not None and nd_repair > 0 and sp_repair > -0.01


def transform_targets(spec: GuardSpec, targets: dict[str, float], prices_by_symbol: dict[str, list[float]], index: int) -> dict[str, float]:
    if spec.transform_mode == "remove_equity":
        return replay.normalize({symbol: weight for symbol, weight in targets.items() if symbol not in EQUITY_SYMBOLS})

    if spec.transform_mode == "partial_equity":
        return replay.normalize({
            symbol: weight * spec.equity_scale if symbol in EQUITY_SYMBOLS else weight
            for symbol, weight in targets.items()
        })

    if spec.transform_mode == "gold_redeploy":
        out: dict[str, float] = {}
        removed = 0.0
        for symbol, weight in targets.items():
            if symbol in EQUITY_SYMBOLS:
                kept = weight * spec.equity_scale
                removed += max(weight - kept, 0.0)
                if kept > 0.0001:
                    out[symbol] = kept
            else:
                out[symbol] = weight
        if gold_trend_ok(prices_by_symbol, index):
            current_gold = out.get("gold_cny", 0.0)
            out["gold_cny"] = min(spec.gold_cap, current_gold + removed)
        return replay.normalize(out)

    raise ValueError(spec.transform_mode)


def simulate(data: dict[str, Any], spec: GuardSpec | None) -> tuple[list[float], dict[str, Any], list[app.Trade]]:
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
    selector_weight = 0.80
    selector_weights: list[float] = []
    switches = 0
    guard_entries = 0
    guard_days = 0
    guard_until = -1
    base_targets: dict[str, float] = {}
    active_targets: dict[str, float] = {}
    max_target_sum = 0.0

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def rebalance_to(index: int, targets: dict[str, float]) -> None:
        nonlocal cash, held, active_targets, max_target_sum
        targets = replay.normalize(targets)
        active_targets = targets
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

    for index in range(len(dates)):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index in targets_by_index:
            signal_index = index - 1
            if signal_index >= 0:
                new_weight = dyn.choose_weight(BEST_047, satellite_values, defensive_values, points, signal_index, selector_weight)
                if abs(new_weight - selector_weight) > 0.05:
                    switches += 1
                selector_weight = new_weight
            satellite_target, defensive_target = targets_by_index[index]
            base_targets = replay.blend_weights(satellite_target, defensive_target, selector_weight)
            selector_weights.append(selector_weight)
            if spec is not None and guard_until >= index:
                guarded = transform_targets(spec, base_targets, prices_by_symbol, index)
                rebalance_to(index, guarded)
            else:
                guard_until = -1
                rebalance_to(index, base_targets)
        elif spec is not None:
            if guard_until >= index:
                guard_days += 1
                if index >= guard_until and should_repair(spec, prices_by_symbol, index):
                    guard_until = -1
                    rebalance_to(index, base_targets)
                else:
                    guarded = transform_targets(spec, base_targets, prices_by_symbol, index)
                    if guarded != active_targets:
                        rebalance_to(index, guarded)
            elif should_trigger(spec, prices_by_symbol, base_targets, points, index):
                guard_entries += 1
                guard_until = index + spec.min_hold_days
                guarded = transform_targets(spec, base_targets, prices_by_symbol, index)
                rebalance_to(index, guarded)

        points.append(portfolio_value(index))

    extra = {
        "switches": switches,
        "guard_entries": guard_entries,
        "guard_days": guard_days,
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


def row_for(data: dict[str, Any], name: str, thesis: str, values: list[float], extra: dict[str, Any], trades: list[app.Trade], spec: GuardSpec | None) -> dict[str, Any]:
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


def specs() -> list[GuardSpec]:
    rows: list[GuardSpec] = []
    for trigger_mode in ["broad_market_shock", "portfolio_confirmed_shock", "triple_confirmed_shock"]:
        for transform_mode in ["partial_equity", "remove_equity", "gold_redeploy"]:
            for min_hold_days in [10, 21, 42]:
                for shock_lookback, shock_threshold in [(20, -0.055), (30, -0.070), (60, -0.095)]:
                    for portfolio_dd in [0.025, 0.035]:
                        for equity_scale in [0.25, 0.45]:
                            name = (
                                f"{trigger_mode}_{transform_mode}_hold{min_hold_days}"
                                f"_l{shock_lookback}_t{int(abs(shock_threshold)*1000)}"
                                f"_dd{int(portfolio_dd*1000)}_eq{int(equity_scale*100)}"
                            )
                            rows.append(
                                GuardSpec(
                                    name=name,
                                    thesis=(
                                        "Keep the 047 dynamic sleeve, but use a daily circuit breaker when market stress "
                                        "and/or the strategy equity curve confirms weakness."
                                    ),
                                    trigger_mode=trigger_mode,
                                    transform_mode=transform_mode,
                                    min_hold_days=min_hold_days,
                                    repair_lookback=20,
                                    portfolio_dd=portfolio_dd,
                                    shock_lookback=shock_lookback,
                                    shock_threshold=shock_threshold,
                                    equity_scale=equity_scale,
                                    gold_cap=0.65,
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
        rows.append(row_for(data, "dynamic_sleeve_047_reference", "Verified 047 dynamic sleeve without daily guard.", base_values, base_extra, base_trades, None))
        for spec in specs():
            values, extra, trades = simulate(data, spec)
            rows.append(row_for(data, spec.name, spec.thesis, values, extra, trades, spec))
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]
        replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("daily_guard_results.json")
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "note": "Target-weight daily guard search on top of 047. No leverage, no shorting, no BTC.",
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
