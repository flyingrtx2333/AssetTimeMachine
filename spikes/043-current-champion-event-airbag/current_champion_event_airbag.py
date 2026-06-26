#!/usr/bin/env python3
"""Daily event airbag on the current one-way champion.

No leverage, no shorting, no BTC. This spike tests a different mechanism from
scheduled rotation parameters: keep the current champion, but add a mild daily
equity airbag after target weights are produced.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import json
import math
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402


@dataclass(frozen=True)
class AirbagSpec:
    name: str
    thesis: str
    mode: str
    equity_scale: float
    redeploy_gold_ratio: float
    cooldown_sessions: int


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    clean = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = sum(clean.values())
    if total > max_total and total > 0:
        factor = max_total / total
        clean = {symbol: weight * factor for symbol, weight in clean.items() if weight * factor > 0.0001}
    return clean


def equity_weight(weights: dict[str, float]) -> float:
    return sum(max(weights.get(symbol, 0.0), 0.0) for symbol in app.EQUITY_SYMBOLS)


def build_context(end_date: date):
    raw = app.fetch_public_history(end_date=end_date)
    prepared = app.prepare_series(raw)
    dates, prices_by_symbol = app.align_rotation_price_series(prepared)
    symbols = [series.symbol for series in prepared]
    config = app.strategy_config("coreGoldSatelliteHeatCappedMomentum")
    current = app.run_strategy("coreGoldSatelliteGoldHandoffMomentum", end_date=end_date)
    breadth = app.run_strategy("coreGoldSatelliteEquityBreadthMomentum", end_date=end_date)
    meta_traces = {
        config.meta_switch.default_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.default_mode)),
        config.meta_switch.defensive_mode: app.simulated_rotation_trace(symbols, prices_by_symbol, dates, app.strategy_config(config.meta_switch.defensive_mode)),
    }
    overlay = app._one_way_vol_managed_overlay(current, breadth)(app._overlay_gold_rollover_cap(app.apply_gold_satellite_overlay))
    ma = {
        "gold_90": app.moving_average(prices_by_symbol["gold_cny"], 90),
        "sp500_40": app.moving_average(prices_by_symbol["sp500"], 40),
        "nasdaq_40": app.moving_average(prices_by_symbol["nasdaq"], 40),
    }
    return dates, prices_by_symbol, symbols, config, meta_traces, overlay, ma


def gold_ok(prices: dict[str, list[float]], ma: dict[str, list[float | None]], index: int) -> bool:
    mom60 = app.price_momentum(prices["gold_cny"], index, 60)
    ma90 = ma["gold_90"][index]
    return mom60 is not None and ma90 is not None and mom60 > -0.02 and prices["gold_cny"][index] >= ma90


def us_shock(prices: dict[str, list[float]], ma: dict[str, list[float | None]], index: int, mode: str) -> bool:
    sp20 = app.price_momentum(prices["sp500"], index, 20)
    sp60 = app.price_momentum(prices["sp500"], index, 60)
    nd20 = app.price_momentum(prices["nasdaq"], index, 20)
    nd60 = app.price_momentum(prices["nasdaq"], index, 60)
    sp_ma = ma["sp500_40"][index]
    nd_ma = ma["nasdaq_40"][index]
    broad_break = (
        sp20 is not None and sp60 is not None and nd20 is not None
        and sp20 < -0.045 and sp60 < 0 and nd20 < -0.045
    )
    nasdaq_break = nd20 is not None and nd60 is not None and nd20 < -0.075 and nd60 < 0
    ma_break = (
        sp_ma is not None and nd_ma is not None
        and prices["sp500"][index] < sp_ma and prices["nasdaq"][index] < nd_ma
        and sp20 is not None and nd20 is not None and sp20 < 0 and nd20 < 0
    )
    if "strict" in mode:
        return broad_break or (nasdaq_break and ma_break)
    if "ma" in mode:
        return broad_break or ma_break
    return broad_break or nasdaq_break


def held_asset_breakdown(prices: dict[str, list[float]], ma: dict[str, list[float | None]], weights: dict[str, float], index: int) -> set[str]:
    broken: set[str] = set()
    for symbol in app.EQUITY_SYMBOLS:
        if weights.get(symbol, 0.0) <= 0.03:
            continue
        mom20 = app.price_momentum(prices[symbol], index, 20)
        dd20 = app.rolling_drawdown_from_high(prices[symbol], index, 20)
        ma40 = ma.get(f"{symbol}_40")
        below_ma = ma40 is not None and ma40[index] is not None and prices[symbol][index] < ma40[index]
        if mom20 is not None and dd20 is not None and below_ma and mom20 < -0.035 and dd20 < -0.055:
            broken.add(symbol)
    return broken


def apply_airbag(
    weights: dict[str, float],
    spec: AirbagSpec | None,
    prices: dict[str, list[float]],
    ma: dict[str, list[float | None]],
    index: int,
    state: dict[str, int],
) -> dict[str, float]:
    if spec is None or equity_weight(weights) <= 0.10:
        return normalize(weights)

    trigger = us_shock(prices, ma, index, spec.mode)
    broken = held_asset_breakdown(prices, ma, weights, index) if "held" in spec.mode else set()
    if trigger or broken:
        state["until"] = max(state.get("until", -1), index + spec.cooldown_sessions)
        if broken:
            state["broken_count"] = state.get("broken_count", 0) + len(broken)

    active = state.get("until", -1) >= index
    if not active and not broken:
        return normalize(weights)

    out = dict(weights)
    removed = 0.0
    for symbol in app.EQUITY_SYMBOLS:
        old = out.get(symbol, 0.0)
        if old <= 0:
            continue
        scale = 0.0 if symbol in broken else spec.equity_scale
        out[symbol] = old * scale
        removed += old - out[symbol]
    if removed > 0 and gold_ok(prices, ma, index):
        out["gold_cny"] = out.get("gold_cny", 0.0) + removed * spec.redeploy_gold_ratio
    return normalize(out)


def run_airbag(spec: AirbagSpec | None, end_date: date = app.parse_date("2026-06-23")) -> app.BacktestResult:
    dates, prices_by_symbol, _symbols, config, meta_traces, overlay, ma = build_context(end_date)
    tradable_symbols = [symbol for symbol in prices_by_symbol if symbol not in config.signal_only_symbols]
    tradable_symbols = [symbol for symbol in tradable_symbols if symbol in {"gold_cny", "nasdaq", "sp500", "shanghai_composite", "csi300"}]

    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    band = max(config.rebalance_band, 0.0)
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []
    weights: dict[str, float] = {}
    state: dict[str, int] = {"until": -1}

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, meta_traces) if config.meta_switch else {}
        champion = overlay(raw_weights or {}, signal_index, dates[signal_index], prices_by_symbol, values_by_index, config)
        return apply_airbag(champion, spec, prices_by_symbol, ma, signal_index, state)

    def rebalance_to(index: int, targets: dict[str, float]) -> None:
        nonlocal cash, held, weights
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
            gross_to_sell = max(current_value - target_value, 0.0) if current_value > target_value * (1 + band) else 0.0
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
            amount = min(cash, max(target_value - current_value, 0.0)) if current_value < target_value * (1 - band) else 0.0
            if amount <= 0:
                continue
            execution_price = price * (1 + slippage_rate)
            bought_units = amount * (1 - fee_rate) / execution_price if execution_price > 0 else 0.0
            units[symbol] = units.get(symbol, 0.0) + bought_units
            cash -= amount
            held.add(symbol)
            trades.append(app.Trade(dates[index].isoformat(), "buy", symbol, execution_price, amount, bought_units))
        weights = dict(targets)

    for index in range(len(dates)):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index == 0 or index % max(config.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = target_weights(signal_index, index) if signal_index >= 0 else {}
            rebalance_to(index, targets)
        elif spec is not None:
            guarded = apply_airbag(weights, spec, prices_by_symbol, ma, index - 1, state)
            if guarded != weights:
                rebalance_to(index, guarded)

        value = portfolio_value(index)
        points.append(value)
        values_by_index[index] = value

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, points)
    return app.BacktestResult(
        strategy=spec.name if spec else "baseline_one_way",
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


def row_for(spec: AirbagSpec | None, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": result.strategy,
        "thesis": spec.thesis if spec else "Current app champion, no daily event airbag.",
        "spec": None if spec is None else spec.__dict__,
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
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-10:]],
    }


def specs() -> list[AirbagSpec]:
    return [
        AirbagSpec("partial_us_airbag_20", "Scale equities after broad US shock; keep part of risk and redeploy some cut to gold.", "broad", 0.55, 0.60, 20),
        AirbagSpec("partial_us_airbag_40", "Same trigger, longer cooldown.", "broad", 0.55, 0.60, 40),
        AirbagSpec("ma_confirmed_airbag_20", "Require moving-average break confirmation before scaling equities.", "ma", 0.55, 0.60, 20),
        AirbagSpec("strict_airbag_20", "Only fire on stricter broad shock confirmation.", "strict", 0.55, 0.60, 20),
        AirbagSpec("held_breakdown_airbag_20", "Remove held equity assets that individually break down, otherwise use broad airbag.", "held_broad", 0.60, 0.55, 20),
        AirbagSpec("held_breakdown_airbag_40", "Held-asset breakdown with longer cooldown.", "held_broad", 0.60, 0.55, 40),
        AirbagSpec("deep_partial_airbag_20", "Cut equity risk more aggressively only after broad shock.", "broad", 0.35, 0.70, 20),
    ]


def main() -> None:
    rows = [row_for(None, run_airbag(None))]
    rows.extend(row_for(spec, run_airbag(spec)) for spec in specs())
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
