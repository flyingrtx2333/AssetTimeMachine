#!/usr/bin/env python3
"""China bubble contagion quarantine on the current champion.

No leverage, no shorting, no BTC. This tests a specific mechanism: after an
A-share bubble rollover, do not immediately hand risk to other equities unless
US equities have repaired. The current one-way champion remains the base.
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

import atm_app_equivalent_backtest as app  # noqa: E402

S43_PATH = ROOT / "spikes" / "043-current-champion-event-airbag" / "current_champion_event_airbag.py"
SPEC43 = importlib.util.spec_from_file_location("current_champion_airbag_base", S43_PATH)
if SPEC43 is None or SPEC43.loader is None:
    raise RuntimeError(f"failed to load {S43_PATH}")
s43 = importlib.util.module_from_spec(SPEC43)
sys.modules["current_champion_airbag_base"] = s43
SPEC43.loader.exec_module(s43)


@dataclass(frozen=True)
class QuarantineSpec:
    name: str
    thesis: str
    cooldown_sessions: int
    equity_scale: float
    redeploy_gold_ratio: float
    repair_required: bool


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    return s43.normalize(weights, max_total)


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    return app.price_momentum(values, index, lookback)


def moving_average(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    return sum(values[index - period + 1:index + 1]) / period


def rolling_dd(values: list[float], index: int, lookback: int) -> float | None:
    return app.rolling_drawdown_from_high(values, index, lookback)


def china_bubble_rollover(prices: dict[str, list[float]], index: int) -> bool:
    broken = 0
    for symbol in ["shanghai_composite", "csi300"]:
        values = prices[symbol]
        mom20 = momentum(values, index, 20)
        mom60 = momentum(values, index, 60)
        mom120 = momentum(values, index, 120)
        dd20 = rolling_dd(values, index, 20)
        dd60 = rolling_dd(values, index, 60)
        ma40 = moving_average(values, index, 40)
        if None in (mom20, mom60, mom120, dd20, dd60, ma40):
            continue
        assert mom20 is not None and mom60 is not None and mom120 is not None and dd20 is not None and dd60 is not None and ma40 is not None
        hot = mom120 > 0.35 or mom60 > 0.22
        rollover = mom20 < -0.02 or dd20 < -0.05 or dd60 < -0.10 or values[index] < ma40
        if hot and rollover:
            broken += 1
    return broken >= 1


def us_repaired(prices: dict[str, list[float]], index: int) -> bool:
    good = 0
    for symbol in ["sp500", "nasdaq"]:
        values = prices[symbol]
        mom20 = momentum(values, index, 20)
        mom60 = momentum(values, index, 60)
        ma40 = moving_average(values, index, 40)
        if mom20 is not None and mom60 is not None and ma40 is not None and mom20 > 0 and mom60 > -0.01 and values[index] > ma40:
            good += 1
    return good >= 2


def apply_quarantine(
    weights: dict[str, float],
    spec: QuarantineSpec | None,
    prices: dict[str, list[float]],
    ma: dict[str, list[float | None]],
    signal_index: int,
    state: dict[str, int],
) -> dict[str, float]:
    if spec is None:
        return normalize(weights)
    if china_bubble_rollover(prices, signal_index):
        state["until"] = max(state.get("until", -1), signal_index + spec.cooldown_sessions)

    active = state.get("until", -1) >= signal_index
    if not active:
        return normalize(weights)
    if spec.repair_required and us_repaired(prices, signal_index):
        return normalize(weights)

    out = dict(weights)
    removed = 0.0
    for symbol in app.EQUITY_SYMBOLS:
        old = out.get(symbol, 0.0)
        if old > 0:
            out[symbol] = old * spec.equity_scale
            removed += old - out[symbol]
    if removed > 0 and s43.gold_ok(prices, ma, signal_index):
        out["gold_cny"] = out.get("gold_cny", 0.0) + removed * spec.redeploy_gold_ratio
    return normalize(out)


def run_quarantine(spec: QuarantineSpec | None, end_date: date = app.parse_date("2026-06-23")) -> app.BacktestResult:
    dates, prices_by_symbol, _symbols, config, meta_traces, overlay, ma = s43.build_context(end_date)
    tradable_symbols = [symbol for symbol in ["gold_cny", "nasdaq", "sp500", "shanghai_composite", "csi300"] if symbol in prices_by_symbol]

    cash = 100_000.0
    fee_rate = 0.001
    slippage_rate = 0.0005
    band = max(config.rebalance_band, 0.0)
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []
    state: dict[str, int] = {"until": -1}

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, meta_traces) if config.meta_switch else {}
        champion = overlay(raw_weights or {}, signal_index, dates[signal_index], prices_by_symbol, values_by_index, config)
        return apply_quarantine(champion, spec, prices_by_symbol, ma, signal_index, state)

    def rebalance_to(index: int, targets: dict[str, float]) -> None:
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

    for index in range(len(dates)):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index == 0 or index % max(config.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = target_weights(signal_index, index) if signal_index >= 0 else {}
            rebalance_to(index, targets)

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


def row_for(spec: QuarantineSpec | None, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": result.strategy,
        "thesis": spec.thesis if spec else "Current app champion without contagion quarantine.",
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


def specs() -> list[QuarantineSpec]:
    return [
        QuarantineSpec("quarantine_120_zero_repair", "After China bubble rollover, remove equities until US repairs or quarantine expires.", 120, 0.0, 0.70, True),
        QuarantineSpec("quarantine_180_zero_repair", "Longer China contagion quarantine with full equity removal.", 180, 0.0, 0.70, True),
        QuarantineSpec("quarantine_120_soft35_repair", "After China bubble rollover, keep only 35% of equity risk until US repair.", 120, 0.35, 0.65, True),
        QuarantineSpec("quarantine_180_soft35_repair", "Longer soft quarantine.", 180, 0.35, 0.65, True),
        QuarantineSpec("quarantine_120_soft55_repair", "Milder quarantine that keeps most equity trend exposure.", 120, 0.55, 0.50, True),
        QuarantineSpec("quarantine_120_soft35_fixed", "Soft quarantine for a fixed 120 sessions even if US repairs early.", 120, 0.35, 0.65, False),
    ]


def main() -> None:
    rows = [row_for(None, run_quarantine(None))]
    rows.extend(row_for(spec, run_quarantine(spec)) for spec in specs())
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
