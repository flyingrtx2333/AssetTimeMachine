#!/usr/bin/env python3
"""Search for Sharpe-2 style logic without parameter grids.

This spike tests structural execution ideas that are not expressible as a
simple 60-session overlay:

- daily confirmation gates;
- daily risk-parity baskets;
- daily cash gates over the current champion target.

The aim is to see whether a no-leverage, long-only, app-feasible strategy can
get close to or above Sharpe 2 on the same public-history data.
"""
from __future__ import annotations

from dataclasses import dataclass
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

Weights = dict[str, float]
DailyTarget = Callable[[int, list[date], dict[str, list[float]], list[float]], Weights]
Overlay = Callable[[dict[str, float], int, date, dict[str, list[float]], list[float] | None, app.Config], Weights]


@dataclass(frozen=True)
class Candidate:
    name: str
    thesis: str
    runner: Callable[[], app.BacktestResult]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: Weights) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def normalize(weights: Weights, max_total: float = 1.0) -> Weights:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(out)
    if total > max_total and total > 0:
        scale = max_total / total
        out = {symbol: weight * scale for symbol, weight in out.items() if weight * scale > 0.0001}
    return out


def rolling_vol(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int = 60) -> float | None:
    values = prices_by_symbol[symbol]
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] > 0 and values[cursor] > 0:
            returns.append(app.math.log(values[cursor] / values[cursor - 1]))
    if len(returns) < 2:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return app.math.sqrt(variance) * app.math.sqrt(app.TRADING_DAYS_PER_YEAR)


def confirmed(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> bool:
    mom60 = logic.mom(prices_by_symbol, symbol, index, 60)
    mom120 = logic.mom(prices_by_symbol, symbol, index, 120)
    return (
        mom60 is not None
        and mom120 is not None
        and mom60 > 0
        and mom120 > 0
        and logic.above_ma(prices_by_symbol, symbol, index, 120)
    )


def strict_confirmed(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> bool:
    mom20 = logic.mom(prices_by_symbol, symbol, index, 20)
    return confirmed(prices_by_symbol, symbol, index) and mom20 is not None and mom20 > 0


def score(prices_by_symbol: dict[str, list[float]], symbol: str, index: int) -> float:
    mom60 = logic.mom(prices_by_symbol, symbol, index, 60) or 0.0
    mom120 = logic.mom(prices_by_symbol, symbol, index, 120) or 0.0
    vol = rolling_vol(prices_by_symbol, symbol, index) or 9.0
    return max(0.0, (mom120 + 0.5 * mom60) / max(vol, 0.01))


def risk_parity(symbols: list[str], prices_by_symbol: dict[str, list[float]], index: int, budget: float = 1.0) -> Weights:
    vols = [(symbol, rolling_vol(prices_by_symbol, symbol, index) or 9.0) for symbol in symbols]
    inv = [(symbol, 1.0 / max(vol, 0.01)) for symbol, vol in vols]
    total = sum(value for _symbol, value in inv)
    if total <= 0:
        return {}
    return {symbol: budget * value / total for symbol, value in inv}


def score_basket(symbols: list[str], prices_by_symbol: dict[str, list[float]], index: int, budget: float = 1.0) -> Weights:
    scored = [(symbol, score(prices_by_symbol, symbol, index)) for symbol in symbols]
    scored = [(symbol, value) for symbol, value in scored if value > 0]
    total = sum(value for _symbol, value in scored)
    if total <= 0:
        return {}
    return {symbol: budget * value / total for symbol, value in scored}


def prepare_data(end_date: str = "2026-06-19") -> tuple[list[date], dict[str, list[float]]]:
    raw = app.fetch_public_history(end_date=app.parse_date(end_date))
    prepared = app.prepare_series(raw)
    return app.align_rotation_price_series(prepared)


def run_daily_target_strategy(name: str, target_fn: DailyTarget, *, fee_rate_pct: float = 0.10, slippage_rate_pct: float = 0.05) -> app.BacktestResult:
    dates, prices_by_symbol = prepare_data()
    symbols = list(prices_by_symbol)
    cash = 100_000.0
    fee_rate = max(fee_rate_pct, 0.0) / 100.0
    slippage_rate = max(slippage_rate_pct, 0.0) / 100.0
    units = {symbol: 0.0 for symbol in symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in symbols)

    for index, current_date in enumerate(dates):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if app.math.isfinite(interest) and interest > 0:
                cash += interest

        if index <= 0:
            points.append(portfolio_value(index))
            continue

        pre_value = portfolio_value(index)
        targets = normalize(target_fn(index - 1, dates, prices_by_symbol, points), 1.0)
        target_symbols = set(targets)

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
            gross_to_sell = max(current_value - target_value, 0.0)
            if gross_to_sell <= pre_value * 0.002:
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

        total_value_after_sells = portfolio_value(index)
        for symbol in sorted(target_symbols):
            price = prices_by_symbol[symbol][index]
            if price <= 0:
                continue
            current_value = units.get(symbol, 0.0) * price
            target_value = total_value_after_sells * targets[symbol]
            amount = min(cash, max(target_value - current_value, 0.0))
            if amount <= total_value_after_sells * 0.002:
                continue
            execution_price = price * (1 + slippage_rate)
            invested = amount * (1 - fee_rate)
            bought_units = invested / execution_price if execution_price > 0 else 0.0
            units[symbol] = units.get(symbol, 0.0) + bought_units
            cash -= amount
            held.add(symbol)
            trades.append(app.Trade(current_date.isoformat(), "buy", symbol, execution_price, amount, bought_units))

        points.append(portfolio_value(index))

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, points)
    return app.BacktestResult(
        strategy=name,
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


def current_handoff_overlay(original: Overlay) -> Overlay:
    return logic.mechanism_gold_to_confirmed_us_handoff(original)


def run_overlay_strategy(name: str, overlay_factory: Callable[[Overlay], Overlay]) -> app.BacktestResult:
    original_overlay = app.apply_gold_satellite_overlay
    gold_guard = base_explorer.make_gold_blowoff_rollover_overlay(
        cap=0.45,
        long_lookback=90,
        long_threshold=0.08,
        short_lookback=20,
    )
    app.apply_gold_satellite_overlay = overlay_factory(gold_guard)  # type: ignore[assignment]
    try:
        result = app.run_strategy("coreGoldSatelliteHeatCappedMomentum", end_date="2026-06-19")
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]
    return app.BacktestResult(
        strategy=name,
        coverage_start=result.coverage_start,
        coverage_end=result.coverage_end,
        point_count=result.point_count,
        annualized_return=result.annualized_return,
        max_drawdown=result.max_drawdown,
        total_return=result.total_return,
        annualized_volatility=result.annualized_volatility,
        sharpe_ratio=result.sharpe_ratio,
        final_value=result.final_value,
        trades=result.trades,
        dates=result.dates,
        values=result.values,
    )


def run_current_handoff() -> app.BacktestResult:
    return run_overlay_strategy("current_gold_handoff", current_handoff_overlay)


def overlay_core_consensus_gate(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        core_count = sum(1 for symbol in ["gold_cny", "nasdaq", "sp500"] if confirmed(prices_by_symbol, symbol, signal_index))
        if core_count < 2:
            return {}
        return base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)

    return overlay


def overlay_selected_assets_must_confirm(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if not weights:
            return weights
        if all(confirmed(prices_by_symbol, symbol, signal_index) for symbol in weights):
            return weights
        return {}

    return overlay


def overlay_selected_assets_strict_confirm(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if not weights:
            return weights
        if all(strict_confirmed(prices_by_symbol, symbol, signal_index) for symbol in weights):
            return weights
        return {}

    return overlay


def overlay_sp500_macro_gate(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        if not confirmed(prices_by_symbol, "sp500", signal_index):
            return {}
        return base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)

    return overlay


def overlay_low_freq_equity_breadth_accelerator(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        equities = [symbol for symbol in app.EQUITY_SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
        if len(equities) < 2:
            return weights
        budget = 1.0 - total_weight(weights)
        if budget <= 0:
            return normalize(weights)
        addition = score_basket(equities, prices_by_symbol, signal_index, budget=budget)
        for symbol, weight in addition.items():
            weights[symbol] = weights.get(symbol, 0.0) + weight
        return normalize(weights)

    return overlay


def overlay_low_freq_core_breadth_accelerator(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        core = [symbol for symbol in ["gold_cny", "nasdaq", "sp500"] if confirmed(prices_by_symbol, symbol, signal_index)]
        if len(core) < 2:
            return weights
        budget = 1.0 - total_weight(weights)
        if budget <= 0:
            return normalize(weights)
        addition = score_basket(core, prices_by_symbol, signal_index, budget=budget)
        for symbol, weight in addition.items():
            weights[symbol] = weights.get(symbol, 0.0) + weight
        return normalize(weights)

    return overlay


def blend_weights(first: Weights, second: Weights, first_share: float = 0.5) -> Weights:
    share = min(max(first_share, 0.0), 1.0)
    out: Weights = {}
    for symbol, weight in first.items():
        out[symbol] = out.get(symbol, 0.0) + weight * share
    for symbol, weight in second.items():
        out[symbol] = out.get(symbol, 0.0) + weight * (1 - share)
    return normalize(out, 1.0)


def overlay_blend_current_equity_breadth(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)
    breadth = overlay_low_freq_equity_breadth_accelerator(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        base_weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        breadth_weights = breadth(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        return blend_weights(base_weights, breadth_weights)

    return overlay


def overlay_blend_current_core_breadth(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)
    breadth = overlay_low_freq_core_breadth_accelerator(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        base_weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        breadth_weights = breadth(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        return blend_weights(base_weights, breadth_weights)

    return overlay


def overlay_equal_three_engine_ensemble(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)
    equity = overlay_low_freq_equity_breadth_accelerator(original)
    core = overlay_low_freq_core_breadth_accelerator(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        out: Weights = {}
        for engine in [base, equity, core]:
            weights = engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
            for symbol, weight in weights.items():
                out[symbol] = out.get(symbol, 0.0) + weight / 3
        return normalize(out, 1.0)

    return overlay


def estimated_target_vol(weights: Weights, prices_by_symbol: dict[str, list[float]], signal_index: int) -> float:
    # Conservative diagonal estimate; good enough for engine-level risk sharing
    # without fitting a covariance matrix to this small asset universe.
    return sum(max(weight, 0.0) * max(rolling_vol(prices_by_symbol, symbol, signal_index) or 0.0, 0.01) for symbol, weight in weights.items())


def overlay_risk_parity_engine_ensemble(original: Overlay) -> Overlay:
    base = current_handoff_overlay(original)
    breadth = overlay_low_freq_equity_breadth_accelerator(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        base_weights = base(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        breadth_weights = breadth(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        base_risk = estimated_target_vol(base_weights, prices_by_symbol, signal_index)
        breadth_risk = estimated_target_vol(breadth_weights, prices_by_symbol, signal_index)
        if base_risk <= 0 and breadth_risk <= 0:
            return {}
        base_share = (1 / max(base_risk, 0.01)) / ((1 / max(base_risk, 0.01)) + (1 / max(breadth_risk, 0.01)))
        return blend_weights(base_weights, breadth_weights, first_share=base_share)

    return overlay


def overlay_vol_scaled_engine_ensemble(original: Overlay) -> Overlay:
    ensemble = overlay_risk_parity_engine_ensemble(original)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = ensemble(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        estimated_vol = estimated_target_vol(weights, prices_by_symbol, signal_index)
        target_vol = config.target_annual_volatility or 0.11
        if estimated_vol > target_vol and estimated_vol > 0:
            scale = target_vol / estimated_vol
            return {symbol: weight * scale for symbol, weight in weights.items() if weight * scale > 0.0001}
        return weights

    return overlay


def target_daily_core_risk_parity(signal_index: int, _dates: list[date], prices_by_symbol: dict[str, list[float]], _points: list[float]) -> Weights:
    symbols = [symbol for symbol in ["gold_cny", "nasdaq", "sp500"] if confirmed(prices_by_symbol, symbol, signal_index)]
    if len(symbols) < 2:
        return {}
    return risk_parity(symbols, prices_by_symbol, signal_index)


def target_daily_strict_core_risk_parity(signal_index: int, _dates: list[date], prices_by_symbol: dict[str, list[float]], _points: list[float]) -> Weights:
    symbols = [symbol for symbol in ["gold_cny", "nasdaq", "sp500"] if strict_confirmed(prices_by_symbol, symbol, signal_index)]
    if len(symbols) < 2:
        return {}
    return risk_parity(symbols, prices_by_symbol, signal_index)


def target_daily_all_risk_parity(signal_index: int, _dates: list[date], prices_by_symbol: dict[str, list[float]], _points: list[float]) -> Weights:
    symbols = [symbol for symbol in app.SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
    if len(symbols) < 3:
        return {}
    return risk_parity(symbols, prices_by_symbol, signal_index)


def target_daily_score_core(signal_index: int, _dates: list[date], prices_by_symbol: dict[str, list[float]], _points: list[float]) -> Weights:
    symbols = [symbol for symbol in ["gold_cny", "nasdaq", "sp500"] if confirmed(prices_by_symbol, symbol, signal_index)]
    if len(symbols) < 2:
        return {}
    return score_basket(symbols, prices_by_symbol, signal_index)


def target_daily_strict_score_core(signal_index: int, _dates: list[date], prices_by_symbol: dict[str, list[float]], _points: list[float]) -> Weights:
    symbols = [symbol for symbol in ["gold_cny", "nasdaq", "sp500"] if strict_confirmed(prices_by_symbol, symbol, signal_index)]
    if len(symbols) < 2:
        return {}
    return score_basket(symbols, prices_by_symbol, signal_index)


def target_daily_us_gold_barbell(signal_index: int, _dates: list[date], prices_by_symbol: dict[str, list[float]], _points: list[float]) -> Weights:
    us_symbols = [symbol for symbol in ["nasdaq", "sp500"] if confirmed(prices_by_symbol, symbol, signal_index)]
    gold_ok = confirmed(prices_by_symbol, "gold_cny", signal_index)
    if not us_symbols or not gold_ok:
        return {}
    us = score_basket(us_symbols, prices_by_symbol, signal_index, budget=0.65)
    return normalize({"gold_cny": 0.35, **us})


def target_daily_equity_breadth_score(signal_index: int, _dates: list[date], prices_by_symbol: dict[str, list[float]], _points: list[float]) -> Weights:
    equities = [symbol for symbol in app.EQUITY_SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
    if len(equities) < 2:
        return {}
    return score_basket(equities, prices_by_symbol, signal_index)


def target_daily_low_vol_confirmed(signal_index: int, _dates: list[date], prices_by_symbol: dict[str, list[float]], _points: list[float]) -> Weights:
    candidates = [symbol for symbol in app.SYMBOLS if confirmed(prices_by_symbol, symbol, signal_index)]
    if len(candidates) < 2:
        return {}
    chosen = sorted(candidates, key=lambda symbol: rolling_vol(prices_by_symbol, symbol, signal_index) or 9.0)[:2]
    return risk_parity(chosen, prices_by_symbol, signal_index)


def target_daily_curve_gate_core(signal_index: int, dates: list[date], prices_by_symbol: dict[str, list[float]], points: list[float]) -> Weights:
    if len(points) >= 40:
        peak = max(points[-40:])
        if peak > 0 and points[-1] / peak - 1 < -0.015:
            return {}
    return target_daily_core_risk_parity(signal_index, dates, prices_by_symbol, points)


def candidate_specs() -> list[Candidate]:
    return [
        Candidate("current_gold_handoff", "Current 60-session champion.", run_current_handoff),
        Candidate(
            "core_consensus_gate",
            "Use current champion only when at least two core engines confirm; otherwise hold cash.",
            lambda: run_overlay_strategy("core_consensus_gate", overlay_core_consensus_gate),
        ),
        Candidate(
            "selected_assets_must_confirm",
            "Use current champion only when every selected sleeve still has medium-term confirmation.",
            lambda: run_overlay_strategy("selected_assets_must_confirm", overlay_selected_assets_must_confirm),
        ),
        Candidate(
            "selected_assets_strict_confirm",
            "Use current champion only when every selected sleeve also has positive short-term confirmation.",
            lambda: run_overlay_strategy("selected_assets_strict_confirm", overlay_selected_assets_strict_confirm),
        ),
        Candidate(
            "sp500_macro_gate",
            "Use current champion only when S&P confirms the global risk regime.",
            lambda: run_overlay_strategy("sp500_macro_gate", overlay_sp500_macro_gate),
        ),
        Candidate(
            "low_freq_equity_breadth_accelerator",
            "Low-frequency version of equity breadth acceleration over the champion target.",
            lambda: run_overlay_strategy("low_freq_equity_breadth_accelerator", overlay_low_freq_equity_breadth_accelerator),
        ),
        Candidate(
            "low_freq_core_breadth_accelerator",
            "Low-frequency core breadth acceleration over gold/Nasdaq/S&P.",
            lambda: run_overlay_strategy("low_freq_core_breadth_accelerator", overlay_low_freq_core_breadth_accelerator),
        ),
        Candidate(
            "ensemble_current_equity_breadth",
            "Equal-weight target ensemble of current champion and equity breadth accelerator.",
            lambda: run_overlay_strategy("ensemble_current_equity_breadth", overlay_blend_current_equity_breadth),
        ),
        Candidate(
            "ensemble_current_core_breadth",
            "Equal-weight target ensemble of current champion and core breadth accelerator.",
            lambda: run_overlay_strategy("ensemble_current_core_breadth", overlay_blend_current_core_breadth),
        ),
        Candidate(
            "ensemble_three_engine",
            "Equal-weight target ensemble of current, equity breadth, and core breadth engines.",
            lambda: run_overlay_strategy("ensemble_three_engine", overlay_equal_three_engine_ensemble),
        ),
        Candidate(
            "risk_parity_engine_ensemble",
            "Dynamic engine ensemble: current champion and equity breadth receive inverse-risk engine weights.",
            lambda: run_overlay_strategy("risk_parity_engine_ensemble", overlay_risk_parity_engine_ensemble),
        ),
        Candidate(
            "vol_scaled_engine_ensemble",
            "Risk-parity engine ensemble with exposure scaled down when estimated target volatility is too high.",
            lambda: run_overlay_strategy("vol_scaled_engine_ensemble", overlay_vol_scaled_engine_ensemble),
        ),
        Candidate(
            "daily_core_risk_parity",
            "Daily confirmed gold/Nasdaq/S&P basket; invest only when at least two engines confirm.",
            lambda: run_daily_target_strategy("daily_core_risk_parity", target_daily_core_risk_parity),
        ),
        Candidate(
            "daily_strict_core_risk_parity",
            "Daily core risk parity with positive short-term confirmation.",
            lambda: run_daily_target_strategy("daily_strict_core_risk_parity", target_daily_strict_core_risk_parity),
        ),
        Candidate(
            "daily_all_risk_parity",
            "Daily risk parity across all confirmed assets; require at least three confirmations.",
            lambda: run_daily_target_strategy("daily_all_risk_parity", target_daily_all_risk_parity),
        ),
        Candidate(
            "daily_score_core",
            "Daily confirmed gold/Nasdaq/S&P basket weighted by risk-adjusted momentum.",
            lambda: run_daily_target_strategy("daily_score_core", target_daily_score_core),
        ),
        Candidate(
            "daily_strict_score_core",
            "Daily risk-adjusted core basket with positive short-term confirmation.",
            lambda: run_daily_target_strategy("daily_strict_score_core", target_daily_strict_score_core),
        ),
        Candidate(
            "daily_us_gold_barbell",
            "Daily US/gold barbell: require gold plus at least one confirmed US engine.",
            lambda: run_daily_target_strategy("daily_us_gold_barbell", target_daily_us_gold_barbell),
        ),
        Candidate(
            "daily_equity_breadth_score",
            "Daily confirmed multi-equity breadth basket weighted by risk-adjusted momentum.",
            lambda: run_daily_target_strategy("daily_equity_breadth_score", target_daily_equity_breadth_score),
        ),
        Candidate(
            "daily_low_vol_confirmed",
            "Daily select the two lowest-vol confirmed assets and risk-parity them.",
            lambda: run_daily_target_strategy("daily_low_vol_confirmed", target_daily_low_vol_confirmed),
        ),
        Candidate(
            "daily_curve_gate_core",
            "Daily core risk parity, but move to cash after a small portfolio drawdown.",
            lambda: run_daily_target_strategy("daily_curve_gate_core", target_daily_curve_gate_core),
        ),
    ]


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None}
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
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = i
    return {
        "peak_date": result.dates[worst_peak].isoformat(),
        "trough_date": result.dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


def run_candidate(spec: Candidate) -> dict[str, Any]:
    result = spec.runner()
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "full": {
            "annualized": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "annual_volatility": result.annualized_volatility,
            "sharpe": result.sharpe_ratio,
            "total": result.total_return,
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
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-10:]],
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
        rows = [run_candidate(spec) for spec in candidate_specs()]
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("\nSUMMARY")
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
