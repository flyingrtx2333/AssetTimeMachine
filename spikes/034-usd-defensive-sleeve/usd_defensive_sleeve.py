#!/usr/bin/env python3
"""USD defensive sleeve candidates.

Holding USD cash is not leverage or financing.  In a CNY-denominated backtest,
USD cash can act as a low-correlation defensive asset.  This spike keeps the
current champion target untouched by default and first uses only idle cash
budget for USD exposure.
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
USD_SYMBOL = "usd_cash"


@dataclass(frozen=True)
class UsdSpec:
    name: str
    thesis: str
    mode: str
    lookback: int
    cap: float
    risk_scale: float


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
    if index - lookback < 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def moving_average(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    return sum(values[index - period + 1 : index + 1]) / period


def usd_trend_ok(prices: list[float], index: int, lookback: int) -> bool:
    mom = momentum(prices, index, lookback)
    ma = moving_average(prices, index, max(lookback, 60))
    return mom is not None and mom > 0 and ma is not None and prices[index] >= ma


def equity_exposure(weights: dict[str, float]) -> float:
    return sum(max(weights.get(symbol, 0.0), 0.0) for symbol in app.EQUITY_SYMBOLS)


def equity_stress(prices_by_symbol: dict[str, list[float]], index: int) -> bool:
    bad = 0
    for symbol in ["sp500", "nasdaq"]:
        mom = app.price_momentum(prices_by_symbol[symbol], index, 60)
        ma = app.moving_average(prices_by_symbol[symbol], 120)[index]
        if mom is not None and mom < 0:
            bad += 1
        elif ma is not None and prices_by_symbol[symbol][index] < ma:
            bad += 1
    return bad >= 1


def add_usd_target(
    champion: dict[str, float],
    spec: UsdSpec,
    prices_by_symbol: dict[str, list[float]],
    signal_index: int,
) -> dict[str, float]:
    out = dict(champion)
    usd_prices = prices_by_symbol[USD_SYMBOL]
    leftover = max(0.0, 1.0 - total_weight(out))
    trend_ok = usd_trend_ok(usd_prices, signal_index, spec.lookback)

    if spec.mode == "unused_always":
        out[USD_SYMBOL] = min(leftover, spec.cap)
        return normalize(out)

    if spec.mode == "unused_trend":
        if trend_ok:
            out[USD_SYMBOL] = min(leftover, spec.cap)
        return normalize(out)

    if spec.mode == "unused_or_riskoff":
        if trend_ok or equity_stress(prices_by_symbol, signal_index):
            out[USD_SYMBOL] = min(leftover, spec.cap)
        return normalize(out)

    if spec.mode == "riskoff_replace_equity":
        if trend_ok and equity_stress(prices_by_symbol, signal_index) and equity_exposure(out) > 0:
            freed = 0.0
            for symbol in app.EQUITY_SYMBOLS:
                old = out.get(symbol, 0.0)
                if old > 0:
                    new = old * spec.risk_scale
                    out[symbol] = new
                    freed += old - new
            out[USD_SYMBOL] = min(leftover + freed, spec.cap)
        elif trend_ok:
            out[USD_SYMBOL] = min(leftover, spec.cap)
        return normalize(out)

    if spec.mode == "cash_yield_switch":
        usd_mom = momentum(usd_prices, signal_index, spec.lookback) or 0.0
        cny_cash = app.cash_annual_rate(app.parse_date("2026-06-23")) * spec.lookback / app.TRADING_DAYS_PER_YEAR
        if usd_mom > cny_cash:
            out[USD_SYMBOL] = min(leftover, spec.cap)
        return normalize(out)

    raise ValueError(spec.mode)


def build_env() -> s30.BacktestEnv:
    current = s30.s28.run_overlay_strategy("current_gold_handoff", base.current_overlay, 60)
    breadth = s30.s28.run_overlay_strategy("equity_breadth", base.breadth_overlay, 60)
    return s30.build_env(base.EngineContext(current=current, breadth=breadth))


def add_usd_series(env: s30.BacktestEnv) -> dict[str, list[float]]:
    prices = {symbol: list(values) for symbol, values in env.prices_by_symbol.items()}
    raw = app.fetch_public_history(end_date=app.parse_date("2026-06-23"))
    fx = raw[app.USD_FX_SYMBOL]
    usd_prices: list[float] = []
    for day in env.dates:
        fx_rate = app.price_on_or_before(fx, day)
        if fx_rate is None or fx_rate <= 0:
            raise RuntimeError(f"missing FX for {day}")
        # App convention: usd_per_cny is USD per CNY when below 1, so CNY per
        # USD is its reciprocal.  If the feed ever stores CNY per USD directly,
        # use it as-is for consistency with app conversion logic.
        usd_prices.append(1 / fx_rate if fx_rate < 1 else fx_rate)
    prices[USD_SYMBOL] = usd_prices
    return prices


def run_usd_strategy(spec: UsdSpec, env: s30.BacktestEnv) -> app.BacktestResult:
    dates = env.dates
    prices_by_symbol = add_usd_series(env)
    config = env.config
    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    tradable_symbols = [symbol for symbol in env.symbols if symbol not in config.signal_only_symbols] + [USD_SYMBOL]
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
        return add_usd_target(champion, spec, prices_by_symbol, signal_index)

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


def row_for(spec: UsdSpec, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": {
            "mode": spec.mode,
            "lookback": spec.lookback,
            "cap": spec.cap,
            "risk_scale": spec.risk_scale,
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


def specs() -> list[UsdSpec]:
    out: list[UsdSpec] = []
    for mode in ["unused_always", "unused_trend", "unused_or_riskoff", "riskoff_replace_equity", "cash_yield_switch"]:
        for lookback in [40, 60, 120, 240]:
            for cap in [0.15, 0.25, 0.40, 1.00]:
                for risk_scale in ([0.50, 0.70] if mode == "riskoff_replace_equity" else [1.0]):
                    name = f"{mode}_lb{lookback}_cap{int(cap*100)}_rs{int(risk_scale*100)}"
                    out.append(UsdSpec(name, "Use USD cash as a no-leverage defensive sleeve.", mode, lookback, cap, risk_scale))
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
        rows = [row_for(spec, run_usd_strategy(spec, env)) for spec in specs()]
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
