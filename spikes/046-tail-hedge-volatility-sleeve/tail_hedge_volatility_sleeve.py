#!/usr/bin/env python3
"""Small volatility tail-hedge sleeve on the current champion.

No leverage, no shorting, no BTC. VIXY/VXX are used only after their real ETF
history begins, and only when broad equity stress plus hedge trend agree.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import bisect
import json
import math
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402

S43_PATH = ROOT / "spikes" / "043-current-champion-event-airbag" / "current_champion_event_airbag.py"
import importlib.util

SPEC43 = importlib.util.spec_from_file_location("current_champion_airbag_base_tail", S43_PATH)
if SPEC43 is None or SPEC43.loader is None:
    raise RuntimeError(f"failed to load {S43_PATH}")
s43 = importlib.util.module_from_spec(SPEC43)
sys.modules["current_champion_airbag_base_tail"] = s43
SPEC43.loader.exec_module(s43)

TAIL_SYMBOLS = ["vixy", "vxx"]
YAHOO = {"vixy": "VIXY", "vxx": "VXX"}


@dataclass(frozen=True)
class TailSpec:
    name: str
    thesis: str
    cap: float
    equity_carve: float
    mode: str


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    return s43.normalize(weights, max_total)


def price_on_or_before(points: list[tuple[date, float]], target: date, max_gap_days: int = 30) -> float | None:
    idx = bisect.bisect_right(points, (target, float("inf"))) - 1
    if idx < 0:
        return None
    day, price = points[idx]
    if (target - day).days > max_gap_days:
        return None
    return price


def cny_per_usd_from_fx(fx: float) -> float | None:
    if not math.isfinite(fx) or fx <= 0:
        return None
    return 1.0 / fx if fx < 1 else fx if fx <= 20 else None


def fetch_tail_adjusted(symbol: str) -> list[tuple[date, float]]:
    path = Path("/tmp/atm_crisis_payoff_cache") / f"yahoo_{YAHOO[symbol]}_adj.json"
    if not path.exists():
        raise RuntimeError(f"missing cached Yahoo adjusted NAV: {path}")
    raw = json.loads(path.read_text())
    return [(date.fromisoformat(day), float(price)) for day, price in raw if float(price) > 0]


def align_tail_prices(dates: list[date], raw: dict[str, list[tuple[date, float]]]) -> dict[str, list[float]]:
    fx = raw[app.USD_FX_SYMBOL]
    out: dict[str, list[float]] = {}
    for symbol in TAIL_SYMBOLS:
        cny_points: list[tuple[date, float]] = []
        for day, price in fetch_tail_adjusted(symbol):
            fx_value = price_on_or_before(fx, day, 30)
            cny_per_usd = cny_per_usd_from_fx(fx_value) if fx_value is not None else None
            if cny_per_usd is not None:
                cny_points.append((day, price * cny_per_usd))
        series: list[float] = []
        for day in dates:
            price = price_on_or_before(cny_points, day, app.MAX_FORWARD_FILL_CALENDAR_DAYS)
            series.append(price if price is not None else 0.0)
        out[symbol] = series
    return out


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0 or values[index] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def moving_average(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    window = values[index - period + 1:index + 1]
    if any(value <= 0 for value in window):
        return None
    return sum(window) / period


def equity_weight(weights: dict[str, float]) -> float:
    return sum(max(weights.get(symbol, 0.0), 0.0) for symbol in app.EQUITY_SYMBOLS)


def equity_stress(prices: dict[str, list[float]], index: int, mode: str) -> bool:
    sp20 = momentum(prices["sp500"], index, 20)
    nd20 = momentum(prices["nasdaq"], index, 20)
    sp60 = momentum(prices["sp500"], index, 60)
    nd60 = momentum(prices["nasdaq"], index, 60)
    sp_ma = moving_average(prices["sp500"], index, 40)
    nd_ma = moving_average(prices["nasdaq"], index, 40)
    broad = (
        sp20 is not None and nd20 is not None and sp60 is not None
        and sp20 < -0.025 and nd20 < -0.035 and sp60 < 0
    )
    ma_break = (
        sp_ma is not None and nd_ma is not None and prices["sp500"][index] < sp_ma
        and prices["nasdaq"][index] < nd_ma and sp20 is not None and nd20 is not None and sp20 < 0 and nd20 < 0
    )
    if "strict" in mode:
        return broad and ma_break
    return broad or ma_break


def tail_score(prices: dict[str, list[float]], symbol: str, index: int, mode: str) -> float | None:
    values = prices[symbol]
    mom5 = momentum(values, index, 5)
    mom10 = momentum(values, index, 10)
    mom20 = momentum(values, index, 20)
    ma20 = moving_average(values, index, 20)
    if None in (mom5, mom10, mom20, ma20):
        return None
    assert mom5 is not None and mom10 is not None and mom20 is not None and ma20 is not None
    if values[index] <= ma20:
        return None
    if "fast" in mode:
        if mom5 <= 0.03 or mom10 <= 0:
            return None
    elif mom10 <= 0.04 or mom20 <= 0:
        return None
    return mom5 + 0.7 * mom10 + 0.35 * mom20


def apply_tail_hedge(
    weights: dict[str, float],
    spec: TailSpec | None,
    prices: dict[str, list[float]],
    signal_index: int,
) -> dict[str, float]:
    if spec is None or equity_weight(weights) <= 0.15 or not equity_stress(prices, signal_index, spec.mode):
        return normalize(weights)
    scored = [(score, symbol) for symbol in TAIL_SYMBOLS if (score := tail_score(prices, symbol, signal_index, spec.mode)) is not None]
    if not scored:
        return normalize(weights)
    scored.sort(reverse=True)
    hedge = scored[0][1]
    hedge_weight = min(spec.cap, equity_weight(weights) * spec.equity_carve)
    if hedge_weight <= 0:
        return normalize(weights)
    out = dict(weights)
    current_equity = equity_weight(out)
    for symbol in app.EQUITY_SYMBOLS:
        old = out.get(symbol, 0.0)
        if old > 0 and current_equity > 0:
            out[symbol] = old * max(0.0, 1.0 - hedge_weight / current_equity)
    out[hedge] = out.get(hedge, 0.0) + hedge_weight
    return normalize(out)


def build_context(end_date: date):
    raw = app.fetch_public_history(end_date=end_date)
    dates, core_prices, symbols, config, meta_traces, overlay, _ma = s43.build_context(end_date)
    tail_prices = align_tail_prices(dates, raw)
    prices_by_symbol = {**core_prices, **tail_prices}
    return dates, prices_by_symbol, symbols, config, meta_traces, overlay


def run_tail(spec: TailSpec | None, end_date: date = app.parse_date("2026-06-23")) -> app.BacktestResult:
    dates, prices_by_symbol, _symbols, config, meta_traces, overlay = build_context(end_date)
    tradable_symbols = [symbol for symbol in ["gold_cny", "nasdaq", "sp500", "shanghai_composite", "csi300", *TAIL_SYMBOLS] if symbol in prices_by_symbol]

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

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices_by_symbol[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, meta_traces) if config.meta_switch else {}
        champion = overlay(raw_weights or {}, signal_index, dates[signal_index], prices_by_symbol, values_by_index, config)
        return apply_tail_hedge(champion, spec, prices_by_symbol, signal_index)

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
            if price <= 0:
                continue
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
            if price <= 0:
                continue
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
            guarded = apply_tail_hedge(weights, spec, prices_by_symbol, index - 1)
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


def row_for(spec: TailSpec | None, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": result.strategy,
        "thesis": spec.thesis if spec else "Current app champion without volatility tail hedge.",
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


def specs() -> list[TailSpec]:
    return [
        TailSpec("tail_fast_cap5", "Carve up to 5% of equity risk into VIXY/VXX during fast confirmed stress.", 0.05, 0.25, "fast"),
        TailSpec("tail_fast_cap8", "Carve up to 8% of equity risk into VIXY/VXX during fast confirmed stress.", 0.08, 0.30, "fast"),
        TailSpec("tail_fast_cap10", "Carve up to 10% of equity risk into VIXY/VXX during fast confirmed stress.", 0.10, 0.35, "fast"),
        TailSpec("tail_strict_cap5", "Strict stress confirmation before 5% volatility hedge.", 0.05, 0.25, "strict"),
        TailSpec("tail_strict_cap8", "Strict stress confirmation before 8% volatility hedge.", 0.08, 0.30, "strict"),
    ]


def main() -> None:
    rows = [row_for(None, run_tail(None))]
    rows.extend(row_for(spec, run_tail(spec)) for spec in specs())
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
