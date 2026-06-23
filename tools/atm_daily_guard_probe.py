#!/usr/bin/env python3
"""Probe event-driven daily risk guards for AssetTimeMachine.

This is a mechanism test, not a parameter grid.  It reuses the App-equivalent
pricing/target-weight logic but adds daily intra-rebalance shock exits to see
whether the remaining 2007 drawdown requires an engine capability beyond
scheduled rebalance target overlays.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date
import json
from typing import Callable, Any

import atm_app_equivalent_backtest as app
import atm_strategy_explorer as ex


@dataclass(frozen=True)
class Guard:
    name: str
    thesis: str
    should_exit_equity: Callable[[int, dict[str, list[float]], dict[str, float], list[float], list[date]], bool]


def pct(x: float | None) -> str:
    return "n/a" if x is None else f"{x * 100:.2f}%"


def equity_exposure(weights: dict[str, float]) -> float:
    return sum(max(weights.get(s, 0.0), 0.0) for s in app.EQUITY_SYMBOLS)


def normalize(weights: dict[str, float], max_total: float = 0.85) -> dict[str, float]:
    total = sum(max(v, 0.0) for v in weights.values())
    if total > max_total and total > 0:
        scale = max_total / total
        return {k: v * scale for k, v in weights.items() if v * scale > 0.0001}
    return {k: v for k, v in weights.items() if v > 0.0001}


def base_guarded_target(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
    # Previous best fixed mechanism: gold blowoff rollover cap, not a daily guard.
    gold_guard = ex.make_gold_blowoff_rollover_overlay(cap=0.45, long_lookback=90, long_threshold=0.08, short_lookback=20)
    return gold_guard(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)


def guard_equity_shock() -> Guard:
    def should_exit(index, prices, weights, points, dates):
        if equity_exposure(weights) <= 0.20:
            return False
        sp20 = app.price_momentum(prices["sp500"], index, 20)
        nd20 = app.price_momentum(prices["nasdaq"], index, 20)
        sp60 = app.price_momentum(prices["sp500"], index, 60)
        # Mechanism: a broad US equity shock during the holding interval exits
        # equity immediately. This targets 2007/2020/2022 gap risk between normal
        # 60-session rebalances.
        return ((sp20 is not None and sp60 is not None and sp20 < -0.06 and sp60 < 0) or (nd20 is not None and nd20 < -0.08))
    return Guard("daily_equity_shock_exit", "Exit equity intra-rebalance when broad US equity shock appears, then wait for next scheduled signal.", should_exit)


def guard_equity_shock_partial() -> Guard:
    def should_exit(index, prices, weights, points, dates):
        if equity_exposure(weights) <= 0.45:
            return False
        sp20 = app.price_momentum(prices["sp500"], index, 20)
        nd20 = app.price_momentum(prices["nasdaq"], index, 20)
        return (sp20 is not None and sp20 < -0.07) or (nd20 is not None and nd20 < -0.09)
    return Guard("daily_equity_shock_exit_partial_trigger", "Exit only when high equity exposure meets a stronger daily shock trigger.", should_exit)


def guard_portfolio_airbag() -> Guard:
    def should_exit(index, prices, weights, points, dates):
        if equity_exposure(weights) <= 0.20 or len(points) < 20:
            return False
        peak = max(points[-20:])
        curve_dd = points[-1] / peak - 1 if peak > 0 else 0
        sp20 = app.price_momentum(prices["sp500"], index, 20)
        # Mechanism: use the strategy's own equity curve as an airbag. Exit only
        # when portfolio drawdown and broad market weakness agree.
        return curve_dd < -0.035 and sp20 is not None and sp20 < -0.03
    return Guard("portfolio_airbag_exit", "Exit equity only when portfolio drawdown confirms market weakness.", should_exit)


def all_guards() -> list[Guard]:
    return [guard_equity_shock(), guard_equity_shock_partial(), guard_portfolio_airbag()]


def run_with_guard(guard: Guard | None) -> app.BacktestResult:
    raw = app.fetch_public_history(end_date=app.parse_date("2026-06-19"))
    prepared = app.prepare_series(raw)
    dates, prices_by_symbol = app.align_rotation_price_series(prepared)
    symbols = [p.symbol for p in prepared]
    config = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")
    ma_by_symbol, vol_by_symbol = app.indicator_maps(prices_by_symbol, config)

    meta_traces = None
    if config.meta_switch:
        meta_traces = {
            config.meta_switch.default_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.default_mode)),
            config.meta_switch.defensive_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.defensive_mode)),
        }

    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    tradable_symbols = [s for s in symbols if s not in config.signal_only_symbols]
    units = {s: 0.0 for s in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []
    weights: dict[str, float] = {}

    def portfolio_value(index: int) -> float:
        return cash + sum(units[s] * prices_by_symbol[s][index] for s in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        if config.meta_switch and meta_traces is not None:
            raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, meta_traces)
            if raw_weights is None:
                return {}
            return base_guarded_target(raw_weights, signal_index, dates[signal_index], prices_by_symbol, points, config)
        raw = app.advanced_rotation_target_weights(symbols, prices_by_symbol, ma_by_symbol, vol_by_symbol, signal_index, dates[signal_index], config)
        return base_guarded_target(raw, signal_index, dates[signal_index], prices_by_symbol, points, config)

    def rebalance_to(index: int, targets: dict[str, float]) -> None:
        nonlocal cash, held, weights
        targets = normalize(targets)
        pre_value = portfolio_value(index)
        target_symbols = set(targets.keys())
        for sym in sorted(held - target_symbols):
            price = prices_by_symbol[sym][index]
            current_units = units.get(sym, 0.0)
            if current_units <= 0:
                continue
            execution_price = max(price * (1 - slippage_rate), 0.0)
            gross = current_units * execution_price
            cash_amount = gross * (1 - fee_rate)
            cash += cash_amount
            units[sym] = 0.0
            trades.append(app.Trade(dates[index].isoformat(), "sell", sym, execution_price, cash_amount, current_units))
        held &= target_symbols

        for sym in sorted(target_symbols):
            current_units = units.get(sym, 0.0)
            if current_units <= 0:
                continue
            price = prices_by_symbol[sym][index]
            current_value = current_units * price
            target_value = pre_value * targets[sym]
            gross_to_sell = max(current_value - target_value, 0.0) if current_value > target_value else 0.0
            if gross_to_sell <= 0:
                continue
            units_to_sell = min(current_units, gross_to_sell / price)
            execution_price = max(price * (1 - slippage_rate), 0.0)
            gross = units_to_sell * execution_price
            cash_amount = gross * (1 - fee_rate)
            cash += cash_amount
            units[sym] = max(current_units - units_to_sell, 0.0)
            trades.append(app.Trade(dates[index].isoformat(), "sell", sym, execution_price, cash_amount, units_to_sell))
            if units[sym] <= 1e-12:
                held.discard(sym)

        total_value = portfolio_value(index)
        for sym in sorted(target_symbols):
            price = prices_by_symbol[sym][index]
            current_value = units.get(sym, 0.0) * price
            target_value = total_value * targets[sym]
            amount = min(cash, max(target_value - current_value, 0.0)) if current_value < target_value else 0.0
            if amount <= 0:
                continue
            execution_price = price * (1 + slippage_rate)
            invested = amount * (1 - fee_rate)
            bought_units = invested / execution_price
            units[sym] = units.get(sym, 0.0) + bought_units
            cash -= amount
            held.add(sym)
            trades.append(app.Trade(dates[index].isoformat(), "buy", sym, execution_price, amount, bought_units))
        weights = dict(targets)

    for index, current_date in enumerate(dates):
        if index > 0 and cash > 0:
            cash += cash * app.cash_daily_return(dates[index - 1])

        if index == 0 or index % max(config.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = target_weights(signal_index, index) if signal_index >= 0 else {}
            rebalance_to(index, targets)
        elif guard is not None and guard.should_exit_equity(index, prices_by_symbol, weights, points, dates):
            # Daily airbag: sell equities only; keep gold if present and already
            # protected by the separate gold blowoff guard.
            reduced = {sym: weight for sym, weight in weights.items() if sym not in app.EQUITY_SYMBOLS}
            rebalance_to(index, reduced)

        points.append(portfolio_value(index))

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, points)
    return app.BacktestResult(
        strategy=guard.name if guard else "gold_blowoff_rollover_reference",
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


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "total": None}
    total, annualized, max_dd, _vol, _sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "total": total}


def max_drawdown_window(result: app.BacktestResult) -> dict[str, object]:
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


def summarize(result: app.BacktestResult, thesis: str) -> dict[str, object]:
    return {
        "name": result.strategy,
        "thesis": thesis,
        "full": {
            "annualized": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "total": result.total_return,
            "sharpe": result.sharpe_ratio,
            "trades": len(result.trades),
            "final_value": result.final_value,
        },
        "slices": {
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-19"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(t.date, t.action, t.symbol, round(t.cash_amount, 2)) for t in result.trades[-10:]],
    }


def main() -> None:
    rows = [summarize(run_with_guard(None), "Reference: gold blowoff rollover cap only.")]
    for guard in all_guards():
        rows.append(summarize(run_with_guard(guard), guard.thesis))
    rows.sort(key=lambda row: (row["full"]["max_drawdown"] <= 0.10, row["full"]["annualized"]), reverse=True)  # type: ignore[index, operator]
    print(json.dumps(rows, ensure_ascii=False, indent=2))
    print("\nSUMMARY")
    print("name | full ann/dd | post2020 ann/dd | last10 ann/dd | post2024 ann/dd | trades | dd window")
    for row in rows:
        full: dict[str, Any] = row["full"]  # type: ignore[assignment]
        slices: dict[str, dict[str, Any]] = row["slices"]  # type: ignore[assignment]
        ddw: dict[str, Any] = row["drawdown_window"]  # type: ignore[assignment]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{pct(slices['post_2020']['max_drawdown'])} | "
            f"{pct(slices['last_10y']['annualized'])}/{pct(slices['last_10y']['max_drawdown'])} | "
            f"{pct(slices['post_2024']['annualized'])}/{pct(slices['post_2024']['max_drawdown'])} | "
            f"{full['trades']} | {ddw['peak_date']}→{ddw['trough_date']}"
        )


if __name__ == "__main__":
    main()
