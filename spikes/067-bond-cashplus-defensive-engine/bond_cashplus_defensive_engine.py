#!/usr/bin/env python3
"""1% fee defensive-engine search with external bond/cash-plus assets.

No leverage, no shorting, no BTC. This spike tests whether a genuinely new
low-correlation sleeve can lift the current App-equivalent gold/equity engine
after transaction costs moved to 1%.

External assets are Yahoo adjusted-close total-return proxies converted to CNY
with the App's usd_per_cny series. A passing result still requires backend
history support before it can be productized.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timezone
import importlib.util
import json
import math
from pathlib import Path
import sys
import urllib.parse
import urllib.request
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SPIKE_DIR = Path(__file__).resolve().parent


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


carry = load_module("atm_spike041_carry", ROOT / "spikes/041-carry-total-return-assets/carry_total_return_assets.py")
app = carry.app

END_DATE = app.parse_date("2026-06-23")
INITIAL_CASH = 100_000.0
FEE_RATE = 0.01
SLIPPAGE_RATE = 0.0005
YAHOO_CACHE = Path("/tmp/atm_spike067_yahoo_cache")

YAHOO_SYMBOLS = {
    "vustx": "VUSTX",
    "vfitx": "VFITX",
    "vfisx": "VFISX",
    "tlt": "TLT",
    "ief": "IEF",
    "shy": "SHY",
    "tip": "TIP",
    "lqd": "LQD",
    "ostix": "OSTIX",
    "rphyx": "RPHYX",
}

TREASURY_POOL = ["vfitx", "vfisx", "ief", "shy", "tip"]
DURATION_POOL = ["vustx", "tlt", "vfitx", "ief", "vfisx", "shy"]
CASHPLUS_POOL = ["ostix", "rphyx", "vfisx", "shy"]
DEFENSIVE_POOL = sorted(set(TREASURY_POOL + DURATION_POOL + CASHPLUS_POOL + ["lqd", "usd_cash"]))
EQUITY_SYMBOLS = {"nasdaq", "sp500", "dowjones", "csi300", "shanghai_composite", "shenzhen_component", "chinext", "hsi", "nikkei"}


@dataclass(frozen=True)
class EngineSpec:
    name: str
    thesis: str
    mode: str
    idle_fraction: float
    cap: float
    per_asset_cap: float
    stress_equity_scale: float = 1.0
    stress_only: bool = False
    rebalance_sessions: int | None = None
    no_trade_band: float = 0.05


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def total_weight(weights: dict[str, float]) -> float:
    return sum(max(weight, 0.0) for weight in weights.values())


def normalize(weights: dict[str, float], max_total: float = 1.0) -> dict[str, float]:
    clean = {symbol: max(weight, 0.0) for symbol, weight in weights.items() if weight > 0.0001}
    total = total_weight(clean)
    if total > max_total and total > 0:
        scale = max_total / total
        clean = {symbol: weight * scale for symbol, weight in clean.items() if weight * scale > 0.0001}
    return clean


def fetch_yahoo_adjusted(symbol: str) -> list[tuple[date, float]]:
    yahoo = YAHOO_SYMBOLS[symbol]
    cache_path = YAHOO_CACHE / f"{urllib.parse.quote(yahoo, safe='')}.json"
    if cache_path.exists():
        raw = json.loads(cache_path.read_text())
        return [(date.fromisoformat(day), float(price)) for day, price in raw if float(price) > 0]

    p1 = int(datetime(1999, 1, 1, tzinfo=timezone.utc).timestamp())
    p2 = int(datetime(2026, 6, 24, tzinfo=timezone.utc).timestamp())
    url = (
        "https://query1.finance.yahoo.com/v8/finance/chart/"
        f"{urllib.parse.quote(yahoo, safe='')}?period1={p1}&period2={p2}"
        "&interval=1d&events=history&includeAdjustedClose=true"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as response:
        payload = json.load(response)
    error = payload.get("chart", {}).get("error")
    if error:
        raise RuntimeError(f"Yahoo error for {yahoo}: {error}")
    result = payload["chart"]["result"][0]
    timestamps = result.get("timestamp") or []
    quote = result["indicators"]["quote"][0]
    adjusted = result["indicators"].get("adjclose", [{}])[0].get("adjclose") or quote["close"]
    rows: list[tuple[date, float]] = []
    for timestamp, price in zip(timestamps, adjusted):
        if price is None or not math.isfinite(float(price)) or float(price) <= 0:
            continue
        rows.append((datetime.fromtimestamp(timestamp, timezone.utc).date(), float(price)))

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps([(day.isoformat(), price) for day, price in rows]))
    return rows


def cny_points_for(symbol: str, fx_points: list[tuple[date, float]]) -> list[tuple[date, float]]:
    points = fetch_yahoo_adjusted(symbol)
    return carry.convert_usd_points_to_cny(points, fx_points)


def align_external_series(dates: list[date], raw: dict[str, list[tuple[date, float]]]) -> dict[str, list[float]]:
    fx_points = raw[app.USD_FX_SYMBOL]
    out: dict[str, list[float]] = {}
    for symbol in YAHOO_SYMBOLS:
        cny_points = cny_points_for(symbol, fx_points)
        series: list[float] = []
        for day in dates:
            price = carry.price_on_or_before(cny_points, day, app.MAX_FORWARD_FILL_CALENDAR_DAYS)
            series.append(price if price is not None else 0.0)
        out[symbol] = series

    usd_cash: list[float] = []
    for day in dates:
        fx = carry.price_on_or_before(fx_points, day, app.MAX_FORWARD_FILL_CALENDAR_DAYS)
        cny_per_usd = carry.cny_per_usd_from_fx(fx) if fx is not None else None
        usd_cash.append(cny_per_usd if cny_per_usd is not None else 0.0)
    out["usd_cash"] = usd_cash
    return out


def ma(values: list[float], index: int, period: int) -> float | None:
    if index - period + 1 < 0:
        return None
    window = values[index - period + 1 : index + 1]
    if any(value <= 0 for value in window):
        return None
    return sum(window) / period


def momentum(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback < 0 or values[index] <= 0 or values[index - lookback] <= 0:
        return None
    return values[index] / values[index - lookback] - 1


def annual_vol(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 1:
        return None
    returns: list[float] = []
    for cursor in range(index - lookback + 1, index + 1):
        if values[cursor - 1] <= 0 or values[cursor] <= 0:
            return None
        returns.append(math.log(values[cursor] / values[cursor - 1]))
    if len(returns) < 20:
        return None
    mean = sum(returns) / len(returns)
    variance = sum((item - mean) ** 2 for item in returns) / (len(returns) - 1)
    return math.sqrt(max(variance, 0.0)) * math.sqrt(app.TRADING_DAYS_PER_YEAR)


def rolling_drawdown(values: list[float], index: int, lookback: int) -> float | None:
    if index - lookback + 1 < 0 or values[index] <= 0:
        return None
    window = values[index - lookback + 1 : index + 1]
    if any(value <= 0 for value in window):
        return None
    peak = max(window)
    return values[index] / peak - 1 if peak > 0 else None


def healthy_defensive(prices: dict[str, list[float]], symbol: str, index: int, stress: bool) -> bool:
    values = prices[symbol]
    if values[index] <= 0:
        return False
    if symbol == "usd_cash":
        mom60 = momentum(values, index, 60)
        return mom60 is not None and mom60 > 0

    ma_period = 80 if symbol in {"ostix", "rphyx", "vfisx", "shy"} else 120
    trend = ma(values, index, ma_period)
    mom60 = momentum(values, index, 60)
    mom120 = momentum(values, index, 120)
    dd60 = rolling_drawdown(values, index, 60)
    if trend is None or mom60 is None or mom120 is None or dd60 is None:
        return False
    if values[index] < trend or dd60 < -0.03:
        return False
    if symbol in {"vustx", "tlt"} and not stress and dd60 < -0.015:
        return False
    if symbol in {"ostix", "lqd"} and dd60 < -0.025:
        return False
    return mom60 > -0.003 and mom120 > -0.006


def defensive_score(prices: dict[str, list[float]], symbol: str, index: int, stress: bool) -> float | None:
    if not healthy_defensive(prices, symbol, index, stress):
        return None
    values = prices[symbol]
    if symbol == "usd_cash":
        mom60 = momentum(values, index, 60) or 0.0
        mom120 = momentum(values, index, 120) or 0.0
        return max(0.0, mom120 + 0.5 * mom60)

    mom60 = momentum(values, index, 60) or 0.0
    mom120 = momentum(values, index, 120) or 0.0
    vol60 = annual_vol(values, index, 60) or 0.08
    bias = {
        "ostix": 0.012,
        "rphyx": 0.004,
        "vfisx": 0.001,
        "shy": 0.001,
        "vfitx": 0.004,
        "ief": 0.004,
        "tip": 0.002,
        "lqd": 0.003,
        "vustx": 0.012 if stress else -0.006,
        "tlt": 0.012 if stress else -0.006,
    }.get(symbol, 0.0)
    score = (mom120 + 0.5 * mom60 + bias) / max(vol60, 0.01)
    return score if score > 0 else None


def choose_defensive_pool(mode: str) -> list[str]:
    if mode == "treasury_idle":
        return TREASURY_POOL
    if mode == "duration_riskoff":
        return DURATION_POOL + ["usd_cash"]
    if mode == "cashplus_idle":
        return CASHPLUS_POOL
    if mode == "cashplus_credit":
        return ["ostix", "rphyx", "lqd", "vfisx", "shy", "usd_cash"]
    return DEFENSIVE_POOL


def allocate_defensive(
    prices: dict[str, list[float]],
    mode: str,
    index: int,
    budget: float,
    per_asset_cap: float,
    stress: bool,
) -> dict[str, float]:
    if budget <= 0:
        return {}
    scored: list[tuple[float, str]] = []
    for symbol in choose_defensive_pool(mode):
        score = defensive_score(prices, symbol, index, stress)
        if score is not None:
            scored.append((score, symbol))
    scored.sort(reverse=True)
    if not scored:
        return {}

    selected = scored[:2 if mode in {"treasury_idle", "all_defensive"} else 1]
    total_score = sum(score for score, _symbol in selected)
    if total_score <= 0:
        return {}
    out: dict[str, float] = {}
    remaining = budget
    for score, symbol in selected:
        weight = min(per_asset_cap, budget * score / total_score, remaining)
        if weight > 0.0001:
            out[symbol] = weight
            remaining -= weight
    return out


def macro_stress(core_prices: dict[str, list[float]], index: int) -> bool:
    weak = 0
    checked = 0
    for symbol in EQUITY_SYMBOLS:
        values = core_prices.get(symbol)
        if not values or index >= len(values) or values[index] <= 0:
            continue
        checked += 1
        ma120 = ma(values, index, 120)
        mom60 = momentum(values, index, 60)
        dd60 = rolling_drawdown(values, index, 60)
        if ma120 is None or mom60 is None or dd60 is None:
            continue
        if values[index] < ma120 or mom60 < -0.03 or dd60 < -0.08:
            weak += 1
    if checked == 0:
        return False
    return weak >= max(2, math.ceil(checked * 0.45))


def portfolio_stress(values_by_index: list[float], index: int) -> bool:
    clean = [value for value in values_by_index[max(0, index - 90) : index + 1] if value > 0]
    if len(clean) < 30:
        return False
    peak = max(clean)
    return peak > 0 and clean[-1] / peak - 1 < -0.035


def apply_engine(
    base_target: dict[str, float],
    spec: EngineSpec,
    prices: dict[str, list[float]],
    core_prices: dict[str, list[float]],
    signal_index: int,
    values_by_index: list[float],
) -> dict[str, float]:
    if spec.mode == "baseline":
        return normalize(base_target)

    stress = macro_stress(core_prices, signal_index) or portfolio_stress(values_by_index, signal_index)
    out = dict(base_target)
    if stress and spec.stress_equity_scale < 1.0:
        for symbol in list(out):
            if symbol in EQUITY_SYMBOLS:
                out[symbol] *= spec.stress_equity_scale
                if out[symbol] <= 0.0001:
                    del out[symbol]

    if spec.stress_only and not stress:
        return normalize(out)

    available = max(0.0, 1.0 - total_weight(out))
    budget = min(spec.cap, available) * min(max(spec.idle_fraction, 0.0), 1.0)
    for symbol, weight in allocate_defensive(prices, spec.mode, signal_index, budget, spec.per_asset_cap, stress).items():
        out[symbol] = out.get(symbol, 0.0) + weight
    return normalize(out)


def run_engine(spec: EngineSpec) -> app.BacktestResult:
    dates, core_prices, symbols, config, meta_traces, overlay, raw = carry.cached_core_context("index", END_DATE)
    external_prices = align_external_series(dates, raw)
    prices = {**core_prices, **external_prices}
    tradable_symbols = [symbol for symbol in symbols if symbol not in config.signal_only_symbols] + list(external_prices.keys())
    tradable_symbols = sorted(set(tradable_symbols))

    cash = INITIAL_CASH
    units = {symbol: 0.0 for symbol in tradable_symbols}
    held: set[str] = set()
    points: list[float] = []
    values_by_index = [0.0 for _ in dates]
    trades: list[app.Trade] = []
    targets_by_index: dict[int, dict[str, float]] = {}
    rebalance_sessions = spec.rebalance_sessions or max(config.rebalance_sessions, 1)
    band = max(config.rebalance_band, spec.no_trade_band)

    def portfolio_value(index: int) -> float:
        return cash + sum(units[symbol] * prices[symbol][index] for symbol in tradable_symbols)

    def target_weights(signal_index: int, trace_index: int) -> dict[str, float]:
        raw_weights = app.meta_rotation_target_weights(config.meta_switch, signal_index, trace_index, meta_traces) if config.meta_switch else {}
        base = overlay(raw_weights or {}, signal_index, dates[signal_index], core_prices, values_by_index, config)
        return apply_engine(base, spec, prices, core_prices, signal_index, values_by_index)

    for index, current_date in enumerate(dates):
        if index > 0 and cash > 0:
            interest = cash * app.cash_daily_return(dates[index - 1])
            if math.isfinite(interest) and interest > 0:
                cash += interest

        if index == 0 or index % rebalance_sessions == 0:
            signal_index = index - 1
            targets = normalize(target_weights(signal_index, index) if signal_index >= 0 else {})
            targets = {symbol: weight for symbol, weight in targets.items() if prices.get(symbol, [0.0])[index] > 0}
            targets_by_index[index] = dict(targets)
            target_symbols = set(targets.keys())
            pre_value = portfolio_value(index)

            for symbol in sorted(held - target_symbols):
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                price = prices[symbol][index]
                if price <= 0:
                    continue
                execution_price = max(price * (1 - SLIPPAGE_RATE), 0.0)
                cash_amount = current_units * execution_price * (1 - FEE_RATE)
                cash += cash_amount
                units[symbol] = 0.0
                trades.append(app.Trade(current_date.isoformat(), "sell", symbol, execution_price, cash_amount, current_units))
            held &= target_symbols

            for symbol in sorted(target_symbols):
                current_units = units.get(symbol, 0.0)
                if current_units <= 0:
                    continue
                price = prices[symbol][index]
                if price <= 0:
                    continue
                current_value = current_units * price
                target_value = pre_value * targets[symbol]
                current_weight = current_value / pre_value if pre_value > 0 else 0.0
                if abs(current_weight - targets[symbol]) < band:
                    continue
                gross_to_sell = max(current_value - target_value, 0.0)
                if gross_to_sell <= 0:
                    continue
                units_to_sell = min(current_units, gross_to_sell / price)
                execution_price = max(price * (1 - SLIPPAGE_RATE), 0.0)
                cash_amount = units_to_sell * execution_price * (1 - FEE_RATE)
                cash += cash_amount
                units[symbol] = max(current_units - units_to_sell, 0.0)
                trades.append(app.Trade(current_date.isoformat(), "sell", symbol, execution_price, cash_amount, units_to_sell))
                if units[symbol] <= sys.float_info.min:
                    held.discard(symbol)

            total = portfolio_value(index)
            for symbol in sorted(target_symbols):
                price = prices[symbol][index]
                if price <= 0:
                    continue
                current_value = units.get(symbol, 0.0) * price
                target_value = total * targets[symbol]
                current_weight = current_value / total if total > 0 else 0.0
                if abs(current_weight - targets[symbol]) < band:
                    continue
                amount = min(cash, max(target_value - current_value, 0.0))
                if amount <= 0:
                    continue
                execution_price = price * (1 + SLIPPAGE_RATE)
                bought_units = amount * (1 - FEE_RATE) / execution_price if execution_price > 0 else 0.0
                units[symbol] = units.get(symbol, 0.0) + bought_units
                cash -= amount
                held.add(symbol)
                trades.append(app.Trade(current_date.isoformat(), "buy", symbol, execution_price, amount, bought_units))

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
    idx = next((index for index, day in enumerate(result.dates) if day >= start_date), None)
    if idx is None or idx >= len(result.dates) - 2:
        return {"annualized": None, "max_drawdown": None, "annual_volatility": None, "sharpe": None, "total": None}
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(result.dates[idx:], result.values[idx:])
    return {"annualized": annualized, "max_drawdown": max_dd, "annual_volatility": annual_vol, "sharpe": sharpe, "total": total}


def window_metrics(result: app.BacktestResult, start: str, end: str) -> dict[str, float | None]:
    start_date = app.parse_date(start)
    end_date = app.parse_date(end)
    points = [(day, value) for day, value in zip(result.dates, result.values) if start_date <= day <= end_date]
    if len(points) < 30:
        return {"annualized": None, "max_drawdown": None, "annual_volatility": None, "sharpe": None, "total": None}
    days = [day for day, _value in points]
    values = [value for _day, value in points]
    total, annualized, max_dd, annual_vol, sharpe = app.performance_metrics(days, values)
    return {"annualized": annualized, "max_drawdown": max_dd, "annual_volatility": annual_vol, "sharpe": sharpe, "total": total}


def max_drawdown_window(result: app.BacktestResult) -> dict[str, Any]:
    peak = result.values[0]
    peak_i = 0
    worst = 0.0
    worst_peak = 0
    worst_trough = 0
    for index, value in enumerate(result.values):
        if value > peak:
            peak = value
            peak_i = index
        dd = (peak - value) / peak if peak > 0 else 0.0
        if dd > worst:
            worst = dd
            worst_peak = peak_i
            worst_trough = index
    return {
        "peak_date": result.dates[worst_peak].isoformat(),
        "trough_date": result.dates[worst_trough].isoformat(),
        "max_drawdown": worst,
    }


def specs() -> list[EngineSpec]:
    out = [EngineSpec("baseline_current_1pct", "Current App-equivalent engine, 1% fee.", "baseline", 0.0, 0.0, 0.0)]
    for mode in ["treasury_idle", "cashplus_idle", "cashplus_credit", "all_defensive"]:
        for idle_fraction in [0.33, 0.50, 1.00]:
            for cap in [0.30, 0.60, 1.00]:
                out.append(
                    EngineSpec(
                        f"{mode}_idle{int(idle_fraction*100)}_cap{int(cap*100)}",
                        "Fill otherwise idle capital with a guarded low-correlation sleeve.",
                        mode,
                        idle_fraction,
                        cap,
                        min(0.60, cap),
                    )
                )
    for mode in ["duration_riskoff", "cashplus_idle", "cashplus_credit", "all_defensive"]:
        for scale in [0.35, 0.55]:
            for cap in [0.50, 0.80, 1.00]:
                out.append(
                    EngineSpec(
                        f"{mode}_stress_scale{int(scale*100)}_cap{int(cap*100)}",
                        "Cut equity risk only during broad stress and route the freed budget to defense.",
                        mode,
                        1.0,
                        cap,
                        min(0.70, cap),
                        stress_equity_scale=scale,
                        stress_only=False,
                    )
                )
    for mode in ["cashplus_idle", "all_defensive"]:
        for rebalance in [63, 126]:
            out.append(
                EngineSpec(
                    f"{mode}_quarterly_idle50_cap60_rb{rebalance}",
                    "Slower defensive sleeve to reduce 1% fee drag.",
                    mode,
                    0.50,
                    0.60,
                    0.60,
                    rebalance_sessions=rebalance,
                    no_trade_band=0.08,
                )
            )
    return out


def row_for(spec: EngineSpec, result: app.BacktestResult) -> dict[str, Any]:
    return {
        "name": spec.name,
        "thesis": spec.thesis,
        "spec": spec.__dict__,
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
            "post_2024": slice_metrics(result, "2024-01-01"),
        },
        "stress": {
            "2008": window_metrics(result, "2007-10-01", "2009-03-31"),
            "2015_china": window_metrics(result, "2015-06-01", "2016-02-29"),
            "2020_covid": window_metrics(result, "2020-02-01", "2020-04-30"),
            "2022_rates": window_metrics(result, "2022-01-01", "2022-12-31"),
        },
        "drawdown_window": max_drawdown_window(result),
        "latest_trades": [(trade.date, trade.action, trade.symbol, round(trade.cash_amount, 2)) for trade in result.trades[-12:]],
    }


def coverage_summary() -> dict[str, Any]:
    out: dict[str, Any] = {}
    for symbol, yahoo in YAHOO_SYMBOLS.items():
        rows = fetch_yahoo_adjusted(symbol)
        out[symbol] = {"source": yahoo, "start": rows[0][0].isoformat(), "end": rows[-1][0].isoformat(), "count": len(rows)}
    return out


def main() -> None:
    rows: list[dict[str, Any]] = []
    errors: dict[str, str] = {}
    for spec in specs():
        try:
            rows.append(row_for(spec, run_engine(spec)))
        except Exception as exc:
            errors[spec.name] = repr(exc)
            print(f"ERR {spec.name}: {exc}", flush=True)

    rows.sort(key=lambda row: (row["full"]["sharpe"] or -9.0, row["full"]["annualized"] or -9.0), reverse=True)
    out_path = SPIKE_DIR / "results.json"
    out_path.write_text(
        json.dumps(
            {
                "generated_at": datetime.now().isoformat(timespec="seconds"),
                "fee_rate": FEE_RATE,
                "slippage_rate": SLIPPAGE_RATE,
                "coverage": coverage_summary(),
                "errors": errors,
                "rows": rows,
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    print(f"WROTE {out_path}")
    print("name | ann/dd/sharpe/vol | post2020 ann/sh | last10 ann/sh | post2024 ann/sh | trades | dd window")
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
