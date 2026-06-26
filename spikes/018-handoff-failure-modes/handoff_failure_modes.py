#!/usr/bin/env python3
"""Diagnose and test logic-first improvements to gold handoff.

This spike compares a few interpretable overlays on top of the current
App-equivalent champion:

- base gold blowoff rollover cap;
- confirmed US handoff.

The goal is to understand the remaining 2007 drawdown and test whether a more
selective handoff can improve the return/drawdown frontier without broad
parameter fitting.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, replace
from datetime import date, datetime
import json
from pathlib import Path
import sys
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402
import atm_new_logic_explorer as logic  # noqa: E402
import atm_strategy_explorer as base_explorer  # noqa: E402

Overlay = Callable[[dict[str, float], int, date, dict[str, list[float]], list[float] | None, app.Config], dict[str, float]]


@dataclass(frozen=True)
class CandidateSpec:
    name: str
    thesis: str
    overlay_factory: Callable[[Overlay], Overlay]
    rebalance_sessions: int | None = None
    adaptive_min_gap_sessions: int | None = None


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "total": None}
    total, annualized, max_dd, _vol, _sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "total": total}


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
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = i
    return {
        "peak_index": worst_peak,
        "trough_index": worst_trough,
        "peak_date": result.dates[worst_peak].isoformat(),
        "trough_date": result.dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


def result_summary(result: app.BacktestResult) -> dict[str, Any]:
    return {
        "annualized": result.annualized_return,
        "max_drawdown": result.max_drawdown,
        "total": result.total_return,
        "sharpe": result.sharpe_ratio,
        "trades": len(result.trades),
        "final_value": result.final_value,
        "coverage_start": result.coverage_start,
        "coverage_end": result.coverage_end,
    }


def price_drawdown(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0:
        return None
    window = prices_by_symbol[symbol][index - lookback + 1:index + 1]
    peak = max(window)
    if peak <= 0:
        return None
    return prices_by_symbol[symbol][index] / peak - 1


def rolling_vol(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int) -> float | None:
    values = prices_by_symbol[symbol]
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for i in range(index - lookback + 1, index + 1):
        if values[i - 1] > 0 and values[i] > 0:
            returns.append(app.math.log(values[i] / values[i - 1]))
    if len(returns) < 2:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return app.math.sqrt(variance) * app.math.sqrt(app.TRADING_DAYS_PER_YEAR)


def us_confirmed(prices_by_symbol: dict[str, list[float]], symbol: str, signal_index: int) -> bool:
    return (
        (logic.mom(prices_by_symbol, symbol, signal_index, 60) or -1.0) > 0
        and logic.above_ma(prices_by_symbol, symbol, signal_index, 120)
    )


def gold_rollover_active(prices_by_symbol: dict[str, list[float]], signal_index: int) -> bool:
    return (
        (logic.mom(prices_by_symbol, "gold_cny", signal_index, 90) or 0.0) > 0.08
        and (logic.mom(prices_by_symbol, "gold_cny", signal_index, 20) or 0.0) < 0
    )


def china_mania_veto(prices_by_symbol: dict[str, list[float]], signal_index: int) -> bool:
    return any(
        (logic.mom(prices_by_symbol, symbol, signal_index, 240) or 0.0) > 1.0
        and (app.donchian_range_position(prices_by_symbol[symbol], signal_index, 240) or 0.0) > 0.95
        for symbol in ["csi300", "shanghai_composite"]
    )


def regional_heat(
    prices_by_symbol: dict[str, list[float]],
    symbols: list[str],
    signal_index: int,
    *,
    momentum_lookback: int,
    momentum_threshold: float,
    donchian_lookback: int,
    donchian_threshold: float,
) -> bool:
    for symbol in symbols:
        long = logic.mom(prices_by_symbol, symbol, signal_index, momentum_lookback)
        donchian = app.donchian_range_position(prices_by_symbol[symbol], signal_index, donchian_lookback)
        if (
            long is not None
            and donchian is not None
            and long > momentum_threshold
            and donchian > donchian_threshold
        ):
            return True
    return False


def handoff_symbol(prices_by_symbol: dict[str, list[float]], signal_index: int) -> str | None:
    candidates = []
    for symbol in ["nasdaq", "sp500"]:
        if us_confirmed(prices_by_symbol, symbol, signal_index):
            candidates.append((logic.mom(prices_by_symbol, symbol, signal_index, 60) or 0.0, symbol))
    if not candidates:
        return None
    return max(candidates)[1]


def mechanism_handoff_both_us_confirm(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if not gold_rollover_active(prices_by_symbol, signal_index) or china_mania_veto(prices_by_symbol, signal_index):
            return logic.normalize_total(weights)
        if not (us_confirmed(prices_by_symbol, "nasdaq", signal_index) and us_confirmed(prices_by_symbol, "sp500", signal_index)):
            return logic.normalize_total(weights)
        symbol = handoff_symbol(prices_by_symbol, signal_index)
        if symbol:
            weights[symbol] = weights.get(symbol, 0.0) + 0.20
        return logic.normalize_total(weights)
    return overlay


def mechanism_handoff_sp500_anchor(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if not gold_rollover_active(prices_by_symbol, signal_index) or china_mania_veto(prices_by_symbol, signal_index):
            return logic.normalize_total(weights)
        sp_ok = us_confirmed(prices_by_symbol, "sp500", signal_index)
        nd_ok = us_confirmed(prices_by_symbol, "nasdaq", signal_index)
        if not (sp_ok or nd_ok):
            return logic.normalize_total(weights)
        sp_mom = logic.mom(prices_by_symbol, "sp500", signal_index, 60) or 0.0
        nd_mom = logic.mom(prices_by_symbol, "nasdaq", signal_index, 60) or 0.0
        symbol = "nasdaq" if nd_ok and nd_mom > sp_mom + 0.05 else "sp500"
        weights[symbol] = weights.get(symbol, 0.0) + 0.20
        return logic.normalize_total(weights)
    return overlay


def mechanism_handoff_quality_filter(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if not gold_rollover_active(prices_by_symbol, signal_index) or china_mania_veto(prices_by_symbol, signal_index):
            return logic.normalize_total(weights)
        symbol = handoff_symbol(prices_by_symbol, signal_index)
        if not symbol:
            return logic.normalize_total(weights)
        dd = price_drawdown(prices_by_symbol, symbol, signal_index, 60)
        short = logic.mom(prices_by_symbol, symbol, signal_index, 20)
        vol = rolling_vol(prices_by_symbol, symbol, signal_index, 30)
        if dd is None or short is None or vol is None:
            return logic.normalize_total(weights)
        if dd < -0.06 or short < -0.02 or vol > 0.24:
            return logic.normalize_total(weights)
        weights[symbol] = weights.get(symbol, 0.0) + 0.20
        return logic.normalize_total(weights)
    return overlay


def mechanism_turbulence_equity_cap(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        sp_turbulent = (
            (logic.mom(prices_by_symbol, "sp500", signal_index, 20) or 0.0) < -0.025
            or not logic.above_ma(prices_by_symbol, "sp500", signal_index, 60)
        )
        nd_turbulent = (
            (logic.mom(prices_by_symbol, "nasdaq", signal_index, 20) or 0.0) < -0.035
            or (price_drawdown(prices_by_symbol, "nasdaq", signal_index, 60) or 0.0) < -0.07
        )
        if logic.equity_exposure(weights) > 0.45 and sp_turbulent and nd_turbulent:
            weights = logic.cap_group(weights, app.EQUITY_SYMBOLS, 0.42)
        return logic.normalize_total(weights)
    return overlay


def mechanism_gold_or_sp500_handoff(original: Overlay) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if not gold_rollover_active(prices_by_symbol, signal_index) or china_mania_veto(prices_by_symbol, signal_index):
            return logic.normalize_total(weights)
        if us_confirmed(prices_by_symbol, "sp500", signal_index):
            weights["sp500"] = weights.get("sp500", 0.0) + 0.20
        return logic.normalize_total(weights)
    return overlay


def mechanism_china_heat_cluster_cap(
    original: Overlay,
    *,
    cluster_cap: float,
    momentum_lookback: int,
    momentum_threshold: float,
    donchian_threshold: float,
) -> Overlay:
    china_symbols = ["csi300", "shanghai_composite"]

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if not any(weights.get(symbol, 0.0) > 0 for symbol in china_symbols):
            return logic.normalize_total(weights)
        if regional_heat(
            prices_by_symbol,
            china_symbols,
            signal_index,
            momentum_lookback=momentum_lookback,
            momentum_threshold=momentum_threshold,
            donchian_lookback=240,
            donchian_threshold=donchian_threshold,
        ):
            weights = logic.cap_group(weights, china_symbols, cluster_cap)
        return logic.normalize_total(weights)

    return overlay


def mechanism_extreme_equity_heat_total_cap(
    original: Overlay,
    *,
    equity_cap: float,
    momentum_threshold: float,
    donchian_threshold: float,
) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if logic.equity_exposure(weights) <= equity_cap:
            return logic.normalize_total(weights)
        if regional_heat(
            prices_by_symbol,
            app.EQUITY_SYMBOLS,
            signal_index,
            momentum_lookback=240,
            momentum_threshold=momentum_threshold,
            donchian_lookback=240,
            donchian_threshold=donchian_threshold,
        ):
            weights = logic.cap_group(weights, app.EQUITY_SYMBOLS, equity_cap)
        return logic.normalize_total(weights)

    return overlay


def mechanism_gold_heat_cap(
    original: Overlay,
    *,
    gold_cap: float,
    momentum_lookback: int,
    momentum_threshold: float,
    donchian_threshold: float,
) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if weights.get("gold_cny", 0.0) <= gold_cap:
            return logic.normalize_total(weights)
        gold_hot = regional_heat(
            prices_by_symbol,
            ["gold_cny"],
            signal_index,
            momentum_lookback=momentum_lookback,
            momentum_threshold=momentum_threshold,
            donchian_lookback=240,
            donchian_threshold=donchian_threshold,
        )
        if gold_hot:
            weights = logic.cap_group(weights, ["gold_cny"], gold_cap)
        return logic.normalize_total(weights)

    return overlay


def mechanism_regional_bubble_cooldown(
    original: Overlay,
    *,
    cooldown_sessions: int,
    equity_cap: float,
    trigger_momentum: float,
    short_threshold: float,
) -> Overlay:
    state = {"until": -1}

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        bubble_rollover = False
        for symbol in ["csi300", "shanghai_composite", "nasdaq"]:
            long = logic.mom(prices_by_symbol, symbol, signal_index, 240)
            short = logic.mom(prices_by_symbol, symbol, signal_index, 20)
            donchian = app.donchian_range_position(prices_by_symbol[symbol], signal_index, 240)
            if (
                long is not None
                and short is not None
                and donchian is not None
                and long > trigger_momentum
                and short < short_threshold
                and donchian > 0.82
            ):
                bubble_rollover = True
                break
        if bubble_rollover:
            state["until"] = max(state["until"], signal_index + cooldown_sessions)

        if signal_index <= state["until"] and logic.equity_exposure(weights) > equity_cap:
            weights = logic.cap_group(weights, app.EQUITY_SYMBOLS, equity_cap)
        return logic.normalize_total(weights)

    return overlay


def mechanism_equity_heat_memory_cap(
    original: Overlay,
    *,
    cooldown_sessions: int,
    equity_cap: float,
    momentum_threshold: float,
    donchian_threshold: float,
) -> Overlay:
    state = {"until": -1}

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if regional_heat(
            prices_by_symbol,
            app.EQUITY_SYMBOLS,
            signal_index,
            momentum_lookback=240,
            momentum_threshold=momentum_threshold,
            donchian_lookback=240,
            donchian_threshold=donchian_threshold,
        ):
            state["until"] = max(state["until"], signal_index + cooldown_sessions)

        if signal_index <= state["until"] and logic.equity_exposure(weights) > equity_cap:
            weights = logic.cap_group(weights, app.EQUITY_SYMBOLS, equity_cap)
        return logic.normalize_total(weights)

    return overlay


def mechanism_regional_bubble_sp500_reentry(
    original: Overlay,
    *,
    cooldown_sessions: int,
    equity_cap: float,
) -> Overlay:
    state = {"until": -1}

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        china_bubble_rollover = False
        for symbol in ["csi300", "shanghai_composite"]:
            long = logic.mom(prices_by_symbol, symbol, signal_index, 240)
            short = logic.mom(prices_by_symbol, symbol, signal_index, 20)
            donchian = app.donchian_range_position(prices_by_symbol[symbol], signal_index, 240)
            if (
                long is not None
                and short is not None
                and donchian is not None
                and long > 0.80
                and short < 0
                and donchian > 0.80
            ):
                china_bubble_rollover = True
                break
        if china_bubble_rollover:
            state["until"] = max(state["until"], signal_index + cooldown_sessions)

        if signal_index <= state["until"]:
            equity_cut = 0.0
            out = dict(weights)
            for symbol in ["nasdaq", "csi300", "shanghai_composite"]:
                equity_cut += max(out.get(symbol, 0.0), 0.0)
                out[symbol] = 0.0
            if us_confirmed(prices_by_symbol, "sp500", signal_index):
                out["sp500"] = min(max(out.get("sp500", 0.0), 0.0) + equity_cut * 0.5, equity_cap)
            weights = logic.cap_group(out, app.EQUITY_SYMBOLS, equity_cap)
        return logic.normalize_total(weights)

    return overlay


def mechanism_equity_entry_ramp(
    original: Overlay,
    *,
    low_exposure_threshold: float,
    high_exposure_threshold: float,
    first_step_cap: float,
    second_step_cap: float,
) -> Overlay:
    state = {"last_exposure": 0.0, "ramp_left": 0}

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        exposure = logic.equity_exposure(weights)
        if state["last_exposure"] <= low_exposure_threshold and exposure >= high_exposure_threshold:
            state["ramp_left"] = 2

        if state["ramp_left"] == 2 and exposure > first_step_cap:
            weights = logic.cap_group(weights, app.EQUITY_SYMBOLS, first_step_cap)
        elif state["ramp_left"] == 1 and exposure > second_step_cap:
            weights = logic.cap_group(weights, app.EQUITY_SYMBOLS, second_step_cap)

        state["last_exposure"] = logic.equity_exposure(weights)
        if state["ramp_left"] > 0:
            state["ramp_left"] -= 1
        return logic.normalize_total(weights)

    return overlay


def mechanism_equity_trailing_turbulence(original: Overlay, *, drawdown_cap: float, equity_cap: float) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = original(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if logic.equity_exposure(weights) <= equity_cap:
            return logic.normalize_total(weights)
        bad_count = 0
        for symbol in ["nasdaq", "sp500"]:
            dd = price_drawdown(prices_by_symbol, symbol, signal_index, 60)
            short = logic.mom(prices_by_symbol, symbol, signal_index, 20)
            if (dd is not None and dd < -drawdown_cap) or (short is not None and short < -0.03):
                bad_count += 1
        if bad_count >= 1 and not us_confirmed(prices_by_symbol, "sp500", signal_index):
            weights = logic.cap_group(weights, app.EQUITY_SYMBOLS, equity_cap)
        return logic.normalize_total(weights)
    return overlay


def compose(*factories: Callable[[Overlay], Overlay]) -> Callable[[Overlay], Overlay]:
    def composed(original: Overlay) -> Overlay:
        overlay = original
        for factory in factories:
            overlay = factory(overlay)
        return overlay
    return composed


def current_weight_map(
    units: dict[str, float],
    cash: float,
    prices_by_symbol: dict[str, list[float]],
    tradable_symbols: list[str],
    index: int,
) -> dict[str, float]:
    total = cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)
    if total <= 0:
        return {}
    return {
        symbol: units.get(symbol, 0.0) * prices_by_symbol[symbol][index] / total
        for symbol in tradable_symbols
        if units.get(symbol, 0.0) > 0
    }


def adaptive_heat_rebalance_needed(
    current_weights: dict[str, float],
    signal_index: int,
    prices_by_symbol: dict[str, list[float]],
) -> bool:
    if signal_index <= 0:
        return False
    gold_weight = current_weights.get("gold_cny", 0.0)
    if gold_weight > 0.70 and regional_heat(
        prices_by_symbol,
        ["gold_cny"],
        signal_index,
        momentum_lookback=90,
        momentum_threshold=0.08,
        donchian_lookback=240,
        donchian_threshold=0.88,
    ):
        return True

    if logic.equity_exposure(current_weights) > 0.50 and regional_heat(
        prices_by_symbol,
        app.EQUITY_SYMBOLS,
        signal_index,
        momentum_lookback=240,
        momentum_threshold=0.65,
        donchian_lookback=240,
        donchian_threshold=0.88,
    ):
        return True

    return False


def run_adaptive_rebalance_strategy(overlay_factory: Callable[[Overlay], Overlay], min_gap_sessions: int) -> app.BacktestResult:
    raw = app.fetch_public_history(end_date=app.parse_date("2026-06-19"))
    prepared = app.prepare_series(raw)
    dates, prices_by_symbol = app.align_rotation_price_series(prepared)
    symbols = [series.symbol for series in prepared]
    config = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")
    ma_by_symbol, vol_by_symbol = app.indicator_maps(prices_by_symbol, config)

    meta_traces: dict[str, app.SimulatedTrace] | None = None
    if config.meta_switch:
        meta_traces = {
            config.meta_switch.default_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.default_mode)),
            config.meta_switch.defensive_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.defensive_mode)),
        }

    cash = 100_000.0
    fee_rate = 0.10 / 100.0
    slippage_rate = 0.05 / 100.0
    band = max(config.rebalance_band, 0.0)
    tradable_symbols = [symbol for symbol in symbols if symbol not in config.signal_only_symbols]
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []
    last_rebalance_index = -10**9

    gold_guard = base_explorer.make_gold_blowoff_rollover_overlay(
        cap=0.45,
        long_lookback=90,
        long_threshold=0.08,
        short_lookback=20,
    )
    overlay = overlay_factory(gold_guard)

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        if config.meta_switch and meta_traces is not None:
            raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, meta_traces)
            if raw_weights is None:
                return {}
            return overlay(raw_weights, signal_index, dates[signal_index], prices_by_symbol, points, config)
        return app.advanced_rotation_target_weights(symbols, prices_by_symbol, ma_by_symbol, vol_by_symbol, signal_index, dates[signal_index], config)

    for index, current_date in enumerate(dates):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if app.math.isfinite(interest) and interest > 0:
                cash += interest

        rebalance_sessions = max(config.rebalance_sessions, 1)
        signal_index = index - 1
        current_weights = current_weight_map(units, cash, prices_by_symbol, tradable_symbols, index)
        enough_gap = index - last_rebalance_index >= max(min_gap_sessions, 1)
        scheduled = (index == 0 or index % rebalance_sessions == 0) and (index == 0 or enough_gap)
        heat_rebalance = (
            signal_index >= 0
            and enough_gap
            and adaptive_heat_rebalance_needed(current_weights, signal_index, prices_by_symbol)
        )

        if scheduled or heat_rebalance:
            pre_value = portfolio_value(index)
            base_targets = target_weights(signal_index, index) if signal_index >= 0 else {}
            targets = base_targets if config.meta_switch else app.apply_portfolio_guard(base_targets, pre_value, points, config)
            target_symbols = set(targets.keys())

            for symbol in sorted(held - target_symbols):
                price = prices_by_symbol[symbol][index]
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                execution_price = max(price * (1 - slippage_rate), 0.0)
                gross = current_units * execution_price
                cash_amount = gross * (1 - fee_rate)
                cash += cash_amount
                units[symbol] = 0.0
                trades.append(app.Trade(current_date.isoformat(), "sell", symbol, execution_price, cash_amount, current_units))
            held &= target_symbols

            for symbol in sorted(target_symbols):
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                price = prices_by_symbol[symbol][index]
                current_value = current_units * price
                target_value = pre_value * targets[symbol]
                gross_to_sell = max(current_value - target_value, 0.0) if current_value > target_value * (1 + band) else 0.0
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
                trades.append(app.Trade(current_date.isoformat(), "sell", symbol, execution_price, cash_amount, units_to_sell))
                if units[symbol] <= sys.float_info.min:
                    held.discard(symbol)

            total_value = portfolio_value(index)
            for symbol in sorted(target_symbols):
                price = prices_by_symbol[symbol][index]
                if price <= 0:
                    continue
                current_value = units.get(symbol, 0.0) * price
                target_value = total_value * targets[symbol]
                amount = min(cash, max(target_value - current_value, 0.0)) if current_value < target_value * (1 - band) else 0.0
                if amount <= 0:
                    continue
                execution_price = price * (1 + slippage_rate)
                invested = amount * (1 - fee_rate)
                bought_units = invested / execution_price if execution_price > 0 else 0.0
                units[symbol] = units.get(symbol, 0.0) + bought_units
                cash -= amount
                held.add(symbol)
                trades.append(app.Trade(current_date.isoformat(), "buy", symbol, execution_price, amount, bought_units))
            last_rebalance_index = index

        points.append(portfolio_value(index))

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, points)
    return app.BacktestResult(
        strategy=f"adaptive_heat_rebalance_{min_gap_sessions}",
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


def candidate_specs() -> list[CandidateSpec]:
    return [
        CandidateSpec(
            "current_gold_handoff",
            "Current strongest: cap gold rollover, then hand 20% to the stronger confirmed US asset.",
            logic.mechanism_gold_to_confirmed_us_handoff,
        ),
        CandidateSpec(
            "handoff_both_us_confirm",
            "Only hand off when both Nasdaq and S&P confirm, reducing single-market false positives.",
            mechanism_handoff_both_us_confirm,
        ),
        CandidateSpec(
            "handoff_sp500_anchor",
            "Prefer S&P as the handoff asset unless Nasdaq has a clear 5pp momentum edge.",
            mechanism_handoff_sp500_anchor,
        ),
        CandidateSpec(
            "current_handoff_rebalance45",
            "Keep current handoff logic, but rebalance every 45 sessions to reduce stale crowded exposures.",
            logic.mechanism_gold_to_confirmed_us_handoff,
            rebalance_sessions=45,
        ),
        CandidateSpec(
            "current_handoff_rebalance30",
            "Keep current handoff logic, but rebalance every 30 sessions to test whether cadence is the real failure mode.",
            logic.mechanism_gold_to_confirmed_us_handoff,
            rebalance_sessions=30,
        ),
        CandidateSpec(
            "current_handoff_rebalance20",
            "Keep current handoff logic, but rebalance every 20 sessions as an upper-bound cadence test.",
            logic.mechanism_gold_to_confirmed_us_handoff,
            rebalance_sessions=20,
        ),
        CandidateSpec(
            "handoff_quality_filter",
            "Require the replacement US asset to avoid short-term drawdown, weak 20-day momentum, and volatility spikes.",
            mechanism_handoff_quality_filter,
        ),
        CandidateSpec(
            "turbulence_equity_cap",
            "After regular handoff, cap all equities if both S&P and Nasdaq show short-term turbulence.",
            lambda original: mechanism_turbulence_equity_cap(logic.mechanism_gold_to_confirmed_us_handoff(original)),
        ),
        CandidateSpec(
            "gold_or_sp500_handoff",
            "Use S&P as the only handoff target; if S&P is not confirmed, leave the released budget in cash.",
            mechanism_gold_or_sp500_handoff,
        ),
        CandidateSpec(
            "china_heat_cluster_cap42",
            "When A-share heat is extreme, cap the China equity cluster at 42% while leaving other confirmed sleeves untouched.",
            lambda original: mechanism_china_heat_cluster_cap(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                cluster_cap=0.42,
                momentum_lookback=240,
                momentum_threshold=0.55,
                donchian_threshold=0.88,
            ),
        ),
        CandidateSpec(
            "china_heat_cluster_cap35",
            "A stricter A-share heat cap: no more than 35% in the China equity cluster during extreme heat.",
            lambda original: mechanism_china_heat_cluster_cap(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                cluster_cap=0.35,
                momentum_lookback=240,
                momentum_threshold=0.55,
                donchian_threshold=0.88,
            ),
        ),
        CandidateSpec(
            "extreme_equity_heat_total_cap50",
            "If any equity cluster is in extreme long-term heat, cap total equity exposure at 50%.",
            lambda original: mechanism_extreme_equity_heat_total_cap(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                equity_cap=0.50,
                momentum_threshold=0.65,
                donchian_threshold=0.88,
            ),
        ),
        CandidateSpec(
            "gold_heat_cap70",
            "When gold is already crowded and near its one-year high, cap gold at 70% before rollover confirmation.",
            lambda original: mechanism_gold_heat_cap(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                gold_cap=0.70,
                momentum_lookback=90,
                momentum_threshold=0.08,
                donchian_threshold=0.88,
            ),
        ),
        CandidateSpec(
            "gold_heat_cap60",
            "A stricter crowded-gold cap: max 60% gold when momentum heat and range position are both high.",
            lambda original: mechanism_gold_heat_cap(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                gold_cap=0.60,
                momentum_lookback=90,
                momentum_threshold=0.08,
                donchian_threshold=0.88,
            ),
        ),
        CandidateSpec(
            "gold_position_cap75",
            "Position-first crowded-gold cap: if gold is near a one-year high with moderate 90-day momentum, cap at 75%.",
            lambda original: mechanism_gold_heat_cap(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                gold_cap=0.75,
                momentum_lookback=90,
                momentum_threshold=0.05,
                donchian_threshold=0.95,
            ),
        ),
        CandidateSpec(
            "gold_position_cap70",
            "Stricter position-first crowded-gold cap: same trigger, cap at 70%.",
            lambda original: mechanism_gold_heat_cap(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                gold_cap=0.70,
                momentum_lookback=90,
                momentum_threshold=0.05,
                donchian_threshold=0.95,
            ),
        ),
        CandidateSpec(
            "dual_heat_caps_eq50_gold70",
            "Cap extreme equity heat at 50% and crowded gold at 70%, covering both exposed max-drawdown modes.",
            compose(
                lambda original: logic.mechanism_gold_to_confirmed_us_handoff(original),
                lambda original: mechanism_extreme_equity_heat_total_cap(
                    original,
                    equity_cap=0.50,
                    momentum_threshold=0.65,
                    donchian_threshold=0.88,
                ),
                lambda original: mechanism_gold_heat_cap(
                    original,
                    gold_cap=0.70,
                    momentum_lookback=90,
                    momentum_threshold=0.08,
                    donchian_threshold=0.88,
                ),
            ),
        ),
        CandidateSpec(
            "dual_position_caps_eq50_gold75",
            "Combine equity extreme-heat cap with a position-first gold cap at 75%.",
            compose(
                lambda original: logic.mechanism_gold_to_confirmed_us_handoff(original),
                lambda original: mechanism_extreme_equity_heat_total_cap(
                    original,
                    equity_cap=0.50,
                    momentum_threshold=0.65,
                    donchian_threshold=0.88,
                ),
                lambda original: mechanism_gold_heat_cap(
                    original,
                    gold_cap=0.75,
                    momentum_lookback=90,
                    momentum_threshold=0.05,
                    donchian_threshold=0.95,
                ),
            ),
        ),
        CandidateSpec(
            "dual_position_caps_eq50_gold70",
            "Combine equity extreme-heat cap with a stricter position-first gold cap at 70%.",
            compose(
                lambda original: logic.mechanism_gold_to_confirmed_us_handoff(original),
                lambda original: mechanism_extreme_equity_heat_total_cap(
                    original,
                    equity_cap=0.50,
                    momentum_threshold=0.65,
                    donchian_threshold=0.88,
                ),
                lambda original: mechanism_gold_heat_cap(
                    original,
                    gold_cap=0.70,
                    momentum_lookback=90,
                    momentum_threshold=0.05,
                    donchian_threshold=0.95,
                ),
            ),
        ),
        CandidateSpec(
            "dual_heat_caps_rebalance30",
            "Combine dual heat caps with 30-session rebalance to test whether earlier action fixes the remaining heat failure.",
            compose(
                lambda original: logic.mechanism_gold_to_confirmed_us_handoff(original),
                lambda original: mechanism_extreme_equity_heat_total_cap(
                    original,
                    equity_cap=0.50,
                    momentum_threshold=0.65,
                    donchian_threshold=0.88,
                ),
                lambda original: mechanism_gold_heat_cap(
                    original,
                    gold_cap=0.70,
                    momentum_lookback=90,
                    momentum_threshold=0.08,
                    donchian_threshold=0.88,
                ),
            ),
            rebalance_sessions=30,
        ),
        CandidateSpec(
            "adaptive_heat_rebalance20",
            "Keep the 60-session rhythm, but allow a heat-triggered early rebalance after 20 sessions when held risk is crowded.",
            compose(
                lambda original: logic.mechanism_gold_to_confirmed_us_handoff(original),
                lambda original: mechanism_extreme_equity_heat_total_cap(
                    original,
                    equity_cap=0.50,
                    momentum_threshold=0.65,
                    donchian_threshold=0.88,
                ),
                lambda original: mechanism_gold_heat_cap(
                    original,
                    gold_cap=0.70,
                    momentum_lookback=90,
                    momentum_threshold=0.08,
                    donchian_threshold=0.88,
                ),
            ),
            adaptive_min_gap_sessions=20,
        ),
        CandidateSpec(
            "adaptive_heat_rebalance30",
            "A slower adaptive variant: only allow heat-triggered early rebalance after at least 30 sessions.",
            compose(
                lambda original: logic.mechanism_gold_to_confirmed_us_handoff(original),
                lambda original: mechanism_extreme_equity_heat_total_cap(
                    original,
                    equity_cap=0.50,
                    momentum_threshold=0.65,
                    donchian_threshold=0.88,
                ),
                lambda original: mechanism_gold_heat_cap(
                    original,
                    gold_cap=0.70,
                    momentum_lookback=90,
                    momentum_threshold=0.08,
                    donchian_threshold=0.88,
                ),
            ),
            adaptive_min_gap_sessions=30,
        ),
        CandidateSpec(
            "dual_heat_caps_eq50_gold60",
            "Stricter dual heat caps: 50% for overheated equities and 60% for crowded gold.",
            compose(
                lambda original: logic.mechanism_gold_to_confirmed_us_handoff(original),
                lambda original: mechanism_extreme_equity_heat_total_cap(
                    original,
                    equity_cap=0.50,
                    momentum_threshold=0.65,
                    donchian_threshold=0.88,
                ),
                lambda original: mechanism_gold_heat_cap(
                    original,
                    gold_cap=0.60,
                    momentum_lookback=90,
                    momentum_threshold=0.08,
                    donchian_threshold=0.88,
                ),
            ),
        ),
        CandidateSpec(
            "regional_bubble_cooldown_80_eq35",
            "After a regional equity bubble rolls over, cap all equity exposure to 35% for 80 sessions.",
            lambda original: mechanism_regional_bubble_cooldown(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                cooldown_sessions=80,
                equity_cap=0.35,
                trigger_momentum=0.80,
                short_threshold=0.0,
            ),
        ),
        CandidateSpec(
            "regional_bubble_cooldown_60_eq45",
            "After a regional equity bubble rolls over, cap all equity exposure to 45% for 60 sessions.",
            lambda original: mechanism_regional_bubble_cooldown(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                cooldown_sessions=60,
                equity_cap=0.45,
                trigger_momentum=0.80,
                short_threshold=0.0,
            ),
        ),
        CandidateSpec(
            "regional_bubble_sp500_reentry",
            "After A-share bubble rollover, do not rotate directly into Nasdaq or A-shares; stage reentry through confirmed S&P.",
            lambda original: mechanism_regional_bubble_sp500_reentry(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                cooldown_sessions=80,
                equity_cap=0.45,
            ),
        ),
        CandidateSpec(
            "equity_heat_memory_120_eq45",
            "After extreme equity heat appears, keep total equity exposure capped at 45% for 120 sessions.",
            lambda original: mechanism_equity_heat_memory_cap(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                cooldown_sessions=120,
                equity_cap=0.45,
                momentum_threshold=0.65,
                donchian_threshold=0.88,
            ),
        ),
        CandidateSpec(
            "entry_ramp_after_low_risk",
            "When equity exposure jumps from low risk to high risk, enter in two rebalance steps instead of all at once.",
            lambda original: mechanism_equity_entry_ramp(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                low_exposure_threshold=0.30,
                high_exposure_threshold=0.55,
                first_step_cap=0.42,
                second_step_cap=0.55,
            ),
        ),
        CandidateSpec(
            "china_heat_cap_plus_entry_ramp",
            "Combine A-share extreme heat cap with staged equity reentry after low-risk periods.",
            compose(
                lambda original: logic.mechanism_gold_to_confirmed_us_handoff(original),
                lambda original: mechanism_china_heat_cluster_cap(
                    original,
                    cluster_cap=0.42,
                    momentum_lookback=240,
                    momentum_threshold=0.55,
                    donchian_threshold=0.88,
                ),
                lambda original: mechanism_equity_entry_ramp(
                    original,
                    low_exposure_threshold=0.30,
                    high_exposure_threshold=0.55,
                    first_step_cap=0.42,
                    second_step_cap=0.55,
                ),
            ),
        ),
        CandidateSpec(
            "handoff_plus_equity_trailing",
            "Keep current handoff, but cap equities when US replacement assets enter short-term turbulence.",
            lambda original: mechanism_equity_trailing_turbulence(
                logic.mechanism_gold_to_confirmed_us_handoff(original),
                drawdown_cap=0.055,
                equity_cap=0.42,
            ),
        ),
        CandidateSpec(
            "bubble_cooldown_plus_trailing",
            "Combine regional bubble cooldown with US equity trailing turbulence cap.",
            compose(
                lambda original: logic.mechanism_gold_to_confirmed_us_handoff(original),
                lambda original: mechanism_regional_bubble_cooldown(
                    original,
                    cooldown_sessions=60,
                    equity_cap=0.45,
                    trigger_momentum=0.80,
                    short_threshold=0.0,
                ),
                lambda original: mechanism_equity_trailing_turbulence(original, drawdown_cap=0.055, equity_cap=0.42),
            ),
        ),
    ]


def run_candidate(spec: CandidateSpec) -> tuple[dict[str, Any], app.BacktestResult]:
    original_overlay = app.apply_gold_satellite_overlay
    original_strategy_config = app.strategy_config
    gold_guard = base_explorer.make_gold_blowoff_rollover_overlay(
        cap=0.45,
        long_lookback=90,
        long_threshold=0.08,
        short_lookback=20,
    )

    if spec.rebalance_sessions is not None:
        def patched_strategy_config(name: str) -> app.Config:
            config = original_strategy_config(name)
            if name in {"coreGoldSatelliteHeatCappedMomentum", "highZoneDecelerationMomentum", "tailBreakdownLockMomentum"}:
                return replace(config, rebalance_sessions=spec.rebalance_sessions)
            return config

        app.strategy_config = patched_strategy_config  # type: ignore[assignment]

    app.apply_gold_satellite_overlay = spec.overlay_factory(gold_guard)  # type: ignore[assignment]
    try:
        if spec.adaptive_min_gap_sessions is not None:
            result = run_adaptive_rebalance_strategy(spec.overlay_factory, spec.adaptive_min_gap_sessions)
        else:
            result = app.run_strategy("coreGoldSatelliteHeatCappedMomentum", end_date="2026-06-19")
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]
        app.strategy_config = original_strategy_config  # type: ignore[assignment]

    row = {
        "name": spec.name,
        "thesis": spec.thesis,
        "full": result_summary(result),
        "slices": {
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-19"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(t.date, t.action, t.symbol, round(t.cash_amount, 2)) for t in result.trades[-8:]],
    }
    return row, result


def prepare_prices(end_date: str = "2026-06-19") -> tuple[list[date], dict[str, list[float]]]:
    raw = app.fetch_public_history(end_date=app.parse_date(end_date))
    prepared = app.prepare_series(raw)
    return app.align_rotation_price_series(prepared)


def weight_trace(result: app.BacktestResult, dates: list[date], prices_by_symbol: dict[str, list[float]]) -> list[dict[str, Any]]:
    trades_by_date: dict[str, list[app.Trade]] = defaultdict(list)
    for trade in result.trades:
        trades_by_date[trade.date].append(trade)

    units = {symbol: 0.0 for symbol in prices_by_symbol}
    rows: list[dict[str, Any]] = []
    values_by_date = {day: result.values[index] for index, day in enumerate(result.dates)}

    for index, day in enumerate(dates):
        for trade in trades_by_date.get(day.isoformat(), []):
            if trade.action == "buy":
                units[trade.symbol] += trade.units
            else:
                units[trade.symbol] = max(units.get(trade.symbol, 0.0) - trade.units, 0.0)

        total = values_by_date.get(day)
        if total is None or total <= 0:
            continue
        weights = {
            symbol: units.get(symbol, 0.0) * prices_by_symbol[symbol][index] / total
            for symbol in prices_by_symbol
            if units.get(symbol, 0.0) > 0
        }
        cash = max(1 - sum(weights.values()), 0.0)
        rows.append({
            "date": day.isoformat(),
            "value": total,
            "weights": {symbol: round(weight, 4) for symbol, weight in sorted(weights.items()) if weight > 0.0001},
            "cash": round(cash, 4),
        })
    return rows


def indicator_snapshot(dates: list[date], prices_by_symbol: dict[str, list[float]], date_text: str) -> dict[str, Any]:
    date_index = {day.isoformat(): index for index, day in enumerate(dates)}
    index = date_index[date_text]
    signal_index = max(index - 1, 0)
    assets: dict[str, Any] = {}
    for symbol in ["gold_cny", "shanghai_composite", "csi300", "nasdaq", "sp500"]:
        assets[symbol] = {
            "mom20": round(logic.mom(prices_by_symbol, symbol, signal_index, 20) or 0.0, 4),
            "mom60": round(logic.mom(prices_by_symbol, symbol, signal_index, 60) or 0.0, 4),
            "mom90": round(logic.mom(prices_by_symbol, symbol, signal_index, 90) or 0.0, 4),
            "mom240": round(logic.mom(prices_by_symbol, symbol, signal_index, 240) or 0.0, 4),
            "don240": round(app.donchian_range_position(prices_by_symbol[symbol], signal_index, 240) or 0.0, 4),
            "above120": logic.above_ma(prices_by_symbol, symbol, signal_index, 120),
        }
    return {
        "date": date_text,
        "signal_date": dates[signal_index].isoformat(),
        "assets": assets,
    }


def failure_window_diagnostics(
    result: app.BacktestResult,
    trace: list[dict[str, Any]],
    dates: list[date],
    prices_by_symbol: dict[str, list[float]],
) -> dict[str, Any]:
    ddw = max_drawdown_window(result)
    peak_date = ddw["peak_date"]
    trough_date = ddw["trough_date"]
    interesting = [row for row in trace if peak_date <= row["date"] <= trough_date]
    trade_dates = {trade.date for trade in result.trades if peak_date <= trade.date <= trough_date}
    sampled = [
        row for row in interesting
        if row["date"] in {peak_date, trough_date} or row["date"] in trade_dates
    ]
    return {
        "drawdown_window": ddw,
        "sampled_weights": sampled,
        "sampled_signals": [indicator_snapshot(dates, prices_by_symbol, row["date"]) for row in sampled],
        "previous_trades": [
            (trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2))
            for trade in result.trades
            if trade.date < peak_date
        ][-6:],
        "trades": [
            (trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2))
            for trade in result.trades
            if peak_date <= trade.date <= trough_date
        ],
    }


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
        rows_and_results = [run_candidate(spec) for spec in candidate_specs()]
        dates, prices_by_symbol = prepare_prices()
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows = [row for row, _ in rows_and_results]
    rows.sort(key=lambda row: (row["full"]["max_drawdown"] <= 0.10, row["full"]["annualized"]), reverse=True)  # type: ignore[index, operator]

    diagnostics_by_candidate: dict[str, Any] = {}
    for diagnostic_name in ["current_gold_handoff", "extreme_equity_heat_total_cap50", "dual_heat_caps_eq50_gold70"]:
        result = next(result for row, result in rows_and_results if row["name"] == diagnostic_name)
        trace = weight_trace(result, dates, prices_by_symbol)
        diagnostics_by_candidate[diagnostic_name] = failure_window_diagnostics(result, trace, dates, prices_by_symbol)

    output = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "rows": rows,
        "failure_diagnostics": diagnostics_by_candidate,
    }
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("\nSUMMARY")
    print("name | full ann/dd | post2020 ann/dd | last10 ann/dd | post2024 ann/dd | trades | dd window")
    for row in rows:
        full: dict[str, Any] = row["full"]
        slices: dict[str, dict[str, Any]] = row["slices"]
        ddw: dict[str, Any] = row["drawdown_window"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{pct(slices['post_2020']['max_drawdown'])} | "
            f"{pct(slices['last_10y']['annualized'])}/{pct(slices['last_10y']['max_drawdown'])} | "
            f"{pct(slices['post_2024']['annualized'])}/{pct(slices['post_2024']['max_drawdown'])} | "
            f"{full['trades']} | {ddw['peak_date']}->{ddw['trough_date']}"
        )

    for name, diagnostics in diagnostics_by_candidate.items():
        print(f"\n{name} FAILURE WINDOW")
        for row in diagnostics["sampled_weights"]:
            print(row)
        print("signals")
        for row in diagnostics["sampled_signals"]:
            print(row)
        print("previous trades", diagnostics["previous_trades"])
        print("trades", diagnostics["trades"])


if __name__ == "__main__":
    main()
