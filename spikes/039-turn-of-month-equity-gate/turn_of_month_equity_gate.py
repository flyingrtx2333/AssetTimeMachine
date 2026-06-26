#!/usr/bin/env python3
"""Turn-of-month equity gate on top of the current champion.

No leverage, no shorting, no BTC.  This tests a structural calendar anomaly:
equity exposure is allowed to be high near month start/end and reduced during
the middle of the month.  Gold exposure is not calendar-gated.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

S30_PATH = ROOT / "spikes" / "030-smooth-risk-budget" / "smooth_risk_budget.py"
SPEC = importlib.util.spec_from_file_location("smooth_risk_budget_base", S30_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"failed to load {S30_PATH}")
s30 = importlib.util.module_from_spec(SPEC)
sys.modules["smooth_risk_budget_base"] = s30
SPEC.loader.exec_module(s30)

app = s30.app
base = s30.base
EQUITIES = set(app.EQUITY_SYMBOLS)


@dataclass(frozen=True)
class CalendarSpec:
    name: str
    thesis: str
    first_days: int
    last_days: int
    off_window_equity_scale: float
    redeploy_removed_to_gold: float
    keep_if_equity_strong: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    clean = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(clean)
    if total > max_total and total > 0:
        factor = max_total / total
        clean = {symbol: weight * factor for symbol, weight in clean.items() if weight * factor > 0.0001}
    return clean


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0:
        return None
    previous = values[index - lookback]
    if previous <= 0:
        return None
    return values[index] / previous - 1


def moving_average(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    return sum(values[index - period + 1 : index + 1]) / period


def gold_can_accept(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    gold = prices_by_symbol["gold_cny"]
    mom60 = momentum(gold, index, 60)
    ma90 = moving_average(gold, index, 90)
    return mom60 is not None and ma90 is not None and mom60 > -0.02 and gold[index] >= ma90


def equity_is_strong(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    strong = 0
    for symbol in ["nasdaq", "sp500"]:
        prices = prices_by_symbol[symbol]
        mom60 = momentum(prices, index, 60)
        mom120 = momentum(prices, index, 120)
        ma120 = moving_average(prices, index, 120)
        if mom60 is not None and mom120 is not None and ma120 is not None and mom60 > 0.03 and mom120 > 0 and prices[index] >= ma120:
            strong += 1
    return strong >= 2


def month_positions(dates: list[date]) -> tuple[list[int], list[int]]:
    first_positions: list[int] = [0] * len(dates)
    remaining_positions: list[int] = [0] * len(dates)
    by_month: dict[tuple[int, int], list[int]] = {}
    for index, day in enumerate(dates):
        by_month.setdefault((day.year, day.month), []).append(index)
    for indices in by_month.values():
        count = len(indices)
        for offset, index in enumerate(indices):
            first_positions[index] = offset + 1
            remaining_positions[index] = count - offset
    return first_positions, remaining_positions


def in_turn_window(spec: CalendarSpec, first_pos: int, remaining_pos: int) -> bool:
    return first_pos <= spec.first_days or remaining_pos <= spec.last_days


def apply_calendar_gate(
    base_target: dict[str, float],
    spec: CalendarSpec,
    prices_by_symbol: dict[str, list[float]],
    index: int,
    first_pos: int,
    remaining_pos: int,
) -> dict[str, float]:
    if in_turn_window(spec, first_pos, remaining_pos):
        return base_target
    if spec.keep_if_equity_strong and equity_is_strong(prices_by_symbol, index):
        return base_target
    out = dict(base_target)
    removed = 0.0
    for symbol in EQUITIES:
        current = out.get(symbol, 0.0)
        if current <= 0:
            continue
        scaled = current * spec.off_window_equity_scale
        out[symbol] = scaled
        removed += current - scaled
    if removed > 0 and spec.redeploy_removed_to_gold > 0 and gold_can_accept(prices_by_symbol, index):
        out["gold_cny"] = out.get("gold_cny", 0.0) + removed * spec.redeploy_removed_to_gold
    return normalize(out)


def build_env() -> s30.BacktestEnv:
    current = s30.s28.run_overlay_strategy("current_gold_handoff", base.current_overlay, 60)
    breadth = s30.s28.run_overlay_strategy("equity_breadth", base.breadth_overlay, 60)
    return s30.build_env(base.EngineContext(current=current, breadth=breadth))


def run_calendar_strategy(spec: CalendarSpec, env: s30.BacktestEnv) -> app.BacktestResult:
    dates = env.dates
    prices_by_symbol = env.prices_by_symbol
    config = env.config
    first_positions, remaining_positions = month_positions(dates)
    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    tradable_symbols = [symbol for symbol in env.symbols if symbol not in config.signal_only_symbols]
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []
    scheduled_target: dict[str, float] = {}
    last_effective_target: dict[str, float] | None = None

    def targets_changed(first: dict[str, float] | None, second: dict[str, float], tolerance: float = 0.000001) -> bool:
        if first is None:
            return True
        symbols = set(first) | set(second)
        return any(abs(first.get(symbol, 0.0) - second.get(symbol, 0.0)) > tolerance for symbol in symbols)

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def scheduled_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, env.meta_traces) if config.meta_switch else {}
        return env.champion_overlay(raw_weights or {}, signal_index, dates[signal_index], prices_by_symbol, values_by_index, config)

    def rebalance_to(targets: dict[str, float], index: int) -> None:
        nonlocal cash, held
        targets = normalize(targets)
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

        scheduled_rebalance = index == 0 or index % max(config.rebalance_sessions, 1) == 0
        if scheduled_rebalance:
            signal_index = index - 1
            scheduled_target = scheduled_weights(signal_index, index) if signal_index >= 0 else {}

        signal_index = max(index - 1, 0)
        effective_target = apply_calendar_gate(
            scheduled_target,
            spec,
            prices_by_symbol,
            signal_index,
            first_positions[index],
            remaining_positions[index],
        )
        if scheduled_rebalance or targets_changed(last_effective_target, effective_target):
            rebalance_to(effective_target, index)
            last_effective_target = dict(effective_target)

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
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = i
    return {"peak_date": result.dates[worst_peak].isoformat(), "trough_date": result.dates[worst_trough].isoformat(), "max_drawdown": worst}


def row_for(spec: CalendarSpec, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": {
            "first_days": spec.first_days,
            "last_days": spec.last_days,
            "off_window_equity_scale": spec.off_window_equity_scale,
            "redeploy_removed_to_gold": spec.redeploy_removed_to_gold,
            "keep_if_equity_strong": spec.keep_if_equity_strong,
        },
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
            "last_10y": slice_metrics(result, "2016-06-23"),
            "post_2022": slice_metrics(result, "2022-01-01"),
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-8:]],
    }


def specs() -> list[CalendarSpec]:
    out = [CalendarSpec("baseline_one_way", "Current champion reproduced in this spike.", 99, 99, 1.0, 0.0, True)]
    for first_days in [3, 5, 7]:
        for last_days in [2, 4, 6]:
            for off_scale in [0.0, 0.25, 0.50]:
                for redeploy in [0.0, 0.50]:
                    for keep_strong in [False, True]:
                        out.append(
                            CalendarSpec(
                                f"turn_f{first_days}_l{last_days}_off{int(off_scale*100)}_gold{int(redeploy*100)}_{'keep' if keep_strong else 'cut'}",
                                "Gate equity exposure to month-turn windows while leaving gold ungated.",
                                first_days,
                                last_days,
                                off_scale,
                                redeploy,
                                keep_strong,
                            )
                        )
    return out


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
        env = build_env()
        rows = [row_for(spec, run_calendar_strategy(spec, env)) for spec in specs()]
    finally:
        app.fetch_public_history = original_fetch  # type: ignore[assignment]

    rows.sort(key=lambda row: (row["full"]["sharpe"] or 0.0, row["full"]["annualized"]), reverse=True)  # type: ignore[index]
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps({"generated_at": datetime.now().isoformat(timespec="seconds"), "rows": rows}, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades | dd window")
    for row in rows[:30]:
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
