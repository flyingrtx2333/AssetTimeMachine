#!/usr/bin/env python3
"""Seasonal quality risk budget on the current champion.

The champion's monthly return profile has persistent weak spots in February,
June, September, and October.  This spike does not blindly exit by month; it
tests whether weak-season risk reduction only when momentum quality is also bad
can improve Sharpe without cutting the strong November/December effect.
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


@dataclass(frozen=True)
class SeasonalSpec:
    name: str
    thesis: str
    months: tuple[int, ...]
    mode: str
    scale: float
    momentum_lookback: int


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    clean = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = sum(clean.values())
    if total > max_total and total > 0:
        factor = max_total / total
        clean = {symbol: weight * factor for symbol, weight in clean.items() if weight * factor > 0.0001}
    return clean


def scale_all(weights: dict[str, float], factor: float) -> dict[str, float]:
    factor = min(max(factor, 0.0), 1.0)
    return normalize({symbol: weight * factor for symbol, weight in weights.items()})


def equity_exposure(weights: dict[str, float]) -> float:
    return sum(max(weights.get(symbol, 0.0), 0.0) for symbol in app.EQUITY_SYMBOLS)


def scale_equity(weights: dict[str, float], factor: float) -> dict[str, float]:
    factor = min(max(factor, 0.0), 1.0)
    out = dict(weights)
    for symbol in app.EQUITY_SYMBOLS:
        if out.get(symbol, 0.0) > 0:
            out[symbol] *= factor
    return normalize(out)


def momentum(prices_by_symbol: dict[str, list[float]], symbol: str, index: int, lookback: int) -> float | None:
    if symbol not in prices_by_symbol:
        return None
    return app.price_momentum(prices_by_symbol[symbol], index, lookback)


def selected_quality_bad(
    weights: dict[str, float],
    prices_by_symbol: dict[str, list[float]],
    index: int,
    lookback: int,
) -> bool:
    selected = [symbol for symbol, weight in weights.items() if weight > 0.05 and symbol in prices_by_symbol]
    if not selected:
        return False
    bad = 0
    for symbol in selected:
        mom = momentum(prices_by_symbol, symbol, index, lookback)
        if mom is not None and mom < 0:
            bad += 1
    return bad >= max(1, len(selected) // 2)


def us_quality_bad(prices_by_symbol: dict[str, list[float]], index: int, lookback: int) -> bool:
    bad = 0
    for symbol in ["sp500", "nasdaq"]:
        mom = momentum(prices_by_symbol, symbol, index, lookback)
        if mom is not None and mom < 0:
            bad += 1
    return bad >= 1


def portfolio_return(values: list[float], index: int, lookback: int) -> float:
    clean = [value for value in values[: index + 1] if value > 0]
    if len(clean) <= lookback or clean[-lookback - 1] <= 0:
        return 0.0
    return clean[-1] / clean[-lookback - 1] - 1


def apply_seasonal(
    weights: dict[str, float],
    spec: SeasonalSpec,
    day: date,
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
    values_by_index: list[float],
) -> dict[str, float]:
    if day.month not in spec.months:
        return weights

    if spec.mode == "selected_equity_bad":
        if equity_exposure(weights) > 0.15 and selected_quality_bad(weights, prices_by_symbol, signal_index, spec.momentum_lookback):
            return scale_equity(weights, spec.scale)
        return weights

    if spec.mode == "us_bad_equity":
        if equity_exposure(weights) > 0.15 and us_quality_bad(prices_by_symbol, signal_index, spec.momentum_lookback):
            return scale_equity(weights, spec.scale)
        return weights

    if spec.mode == "selected_bad_total":
        if selected_quality_bad(weights, prices_by_symbol, signal_index, spec.momentum_lookback):
            return scale_all(weights, spec.scale)
        return weights

    if spec.mode == "profit_lock_total":
        recent = portfolio_return(values_by_index, signal_index, 60)
        if recent > 0.06:
            return scale_all(weights, spec.scale)
        return weights

    if spec.mode == "us_bad_or_profit":
        recent = portfolio_return(values_by_index, signal_index, 60)
        if us_quality_bad(prices_by_symbol, signal_index, spec.momentum_lookback) or recent > 0.06:
            return scale_equity(weights, spec.scale)
        return weights

    raise ValueError(spec.mode)


def run_seasonal_strategy(spec: SeasonalSpec, env: s30.BacktestEnv) -> app.BacktestResult:
    dates = env.dates
    prices_by_symbol = env.prices_by_symbol
    config = env.config
    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    tradable_symbols = [symbol for symbol in env.symbols if symbol not in config.signal_only_symbols]
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, env.meta_traces) if config.meta_switch else {}
        champion = env.champion_overlay(raw_weights or {}, signal_index, dates[signal_index], prices_by_symbol, values_by_index, config)
        return apply_seasonal(champion, spec, dates[signal_index], prices_by_symbol, signal_index, values_by_index)

    for index in range(len(dates)):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index == 0 or index % max(config.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = normalize(target_weights(signal_index, index) if signal_index >= 0 else {})
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


def row_for(spec: SeasonalSpec, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": {
            "months": list(spec.months),
            "mode": spec.mode,
            "scale": spec.scale,
            "momentum_lookback": spec.momentum_lookback,
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


def specs() -> list[SeasonalSpec]:
    month_sets = {
        "weak4": (2, 6, 9, 10),
        "autumn": (9, 10),
        "soft6": (2, 3, 6, 8, 9, 10),
        "summer_autumn": (6, 8, 9, 10),
    }
    out: list[SeasonalSpec] = []
    for label, months in month_sets.items():
        for mode in ["selected_equity_bad", "us_bad_equity", "selected_bad_total", "profit_lock_total", "us_bad_or_profit"]:
            for lookback in [20, 40, 60]:
                for factor in [0.35, 0.50, 0.65, 0.80]:
                    name = f"{label}_{mode}_lb{lookback}_f{int(factor*100)}"
                    out.append(SeasonalSpec(name, "Weak-season risk budget with momentum-quality confirmation.", months, mode, factor, lookback))
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
        current = s30.s28.run_overlay_strategy("current_gold_handoff", base.current_overlay, 60)
        breadth = s30.s28.run_overlay_strategy("equity_breadth", base.breadth_overlay, 60)
        env = s30.build_env(base.EngineContext(current=current, breadth=breadth))
        rows = [row_for(spec, run_seasonal_strategy(spec, env)) for spec in specs()]
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
