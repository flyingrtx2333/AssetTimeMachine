#!/usr/bin/env python3
"""App-only router search for AssetTimeMachine.

This spike keeps the App-equivalent heat-capped rotation engine and tests only
router logic between two App-only child engines:

- current/defensive: gold rollover handoff
- offensive: confirmed equity breadth

The asset universe is the current public-history App universe:
gold_cny, nasdaq, sp500, csi300, shanghai_composite, plus idle CNY cash.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date
import json
import math
from pathlib import Path
import sys
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402

Overlay = Callable[
    [dict[str, float], int, date, dict[str, list[float]], list[float] | None, app.Config],
    dict[str, float],
]


@dataclass(frozen=True)
class PreparedRunContext:
    dates: list[date]
    prices_by_symbol: dict[str, list[float]]
    symbols: list[str]
    config: app.Config
    ma_by_symbol: dict[str, list[float | None]]
    vol_by_symbol: dict[str, list[float | None]]
    meta_traces: dict[str, app.SimulatedTrace] | None


@dataclass(frozen=True)
class Candidate:
    name: str
    params: dict[str, object]
    annualized: float
    max_drawdown: float
    annualized_volatility: float | None
    sharpe: float | None
    total_return: float
    final_value: float | None
    trades: int
    slices: dict[str, dict[str, float | None]]
    latest_trades: list[tuple[str, str, str, float]]


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def prepare_context(end_date: str) -> PreparedRunContext:
    raw = app.fetch_public_history(end_date=app.parse_date(end_date))
    prepared = app.prepare_series(raw)
    dates, prices_by_symbol = app.align_rotation_price_series(prepared)
    symbols = [item.symbol for item in prepared]
    config = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")
    ma_by_symbol, vol_by_symbol = app.indicator_maps(prices_by_symbol, config)

    meta_traces: dict[str, app.SimulatedTrace] | None = None
    if config.meta_switch:
        meta_traces = {
            config.meta_switch.default_mode: app.simulated_rotation_trace(
                symbols,
                prices_by_symbol,
                dates,
                app.strategy_config(config.meta_switch.default_mode),
            ),
            config.meta_switch.defensive_mode: app.simulated_rotation_trace(
                symbols,
                prices_by_symbol,
                dates,
                app.strategy_config(config.meta_switch.defensive_mode),
            ),
        }

    return PreparedRunContext(
        dates=dates,
        prices_by_symbol=prices_by_symbol,
        symbols=symbols,
        config=config,
        ma_by_symbol=ma_by_symbol,
        vol_by_symbol=vol_by_symbol,
        meta_traces=meta_traces,
    )


def run_prepared_strategy(
    context: PreparedRunContext,
    *,
    name: str,
    fee_rate: float = 0.01,
    slippage_rate: float = 0.0005,
) -> app.BacktestResult:
    initial_cash = 100_000.0
    band = max(context.config.rebalance_band, 0.0)
    tradable_symbols = [symbol for symbol in context.symbols if symbol not in context.config.signal_only_symbols]
    cash = initial_cash
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []
    last_rebalance_index = -10**9

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * context.prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        if context.config.meta_switch and context.meta_traces is not None:
            raw_weights = app.meta_rotation_target_weights(
                context.config.meta_switch,
                signal_index,
                trace_index,
                context.meta_traces,
            )
            if raw_weights is None:
                return {}
            return app.apply_gold_satellite_overlay(
                raw_weights,
                signal_index,
                context.dates[signal_index],
                context.prices_by_symbol,
                points,
                context.config,
            )
        return app.advanced_rotation_target_weights(
            context.symbols,
            context.prices_by_symbol,
            context.ma_by_symbol,
            context.vol_by_symbol,
            signal_index,
            context.dates[signal_index],
            context.config,
        )

    for index, current_date in enumerate(context.dates):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(context.dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        rebalance_sessions = max(context.config.rebalance_sessions, 1)
        if context.config.rebalances_from_first_signal:
            should_rebalance = index > 0 and index - last_rebalance_index >= rebalance_sessions
        else:
            should_rebalance = index == 0 or index % rebalance_sessions == 0

        if should_rebalance:
            signal_index = index - 1
            pre_value = portfolio_value(index)
            base_targets = target_weights(signal_index, index) if signal_index >= 0 else {}
            targets = base_targets if context.config.meta_switch else app.apply_portfolio_guard(
                base_targets,
                pre_value,
                points,
                context.config,
            )
            target_symbols = set(targets.keys())

            for symbol in sorted(held - target_symbols):
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                price = context.prices_by_symbol[symbol][index]
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
                price = context.prices_by_symbol[symbol][index]
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
                price = context.prices_by_symbol[symbol][index]
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

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(context.dates, points)
    return app.BacktestResult(
        strategy=name,
        coverage_start=context.dates[0].isoformat(),
        coverage_end=context.dates[-1].isoformat(),
        point_count=len(points),
        annualized_return=annualized,
        max_drawdown=max_dd,
        total_return=total,
        annualized_volatility=annual_vol,
        sharpe_ratio=sharpe,
        final_value=points[-1],
        trades=trades,
        dates=context.dates,
        values=points,
    )


def run_with_overlay(context: PreparedRunContext, name: str, overlay: Overlay) -> app.BacktestResult:
    original_overlay = app.apply_gold_satellite_overlay
    app.apply_gold_satellite_overlay = overlay  # type: ignore[assignment]
    try:
        return run_prepared_strategy(context, name=name)
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]


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


def trailing_volatility(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns = [
        math.log(values[cursor] / values[cursor - 1])
        for cursor in range(index - lookback + 1, index + 1)
        if values[cursor - 1] > 0 and values[cursor] > 0
    ]
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def blend_weights(first: dict[str, float], second: dict[str, float], first_share: float) -> dict[str, float]:
    share = min(max(first_share, 0.0), 1.0)
    output: dict[str, float] = {}
    for symbol, weight in first.items():
        output[symbol] = output.get(symbol, 0.0) + max(weight, 0.0) * share
    for symbol, weight in second.items():
        output[symbol] = output.get(symbol, 0.0) + max(weight, 0.0) * (1 - share)
    return app._normalize_weights(output)


def scaled_weights(weights: dict[str, float], scale: float) -> dict[str, float]:
    factor = min(max(scale, 0.0), 1.0)
    return {symbol: weight * factor for symbol, weight in weights.items() if weight * factor > 0.0001}


def router_overlay(
    current_trace: app.BacktestResult,
    breadth_trace: app.BacktestResult,
    *,
    lookback: int,
    metric: str,
    offensive_share: float,
    defensive_current_share: float,
    drawdown_threshold: float,
    scale_mode: str,
    cash_gate: bool,
    min_offensive_return: float,
    score_margin: float,
) -> Overlay:
    original_overlay = app.apply_gold_satellite_overlay
    base_overlay = app._overlay_gold_rollover_cap(original_overlay)
    current_engine = app._overlay_gold_handoff(base_overlay)
    breadth_engine = app._overlay_equity_breadth(base_overlay)

    def score(value_return: float, value_volatility: float | None, value_drawdown: float | None) -> float:
        if metric == "return":
            return value_return
        if metric == "sharpe":
            return value_return / max(value_volatility or 9.0, 0.01)
        if metric == "calmar":
            return value_return / max(abs(value_drawdown or 0.0), 0.03)
        return value_return / max(value_volatility or 9.0, 0.01) + 0.25 * value_return / max(abs(value_drawdown or 0.0), 0.03)

    def overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        current_weights = current_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        breadth_weights = breadth_engine(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)

        current_return = trailing_return(current_trace.values, signal_index, lookback)
        breadth_return = trailing_return(breadth_trace.values, signal_index, lookback)
        if current_return is None or breadth_return is None:
            return current_weights

        current_volatility = trailing_volatility(current_trace.values, signal_index, lookback)
        breadth_volatility = trailing_volatility(breadth_trace.values, signal_index, lookback)
        current_drawdown = trailing_drawdown(current_trace.values, signal_index, lookback)
        breadth_drawdown = trailing_drawdown(breadth_trace.values, signal_index, lookback)

        if cash_gate and current_return < 0 and breadth_return < 0:
            return {}

        current_score = score(current_return, current_volatility, current_drawdown)
        breadth_score = score(breadth_return, breadth_volatility, breadth_drawdown)
        routed = current_weights
        offensive = False

        if breadth_return >= min_offensive_return and breadth_score > current_score + score_margin:
            if breadth_drawdown is not None and breadth_drawdown < -max(drawdown_threshold, 0.0):
                routed = blend_weights(current_weights, breadth_weights, defensive_current_share)
            else:
                routed = blend_weights(breadth_weights, current_weights, offensive_share)
                offensive = True

        if offensive and scale_mode != "none":
            scale = 1.0
            if (
                scale_mode == "current_vol"
                and current_volatility is not None
                and breadth_volatility is not None
                and breadth_volatility > current_volatility
                and breadth_volatility > 0
            ):
                scale = min(max(current_volatility / breadth_volatility, 0.0), 1.0)
            elif scale_mode == "target10" and breadth_volatility is not None and breadth_volatility > 0.10:
                scale = min(max(0.10 / breadth_volatility, 0.0), 1.0)
            elif scale_mode == "target12" and breadth_volatility is not None and breadth_volatility > 0.12:
                scale = min(max(0.12 / breadth_volatility, 0.0), 1.0)
            if scale < 1:
                routed = scaled_weights(routed, scale)

        return app._normalize_weights(routed)

    return overlay


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    index = next((cursor for cursor, day in enumerate(result.dates) if day >= start_date), None)
    if index is None or index >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "total": None}
    total, annualized, max_dd, _vol, _sharpe = app.performance_metrics(result.dates[index:], result.values[index:])
    return {"annualized": annualized, "max_drawdown": max_dd, "total": total}


def summarize(name: str, params: dict[str, object], result: app.BacktestResult) -> Candidate:
    return Candidate(
        name=name,
        params=params,
        annualized=result.annualized_return,
        max_drawdown=result.max_drawdown,
        annualized_volatility=result.annualized_volatility,
        sharpe=result.sharpe_ratio,
        total_return=result.total_return,
        final_value=result.final_value,
        trades=len(result.trades),
        slices={
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-19"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        latest_trades=[
            (trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2))
            for trade in result.trades[-8:]
        ],
    )


def main() -> None:
    end_date = "2026-06-19"
    context = prepare_context(end_date)
    original_overlay = app.apply_gold_satellite_overlay

    current_trace = run_with_overlay(
        context,
        "gold_handoff",
        app._overlay_gold_handoff(app._overlay_gold_rollover_cap(original_overlay)),
    )
    breadth_trace = run_with_overlay(
        context,
        "equity_breadth",
        app._overlay_equity_breadth(app._overlay_gold_rollover_cap(original_overlay)),
    )

    candidates: list[Candidate] = []
    existing_one_way = app.run_strategy("coreGoldSatelliteOneWayVolManagedMomentum", end_date=end_date)
    candidates.append(summarize("existing_one_way", {}, existing_one_way))

    for lookback in [120, 240, 360]:
        for metric in ["return", "sharpe"]:
            for offensive_share in [0.75, 1.0]:
                for defensive_current_share in [0.7]:
                    for drawdown_threshold in [0.08]:
                        for scale_mode in ["current_vol", "target12"]:
                            for cash_gate in [False, True]:
                                for min_offensive_return in [0.0]:
                                    for score_margin in [0.0, 0.02]:
                                        params = {
                                            "lookback": lookback,
                                            "metric": metric,
                                            "offensive_share": offensive_share,
                                            "defensive_current_share": defensive_current_share,
                                            "drawdown_threshold": drawdown_threshold,
                                            "scale_mode": scale_mode,
                                            "cash_gate": cash_gate,
                                            "min_offensive_return": min_offensive_return,
                                            "score_margin": score_margin,
                                        }
                                        overlay = router_overlay(current_trace, breadth_trace, **params)
                                        result = run_with_overlay(context, "app_only_router", overlay)
                                        if result.sharpe_ratio is not None and result.annualized_return >= 0.08:
                                            candidates.append(summarize("app_only_router", params, result))

    candidates.sort(key=lambda item: (item.sharpe or -9.0, item.annualized), reverse=True)
    output = [candidate.__dict__ for candidate in candidates[:80]]
    print(json.dumps(output, ensure_ascii=False, indent=2))
    print("\nSUMMARY")
    print("name | ann/dd/vol/sharpe | post2020 ann/dd | last10 ann/dd | trades | params")
    for candidate in candidates[:40]:
        print(
            f"{candidate.name} | "
            f"{pct(candidate.annualized)}/{pct(candidate.max_drawdown)}/{pct(candidate.annualized_volatility)}/"
            f"{candidate.sharpe:.3f} | "
            f"{pct(candidate.slices['post_2020']['annualized'])}/{pct(candidate.slices['post_2020']['max_drawdown'])} | "
            f"{pct(candidate.slices['last_10y']['annualized'])}/{pct(candidate.slices['last_10y']['max_drawdown'])} | "
            f"{candidate.trades} | {candidate.params}"
        )


if __name__ == "__main__":
    main()
