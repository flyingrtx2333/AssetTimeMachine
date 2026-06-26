#!/usr/bin/env python3
"""Narrow App-equivalent search for gold blowoff rollover caps.

This spike keeps the current App-equivalent strategy engine intact and only
patches the gold satellite overlay with an interpretable rule:

If gold has had a sharp medium-term run-up and then rolls over short term, cap
gold exposure for that rebalance. The goal is to remove the 2003 gold-heavy
drawdown without broad fitting.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import date, datetime
import json
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402

_original_moving_average = app.moving_average
_ma_cache: dict[tuple[int, int], list[float | None]] = {}


def cached_moving_average(values: list[float], period: int) -> list[float | None]:
    key = (id(values), period)
    cached = _ma_cache.get(key)
    if cached is None:
        cached = _original_moving_average(values, period)
        _ma_cache[key] = cached
    return cached


@dataclass(frozen=True)
class Candidate:
    cap: float
    long_lookback: int
    long_threshold: float
    short_lookback: int
    short_threshold: float
    full: dict[str, float | int | str | None]
    slices: dict[str, dict[str, float | None]]
    drawdown_window: dict[str, str | float]


@dataclass(frozen=True)
class PreparedRunContext:
    dates: list[date]
    prices_by_symbol: dict[str, list[float]]
    symbols: list[str]
    config: app.Config
    ma_by_symbol: dict[str, list[float | None]]
    vol_by_symbol: dict[str, list[float | None]]
    meta_traces: dict[str, app.SimulatedTrace] | None


def pct(x: float | None) -> str:
    return "n/a" if x is None else f"{x * 100:.2f}%"


def parse_day(text: str) -> date:
    return app.parse_date(text)


def slice_metrics(result: app.BacktestResult, start: str) -> dict[str, float | None]:
    start_date = parse_day(start)
    idx = next((i for i, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "total": None}
    total, annualized, max_dd, _vol, _sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "total": total}


def max_drawdown_window(result: app.BacktestResult) -> dict[str, str | float]:
    peak_value = result.values[0]
    peak_index = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for i, value in enumerate(result.values):
        if value > peak_value:
            peak_value = value
            peak_index = i
        if peak_value > 0:
            dd = (peak_value - value) / peak_value
            if dd > worst:
                worst = dd
                worst_peak = peak_index
                worst_trough = i
    return {
        "peak_date": result.dates[worst_peak].isoformat(),
        "trough_date": result.dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


def make_overlay(
    *,
    cap: float,
    long_lookback: int,
    long_threshold: float,
    short_lookback: int,
    short_threshold: float,
):
    original_overlay = app.apply_gold_satellite_overlay

    def patched_overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config):
        final = original_overlay(raw_weights, signal_index, signal_date, prices_by_symbol, portfolio_values, config)
        gold_weight = final.get("gold_cny", 0.0)
        if gold_weight > cap:
            gold_prices = prices_by_symbol["gold_cny"]
            long_momentum = app.price_momentum(gold_prices, signal_index, long_lookback)
            short_momentum = app.price_momentum(gold_prices, signal_index, short_lookback)
            if (
                long_momentum is not None
                and short_momentum is not None
                and long_momentum > long_threshold
                and short_momentum < short_threshold
            ):
                final["gold_cny"] = cap

        total = sum(max(weight, 0.0) for weight in final.values())
        if total > 0.85 and total > 0:
            scale = 0.85 / total
            final = {symbol: weight * scale for symbol, weight in final.items()}
        return {symbol: weight for symbol, weight in final.items() if weight > 0.0001}

    return patched_overlay


def prepare_context(end_date: str) -> PreparedRunContext:
    cutoff = parse_day(end_date)
    raw = app.fetch_public_history(end_date=cutoff)
    prepared = app.prepare_series(raw)
    dates, prices_by_symbol = app.align_rotation_price_series(prepared)
    symbols = [p.symbol for p in prepared]
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


def run_prepared_strategy(context: PreparedRunContext) -> app.BacktestResult:
    strategy = "coreGoldSatelliteHeatCappedMomentum"
    initial_cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    band = max(context.config.rebalance_band, 0.0)
    tradable_symbols = [s for s in context.symbols if s not in context.config.signal_only_symbols]
    cash = initial_cash
    units = {sym: 0.0 for sym in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    trades: list[app.Trade] = []
    last_rebalance_index = -10**9

    def portfolio_value(index: int) -> float:
        return cash + sum(units[sym] * context.prices_by_symbol[sym][index] for sym in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        if context.config.meta_switch and context.meta_traces is not None:
            raw_weights = app.meta_rotation_target_weights(context.config.meta_switch, signal_index, trace_index, context.meta_traces)
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
            if app.math.isfinite(interest) and interest > 0:
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
            targets = base_targets if context.config.meta_switch else app.apply_portfolio_guard(base_targets, pre_value, points, context.config)
            target_symbols = set(targets.keys())

            for sym in sorted(held - target_symbols):
                price = context.prices_by_symbol[sym][index]
                current_units = units.get(sym, 0.0)
                if current_units <= 0:
                    continue
                execution_price = max(price * (1 - slippage_rate), 0.0)
                gross = current_units * execution_price
                cash_amount = gross * (1 - fee_rate)
                cash += cash_amount
                units[sym] = 0.0
                trades.append(app.Trade(current_date.isoformat(), "sell", sym, execution_price, cash_amount, current_units))
            held &= target_symbols

            for sym in sorted(target_symbols):
                current_units = units.get(sym, 0.0)
                if current_units <= 0:
                    continue
                price = context.prices_by_symbol[sym][index]
                current_value = current_units * price
                target_value = pre_value * targets[sym]
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
                units[sym] = max(current_units - units_to_sell, 0.0)
                trades.append(app.Trade(current_date.isoformat(), "sell", sym, execution_price, cash_amount, units_to_sell))
                if units[sym] <= sys.float_info.min:
                    held.discard(sym)

            total_value = portfolio_value(index)
            for sym in sorted(target_symbols):
                price = context.prices_by_symbol[sym][index]
                if price <= 0:
                    continue
                current_value = units.get(sym, 0.0) * price
                target_value = total_value * targets[sym]
                amount = min(cash, max(target_value - current_value, 0.0)) if current_value < target_value * (1 - band) else 0.0
                if amount <= 0:
                    continue
                execution_price = price * (1 + slippage_rate)
                invested = amount * (1 - fee_rate)
                bought_units = invested / execution_price if execution_price > 0 else 0.0
                units[sym] = units.get(sym, 0.0) + bought_units
                cash -= amount
                held.add(sym)
                trades.append(app.Trade(current_date.isoformat(), "buy", sym, execution_price, amount, bought_units))
            last_rebalance_index = index

        points.append(portfolio_value(index))

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(context.dates, points)
    return app.BacktestResult(
        strategy=strategy,
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


def run_one(
    context: PreparedRunContext,
    *,
    cap: float,
    long_lookback: int,
    long_threshold: float,
    short_lookback: int,
    short_threshold: float,
) -> Candidate:
    original_overlay = app.apply_gold_satellite_overlay
    app.apply_gold_satellite_overlay = make_overlay(
        cap=cap,
        long_lookback=long_lookback,
        long_threshold=long_threshold,
        short_lookback=short_lookback,
        short_threshold=short_threshold,
    )  # type: ignore[assignment]
    try:
        result = run_prepared_strategy(context)
    finally:
        app.apply_gold_satellite_overlay = original_overlay  # type: ignore[assignment]

    return Candidate(
        cap=cap,
        long_lookback=long_lookback,
        long_threshold=long_threshold,
        short_lookback=short_lookback,
        short_threshold=short_threshold,
        full={
            "annualized": result.annualized_return,
            "max_drawdown": result.max_drawdown,
            "total": result.total_return,
            "sharpe": result.sharpe_ratio,
            "trades": len(result.trades),
            "coverage_start": result.coverage_start,
            "coverage_end": result.coverage_end,
        },
        slices={
            "post_2020": slice_metrics(result, "2020-01-01"),
            "last_10y": slice_metrics(result, "2016-06-19"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        drawdown_window=max_drawdown_window(result),
    )


def candidate_score(candidate: Candidate) -> float:
    full_ann = float(candidate.full["annualized"] or 0)
    full_dd = float(candidate.full["max_drawdown"] or 1)
    post_2020 = candidate.slices["post_2020"]
    last_10y = candidate.slices["last_10y"]
    post_2024 = candidate.slices["post_2024"]
    return (
        full_ann * 2.0
        + float(post_2020["annualized"] or 0) * 0.35
        + float(last_10y["annualized"] or 0) * 0.25
        + float(post_2024["annualized"] or 0) * 0.15
        - full_dd * 1.8
        - max(full_dd - 0.10, 0) * 12
    )


def main() -> None:
    end_date = "2026-06-19"
    context = prepare_context(end_date)
    rows: list[Candidate] = []
    original_moving_average = app.moving_average
    app.moving_average = cached_moving_average  # type: ignore[assignment]
    try:
        for cap in [0.44, 0.45, 0.46, 0.48, 0.50]:
            for long_lookback in [75, 90, 105]:
                for long_threshold in [0.06, 0.08, 0.10]:
                    for short_lookback in [15, 20, 25]:
                        for short_threshold in [-0.01, 0.0, 0.01]:
                            rows.append(
                                run_one(
                                    context,
                                    cap=cap,
                                    long_lookback=long_lookback,
                                    long_threshold=long_threshold,
                                    short_lookback=short_lookback,
                                    short_threshold=short_threshold,
                                )
                            )
    finally:
        app.moving_average = original_moving_average  # type: ignore[assignment]

    rows.sort(key=lambda item: (float(item.full["max_drawdown"] or 1) <= 0.10, candidate_score(item)), reverse=True)
    under_10 = [row for row in rows if float(row.full["max_drawdown"] or 1) <= 0.10]
    under_98 = [row for row in rows if float(row.full["max_drawdown"] or 1) <= 0.098]

    output = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "evaluated": len(rows),
        "top_score": [asdict(row) | {"score": candidate_score(row)} for row in rows[:30]],
        "under_10_by_return": [
            asdict(row) | {"score": candidate_score(row)}
            for row in sorted(under_10, key=lambda item: float(item.full["annualized"] or 0), reverse=True)[:30]
        ],
        "under_9_8_by_return": [
            asdict(row) | {"score": candidate_score(row)}
            for row in sorted(under_98, key=lambda item: float(item.full["annualized"] or 0), reverse=True)[:30]
        ],
    }
    result_path = Path(__file__).with_name("results.json")
    result_path.write_text(json.dumps(output, ensure_ascii=False, indent=2))

    print(f"WROTE {result_path}")
    for section in ["under_10_by_return", "under_9_8_by_return", "top_score"]:
        print(f"\n== {section} ==")
        for index, row in enumerate(output[section][:10], 1):
            full: dict[str, Any] = row["full"]
            slices: dict[str, dict[str, Any]] = row["slices"]
            ddw: dict[str, Any] = row["drawdown_window"]
            print(
                index,
                "ann", pct(full["annualized"]),
                "dd", pct(full["max_drawdown"]),
                "post2020", f"{pct(slices['post_2020']['annualized'])}/{pct(slices['post_2020']['max_drawdown'])}",
                "last10", f"{pct(slices['last_10y']['annualized'])}/{pct(slices['last_10y']['max_drawdown'])}",
                "post2024", f"{pct(slices['post_2024']['annualized'])}/{pct(slices['post_2024']['max_drawdown'])}",
                "cap", row["cap"],
                "long", row["long_lookback"],
                row["long_threshold"],
                "short", row["short_lookback"],
                row["short_threshold"],
                "ddwin", f"{ddw['peak_date']}->{ddw['trough_date']}",
            )


if __name__ == "__main__":
    main()
