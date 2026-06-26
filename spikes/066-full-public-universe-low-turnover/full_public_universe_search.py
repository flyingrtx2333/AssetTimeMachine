#!/usr/bin/env python3
"""Low-turnover tactical allocation across all non-crypto public assets.

This spike tests whether the broader backend asset universe contains a better
low-correlation source for the App's 1% fee world. It excludes crypto and
leverage, then runs quarterly/monthly tactical allocation variants.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
import bisect
import json
import math
from pathlib import Path
import statistics
import urllib.parse
import urllib.request
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]

import sys
sys.path.insert(0, str(ROOT / "tools"))
import atm_app_equivalent_backtest as app  # noqa: E402

API_URL = "https://api.flyingrtx.com/api/v1/money/public/history"
FEE_RATE = 0.01
SLIPPAGE_RATE = 0.0005
INITIAL_CASH = 100_000.0
SYMBOL_ALIASES = {
    "nasdaq_composite": "nasdaq",
    "dow_jones": "dowjones",
    "nikkei225": "nikkei",
    "hang_seng": "hsi",
}
CRYPTO = {"btc", "eth", "bnb", "sol", "xrp", "doge"}
TRADE_UNIVERSE = [
    "gold_cny",
    "nasdaq",
    "sp500",
    "dowjones",
    "nikkei",
    "hsi",
    "shanghai_composite",
    "shenzhen_component",
    "csi300",
    "chinext",
    "oil_wti_cny",
    "oil_brent_cny",
    "usd_cash",
]
USD_CONVERTED = {"nasdaq", "sp500", "dowjones", "gold_usd", "oil_wti_usd", "oil_brent_usd"}


@dataclass(frozen=True)
class TacticalSpec:
    name: str
    thesis: str
    mode: str
    rebalance_sessions: int
    top_count: int
    max_asset_weight: float
    max_total_weight: float
    min_score: float
    trend_ma: int
    fast_lookback: int
    slow_lookback: int
    vol_lookback: int
    rebalance_band: float


def parse_date(text: str) -> date:
    return datetime.strptime(text[:10], "%Y-%m-%d").date()


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def fetch_raw() -> dict[str, list[tuple[date, float]]]:
    url = API_URL + "?" + urllib.parse.urlencode({"period": "all"})
    with urllib.request.urlopen(url, timeout=90) as response:
        payload = json.load(response)
    if not payload.get("success"):
        raise RuntimeError(f"history API failed: {payload!r}")
    out: dict[str, list[tuple[date, float]]] = {}
    for item in payload.get("series", []):
        symbol = SYMBOL_ALIASES.get(str(item["symbol"]), str(item["symbol"]))
        if symbol in CRYPTO:
            continue
        rows: dict[date, float] = {}
        for date_text, price in zip(item["dates"], item["prices"]):
            if isinstance(price, (int, float)) and math.isfinite(price) and price > 0:
                rows[parse_date(date_text)] = float(price)
        if rows:
            out[symbol] = sorted(rows.items())
    return out


def price_on_or_before(points: list[tuple[date, float]], target: date) -> float | None:
    days = [day for day, _price in points]
    idx = bisect.bisect_right(days, target) - 1
    if idx < 0:
        return None
    return points[idx][1]


def normalize_usd_assets(raw: dict[str, list[tuple[date, float]]]) -> dict[str, list[tuple[date, float]]]:
    fx = raw["usd_per_cny"]
    out: dict[str, list[tuple[date, float]]] = {}
    for symbol, rows in raw.items():
        if symbol == "usd_per_cny":
            continue
        converted: list[tuple[date, float]] = []
        for day, price in rows:
            if symbol in USD_CONVERTED:
                fx_rate = price_on_or_before(fx, day)
                if fx_rate is None or fx_rate <= 0 or not math.isfinite(fx_rate):
                    continue
                cny_price = price / fx_rate if fx_rate < 1 else price * fx_rate if fx_rate <= 20 else None
                if cny_price is None:
                    continue
                converted.append((day, cny_price))
            else:
                converted.append((day, price))
        out[symbol] = converted

    usd_cash: list[tuple[date, float]] = []
    for day, fx_rate in fx:
        if fx_rate <= 0:
            continue
        usd_cash.append((day, 1 / fx_rate if fx_rate < 1 else fx_rate))
    out["usd_cash"] = usd_cash
    return out


def align_series(raw: dict[str, list[tuple[date, float]]], symbols: list[str]) -> tuple[list[date], dict[str, list[float]], dict[str, list[bool]]]:
    point_days = {symbol: [day for day, _price in raw[symbol]] for symbol in symbols if symbol in raw}
    all_dates = sorted({day for symbol in symbols if symbol in raw for day, _price in raw[symbol]})
    indices = {symbol: 0 for symbol in symbols if symbol in raw}
    latest_prices: dict[str, float] = {}
    latest_dates: dict[str, date] = {}
    dates: list[date] = []
    prices = {symbol: [] for symbol in symbols if symbol in raw}
    valid = {symbol: [] for symbol in symbols if symbol in raw}

    for current_date in all_dates:
        for symbol in list(prices):
            rows = raw[symbol]
            idx = indices[symbol]
            while idx < len(rows) and rows[idx][0] <= current_date:
                latest_dates[symbol], latest_prices[symbol] = rows[idx]
                idx += 1
            indices[symbol] = idx
        if "gold_cny" not in latest_prices or "nasdaq" not in latest_prices or "sp500" not in latest_prices:
            continue
        dates.append(current_date)
        for symbol in list(prices):
            if symbol in latest_prices:
                stale_days = (current_date - latest_dates[symbol]).days
                prices[symbol].append(latest_prices[symbol])
                valid[symbol].append(stale_days <= app.MAX_FORWARD_FILL_CALENDAR_DAYS)
            else:
                prices[symbol].append(0.0)
                valid[symbol].append(False)
    return dates, prices, valid


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index - lookback] <= 0 or values[index] <= 0:
        return None
    return values[index] / values[index - lookback] - 1.0


def moving_average(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    window = values[index - period + 1:index + 1]
    if any(value <= 0 for value in window):
        return None
    return sum(window) / period


def annual_vol(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        prev = values[cursor - 1]
        cur = values[cursor]
        if prev <= 0 or cur <= 0:
            return None
        returns.append(math.log(cur / prev))
    if len(returns) < 20:
        return None
    return statistics.stdev(returns) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def rolling_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0 or values[index] <= 0:
        return None
    window = values[index - lookback + 1:index + 1]
    if any(value <= 0 for value in window):
        return None
    peak = max(window)
    return values[index] / peak - 1.0 if peak > 0 else None


def normalize(weights: dict[str, float], max_total: float, max_asset: float) -> dict[str, float]:
    clean = {
        symbol: min(max(weight, 0.0), max_asset)
        for symbol, weight in weights.items()
        if weight > 0.0001
    }
    total = sum(clean.values())
    if total > max_total and total > 0:
        scale = max_total / total
        clean = {symbol: weight * scale for symbol, weight in clean.items() if weight * scale > 0.0001}
    return clean


def asset_score(
    symbol: str,
    prices: dict[str, list[float]],
    valid: dict[str, list[bool]],
    index: int,
    spec: TacticalSpec,
) -> tuple[float, float] | None:
    if symbol not in prices or not valid[symbol][index] or prices[symbol][index] <= 0:
        return None
    values = prices[symbol]
    fast = momentum(values, index, spec.fast_lookback)
    slow = momentum(values, index, spec.slow_lookback)
    ma = moving_average(values, index, spec.trend_ma)
    vol = annual_vol(values, index, spec.vol_lookback)
    dd = rolling_drawdown(values, index, spec.vol_lookback)
    if None in (fast, slow, ma, vol, dd):
        return None
    assert fast is not None and slow is not None and ma is not None and vol is not None and dd is not None
    if prices[symbol][index] < ma or fast <= 0 or slow < -0.04:
        return None
    if symbol.startswith("oil_") and (vol > 0.70 or dd < -0.25):
        return None
    if symbol in {"hsi", "nikkei", "shanghai_composite", "shenzhen_component", "csi300", "chinext"} and dd < -0.22:
        return None
    raw = (0.65 * fast + 0.35 * slow + max(dd, -0.30) * 0.15) / max(vol, 0.04)
    if spec.mode == "momentum":
        score = raw
    elif spec.mode == "defensive_bias":
        defensive_bonus = 0.25 if symbol in {"gold_cny", "usd_cash"} else 0.0
        score = raw + defensive_bonus
    elif spec.mode == "commodity_separate":
        score = raw
        if symbol.startswith("oil_"):
            score *= 0.75
        if symbol == "gold_cny":
            score += 0.15
    else:
        raise ValueError(spec.mode)
    if score <= spec.min_score:
        return None
    return score, vol


def target_weights(
    prices: dict[str, list[float]],
    valid: dict[str, list[bool]],
    index: int,
    spec: TacticalSpec,
) -> dict[str, float]:
    scored: list[tuple[float, float, str]] = []
    for symbol in TRADE_UNIVERSE:
        result = asset_score(symbol, prices, valid, index, spec)
        if result is None:
            continue
        score, vol = result
        scored.append((score, vol, symbol))
    scored.sort(reverse=True)
    selected = scored[:max(spec.top_count, 1)]
    if not selected:
        return {}
    inv_scores = {symbol: max(score, 0.01) / max(vol, 0.05) for score, vol, symbol in selected}
    total = sum(inv_scores.values())
    raw = {symbol: spec.max_total_weight * value / total for symbol, value in inv_scores.items() if total > 0}
    return normalize(raw, spec.max_total_weight, spec.max_asset_weight)


def targets_changed(first: dict[str, float], second: dict[str, float], tolerance: float = 0.0005) -> bool:
    symbols = set(first) | set(second)
    return any(abs(first.get(symbol, 0.0) - second.get(symbol, 0.0)) > tolerance for symbol in symbols)


def rebalance(
    *,
    index: int,
    dates: list[date],
    prices: dict[str, list[float]],
    targets: dict[str, float],
    cash_box: dict[str, float],
    units: dict[str, float],
    held: set[str],
    trades: list[Any],
    band: float,
) -> dict[str, float]:
    cash = cash_box["cash"]
    targets = normalize(targets, 1.0, 1.0)
    target_symbols = set(targets)
    tradable_symbols = list(units)

    def portfolio_value() -> float:
        return cash + sum(units[symbol] * prices[symbol][index] for symbol in tradable_symbols)

    pre_value = portfolio_value()
    for symbol in sorted(held - target_symbols):
        current_units = units.get(symbol, 0.0)
        if current_units <= 0:
            continue
        execution_price = max(prices[symbol][index] * (1 - SLIPPAGE_RATE), 0.0)
        cash_amount = current_units * execution_price * (1 - FEE_RATE)
        cash += cash_amount
        units[symbol] = 0.0
        trades.append((dates[index].isoformat(), "sell", symbol, cash_amount))
    held &= target_symbols

    for symbol in sorted(target_symbols):
        current_units = units.get(symbol, 0.0)
        if current_units <= 0:
            continue
        price = prices[symbol][index]
        current_value = current_units * price
        target_value = pre_value * targets[symbol]
        if current_value <= target_value * (1 + band):
            continue
        units_to_sell = min(current_units, (current_value - target_value) / price)
        execution_price = max(price * (1 - SLIPPAGE_RATE), 0.0)
        cash_amount = units_to_sell * execution_price * (1 - FEE_RATE)
        cash += cash_amount
        units[symbol] = max(current_units - units_to_sell, 0.0)
        trades.append((dates[index].isoformat(), "sell", symbol, cash_amount))
        if units[symbol] <= 1e-12:
            held.discard(symbol)

    total_value = portfolio_value()
    for symbol in sorted(target_symbols):
        price = prices[symbol][index]
        current_value = units.get(symbol, 0.0) * price
        target_value = total_value * targets[symbol]
        if current_value >= target_value * (1 - band):
            continue
        amount = min(cash, max(target_value - current_value, 0.0))
        if amount <= 1.0:
            continue
        execution_price = price * (1 + SLIPPAGE_RATE)
        bought_units = amount * (1 - FEE_RATE) / execution_price if execution_price > 0 else 0.0
        units[symbol] = units.get(symbol, 0.0) + bought_units
        cash -= amount
        held.add(symbol)
        trades.append((dates[index].isoformat(), "buy", symbol, amount))

    cash_box["cash"] = cash
    return targets


def run_spec(dates: list[date], prices: dict[str, list[float]], valid: dict[str, list[bool]], spec: TacticalSpec) -> dict[str, Any]:
    symbols = [symbol for symbol in TRADE_UNIVERSE if symbol in prices]
    cash_box = {"cash": INITIAL_CASH}
    units = {symbol: 0.0 for symbol in symbols}
    held: set[str] = set()
    trades: list[Any] = []
    values: list[float] = []
    active_targets: dict[str, float] = {}
    max_target_sum = 0.0

    def portfolio_value(index: int) -> float:
        return cash_box["cash"] + sum(units[symbol] * prices[symbol][index] for symbol in symbols)

    for index, _day in enumerate(dates):
        if index > 0 and cash_box["cash"] > 0:
            interest = cash_box["cash"] * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash_box["cash"] += interest
        if index == 0 or index % max(spec.rebalance_sessions, 1) == 0:
            signal_index = index - 1
            targets = target_weights(prices, valid, signal_index, spec) if signal_index >= 0 else {}
            max_target_sum = max(max_target_sum, sum(targets.values()))
            if targets_changed(targets, active_targets):
                active_targets = rebalance(
                    index=index,
                    dates=dates,
                    prices=prices,
                    targets=targets,
                    cash_box=cash_box,
                    units=units,
                    held=held,
                    trades=trades,
                    band=spec.rebalance_band,
                )
        values.append(portfolio_value(index))

    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates, values)
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": spec.__dict__,
        "full": {
            "annualized": annualized,
            "max_drawdown": max_dd,
            "annual_volatility": annual_vol,
            "sharpe": sharpe,
            "total": total,
            "trades": len(trades),
        },
        "slices": {
            "post_2020": slice_metrics(dates, values, "2020-01-01"),
            "last_10y": slice_metrics(dates, values, "2016-06-23"),
            "post_2022": slice_metrics(dates, values, "2022-01-01"),
            "post_2024": slice_metrics(dates, values, "2024-01-01"),
        },
        "drawdown_window": max_drawdown_window(dates, values),
        "latest_trades": trades[-10:],
        "extra": {
            "max_target_sum": max_target_sum,
            "symbols": symbols,
        },
    }


def slice_metrics(dates: list[date], values: list[float], start: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    idx = next((i for i, day in enumerate(dates) if day >= start_date), None)
    if idx is None or idx >= len(dates) - 2:
        return {"annualized": None, "max_drawdown": None, "sharpe": None, "annual_volatility": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(dates[idx:], values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "sharpe": sharpe, "annual_volatility": annual_vol, "total": total}


def max_drawdown_window(dates: list[date], values: list[float]) -> dict[str, Any]:
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


def specs() -> list[TacticalSpec]:
    out: list[TacticalSpec] = []
    for mode in ["momentum", "defensive_bias", "commodity_separate"]:
        for rebalance_sessions in [21, 63, 126]:
            for top_count in [1, 2, 3]:
                for max_asset_weight in [0.45, 0.60, 0.80]:
                    for max_total_weight in [0.70, 0.85, 1.0]:
                        for min_score in [0.0, 0.25, 0.50]:
                            out.append(
                                TacticalSpec(
                                    name=(
                                        f"{mode}_r{rebalance_sessions}_top{top_count}_"
                                        f"asset{int(max_asset_weight*100)}_gross{int(max_total_weight*100)}_"
                                        f"score{int(min_score*100)}"
                                    ),
                                    thesis="Low-turnover all-public-assets tactical allocation.",
                                    mode=mode,
                                    rebalance_sessions=rebalance_sessions,
                                    top_count=top_count,
                                    max_asset_weight=max_asset_weight,
                                    max_total_weight=max_total_weight,
                                    min_score=min_score,
                                    trend_ma=180,
                                    fast_lookback=63,
                                    slow_lookback=126,
                                    vol_lookback=126,
                                    rebalance_band=0.05,
                                )
                            )
    return out


def main() -> None:
    raw = normalize_usd_assets(fetch_raw())
    dates, prices, valid = align_series(raw, TRADE_UNIVERSE)
    rows = [run_spec(dates, prices, valid, spec) for spec in specs()]
    rows = [row for row in rows if row["full"]["trades"] >= 20]
    rows.sort(key=lambda row: (row["full"]["sharpe"] or -9.0, row["full"]["annualized"]), reverse=True)
    out_path = HERE / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "coverage": {"start": dates[0].isoformat(), "end": dates[-1].isoformat(), "count": len(dates)},
                "note": "All non-crypto public assets, 1% fee, 0.05% slippage, no leverage, no shorting.",
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sharpe | last10 ann/sharpe | post2024 ann/sharpe | trades | dd window")
    for row in rows[:60]:
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
