#!/usr/bin/env python3
"""Low-turnover quality/income gated basket search under 1% fee.

This spike tests a new source of return instead of retuning the existing gold
handoff family.  The structure is:

- income/gold/cash as a stabilizing sleeve;
- quality equities, sector funds, and the current app-equivalent CORE sleeve as
  the offensive sleeve;
- low-frequency rebalancing only;
- explicit 1% fee and 0.05% slippage on every buy and sell;
- no leverage, no shorting, no BTC.

The purpose is to see whether a fundamentally different low-turnover return
source can move toward a Sharpe target above the current ~1.05 boundary.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import importlib.util
import itertools
import json
import math
from pathlib import Path
import sys
from typing import Any, Literal

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app  # noqa: E402


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


scan070 = load_module("atm_spike070_source_for_072", ROOT / "spikes/070-long-fund-source-scan/long_fund_source_scan.py")
carry = scan070.carry


END_DATE = "2026-06-23"
START_DATE = app.parse_date("2005-01-03")
INITIAL_CASH = 100_000.0
FEE_RATE = 0.01
SLIPPAGE_RATE = 0.0005

INCOME_SYMBOLS = ["OSTIX", "PIMIX", "PONAX", "PRWCX"]
DEFENSIVE_SYMBOLS = ["OSTIX", "PIMIX", "PONAX", "PRWCX", "GLD", "IAU"]
RISK_SYMBOLS = [
    "CORE",
    "QQQ",
    "VGT",
    "XLK",
    "SMH",
    "SOXX",
    "FSELX",
    "FSPTX",
    "FDGRX",
    "FBGRX",
    "AAPL",
    "MSFT",
    "COST",
    "LLY",
    "NVO",
    "UNH",
    "ORLY",
    "AZO",
    "ROP",
    "MCD",
    "HD",
    "LOW",
    "WM",
    "TMO",
    "LIN",
    "DHR",
    "AMGN",
    "JNJ",
    "PG",
    "KO",
    "PEP",
    "XLP",
    "XLV",
]
ALL_SYMBOLS = sorted(set(INCOME_SYMBOLS + DEFENSIVE_SYMBOLS + RISK_SYMBOLS) - {"CORE"})


@dataclass(frozen=True)
class StrategySpec:
    name: str
    score_mode: Literal["trend", "efficiency", "stability"]
    rebalance_sessions: int
    risk_weight: float
    income_weight: float
    gold_weight: float
    top_count: int
    max_single_weight: float
    require_market_trend: bool
    crash_risk_scale: float


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def moving_average(values: list[float | None], index: int, lookback: int) -> float | None:
    if lookback <= 0 or index - lookback + 1 < 0:
        return None
    window = values[index - lookback + 1 : index + 1]
    if any(item is None or item <= 0 for item in window):
        return None
    return sum(float(item) for item in window) / len(window)


def trailing_return(values: list[float | None], index: int, lookback: int) -> float | None:
    if lookback <= 0 or index - lookback < 0:
        return None
    current = values[index]
    previous = values[index - lookback]
    if current is None or previous is None or current <= 0 or previous <= 0:
        return None
    return current / previous - 1


def trailing_drawdown(values: list[float | None], index: int, lookback: int) -> float | None:
    if lookback <= 1 or index - lookback + 1 < 0:
        return None
    window = values[index - lookback + 1 : index + 1]
    if any(item is None or item <= 0 for item in window):
        return None
    peak = max(float(item) for item in window)
    current = float(values[index] or 0.0)
    return current / peak - 1 if peak > 0 else None


def trailing_volatility(values: list[float | None], index: int, lookback: int) -> float | None:
    if lookback <= 2 or index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        previous = values[cursor - 1]
        current = values[cursor]
        if current is None or previous is None or current <= 0 or previous <= 0:
            return None
        returns.append(current / previous - 1)
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / max(len(returns) - 1, 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def price_on_or_before(points: list[tuple[date, float]], day: date) -> float | None:
    return carry.price_on_or_before(points, day, app.MAX_FORWARD_FILL_CALENDAR_DAYS)


def load_price_series() -> tuple[list[date], dict[str, list[float | None]], dict[str, str]]:
    core = app.run_strategy("coreGoldSatelliteOneWayVolManagedMomentum", end_date=END_DATE, start_date=START_DATE.isoformat())
    raw = app.fetch_public_history(end_date=app.parse_date(END_DATE))
    dates = core.dates
    fx_points = raw[app.USD_FX_SYMBOL]
    series: dict[str, list[float | None]] = {"CORE": [float(value) / INITIAL_CASH for value in core.values]}
    errors: dict[str, str] = {}

    for symbol in ALL_SYMBOLS:
        try:
            usd_points = scan070.fetch_yahoo_adjusted(symbol)
            cny_points = carry.convert_usd_points_to_cny(usd_points, fx_points)
            values = [price_on_or_before(cny_points, day) if day >= START_DATE else None for day in dates]
            first = next((value for value in values if value is not None and value > 0), None)
            if first is None:
                continue
            series[symbol] = [value / first if value is not None and value > 0 else None for value in values]
        except Exception as exc:
            errors[symbol] = repr(exc)
    return dates, series, errors


def normalize_targets(raw: dict[str, float], max_single: float) -> dict[str, float]:
    capped = {symbol: min(max(weight, 0.0), max_single) for symbol, weight in raw.items() if weight > 0.0001}
    total = sum(capped.values())
    if total <= 1.0:
        return capped
    return {symbol: weight / total for symbol, weight in capped.items() if weight > 0.0001}


def score_symbol(series: dict[str, list[float | None]], symbol: str, index: int, mode: str) -> tuple[float, dict[str, float]] | None:
    values = series[symbol]
    ret252 = trailing_return(values, index, 252)
    ret126 = trailing_return(values, index, 126)
    ret63 = trailing_return(values, index, 63)
    vol126 = trailing_volatility(values, index, 126)
    dd126 = trailing_drawdown(values, index, 126)
    ma200 = moving_average(values, index, 200)
    current = values[index]
    if None in (ret252, ret126, ret63, vol126, dd126, ma200, current):
        return None
    assert ret252 is not None and ret126 is not None and ret63 is not None and vol126 is not None and dd126 is not None and ma200 is not None and current is not None
    if ret126 <= 0 or ret252 <= -0.03 or current < ma200:
        return None
    vol = max(vol126, 0.03)
    drawdown_penalty = max(abs(dd126) - 0.04, 0.0)
    if mode == "trend":
        score = ret252 * 0.65 + ret126 * 0.25 + ret63 * 0.10 - vol * 0.20 - drawdown_penalty * 0.40
    elif mode == "efficiency":
        score = (ret252 * 0.70 + ret126 * 0.30) / vol - drawdown_penalty * 1.50
    else:
        score = ret126 / vol + ret63 * 0.40 - drawdown_penalty * 2.50
    return score, {"ret252": ret252, "ret126": ret126, "ret63": ret63, "vol126": vol126, "dd126": dd126}


def pick_symbols(series: dict[str, list[float | None]], candidates: list[str], index: int, mode: str, top_count: int) -> list[tuple[str, float, dict[str, float]]]:
    scored: list[tuple[str, float, dict[str, float]]] = []
    for symbol in candidates:
        if symbol not in series:
            continue
        item = score_symbol(series, symbol, index, mode)
        if item is None:
            continue
        score, stats = item
        scored.append((symbol, score, stats))
    scored.sort(key=lambda row: (-row[1], row[0]))
    return scored[:top_count]


def market_is_healthy(series: dict[str, list[float | None]], index: int) -> bool:
    gauges = [symbol for symbol in ["CORE", "QQQ", "XLV", "XLP"] if symbol in series]
    votes = 0
    total = 0
    for symbol in gauges:
        values = series[symbol]
        ma200 = moving_average(values, index, 200)
        ret126 = trailing_return(values, index, 126)
        current = values[index]
        if ma200 is None or ret126 is None or current is None:
            continue
        total += 1
        if current >= ma200 and ret126 > 0:
            votes += 1
    return votes >= max(1, math.ceil(total / 2)) if total else True


def market_is_crashing(series: dict[str, list[float | None]], index: int) -> bool:
    gauges = [symbol for symbol in ["CORE", "QQQ", "VGT", "XLK"] if symbol in series]
    bad = 0
    total = 0
    for symbol in gauges:
        dd63 = trailing_drawdown(series[symbol], index, 63)
        ret63 = trailing_return(series[symbol], index, 63)
        if dd63 is None or ret63 is None:
            continue
        total += 1
        if dd63 < -0.10 and ret63 < -0.04:
            bad += 1
    return bad >= max(1, math.ceil(total / 2)) if total else False


def target_weights(series: dict[str, list[float | None]], index: int, spec: StrategySpec) -> dict[str, float]:
    risk_budget = spec.risk_weight
    if spec.require_market_trend and not market_is_healthy(series, index):
        risk_budget *= 0.45
    if market_is_crashing(series, index):
        risk_budget *= spec.crash_risk_scale

    raw: dict[str, float] = {}
    income_picks = pick_symbols(series, [symbol for symbol in INCOME_SYMBOLS if symbol in series], index, "efficiency", 1)
    if income_picks and spec.income_weight > 0:
        raw[income_picks[0][0]] = raw.get(income_picks[0][0], 0.0) + spec.income_weight

    gold_picks = pick_symbols(series, [symbol for symbol in ["GLD", "IAU"] if symbol in series], index, "trend", 1)
    if gold_picks and spec.gold_weight > 0:
        raw[gold_picks[0][0]] = raw.get(gold_picks[0][0], 0.0) + spec.gold_weight

    risk_picks = pick_symbols(series, [symbol for symbol in RISK_SYMBOLS if symbol in series], index, spec.score_mode, spec.top_count)
    if risk_picks and risk_budget > 0:
        inverse_vols: list[tuple[str, float]] = []
        for symbol, _, stats in risk_picks:
            inverse_vols.append((symbol, 1.0 / max(stats["vol126"], 0.06)))
        total = sum(weight for _, weight in inverse_vols)
        for symbol, weight in inverse_vols:
            raw[symbol] = raw.get(symbol, 0.0) + risk_budget * weight / total

    return normalize_targets(raw, spec.max_single_weight)


def portfolio_value(cash: float, units: dict[str, float], prices: dict[str, list[float | None]], index: int) -> float:
    value = cash
    for symbol, qty in units.items():
        price = prices[symbol][index]
        if qty > 0 and price is not None and price > 0:
            value += qty * price
    return value


def rebalance(cash: float, units: dict[str, float], prices: dict[str, list[float | None]], index: int, targets: dict[str, float]) -> tuple[float, dict[str, float], int]:
    value = portfolio_value(cash, units, prices, index)
    trades = 0
    held_symbols = {symbol for symbol, qty in units.items() if qty > 0}
    target_symbols = set(targets)

    for symbol in sorted(held_symbols - target_symbols):
        price = prices[symbol][index]
        qty = units.get(symbol, 0.0)
        if price is None or price <= 0 or qty <= 0:
            continue
        cash += qty * price * (1 - SLIPPAGE_RATE) * (1 - FEE_RATE)
        units[symbol] = 0.0
        trades += 1

    value = portfolio_value(cash, units, prices, index)
    for symbol in sorted(target_symbols):
        price = prices[symbol][index]
        if price is None or price <= 0:
            continue
        current_value = units.get(symbol, 0.0) * price
        desired_value = value * targets[symbol]
        if current_value > desired_value * 1.12:
            sell_value = current_value - desired_value
            qty = min(units.get(symbol, 0.0), sell_value / price)
            if qty > 0:
                cash += qty * price * (1 - SLIPPAGE_RATE) * (1 - FEE_RATE)
                units[symbol] = units.get(symbol, 0.0) - qty
                trades += 1

    value = portfolio_value(cash, units, prices, index)
    for symbol in sorted(target_symbols):
        price = prices[symbol][index]
        if price is None or price <= 0:
            continue
        current_value = units.get(symbol, 0.0) * price
        desired_value = value * targets[symbol]
        if current_value < desired_value * 0.88:
            gross_needed = desired_value - current_value
            cash_needed = gross_needed * (1 + SLIPPAGE_RATE) * (1 + FEE_RATE)
            spend = min(cash, cash_needed)
            if spend > 0:
                qty = spend / ((1 + SLIPPAGE_RATE) * (1 + FEE_RATE) * price)
                units[symbol] = units.get(symbol, 0.0) + qty
                cash -= spend
                trades += 1

    return cash, units, trades


def run_strategy(dates: list[date], prices: dict[str, list[float | None]], spec: StrategySpec) -> dict[str, Any]:
    start_index = next(index for index, day in enumerate(dates) if day >= START_DATE) + 252
    cash = INITIAL_CASH
    units: dict[str, float] = {symbol: 0.0 for symbol in prices}
    values: list[float] = []
    out_dates: list[date] = []
    trade_count = 0
    weight_trace: list[dict[str, float]] = []

    for index in range(start_index, len(dates)):
        if index > start_index and cash > 0:
            cash += cash * app.cash_daily_return(dates[index - 1])
        if index == start_index or (index - start_index) % spec.rebalance_sessions == 0:
            targets = target_weights(prices, index - 1, spec)
            cash, units, trades = rebalance(cash, units, prices, index, targets)
            trade_count += trades
            weight_trace.append(targets)
        out_dates.append(dates[index])
        values.append(portfolio_value(cash, units, prices, index))

    return summarize(spec.name, out_dates, values, spec, trade_count, weight_trace)


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    index = next((cursor for cursor, day in enumerate(dates) if day >= start_date), None)
    if index is None or index >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "annual_volatility": None, "sharpe": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates[index:], values[index:])
    return {"annualized": annualized, "max_drawdown": max_dd, "annual_volatility": annual_vol, "sharpe": sharpe, "total": total}


def drawdown_window(dates: list[date], values: list[float]) -> dict[str, Any]:
    peak = values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for index, value in enumerate(values):
        if value > peak:
            peak = value
            peak_i = index
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = index
    return {"peak_date": dates[worst_peak].isoformat(), "trough_date": dates[worst_trough].isoformat(), "max_drawdown": worst}


def summarize(name: str, dates: list[date], values: list[float], spec: StrategySpec, trades: int, weight_trace: list[dict[str, float]]) -> dict[str, Any]:
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    top_holdings: dict[str, int] = {}
    for weights in weight_trace:
        for symbol in weights:
            top_holdings[symbol] = top_holdings.get(symbol, 0) + 1
    return {
        "name": name,
        "spec": spec.__dict__,
        "trades": trades,
        "top_holdings": dict(sorted(top_holdings.items(), key=lambda item: (-item[1], item[0]))[:12]),
        "coverage": {"start": dates[0].isoformat(), "end": dates[-1].isoformat(), "points": len(dates)},
        "full": {
            "annualized": annualized,
            "max_drawdown": max_dd,
            "annual_volatility": annual_vol,
            "sharpe": sharpe,
            "total": total,
        },
        "slices": {
            "post_2020": slice_metrics(dates, values, "2020-01-01"),
            "last_10y": slice_metrics(dates, values, "2016-06-23"),
            "post_2022": slice_metrics(dates, values, "2022-01-01"),
            "post_2024": slice_metrics(dates, values, "2024-01-01"),
        },
        "drawdown_window": drawdown_window(dates, values),
    }


def specs() -> list[StrategySpec]:
    rows: list[StrategySpec] = []
    for mode, rebalance, top_count, risk_weight, income_weight, gold_weight, max_single, trend_gate, crash_scale in itertools.product(
        ["trend", "efficiency", "stability"],
        [63, 126],
        [2, 3],
        [0.55, 0.65, 0.75],
        [0.15, 0.25],
        [0.0, 0.10],
        [0.25, 0.35],
        [True],
        [0.25, 0.45, 0.65],
    ):
        if risk_weight + income_weight + gold_weight > 1.0:
            continue
        name = (
            f"{mode}_rb{rebalance}_top{top_count}_risk{int(risk_weight*100)}"
            f"_inc{int(income_weight*100)}_gold{int(gold_weight*100)}"
            f"_cap{int(max_single*100)}_{'gate' if trend_gate else 'nogate'}_crash{int(crash_scale*100)}"
        )
        rows.append(StrategySpec(name, mode, rebalance, risk_weight, income_weight, gold_weight, top_count, max_single, trend_gate, crash_scale))
    return rows


def main() -> None:
    dates, series, errors = load_price_series()
    available = sorted(series)
    rows = [run_strategy(dates, series, spec) for spec in specs()]
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)
    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "fee_rate": FEE_RATE,
        "slippage_rate": SLIPPAGE_RATE,
        "available_symbols": available,
        "errors": errors,
        "rows": rows,
        "interesting": {
            "top_by_sharpe": rows[:50],
            "annual_ge_12": [row for row in rows if row["full"]["annualized"] >= 0.12][:40],
            "annual_ge_15": [row for row in rows if row["full"]["annualized"] >= 0.15][:40],
            "post2020_ge_1": [row for row in rows if (row["slices"]["post_2020"]["sharpe"] or 0.0) >= 1.0][:40],
        },
    }
    out_path = HERE / "results.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | trades | holdings")
    for row in rows[:50]:
        full = row["full"]
        slices = row["slices"]
        print(
            f"{row['name']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{(full['sharpe'] or 0):.4f}/{pct(full['annual_volatility'])} | "
            f"{pct(slices['post_2020']['annualized'])}/{(slices['post_2020']['sharpe'] or 0):.4f} | "
            f"{pct(slices['last_10y']['annualized'])}/{(slices['last_10y']['sharpe'] or 0):.4f} | "
            f"{row['trades']} | {row['top_holdings']}"
        )


if __name__ == "__main__":
    main()
