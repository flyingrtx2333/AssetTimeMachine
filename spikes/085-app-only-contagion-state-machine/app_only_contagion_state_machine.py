#!/usr/bin/env python3
"""App-only contagion state-machine candidates.

This is a mechanism test, not a parameter search:

- Base engine: the App-only router + equity-curve state gate promoted in spike 084.
- New logic: detect when gold no longer diversifies equity risk.
- If gold and equities are both weak, or their rolling correlation turns
  positive during a joint selloff, step down risk and only reopen in stages.

No external assets, BTC, leverage, or financing are used.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import date
from pathlib import Path
import importlib.util
import math
import sys
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402

ROUTER_083_PATH = ROOT / "spikes" / "083-app-only-router-search" / "app_only_router_search.py"
spec = importlib.util.spec_from_file_location("router083", ROUTER_083_PATH)
router083 = importlib.util.module_from_spec(spec)
sys.modules["router083"] = router083
assert spec.loader is not None
spec.loader.exec_module(router083)

Overlay = Callable[
    [dict[str, float], int, date, dict[str, list[float]], list[float] | None, app.Config],
    dict[str, float],
]

EQUITY_SYMBOLS = ["nasdaq", "sp500", "csi300", "shanghai_composite"]


@dataclass(frozen=True)
class EquityCurveGate:
    lookback: int
    enter_return: float
    enter_drawdown: float
    exit_return: float
    exit_drawdown: float
    low_scale: float


@dataclass(frozen=True)
class ContagionStateMachine:
    name: str
    stress_scale: float
    recovery_scale: float
    require_gold_recovery: bool
    use_correlation_failure: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def trailing_return(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def trailing_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    start = max(0, index - lookback + 1)
    window = values[start : index + 1]
    if not window:
        return None
    peak = max(window)
    return values[index] / peak - 1 if peak > 0 else None


def basket_return(prices_by_symbol: dict[str, list[float]], symbols: list[str], index: int, lookback: int) -> float | None:
    values = [
        trailing_return(prices_by_symbol[symbol], index, lookback)
        for symbol in symbols
        if symbol in prices_by_symbol
    ]
    values = [value for value in values if value is not None]
    return sum(values) / len(values) if values else None


def rolling_returns(values: list[float], index: int, lookback: int) -> list[float]:
    if index - lookback + 1 < 1:
        return []
    output: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        previous = values[cursor - 1]
        current = values[cursor]
        if previous > 0 and current > 0:
            output.append(current / previous - 1)
    return output


def rolling_correlation(
    prices_by_symbol: dict[str, list[float]],
    left: str,
    right_symbols: list[str],
    index: int,
    lookback: int,
) -> float | None:
    left_returns = rolling_returns(prices_by_symbol[left], index, lookback)
    right_series = []
    for symbol in right_symbols:
        series = rolling_returns(prices_by_symbol[symbol], index, lookback)
        if len(series) == len(left_returns):
            right_series.append(series)
    if len(left_returns) < 20 or not right_series:
        return None
    right_returns = [
        sum(series[cursor] for series in right_series) / len(right_series)
        for cursor in range(len(left_returns))
    ]
    left_mean = sum(left_returns) / len(left_returns)
    right_mean = sum(right_returns) / len(right_returns)
    left_var = sum((item - left_mean) ** 2 for item in left_returns)
    right_var = sum((item - right_mean) ** 2 for item in right_returns)
    if left_var <= 0 or right_var <= 0:
        return None
    covariance = sum(
        (left_returns[cursor] - left_mean) * (right_returns[cursor] - right_mean)
        for cursor in range(len(left_returns))
    )
    return covariance / math.sqrt(left_var * right_var)


def scaled_weights(weights: dict[str, float], scale: float) -> dict[str, float]:
    factor = min(max(scale, 0.0), 1.0)
    return {symbol: weight * factor for symbol, weight in weights.items() if weight * factor > 0.0001}


def make_equity_curve_gate(base_overlay: Overlay, gate: EquityCurveGate) -> Overlay:
    defensive = False

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        nonlocal defensive
        weights = base_overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if not portfolio_values or signal_index >= len(portfolio_values):
            return weights

        recent_return = trailing_return(portfolio_values, signal_index, gate.lookback)
        recent_drawdown = trailing_drawdown(portfolio_values, signal_index, gate.lookback)
        if defensive:
            if (recent_return is not None and recent_return > gate.exit_return) or (
                recent_drawdown is not None and recent_drawdown > -gate.exit_drawdown
            ):
                defensive = False
        else:
            if (recent_return is not None and recent_return < gate.enter_return) or (
                recent_drawdown is not None and recent_drawdown < -gate.enter_drawdown
            ):
                defensive = True

        return scaled_weights(weights, gate.low_scale) if defensive else weights

    return overlay


def make_contagion_state_machine(base_overlay: Overlay, machine: ContagionStateMachine) -> Overlay:
    state = "normal"

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        nonlocal state
        weights = base_overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if signal_index < 126:
            return weights

        gold_20 = trailing_return(prices_by_symbol["gold_cny"], signal_index, 20) or 0.0
        gold_63 = trailing_return(prices_by_symbol["gold_cny"], signal_index, 63) or 0.0
        equity_20 = basket_return(prices_by_symbol, EQUITY_SYMBOLS, signal_index, 20) or 0.0
        equity_63 = basket_return(prices_by_symbol, EQUITY_SYMBOLS, signal_index, 63) or 0.0
        equity_breadth = sum(
            1
            for symbol in EQUITY_SYMBOLS
            if (trailing_return(prices_by_symbol[symbol], signal_index, 63) or -1.0) > 0
        )
        gold_equity_corr = rolling_correlation(prices_by_symbol, "gold_cny", ["nasdaq", "sp500"], signal_index, 63) or 0.0

        joint_weakness = gold_20 < 0 and gold_63 < 0 and equity_breadth <= 1 and equity_63 < 0
        correlation_failure = (
            machine.use_correlation_failure
            and gold_equity_corr > 0.20
            and gold_20 < 0
            and equity_20 < 0
        )
        recovery = equity_breadth >= 2 and equity_63 > 0 and (gold_20 > 0 or not machine.require_gold_recovery)
        full_recovery = equity_breadth >= 3 and equity_63 > 0.04 and gold_63 > -0.02

        if state == "normal":
            if joint_weakness or correlation_failure:
                state = "stress"
        elif state == "stress":
            if recovery:
                state = "recovery"
        else:
            if joint_weakness or correlation_failure:
                state = "stress"
            elif full_recovery:
                state = "normal"

        if state == "stress":
            return scaled_weights(weights, machine.stress_scale)
        if state == "recovery":
            return scaled_weights(weights, machine.recovery_scale)
        return weights

    return overlay


def make_diversification_credit(
    base_overlay: Overlay,
    *,
    gold_floor: float,
    max_total: float,
    corr_ceiling: float,
) -> Overlay:
    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        weights = base_overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        if signal_index < 126 or not weights:
            return weights
        if portfolio_values and signal_index < len(portfolio_values):
            strategy_return = trailing_return(portfolio_values, signal_index, 90)
            strategy_drawdown = trailing_drawdown(portfolio_values, signal_index, 90)
            if (strategy_return is not None and strategy_return < 0) or (
                strategy_drawdown is not None and strategy_drawdown < -0.03
            ):
                return weights

        gold_126 = trailing_return(prices_by_symbol["gold_cny"], signal_index, 126) or 0.0
        us_126 = basket_return(prices_by_symbol, ["nasdaq", "sp500"], signal_index, 126) or 0.0
        gold_20 = trailing_return(prices_by_symbol["gold_cny"], signal_index, 20) or 0.0
        corr = rolling_correlation(prices_by_symbol, "gold_cny", ["nasdaq", "sp500"], signal_index, 63) or 1.0
        has_us_equity = any(weights.get(symbol, 0.0) > 0.0001 for symbol in ["nasdaq", "sp500"])
        if not has_us_equity or gold_126 <= 0 or gold_20 <= -0.02 or us_126 <= 0 or corr >= corr_ceiling:
            return weights

        adjusted = dict(weights)
        adjusted["gold_cny"] = max(adjusted.get("gold_cny", 0.0), gold_floor)
        return app._normalize_weights(adjusted, max_total=max_total)

    return overlay


def make_base_overlay(context: router083.PreparedRunContext) -> Overlay:
    original_overlay = app.apply_gold_satellite_overlay
    current_trace = router083.run_with_overlay(
        context,
        "gold_handoff",
        app._overlay_gold_handoff(app._overlay_gold_rollover_cap(original_overlay)),
    )
    breadth_trace = router083.run_with_overlay(
        context,
        "equity_breadth",
        app._overlay_equity_breadth(app._overlay_gold_rollover_cap(original_overlay)),
    )
    return router083.router_overlay(
        current_trace,
        breadth_trace,
        lookback=240,
        metric="return",
        offensive_share=1.0,
        defensive_current_share=0.70,
        drawdown_threshold=0.08,
        scale_mode="current_vol",
        cash_gate=False,
        min_offensive_return=0.0,
        score_margin=0.0,
    )


def slice_metrics(result: app.BacktestResult, start: str) -> tuple[float | None, float | None]:
    start_date = app.parse_date(start)
    index = next((cursor for cursor, day in enumerate(result.dates) if day >= start_date), None)
    if index is None or index >= len(result.dates) - 2:
        return None, None
    _total, annualized, _max_dd, _vol, sharpe = app.performance_metrics(result.dates[index:], result.values[index:])
    return annualized, sharpe


def main() -> None:
    end_date = "2026-06-26"
    context = router083.prepare_context(end_date)
    context = router083.PreparedRunContext(
        dates=context.dates,
        prices_by_symbol=context.prices_by_symbol,
        symbols=context.symbols,
        config=replace(context.config, rebalance_band=0.08),
        ma_by_symbol=context.ma_by_symbol,
        vol_by_symbol=context.vol_by_symbol,
        meta_traces=context.meta_traces,
    )

    base_router = make_base_overlay(context)
    state_gate = make_equity_curve_gate(
        base_router,
        EquityCurveGate(
            lookback=90,
            enter_return=0.0,
            enter_drawdown=0.025,
            exit_return=0.02,
            exit_drawdown=0.03,
            low_scale=0.70,
        ),
    )

    candidates: list[tuple[str, app.BacktestResult]] = [
        ("app_promoted_state_gate", router083.run_with_overlay(context, "app_promoted_state_gate", state_gate)),
    ]

    machines = [
        ContagionStateMachine("contagion_joint_weakness", 0.45, 0.70, True, False),
        ContagionStateMachine("contagion_corr_failure", 0.45, 0.70, True, True),
        ContagionStateMachine("contagion_fast_reopen", 0.50, 0.80, False, True),
        ContagionStateMachine("contagion_hard_shelter", 0.30, 0.65, True, True),
    ]
    for machine in machines:
        overlay = make_contagion_state_machine(state_gate, machine)
        candidates.append((machine.name, router083.run_with_overlay(context, machine.name, overlay)))

    credit_candidates = [
        ("div_credit_gold20_gross90", 0.20, 0.90, 0.15),
        ("div_credit_gold25_gross95", 0.25, 0.95, 0.15),
        ("div_credit_gold30_gross95_loosecorr", 0.30, 0.95, 0.30),
        ("div_credit_gold20_gross100_loosecorr", 0.20, 1.00, 0.30),
    ]
    for name, gold_floor, max_total, corr_ceiling in credit_candidates:
        overlay = make_diversification_credit(
            state_gate,
            gold_floor=gold_floor,
            max_total=max_total,
            corr_ceiling=corr_ceiling,
        )
        candidates.append((name, router083.run_with_overlay(context, name, overlay)))

    print("name | annualized | max_drawdown | volatility | sharpe | post2020 ann/sh | last10y ann/sh | trades")
    for name, result in candidates:
        post_ann, post_sharpe = slice_metrics(result, "2020-01-01")
        last_ann, last_sharpe = slice_metrics(result, "2016-06-26")
        print(
            f"{name} | "
            f"{pct(result.annualized_return)} | "
            f"{pct(result.max_drawdown)} | "
            f"{pct(result.annualized_volatility)} | "
            f"{(result.sharpe_ratio or 0):.3f} | "
            f"{pct(post_ann)}/{(post_sharpe or 0):.3f} | "
            f"{pct(last_ann)}/{(last_sharpe or 0):.3f} | "
            f"{len(result.trades)}"
        )


if __name__ == "__main__":
    main()
