#!/usr/bin/env python3
"""Event-driven risk state machine on top of the current champion.

This is deliberately separated from the app-equivalent low-frequency engine:
it tests a new engine idea.  The base target remains the one-way
volatility-managed router, but a daily risk state can liquidate selected risk
assets before the next scheduled rebalance.

No leverage, no shorting, no financing.  Cash receives the same app cash yield.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))

S28_PATH = ROOT / "spikes" / "028-calendar-invariant-sharpe14" / "sharpe14_logic.py"
SPEC = importlib.util.spec_from_file_location("sharpe14_logic_base", S28_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"failed to load {S28_PATH}")
s28 = importlib.util.module_from_spec(SPEC)
sys.modules["sharpe14_logic_base"] = s28
SPEC.loader.exec_module(s28)

app = s28.app
base = s28.base
EQUITIES = app.EQUITY_SYMBOLS
US_EQUITIES = ["nasdaq", "sp500"]


@dataclass(frozen=True)
class EventSpec:
    name: str
    thesis: str
    modules: tuple[str, ...]
    cooldown_sessions: int
    allow_gold_during_cooldown: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def positive_total(weights: dict[str, float]) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = positive_total(out)
    if total > max_total and total > 0:
        factor = max_total / total
        out = {symbol: weight * factor for symbol, weight in out.items() if weight * factor > 0.0001}
    return out


def price_mom(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int) -> float | None:
    return app.price_momentum(prices_by_symbol[symbol], index, lookback)


def above_ma(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, period: int) -> bool:
    ma = app.moving_average(prices_by_symbol[symbol], period)[index]
    return ma is not None and prices_by_symbol[symbol][index] >= ma


def portfolio_drawdown(points: list[float], lookback: int) -> float:
    if not points:
        return 0.0
    window = points[-lookback:]
    peak = max(window)
    return window[-1] / peak - 1 if peak > 0 else 0.0


def us_breakdown(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    broken = 0
    for symbol in US_EQUITIES:
        mom10 = price_mom(prices_by_symbol, symbol, index, 10)
        mom20 = price_mom(prices_by_symbol, symbol, index, 20)
        if (
            (mom10 is not None and mom10 < -0.035)
            or (mom20 is not None and mom20 < -0.055)
            or not above_ma(prices_by_symbol, symbol, index, 60)
        ):
            broken += 1
    return broken >= 2


def china_contagion(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    china = ["csi300", "shanghai_composite"]
    bubble = any(
        (price_mom(prices_by_symbol, symbol, index, 240) or 0.0) > 0.55
        and (app.donchian_range_position(prices_by_symbol[symbol], index, 240) or 0.0) > 0.75
        for symbol in china
    )
    rollover = any(
        (price_mom(prices_by_symbol, symbol, index, 20) or 0.0) < -0.04
        or (app.rolling_drawdown_from_high(prices_by_symbol[symbol], index, 60) or 0.0) < -0.10
        for symbol in china
    )
    return bubble and rollover


def gold_invalid(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    long = price_mom(prices_by_symbol, "gold_cny", index, 90)
    short = price_mom(prices_by_symbol, "gold_cny", index, 20)
    return long is not None and short is not None and long > 0.08 and short < 0


def event_exit_symbols(
    spec: EventSpec,
    held: set[str],
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
    points: list[float],
) -> tuple[set[str], bool]:
    exit_symbols: set[str] = set()
    full_cooldown = False

    if "us_breakdown" in spec.modules and us_breakdown(prices_by_symbol, signal_index):
        exit_symbols.update(symbol for symbol in held if symbol in EQUITIES)

    if "china_contagion" in spec.modules and china_contagion(prices_by_symbol, signal_index):
        exit_symbols.update(symbol for symbol in held if symbol in EQUITIES)

    if "gold_blowoff" in spec.modules and "gold_cny" in held and gold_invalid(prices_by_symbol, signal_index):
        exit_symbols.add("gold_cny")

    if "portfolio_dd" in spec.modules and portfolio_drawdown(points, 60) < -0.035:
        exit_symbols.update(held)
        full_cooldown = True

    if "held_equity_breakdown" in spec.modules:
        for symbol in sorted(held):
            if symbol not in EQUITIES:
                continue
            dd = app.rolling_drawdown_from_high(prices_by_symbol[symbol], signal_index, 40) or 0.0
            mom10 = price_mom(prices_by_symbol, symbol, signal_index, 10) or 0.0
            mom20 = price_mom(prices_by_symbol, symbol, signal_index, 20) or 0.0
            if (dd < -0.075 and mom10 < 0) or (dd < -0.055 and mom20 < -0.025):
                exit_symbols.add(symbol)

    if "held_gold_breakdown" in spec.modules and "gold_cny" in held:
        dd = app.rolling_drawdown_from_high(prices_by_symbol["gold_cny"], signal_index, 40) or 0.0
        mom10 = price_mom(prices_by_symbol, "gold_cny", signal_index, 10) or 0.0
        if dd < -0.040 and mom10 < 0:
            exit_symbols.add("gold_cny")

    return exit_symbols, full_cooldown


def cooldown_targets(
    base_targets: dict[str, float],
    spec: EventSpec,
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
    full_cooldown: bool,
) -> dict[str, float]:
    if not full_cooldown and spec.allow_gold_during_cooldown and base_targets.get("gold_cny", 0.0) > 0 and not gold_invalid(prices_by_symbol, signal_index):
        return {"gold_cny": min(base_targets["gold_cny"], 0.45)}
    if spec.allow_gold_during_cooldown and not gold_invalid(prices_by_symbol, signal_index):
        mom = price_mom(prices_by_symbol, "gold_cny", signal_index, 60)
        if mom is not None and mom > 0 and above_ma(prices_by_symbol, "gold_cny", signal_index, 90):
            return {"gold_cny": 0.35}
    return {}


def make_target_overlay() -> Callable[[Any], Any]:
    context = base.EngineContext(
        current=s28.run_overlay_strategy("current_gold_handoff", base.current_overlay, 60),
        breadth=s28.run_overlay_strategy("equity_breadth", base.breadth_overlay, 60),
    )
    candidate = next(item for item in s28.candidate_specs() if item.name == "baseline_one_way_vol")
    return s28.overlay_factory(context, candidate)


def run_event_strategy(spec: EventSpec) -> app.BacktestResult:
    original_overlay = app.apply_gold_satellite_overlay
    gold_guard = base.base_explorer.make_gold_blowoff_rollover_overlay(
        cap=0.45,
        long_lookback=90,
        long_threshold=0.08,
        short_lookback=20,
    )
    app.apply_gold_satellite_overlay = make_target_overlay()(gold_guard)  # type: ignore[assignment]
    try:
        raw = app.fetch_public_history(end_date=app.parse_date("2026-06-19"))
        prepared = app.prepare_series(raw)
        dates, prices_by_symbol = app.align_rotation_price_series(prepared)
        symbols = [item.symbol for item in prepared]
        config = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")
        ma_by_symbol, vol_by_symbol = app.indicator_maps(prices_by_symbol, config)
        meta_traces = {
            config.meta_switch.default_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.default_mode)),
            config.meta_switch.defensive_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.defensive_mode)),
        } if config.meta_switch else None

        cash = 100_000.0
        fee_rate = 0.001
        slippage_rate = 0.0005
        tradable_symbols = [symbol for symbol in symbols if symbol not in config.signal_only_symbols]
        units = {symbol: 0.0 for symbol in tradable_symbols}
        held: set[str] = set()
        points: list[float] = []
        trades: list[app.Trade] = []
        values_by_index = [0.0 for _ in dates]
        last_rebalance_index = -10**9
        cooldown_until = -1
        cooldown_is_full = False

        def portfolio_value(index: int) -> float:
            return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

        def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
            if config.meta_switch and meta_traces is not None:
                raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, meta_traces)
                if raw_weights is None:
                    return {}
                return app.apply_gold_satellite_overlay(raw_weights, signal_index, dates[signal_index], prices_by_symbol, values_by_index, config)
            return app.advanced_rotation_target_weights(symbols, prices_by_symbol, ma_by_symbol, vol_by_symbol, signal_index, dates[signal_index], config)

        def sell_symbols(to_sell: set[str], index: int) -> None:
            nonlocal cash, held
            for symbol in sorted(to_sell):
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                price = prices_by_symbol[symbol][index]
                execution_price = max(price * (1 - slippage_rate), 0.0)
                gross = current_units * execution_price
                cash_amount = gross * (1 - fee_rate)
                cash += cash_amount
                units[symbol] = 0.0
                held.discard(symbol)
                trades.append(app.Trade(dates[index].isoformat(), "sell", symbol, execution_price, cash_amount, current_units))

        for index in range(len(dates)):
            if index > 0 and cash > 0:
                interest = cash * app.cash_daily_return(dates[index - 1])
                if math.isfinite(interest) and interest > 0:
                    cash += interest

            signal_index = index - 1
            if signal_index >= 0 and held:
                to_sell, full_cooldown = event_exit_symbols(spec, held, prices_by_symbol, signal_index, points)
                if to_sell:
                    sell_symbols(to_sell, index)
                    cooldown_until = max(cooldown_until, index + max(spec.cooldown_sessions, 0))
                    cooldown_is_full = cooldown_is_full or full_cooldown

            rebalance_sessions = max(config.rebalance_sessions, 1)
            should_rebalance = index == 0 or index % rebalance_sessions == 0
            if should_rebalance:
                signal_index = index - 1
                pre_value = portfolio_value(index)
                base_targets = target_weights(signal_index, index) if signal_index >= 0 else {}
                if index < cooldown_until:
                    targets = cooldown_targets(base_targets, spec, prices_by_symbol, max(signal_index, 0), cooldown_is_full)
                else:
                    cooldown_is_full = False
                    targets = app.apply_portfolio_guard(base_targets, pre_value, points, config) if not config.meta_switch else base_targets
                targets = normalize(targets)
                target_symbols = set(targets.keys())

                sell_symbols(held - target_symbols, index)

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
                    if units_to_sell <= 0:
                        continue
                    execution_price = max(price * (1 - slippage_rate), 0.0)
                    gross = units_to_sell * execution_price
                    cash_amount = gross * (1 - fee_rate)
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
                    invested = amount * (1 - fee_rate)
                    bought_units = invested / execution_price if execution_price > 0 else 0.0
                    units[symbol] = units.get(symbol, 0.0) + bought_units
                    cash -= amount
                    held.add(symbol)
                    trades.append(app.Trade(dates[index].isoformat(), "buy", symbol, execution_price, amount, bought_units))
                last_rebalance_index = index

            value = portfolio_value(index)
            points.append(value)
            values_by_index[index] = value

        total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, points)
        return app.BacktestResult(
            strategy=spec.name,
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
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]


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
        drawdown = (peak - value) / peak if peak > 0 else 0.0
        if drawdown > worst:
            worst = drawdown
            worst_peak = peak_i
            worst_trough = i
    return {
        "peak_date": result.dates[worst_peak].isoformat(),
        "trough_date": result.dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


def row_for(spec: EventSpec, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "modules": list(spec.modules),
        "cooldown_sessions": spec.cooldown_sessions,
        "allow_gold_during_cooldown": spec.allow_gold_during_cooldown,
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
            "last_10y": slice_metrics(result, "2016-06-19"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-8:]],
    }


def specs() -> list[EventSpec]:
    return [
        EventSpec("daily_us_breakdown_exit", "Daily exit from equities when both US core assets break short-term trend.", ("us_breakdown",), 20, True),
        EventSpec("daily_contagion_exit", "Daily equity exit during China bubble rollover contagion.", ("china_contagion",), 20, True),
        EventSpec("daily_us_contagion_exit", "Daily equity exit for either US breakdown or China contagion state.", ("us_breakdown", "china_contagion"), 20, True),
        EventSpec("daily_tail_state_machine", "Daily equity/gold invalidation plus full cash cooldown after portfolio drawdown.", ("us_breakdown", "china_contagion", "gold_blowoff", "portfolio_dd"), 20, True),
        EventSpec("daily_tail_cash_only", "Same risk state, but cooldown holds only cash.", ("us_breakdown", "china_contagion", "gold_blowoff", "portfolio_dd"), 20, False),
        EventSpec("daily_tail_short_cooldown", "Full risk state with shorter cooldown.", ("us_breakdown", "china_contagion", "gold_blowoff", "portfolio_dd"), 10, True),
        EventSpec("daily_tail_long_cooldown", "Full risk state with longer cooldown.", ("us_breakdown", "china_contagion", "gold_blowoff", "portfolio_dd"), 40, True),
        EventSpec("daily_held_equity_breakdown", "Exit only the held equity sleeve when that asset itself breaks down.", ("held_equity_breakdown",), 20, True),
        EventSpec("daily_held_asset_breakdown", "Exit held equity or gold only when the held asset itself breaks down.", ("held_equity_breakdown", "held_gold_breakdown"), 20, True),
        EventSpec("daily_held_breakdown_short_cooldown", "Held-asset breakdown protection with shorter cooldown.", ("held_equity_breakdown", "held_gold_breakdown"), 10, True),
    ]


def main() -> None:
    original_fetch = app.fetch_public_history
    cache: dict[str | None, dict[str, list[tuple[date, float]]]] = {}

    def cached_fetch(end_date: date | None = None):
        key = end_date.isoformat() if end_date else None
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        rows = [row_for(spec, run_event_strategy(spec)) for spec in specs()]
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades | dd window")
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
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
