#!/usr/bin/env python3
"""Static and ultra-low-turnover quality/income frontier under 1% fee.

After dynamic quality rotation failed, this spike tests whether the same return
source works only when turnover is almost removed.  It searches constrained
quality/income/gold/CORE baskets and then replays the best buy-and-hold screens
with annual rebalancing and explicit 1% fees.
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
from typing import Any

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


scan070 = load_module("atm_spike070_source_for_073", ROOT / "spikes/070-long-fund-source-scan/long_fund_source_scan.py")
carry = scan070.carry


END_DATE = "2026-06-23"
START_DATE = app.parse_date("2005-01-03")
MIN_COVERAGE_YEARS = 15.0
INITIAL_CASH = 100_000.0
FEE_RATE = 0.01
SLIPPAGE_RATE = 0.0005

INCOME = ["OSTIX", "PIMIX"]
GOLD = ["IAU"]
RISK = [
    "AAPL",
    "MSFT",
    "COST",
    "LLY",
    "NVO",
    "ORLY",
    "AZO",
    "FSELX",
    "SMH",
    "XLV",
    "XLP",
    "WM",
    "MCD",
    "UNH",
    "TMO",
]
ALL_EXTERNAL = sorted(set(INCOME + GOLD + RISK))


@dataclass(frozen=True)
class Basket:
    weights: dict[str, float]

    @property
    def name(self) -> str:
        return "+".join(f"{symbol}:{weight:.2f}" for symbol, weight in self.weights.items() if weight > 0)


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def load_series() -> tuple[list[date], dict[str, list[float | None]], dict[str, str]]:
    core = app.run_strategy("coreGoldSatelliteOneWayVolManagedMomentum", end_date=END_DATE, start_date=START_DATE.isoformat())
    raw = app.fetch_public_history(end_date=app.parse_date(END_DATE))
    dates = core.dates
    fx_points = raw[app.USD_FX_SYMBOL]
    series: dict[str, list[float | None]] = {"CORE": [float(value) for value in core.values]}
    errors: dict[str, str] = {}
    for symbol in ALL_EXTERNAL:
        try:
            usd = scan070.fetch_yahoo_adjusted(symbol)
            cny = carry.convert_usd_points_to_cny(usd, fx_points)
            values = [carry.price_on_or_before(cny, day, app.MAX_FORWARD_FILL_CALENDAR_DAYS) for day in dates]
            series[symbol] = values
        except Exception as exc:
            errors[symbol] = repr(exc)
    return dates, series, errors


def aligned_indices(dates: list[date], series: dict[str, list[float | None]], symbols: list[str]) -> list[int]:
    indices = []
    for index, day in enumerate(dates):
        if day < START_DATE:
            continue
        if all(index < len(series[symbol]) and series[symbol][index] is not None and float(series[symbol][index] or 0) > 0 for symbol in symbols):
            indices.append(index)
    if not indices:
        return []
    years = (dates[indices[-1]] - dates[indices[0]]).days / 365.25
    if years < MIN_COVERAGE_YEARS:
        return []
    return indices


def buy_hold_curve(dates: list[date], series: dict[str, list[float | None]], basket: Basket) -> tuple[list[date], list[float]] | None:
    symbols = list(basket.weights)
    indices = aligned_indices(dates, series, symbols)
    if not indices:
        return None
    start = indices[0]
    out_dates = [dates[index] for index in indices]
    base_values = {symbol: float(series[symbol][start] or 0.0) for symbol in symbols}
    values: list[float] = []
    for index in indices:
        value = 0.0
        for symbol, weight in basket.weights.items():
            price = float(series[symbol][index] or 0.0)
            fee_drag = 1.0 if symbol == "CORE" else 1.0 - FEE_RATE
            value += INITIAL_CASH * weight * fee_drag * price / base_values[symbol]
        values.append(value)
    return out_dates, values


def metric_row(name: str, kind: str, dates: list[date], values: list[float], basket: Basket, trades: int | None = None) -> dict[str, Any]:
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": name,
        "kind": kind,
        "weights": basket.weights,
        "trades": trades,
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
    }


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    index = next((cursor for cursor, day in enumerate(dates) if day >= start_date), None)
    if index is None or index >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "annual_volatility": None, "sharpe": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates[index:], values[index:])
    return {"annualized": annualized, "max_drawdown": max_dd, "annual_volatility": annual_vol, "sharpe": sharpe, "total": total}


def basket_candidates() -> list[Basket]:
    rows: list[Basket] = []
    core_weights = [0.20, 0.30, 0.40, 0.50]
    income_weights = [0.20, 0.30]
    gold_weights = [0.0, 0.10]
    for income_symbol in INCOME:
        for gold_symbol in [None, *GOLD]:
            for risk_count in [2, 3]:
                for risk_symbols in itertools.combinations(RISK, risk_count):
                    for core_w, income_w, gold_w in itertools.product(core_weights, income_weights, gold_weights):
                        if gold_symbol is None and gold_w > 0:
                            continue
                        remainder = 1.0 - core_w - income_w - gold_w
                        if remainder < 0.20 or remainder > 0.60:
                            continue
                        weights = {"CORE": core_w, income_symbol: income_w}
                        if gold_symbol is not None and gold_w > 0:
                            weights[gold_symbol] = gold_w
                        risk_w = remainder / risk_count
                        for symbol in risk_symbols:
                            weights[symbol] = risk_w
                        rows.append(Basket(dict(sorted(weights.items()))))
    unique: dict[str, Basket] = {}
    for row in rows:
        unique[row.name] = row
    return list(unique.values())


def replay_annual_rebalance(dates: list[date], series: dict[str, list[float | None]], basket: Basket) -> tuple[list[date], list[float], int] | None:
    symbols = list(basket.weights)
    indices = aligned_indices(dates, series, symbols)
    if not indices:
        return None
    cash = INITIAL_CASH
    units = {symbol: 0.0 for symbol in symbols}
    out_dates: list[date] = []
    values: list[float] = []
    trades = 0
    last_rebalance_year: int | None = None

    def value_at(index: int) -> float:
        total = cash
        for symbol, qty in units.items():
            price = float(series[symbol][index] or 0.0)
            if qty > 0 and price > 0:
                total += qty * price
        return total

    for index in indices:
        day = dates[index]
        if last_rebalance_year is None or day.year != last_rebalance_year:
            current_value = value_at(index)
            for symbol in symbols:
                price = float(series[symbol][index] or 0.0)
                if price <= 0:
                    continue
                current_symbol_value = units[symbol] * price
                desired = current_value * basket.weights[symbol]
                if current_symbol_value > desired:
                    qty = min(units[symbol], (current_symbol_value - desired) / price)
                    if qty > 0:
                        fee = 0.0 if symbol == "CORE" else FEE_RATE
                        cash += qty * price * (1 - SLIPPAGE_RATE) * (1 - fee)
                        units[symbol] -= qty
                        trades += 1
            current_value = value_at(index)
            for symbol in symbols:
                price = float(series[symbol][index] or 0.0)
                if price <= 0:
                    continue
                current_symbol_value = units[symbol] * price
                desired = current_value * basket.weights[symbol]
                if current_symbol_value < desired:
                    gross = desired - current_symbol_value
                    fee = 0.0 if symbol == "CORE" else FEE_RATE
                    spend = min(cash, gross * (1 + SLIPPAGE_RATE) * (1 + fee))
                    if spend > 0:
                        units[symbol] += spend / ((1 + SLIPPAGE_RATE) * (1 + fee) * price)
                        cash -= spend
                        trades += 1
            last_rebalance_year = day.year
        out_dates.append(day)
        values.append(value_at(index))
    return out_dates, values, trades


def main() -> None:
    dates, series, errors = load_series()
    rows: list[dict[str, Any]] = []
    for basket in basket_candidates():
        curve = buy_hold_curve(dates, series, basket)
        if curve is None:
            continue
        curve_dates, values = curve
        rows.append(metric_row(basket.name, "buy_hold", curve_dates, values, basket))
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)

    replay_rows: list[dict[str, Any]] = []
    replay_seen = set()
    screen_pool = rows[:250] + [row for row in rows if row["full"]["annualized"] >= 0.12][:250] + [row for row in rows if row["full"]["annualized"] >= 0.15][:250]
    for row in screen_pool:
        key = row["name"]
        if key in replay_seen:
            continue
        replay_seen.add(key)
        basket = Basket({symbol: float(weight) for symbol, weight in row["weights"].items()})
        replay = replay_annual_rebalance(dates, series, basket)
        if replay is None:
            continue
        replay_dates, replay_values, trades = replay
        replay_rows.append(metric_row(key, "annual_rebalance", replay_dates, replay_values, basket, trades))
    replay_rows.sort(key=lambda row: (row["full"]["sharpe"] or -99.0, row["full"]["annualized"]), reverse=True)

    out = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "fee_rate": FEE_RATE,
        "slippage_rate": SLIPPAGE_RATE,
        "errors": errors,
        "row_count": len(rows),
        "buy_hold": rows,
        "annual_rebalance": replay_rows,
        "interesting": {
            "buy_hold_top_sharpe": rows[:50],
            "buy_hold_annual_ge_12": [row for row in rows if row["full"]["annualized"] >= 0.12][:50],
            "buy_hold_annual_ge_15": [row for row in rows if row["full"]["annualized"] >= 0.15][:50],
            "annual_rebalance_top_sharpe": replay_rows[:50],
            "annual_rebalance_annual_ge_12": [row for row in replay_rows if row["full"]["annualized"] >= 0.12][:50],
        },
    }
    out_path = HERE / "results.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2))

    print(f"WROTE {out_path}")
    print("\nBuy-hold top")
    print_rows(rows[:30])
    print("\nAnnual rebalance top")
    print_rows(replay_rows[:30])


def print_rows(rows: list[dict[str, Any]]) -> None:
    for row in rows:
        full = row["full"]
        post = row["slices"]["post_2020"]
        last10 = row["slices"]["last_10y"]
        print(
            f"{row['name']} | {row['kind']} | "
            f"{pct(full['annualized'])}/{pct(full['max_drawdown'])}/{(full['sharpe'] or 0):.4f}/{pct(full['annual_volatility'])} | "
            f"post2020 {pct(post['annualized'])}/{(post['sharpe'] or 0):.4f} | "
            f"last10 {pct(last10['annualized'])}/{(last10['sharpe'] or 0):.4f} | trades={row['trades']}"
        )


if __name__ == "__main__":
    main()
