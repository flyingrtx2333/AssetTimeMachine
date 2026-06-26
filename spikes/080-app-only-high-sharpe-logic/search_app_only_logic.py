#!/usr/bin/env python3
"""Search app-only AssetTimeMachine strategy mechanisms.

The point of this spike is not to reuse external tickers.  Every traded asset is
already present in the app/backtest asset universe.  Fees are deliberately set to
the current app default of 1%.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import bisect
import importlib.util
import json
import math
from pathlib import Path
import sys
import urllib.parse
import urllib.request
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import atm_app_equivalent_backtest as app

API_URL = "https://api.flyingrtx.com/api/v1/money/public/history"
START = date(2002, 1, 4)
INITIAL = 100_000.0
FEE_RATE = 0.01
SLIPPAGE = 0.0005
TRADING_DAYS = 252.0
MAX_FFILL_DAYS = 30

RAW_SYMBOLS = [
    "gold_cny",
    "nasdaq",
    "sp500",
    "dow_jones",
    "hang_seng",
    "nikkei225",
    "csi300",
    "shanghai_composite",
    "shenzhen_component",
    "chinext",
    "usd_per_cny",
]
ALIASES = {
    "nasdaq_composite": "nasdaq",
    "dow_jones": "dowjones",
    "hang_seng": "hsi",
    "nikkei225": "nikkei",
}
USD_ASSETS = {"nasdaq", "sp500", "dowjones"}
CORE_FULL_HISTORY = [
    "gold_cny",
    "nasdaq",
    "sp500",
    "dowjones",
    "hsi",
    "nikkei",
    "csi300",
    "shanghai_composite",
    "shenzhen_component",
]
ALL_APP_ASSETS = CORE_FULL_HISTORY + ["chinext"]
EQUITIES = [s for s in ALL_APP_ASSETS if s != "gold_cny"]
US = ["nasdaq", "sp500", "dowjones"]
CHINA = ["csi300", "shanghai_composite", "shenzhen_component", "chinext"]
GLOBAL = ["hsi", "nikkei"]


@dataclass(frozen=True)
class Result:
    name: str
    thesis: str
    dates: list[date]
    values: list[float]
    trades: int
    average_exposure: float
    latest_weights: dict[str, float]


def parse_date(text: str) -> date:
    return datetime.strptime(text, "%Y-%m-%d").date()


def fetch_history() -> dict[str, list[tuple[date, float]]]:
    url = API_URL + "?" + urllib.parse.urlencode({"symbols": ",".join(RAW_SYMBOLS), "period": "all"})
    with urllib.request.urlopen(url, timeout=90) as response:
        payload = json.load(response)
    if not payload.get("success"):
        raise RuntimeError(f"history API failed: {payload!r}")
    raw: dict[str, list[tuple[date, float]]] = {}
    for item in payload["series"]:
        symbol = ALIASES.get(item["symbol"], item["symbol"])
        rows = []
        for date_text, price in zip(item["dates"], item["prices"]):
            if isinstance(price, (int, float)) and math.isfinite(price) and price > 0:
                rows.append((parse_date(date_text), float(price)))
        raw[symbol] = sorted({d: p for d, p in rows}.items())
    return raw


def price_on_or_before(points: list[tuple[date, float]], target: date) -> float | None:
    dates = [d for d, _p in points]
    idx = bisect.bisect_right(dates, target) - 1
    if idx < 0:
        return None
    return points[idx][1]


def prepare_points(raw: dict[str, list[tuple[date, float]]]) -> dict[str, list[tuple[date, float]]]:
    fx = raw["usd_per_cny"]
    out: dict[str, list[tuple[date, float]]] = {}
    for symbol in ALL_APP_ASSETS:
        points = []
        for day, price in raw[symbol]:
            if symbol in USD_ASSETS:
                rate = price_on_or_before(fx, day)
                if rate is None or rate <= 0 or not math.isfinite(rate):
                    continue
                price = price / rate if rate < 1 else price * rate if rate <= 20 else math.nan
                if not math.isfinite(price):
                    continue
            if day >= START:
                points.append((day, price))
        out[symbol] = points
    return out


def align(points: dict[str, list[tuple[date, float]]], symbols: list[str]) -> tuple[list[date], dict[str, list[float]]]:
    all_dates = sorted({day for symbol in symbols for day, _price in points[symbol] if day >= START})
    indices = {symbol: 0 for symbol in symbols}
    latest: dict[str, float] = {}
    latest_date: dict[str, date] = {}
    dates: list[date] = []
    prices = {symbol: [] for symbol in symbols}
    for current in all_dates:
        ok = True
        for symbol in symbols:
            series = points[symbol]
            idx = indices[symbol]
            while idx < len(series) and series[idx][0] <= current:
                latest_date[symbol], latest[symbol] = series[idx]
                idx += 1
            indices[symbol] = idx
            if symbol not in latest or (current - latest_date[symbol]).days > MAX_FFILL_DAYS:
                ok = False
                break
        if not ok:
            continue
        dates.append(current)
        for symbol in symbols:
            prices[symbol].append(latest[symbol])
    return dates, prices


def moving_average(values: list[float], period: int) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    rolling = 0.0
    for i, value in enumerate(values):
        rolling += value
        if i >= period:
            rolling -= values[i - period]
        if i >= period - 1:
            out[i] = rolling / period
    return out


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def rolling_vol(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] > 0 and values[cursor] > 0:
            returns.append(math.log(values[cursor] / values[cursor - 1]))
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(TRADING_DAYS)


def rolling_drawdown(values: list[float], index: int, lookback: int) -> float:
    start = max(0, index - lookback + 1)
    window = values[start : index + 1]
    peak = max(window) if window else 0.0
    return values[index] / peak - 1 if peak > 0 else 0.0


def performance(dates: list[date], values: list[float]) -> dict[str, float | None]:
    total, annualized, max_dd, vol, sharpe = app.performance_metrics(dates, values)
    return {
        "total": total,
        "annualized": annualized,
        "max_drawdown": max_dd,
        "volatility": vol,
        "sharpe": sharpe,
    }


def slice_metrics(dates: list[date], values: list[float], start: date) -> dict[str, float | None] | None:
    idx = next((i for i, day in enumerate(dates) if day >= start), None)
    if idx is None or idx >= len(dates) - 20:
        return None
    return performance(dates[idx:], values[idx:])


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    out = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = sum(out.values())
    if total > max_total and total > 0:
        scale = max_total / total
        out = {symbol: weight * scale for symbol, weight in out.items() if weight * scale > 0.0001}
    return out


def add_scaled(weights: dict[str, float], addition: dict[str, float]) -> None:
    for symbol, weight in addition.items():
        weights[symbol] = weights.get(symbol, 0.0) + weight


class Context:
    def __init__(self, dates: list[date], prices: dict[str, list[float]]):
        self.dates = dates
        self.prices = prices
        self.ma = {
            (symbol, period): moving_average(series, period)
            for symbol, series in prices.items()
            for period in [60, 90, 120, 160, 180, 200, 220, 240]
        }

    def mom(self, symbol: str, index: int, lookback: int) -> float | None:
        return momentum(self.prices[symbol], index, lookback)

    def vol(self, symbol: str, index: int, lookback: int = 60) -> float | None:
        return rolling_vol(self.prices[symbol], index, lookback)

    def above_ma(self, symbol: str, index: int, period: int) -> bool:
        ma = self.ma[(symbol, period)][index]
        return ma is not None and self.prices[symbol][index] >= ma

    def confirmed(self, symbol: str, index: int, *, ma_period: int = 180) -> bool:
        m60 = self.mom(symbol, index, 60)
        m120 = self.mom(symbol, index, 120)
        return m60 is not None and m120 is not None and m60 > 0 and m120 > 0 and self.above_ma(symbol, index, ma_period)

    def score(self, symbol: str, index: int) -> float:
        m60 = self.mom(symbol, index, 60) or 0.0
        m120 = self.mom(symbol, index, 120) or 0.0
        m240 = self.mom(symbol, index, 240) or 0.0
        vol = self.vol(symbol, index, 60) or 9.0
        return max(0.0, (0.65 * m120 + 0.25 * m60 + 0.10 * m240) / max(vol, 0.03))

    def scored_budget(self, symbols: list[str], index: int, budget: float, top_count: int, per_asset_cap: float) -> dict[str, float]:
        scored = [(self.score(symbol, index), symbol) for symbol in symbols if self.confirmed(symbol, index)]
        scored = [(score, symbol) for score, symbol in scored if score > 0]
        scored.sort(reverse=True)
        picked = scored[:top_count]
        total = sum(score for score, _symbol in picked)
        if total <= 0:
            return {}
        weights = {symbol: min(per_asset_cap, budget * score / total) for score, symbol in picked}
        leftover = budget - sum(weights.values())
        if leftover > 0.0001:
            uncapped = [item for item in picked if weights[item[1]] < per_asset_cap - 0.0001]
            total_uncapped = sum(score for score, symbol in uncapped if weights[symbol] < per_asset_cap - 0.0001)
            for score, symbol in uncapped:
                weights[symbol] += leftover * score / total_uncapped if total_uncapped > 0 else 0.0
        return normalize(weights, budget)


TargetFn = Callable[[Context, int, date, list[float], dict[str, float]], dict[str, float]]


def scale_risky(weights: dict[str, float], scale: float) -> dict[str, float]:
    return {symbol: weight * scale for symbol, weight in weights.items() if weight * scale > 0.0001}


def cash_barbell(ctx: Context, index: int, _day: date, values: list[float], _current: dict[str, float]) -> dict[str, float]:
    weights: dict[str, float] = {}
    if ctx.confirmed("gold_cny", index, ma_period=120):
        weights["gold_cny"] = 0.42
    us_ok = ctx.confirmed("sp500", index, ma_period=180) or ctx.confirmed("nasdaq", index, ma_period=180)
    if us_ok:
        add_scaled(weights, ctx.scored_budget(US, index, 0.32, top_count=2, per_asset_cap=0.22))
    china_ok = sum(1 for symbol in CHINA[:-1] if ctx.confirmed(symbol, index, ma_period=180)) >= 2
    if china_ok and not weak_global_risk(ctx, index):
        add_scaled(weights, ctx.scored_budget(CHINA[:-1], index, 0.14, top_count=2, per_asset_cap=0.08))
    if len(values) > 120 and rolling_drawdown(values, len(values) - 1, 120) < -0.045:
        weights = scale_risky(weights, 0.62)
    return normalize(weights, 0.82)


def weak_global_risk(ctx: Context, index: int) -> bool:
    sp = ctx.mom("sp500", index, 60) or 0.0
    nd = ctx.mom("nasdaq", index, 60) or 0.0
    us_dd = min(rolling_drawdown(ctx.prices["sp500"], index, 60), rolling_drawdown(ctx.prices["nasdaq"], index, 60))
    return (sp < -0.04 and nd < -0.04) or us_dd < -0.10


def canary_global_momentum(ctx: Context, index: int, _day: date, values: list[float], _current: dict[str, float]) -> dict[str, float]:
    canary_score = sum(1 for symbol in US[:2] if ctx.confirmed(symbol, index, ma_period=180))
    if canary_score == 0:
        if ctx.confirmed("gold_cny", index, ma_period=120):
            target = {"gold_cny": 0.55}
        else:
            target = {}
    else:
        target = {}
        add_scaled(target, ctx.scored_budget(["gold_cny"], index, 0.30, top_count=1, per_asset_cap=0.30))
        add_scaled(target, ctx.scored_budget(US + GLOBAL + CHINA[:-1], index, 0.58, top_count=3, per_asset_cap=0.26))
    if len(values) > 90 and rolling_drawdown(values, len(values) - 1, 90) < -0.035:
        target = scale_risky(target, 0.70)
    return normalize(target, 0.88)


def gold_us_handoff_plus_cash(ctx: Context, index: int, _day: date, values: list[float], _current: dict[str, float]) -> dict[str, float]:
    weights: dict[str, float] = {}
    gold_hot = (ctx.mom("gold_cny", index, 90) or 0.0) > 0.08
    gold_roll = (ctx.mom("gold_cny", index, 20) or 0.0) < 0
    if ctx.confirmed("gold_cny", index, ma_period=120):
        weights["gold_cny"] = 0.55 if not (gold_hot and gold_roll) else 0.35
    us_confirmed = [symbol for symbol in US[:2] if ctx.confirmed(symbol, index, ma_period=180)]
    if us_confirmed and (not weights or gold_roll):
        add_scaled(weights, ctx.scored_budget(US, index, 0.35, top_count=2, per_asset_cap=0.22))
    elif us_confirmed:
        add_scaled(weights, ctx.scored_budget(US, index, 0.20, top_count=1, per_asset_cap=0.20))
    if len(values) > 180 and rolling_drawdown(values, len(values) - 1, 180) < -0.06:
        weights = scale_risky(weights, 0.50)
    return normalize(weights, 0.85)


def low_turnover_persistence(ctx: Context, index: int, _day: date, values: list[float], current: dict[str, float]) -> dict[str, float]:
    keep: dict[str, float] = {}
    for symbol, weight in current.items():
        m60 = ctx.mom(symbol, index, 60)
        if m60 is not None and m60 > -0.025 and ctx.above_ma(symbol, index, 160):
            keep[symbol] = min(weight, 0.55 if symbol == "gold_cny" else 0.30)
    target = dict(keep)
    free_budget = max(0.0, 0.82 - sum(target.values()))
    if free_budget > 0.10:
        universe = ["gold_cny"] + US + CHINA[:-1] + GLOBAL
        add_scaled(target, ctx.scored_budget(universe, index, free_budget, top_count=2, per_asset_cap=0.35))
    if len(values) > 120 and rolling_drawdown(values, len(values) - 1, 120) < -0.05:
        target = scale_risky(target, 0.65)
    return normalize(target, 0.82)


def simulate(name: str, thesis: str, ctx: Context, target_fn: TargetFn, rebalance_sessions: int, band: float) -> Result:
    cash = INITIAL
    units = {symbol: 0.0 for symbol in ctx.prices}
    weights: dict[str, float] = {}
    values: list[float] = []
    trades = 0
    exposure_sum = 0.0
    last_rebalance = -10**9

    def value_at(index: int) -> float:
        return cash + sum(units[symbol] * ctx.prices[symbol][index] for symbol in ctx.prices)

    for index, day in enumerate(ctx.dates):
        if index > 0 and cash > 0:
            cash += cash * app.cash_daily_return(ctx.dates[index - 1])
        current_value = value_at(index)
        if index > 260 and (index == 260 or index - last_rebalance >= rebalance_sessions):
            signal_index = index - 1
            targets = target_fn(ctx, signal_index, ctx.dates[signal_index], values, weights)
            target_symbols = set(targets)
            held_symbols = {symbol for symbol, unit in units.items() if unit > 0}
            for symbol in sorted(held_symbols - target_symbols):
                price = ctx.prices[symbol][index] * (1 - SLIPPAGE)
                gross = units[symbol] * price
                cash += gross * (1 - FEE_RATE)
                units[symbol] = 0.0
                trades += 1
            for symbol in sorted(target_symbols):
                price = ctx.prices[symbol][index]
                current_position = units[symbol] * price
                target_position = current_value * targets[symbol]
                if current_position > target_position * (1 + band):
                    sell_value = current_position - target_position
                    sell_units = min(units[symbol], sell_value / price)
                    gross = sell_units * price * (1 - SLIPPAGE)
                    cash += gross * (1 - FEE_RATE)
                    units[symbol] -= sell_units
                    trades += 1
            current_value = value_at(index)
            for symbol in sorted(target_symbols):
                price = ctx.prices[symbol][index]
                current_position = units[symbol] * price
                target_position = current_value * targets[symbol]
                if current_position < target_position * (1 - band):
                    amount = min(cash, target_position - current_position)
                    if amount > 0:
                        units[symbol] += amount * (1 - FEE_RATE) / (price * (1 + SLIPPAGE))
                        cash -= amount
                        trades += 1
            weights = targets
            last_rebalance = index
        value = value_at(index)
        values.append(value)
        exposure_sum += sum(max(weight, 0.0) for weight in weights.values())
    return Result(name, thesis, ctx.dates, values, trades, exposure_sum / max(len(ctx.dates), 1), weights)


def summarize(result: Result) -> dict[str, object]:
    metrics = performance(result.dates, result.values)
    return {
        "name": result.name,
        "thesis": result.thesis,
        "full": metrics,
        "slices": {
            "post_2020": slice_metrics(result.dates, result.values, date(2020, 1, 1)),
            "last_10y": slice_metrics(result.dates, result.values, date(result.dates[-1].year - 10, result.dates[-1].month, result.dates[-1].day)),
            "post_2022": slice_metrics(result.dates, result.values, date(2022, 1, 1)),
            "post_2024": slice_metrics(result.dates, result.values, date(2024, 1, 1)),
        },
        "trades": result.trades,
        "average_exposure": result.average_exposure,
        "latest_weights": result.latest_weights,
    }


def run_baselines() -> list[dict[str, object]]:
    rows = []
    for strategy in [
        "coreGoldSatelliteHeatCappedMomentum",
        "coreGoldSatelliteGoldHandoffMomentum",
        "coreGoldSatelliteEquityBreadthMomentum",
        "coreGoldSatelliteOneWayVolManagedMomentum",
    ]:
        result = app.run_strategy(strategy)
        rows.append({
            "name": f"app_equivalent_{strategy}",
            "thesis": "Current app-equivalent parity baseline.",
            "full": performance(result.dates, result.values),
            "slices": {
                "post_2020": slice_metrics(result.dates, result.values, date(2020, 1, 1)),
                "last_10y": slice_metrics(result.dates, result.values, date(result.dates[-1].year - 10, result.dates[-1].month, result.dates[-1].day)),
                "post_2022": slice_metrics(result.dates, result.values, date(2022, 1, 1)),
                "post_2024": slice_metrics(result.dates, result.values, date(2024, 1, 1)),
            },
            "trades": len(result.trades),
            "average_exposure": None,
            "latest_weights": None,
        })
    return rows


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def main() -> None:
    raw = fetch_history()
    points = prepare_points(raw)
    full_dates, full_prices = align(points, CORE_FULL_HISTORY)
    ctx = Context(full_dates, full_prices)

    candidates: list[Result] = []
    mechanisms = [
        ("cash_barbell", "Cash ballast plus separate gold, US, and China sleeves; portfolio drawdown throttles all risk.", cash_barbell),
        ("canary_global_momentum", "US canary decides whether global risk is allowed; otherwise gold or cash only.", canary_global_momentum),
        ("gold_us_handoff_plus_cash", "Gold is the main safe sleeve, but a gold rollover hands risk to confirmed US assets or cash.", gold_us_handoff_plus_cash),
        ("low_turnover_persistence", "Keep still-valid holdings to avoid 1% fee drag, then refill only free risk budget with confirmed leaders.", low_turnover_persistence),
    ]
    for rebalance in [20, 40, 60, 120]:
        for band in [0.02, 0.05]:
            for name, thesis, fn in mechanisms:
                candidates.append(simulate(f"{name}_reb{rebalance}_band{int(band * 100)}", thesis, ctx, fn, rebalance, band))

    rows = run_baselines() + [summarize(result) for result in candidates]
    rows.sort(
        key=lambda row: (
            (row["full"]["sharpe"] or -9),  # type: ignore[index]
            (row["full"]["annualized"] or -9),  # type: ignore[index]
        ),
        reverse=True,
    )

    output = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "constraints": {
            "assets": CORE_FULL_HISTORY,
            "fee_rate": FEE_RATE,
            "slippage": SLIPPAGE,
            "no_leverage": True,
            "no_external_tickers": True,
        },
        "coverage": {
            "start": full_dates[0].isoformat(),
            "end": full_dates[-1].isoformat(),
            "points": len(full_dates),
        },
        "rows": rows,
    }
    out_path = Path(__file__).with_name("results.json")
    out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2))
    print(f"WROTE {out_path}")
    print("name | ann | dd | vol | sharpe | post2020 ann/dd | trades | avg exposure | latest")
    for row in rows[:20]:
        full = row["full"]  # type: ignore[assignment]
        p20 = row["slices"]["post_2020"]  # type: ignore[index]
        latest = row["latest_weights"]
        print(
            f"{row['name']} | {pct(full['annualized'])} | {pct(full['max_drawdown'])} | "
            f"{pct(full['volatility'])} | {full['sharpe']:.3f} | "
            f"{pct(p20['annualized']) if p20 else 'n/a'}/{pct(p20['max_drawdown']) if p20 else 'n/a'} | "
            f"{row['trades']} | {row['average_exposure']} | {latest}"
        )


if __name__ == "__main__":
    main()
